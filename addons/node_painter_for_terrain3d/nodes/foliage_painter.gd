@tool
## Uses the shapes to create transforms for foliage and places them in the world. Useful for creating sparce to medium density foliage. For higher densities like grass consider unsing GrassPainter instead.
## Nodes are processed in order of the SceneTree.
class_name FoliagePainter
extends NodePainterContainer

@export_tool_button("Regenerate", "Reload") var button := update_terrain

## One Foliage Painter Node can only handle 32 different scenes due to limitations with the compute shader.
@export var meshes : Array[NodePainterMesh] = []:
	set(value):
		if value.size() < 33:
			meshes = value
		else:
			meshes = value.slice(0, 32)
## Defines the relative size between Terrain3D regions and chunks used for the foliage system.
@export_enum("1:1", "4:2", "9:3", "16:4") var chunks_per_region : int = 2

@export_placeholder("Fixed Seed") var gen_seed: String = "":
	set(value):
		gen_seed = value

## DO NOT CHANGE! It need's to be visible in order to be stored correctly
@export var output_node: Node

@export_storage var generated_transforms : Dictionary[NodePainterMesh, Dictionary]
var rd_device: RenderingDevice
var shader: RID
const compute_shader_file := preload("res://addons/node_painter_for_terrain3d/resources/foliage_transform_compute.glsl")
static var billboard_generator := preload("res://addons/node_painter_for_terrain3d/utility/billboard_generator_node.tscn")
static var billboard_shader := preload("res://addons/node_painter_for_terrain3d/utility/billboard.gdshader")
const output_node_script := preload("res://addons/node_painter_for_terrain3d/utility/chunk_management.gd")

var _worker_id : int
var _task_ongoing := false
@onready var _mutex := Mutex.new()


func _enter_tree():
	container_type = ContainerType.TYPE_FOLIAGE
	rd_device = RenderingServer.create_local_rendering_device()
	var spriv := compute_shader_file.get_spirv()
	shader = rd_device.shader_create_from_spirv(spriv, "FoliageTransformCompute")
	
	if Engine.is_editor_hint() and not terrainNode.data.height_maps_changed.is_connected(update_terrain):
		terrainNode.data.height_maps_changed.connect(update_terrain)

func _ready():	
	if !is_instance_valid(output_node):
		output_node = Node.new()
		output_node.set_name("Output")
		output_node.set_script(output_node_script)
		output_node.setup(terrainNode, chunks_per_region, _get_max_instance_radius())
		add_child(output_node, true)
	
	_procedual_update()

func _exit_tree():
	if _task_ongoing:
		WorkerThreadPool.wait_for_group_task_completion(_worker_id)
		_task_ongoing = false
	
	# Perform GPU cleanup
	if rd_device == null:
		return
	
	rd_device.free_rid(shader)
	rd_device.free()
	rd_device = null

func _procedual_update() -> void:
	if _task_ongoing:
		WorkerThreadPool.wait_for_group_task_completion(_worker_id)
		_task_ongoing = false
	
	# Create Computation Pipeline
	var rids : Array[RID] = []
	var pipeline := rd_device.compute_pipeline_create(shader)
	rids.push_back(pipeline)
	var transform_buffers : Dictionary[NodePainterMesh, RID] = {}
	
	# Read the Shape Data
	var shape_data := get_shape_data_buffer(true)
	var shape_buffer := rd_device.storage_buffer_create(shape_data["ShapeBuffer"].size(), shape_data["ShapeBuffer"])
	rids.push_back(shape_buffer)
	
	var shape_uniform := RDUniform.new()
	shape_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	shape_uniform.binding = 1
	shape_uniform.add_id(shape_buffer)
	
	var seed : int
	if gen_seed.length() > 0:
		seed = gen_seed.to_int()
		if seed == 0:
			seed = gen_seed.hash()
	else:
		seed = randi()
	var seed_bytes := PackedInt32Array([seed]).to_byte_array()
	
	if terrainNode and shape_data["ShapeBuffer"].size() > 8:
		_mutex.lock()
		transform_buffers = {}
		_mutex.unlock()
		
		# retrive Region data
		var regions := terrainNode.data.get_regions_active()
		var rg_size := terrainNode.region_size
		
		var region_settings : PackedByteArray = PackedFloat32Array([1.0 / terrainNode.vertex_spacing, terrainNode.vertex_spacing,
				rg_size, 1.0/rg_size, (rg_size * terrainNode.vertex_spacing)/chunks_per_region]).to_byte_array()
		region_settings.append_array(PackedInt32Array([32, terrainNode.material.world_background]).to_byte_array())
		region_settings.append_array(terrainNode.data.get_region_map().to_byte_array())
		var terrain_settings_buffer := rd_device.storage_buffer_create(region_settings.size(), region_settings)
		rids.push_back(terrain_settings_buffer)
		
		var terrain_settings_uniform := RDUniform.new()
		terrain_settings_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		terrain_settings_uniform.binding = 0
		terrain_settings_uniform.add_id(terrain_settings_buffer)
		
		# Get Heightmaps
		var heightmaps := terrainNode.data.get_maps(Terrain3DRegion.TYPE_HEIGHT)
		var first_heightmap : Image = heightmaps.front()
		var img_data : Array[PackedByteArray] = []
		for h: Image in heightmaps:
			img_data.push_back(h.get_data())
		
		var hm_sampler := RDSamplerState.new()
		hm_sampler.repeat_u = 3
		hm_sampler.repeat_v = 3
		hm_sampler.repeat_w = 3
		var ssid := rd_device.sampler_create(hm_sampler)
		rids.push_back(ssid)
		
		var heightmap_format := RDTextureFormat.new()
		heightmap_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
		heightmap_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
		heightmap_format.height = first_heightmap.get_size().y
		heightmap_format.width = first_heightmap.get_size().x
		heightmap_format.array_layers = max(heightmaps.size(), 1)
		heightmap_format.mipmaps = max(first_heightmap.get_mipmap_count(), 1)
		heightmap_format.is_discardable = true
		heightmap_format.usage_bits = \
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		
		var heightmaps_rid := rd_device.texture_create(heightmap_format, RDTextureView.new(), img_data)
		
		var heightmaps_uniform := RDUniform.new()
		heightmaps_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		heightmaps_uniform.binding = 2
		heightmaps_uniform.add_id(ssid)
		heightmaps_uniform.add_id(heightmaps_rid)
		rids.push_back(heightmaps_rid)
		
		# Persistent Uniform Set
		var persistent_set := rd_device.uniform_set_create([terrain_settings_uniform, shape_uniform, heightmaps_uniform], shader, 1)
		
		var id : int = 0
		for ins: NodePainterMesh in meshes:
			var grid_size : int = roundi(rg_size*ins.density)
			var instance_distance := float(rg_size / (grid_size + 1.0))
			
			
			var instance_parameters := PackedInt32Array([id]).to_byte_array()
			instance_parameters.append_array( PackedFloat32Array([instance_distance, ins.slope_restriction, ins.terrain_normal_influence, ins.random_offset, ins.random_scale, ins.condition_randomness]).to_byte_array() )
			instance_parameters.append_array(seed_bytes)
			
			var ipb := rd_device.storage_buffer_create(instance_parameters.size(), instance_parameters)
			rids.push_back(ipb)
			id += 1
			
			var instance_parameters_uniform := RDUniform.new()
			instance_parameters_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			instance_parameters_uniform.binding = 1
			instance_parameters_uniform.add_id(ipb)
			
			var tb_uniform := RDUniform.new()
			var tb_noByte := PackedInt32Array([0])
			tb_noByte.resize(grid_size*grid_size*regions.size()*10 + 1)
			var tb := tb_noByte.to_byte_array()
			
			var tb_rid := rd_device.storage_buffer_create(tb.size(), tb)
			transform_buffers[ins] = tb_rid
			rids.push_back(tb_rid)
			tb_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			tb_uniform.binding = 0
			tb_uniform.add_id(tb_rid)
			
			var offset := Vector2.ONE * (instance_distance/2.0)
			var region_locations := PackedVector2Array([])
			for region: Terrain3DRegion in regions:
				region_locations.push_back(Vector2(region.location) * rg_size + offset)
			
			var r_loc_buffer := region_locations.to_byte_array()
			var gl_rid := rd_device.storage_buffer_create(r_loc_buffer.size(), r_loc_buffer)
			rids.push_back(gl_rid)
			var region_loc_uniform := RDUniform.new()
			region_loc_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			region_loc_uniform.binding = 2
			region_loc_uniform.add_id(gl_rid)
				
			var individual_set := rd_device.uniform_set_create([tb_uniform, instance_parameters_uniform, region_loc_uniform], shader, 0)
				
			var compute_list := rd_device.compute_list_begin()
			rd_device.compute_list_bind_compute_pipeline(compute_list, pipeline)
			rd_device.compute_list_bind_uniform_set(compute_list, individual_set, 0)
			rd_device.compute_list_bind_uniform_set(compute_list, persistent_set, 1)
			rd_device.compute_list_dispatch(compute_list, grid_size, grid_size, regions.size())
			rd_device.compute_list_end()
		
		rd_device.submit()
		# Free previous Output
		for c: Node in output_node.get_children():
			c.call_deferred(&"free")
		
		_run_billboard_checks()
		
		rd_device.sync()
		
		var dic : Dictionary[NodePainterMesh, PackedByteArray] = {}
		for instance: NodePainterMesh in transform_buffers.keys():
			var value : PackedByteArray = rd_device.buffer_get_data(transform_buffers[instance])
			
			_mutex.lock()
			dic[instance] = value
			_mutex.unlock()
		
		if ProjectSettings.get_setting(NodePainter.multithreading_setting):
			_worker_id = WorkerThreadPool.add_group_task(_generate_transforms_from_buffer.bind(dic), transform_buffers.size(), -1, true, "NodePainter Buffer Decoding")
			_task_ongoing = true
		else:
			for i in range(0, transform_buffers.size()):
				_generate_transforms_from_buffer(i, dic)
	
		for rid in rids:
			rd_device.free_rid(rid)

func _generate_transforms_from_buffer(idx: int, buffers: Dictionary[NodePainterMesh, PackedByteArray]) -> void:
	# Retrive Parameters
	var instance : NodePainterMesh = buffers.keys()[idx]
	var buffer := buffers[instance]
	
	var points := buffer.decode_s32(0)
	var data := buffer.slice(4).to_float32_array()
	
	var t_out : Array[Transform3D] = []
	var c_out : Array[Vector2i] = []
	
	# Calculate full Transforms from compute results
	var seed : int
	if gen_seed.length() > 0:
		seed = gen_seed.to_int()
	if seed == 0:
		seed = gen_seed.hash()
	else:
		seed = randi()
	var _rng := RandomNumberGenerator.new()
	
	for i in range(0, points):
		var real_i := i * 10
		var pos := Vector3(data[real_i], data[real_i + 1], data[real_i + 2])
		var up := Vector3(data[real_i + 3], data[real_i + 4], data[real_i + 5]).normalized()
		
		if instance.randomize_rotation > 0.001:
			_rng.seed = floori((pos.x + pos.z) * 214.42 + seed)
			var theta := _rng.randf_range(0, 2*PI)
			var y := _rng.randf_range(-1.0, 1.0)
			var k := sqrt(1.0-y*y)
			
			var direction := Vector3(
				k * cos(theta),
				k * sin(theta),
				y
			)
			up = lerp(up, direction, instance.randomize_rotation).normalized()
		
		var side := Vector3(0.0, -up.z, up.y)
		var forward := up.cross(side)
		var base := Basis(forward, up, side).rotated(up, data[real_i + 6])
		
		base = base.orthonormalized() * data[real_i + 7]
		var trans := Transform3D(base, pos)
		
		var chunk := Vector2i(int(data[real_i + 8]), int(data[real_i + 9]))
		t_out.push_back(trans)
		c_out.push_back(chunk)
	
	var add_dic: Dictionary[String, Array] = {"transforms": t_out, "chunks": c_out}
	
	# Scene instantiation and analysis
	var instance_node : Node3D = instance.scene.instantiate()
	var billboard_found := instance.generate_billboards
	var scene_name := instance_node.name
	var collision_shapes : Dictionary[Node3D, Array] = {}
	var range : float = ((terrainNode.vertex_spacing * terrainNode.region_size) / chunks_per_region) * (-0.5 + instance.billboard_radius)
	
	for sub_node: Node3D in instance_node.find_children("*", "Node3D"):
			# Visibility Range limit
			if sub_node is GeometryInstance3D:
				sub_node.visibility_range_end = range
			
			# Billboard recognition
			if billboard_found == false and sub_node is MeshInstance3D:
				var verticies : int = sub_node.mesh.get_faces().size()
				if verticies <= 12:
					billboard_found = true
					instance.billboard_mesh = sub_node.mesh
					sub_node.free()
			
			if sub_node is StaticBody3D:
				collision_shapes[sub_node] = []
				for shapes in sub_node.find_children("*", "CollisionShape3D"):
					collision_shapes[sub_node].push_back(shapes)
				for shapes in sub_node.find_children("*", "CollisionPolygon3D"):
					collision_shapes[sub_node].push_back(shapes)
	
	var billboard_instance : MeshInstance3D
	if instance.instancing > 1 and instance.max_billboard_distance > 0.001 and billboard_found:
		billboard_instance = MeshInstance3D.new()
		billboard_instance.visibility_range_end = instance.max_billboard_distance
		billboard_instance.visibility_range_begin = range - 5.0
		billboard_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		billboard_instance.layers = instance.billboard_render_layer
		billboard_instance.extra_cull_margin = 2.0
		billboard_instance.mesh = instance.billboard_mesh

	
	
	# Generate MeshInstances and add them to the scene tree
	var node_reference : Array[Node3D] = []
	if instance.instancing > 0:
		idx = 0
		for t: Transform3D in t_out:
			var c : Node3D = instance_node.duplicate(7)
			output_node.call_deferred(&"add_child", c, true)
			c.set_deferred(&"global_transform", t)
			c.call_deferred(&"set_owner", output_node)
			c.set_meta(&"chunk", c_out[idx])
			
			if instance.instancing == NodePainterMesh.grouping.INSTANCE_SCENES_BILLBOARDS:
				node_reference.push_back(c)
			
			idx += 1
			
			if billboard_instance:
				var bill_instance : MeshInstance3D = billboard_instance.duplicate(7)
				if bill_instance.mesh == null:
					var callable := _delayed_mmi_mesh_set.bind(instance, billboard_instance)
					if not instance._billboard_changed.is_connected(callable):
						instance._billboard_changed.connect(callable)
				
				# Connect Free and Visibility changes
				c.visibility_changed.connect(
					(func(n,b: MeshInstance3D): if b.is_inside_tree(): _billboard_instance_hide.rpc(n,b) ).bind(c, bill_instance), 1)
				c.tree_exited.connect(
					(func(b: MeshInstance3D): if b.is_inside_tree(): _billboard_instance_free.rpc(b) ).bind(bill_instance))
				
				output_node.call_deferred(&"add_child", bill_instance, true)
				bill_instance.set_deferred(&"global_transform", t)
				bill_instance.call_deferred(&"set_owner", output_node)
	
	# Add Multimeshes to the scnene tree
	var vis_dis_offset := (terrainNode.region_size * terrainNode.vertex_spacing) / chunks_per_region
	if instance.instancing < 2 and (instance.generate_billboards or billboard_instance): # Distant Billboard
		var mmis := _get_chunk_MMI(instance, add_dic, true, instance.billboard_mesh, scene_name)
		for multi_mesh_instance: MultiMeshInstance3D in mmis:
			multi_mesh_instance.visibility_range_end = instance.max_billboard_distance + vis_dis_offset
			multi_mesh_instance.visibility_range_begin = range - 4.0 - vis_dis_offset * 2.0
			
			if instance.generate_billboards:
				var callable := _delayed_mmi_mesh_set.bind(instance, multi_mesh_instance)
				if not instance._billboard_changed.is_connected(callable):
					instance._billboard_changed.connect(callable)
			
			# Connect visibilty changes of individual nodes to their billbords. Array only filled if INSTANCE_SCENES_BILLBOARDS
			var index := 0
			for high_instance: Node3D in node_reference:
				high_instance.visibility_changed.connect(
					(func(s: Node3D, i: int, mm: MultiMesh): 
						if multi_mesh_instance.is_inside_tree(): _billboard_mmi_visibility_change.rpc(mm, i, s.visible)
						).bind(high_instance, index, multi_mesh_instance.multimesh), 1
				)
				high_instance.tree_exited.connect(
					(func(i: int, mm: MultiMesh): 
						if multi_mesh_instance.is_inside_tree(): _billboard_mmi_visibility_change.rpc(mm, i, false) 
						).bind(index, multi_mesh_instance.multimesh)
				)
				index += 1
			
			output_node.call_deferred(&"add_child", multi_mesh_instance, true)
			multi_mesh_instance.call_deferred(&"set_owner", output_node)
		
	
	if instance.instancing == 0: # Close Up Scene
		for mesh: MeshInstance3D in instance_node.find_children("*", "MeshInstance3D", true):
			var mmis := _get_chunk_MMI(instance, add_dic, false, mesh.mesh, scene_name + "-" + mesh.name, mesh.transform)
			for mmi: MultiMeshInstance3D in mmis:
				mmi.visibility_range_end = mesh.visibility_range_end + vis_dis_offset
				mmi.layers = mesh.layers
				mmi.material_override = mesh.material_override
				mmi.material_overlay = mesh.material_overlay
				mmi.cast_shadow = mesh.cast_shadow
				mmi.gi_mode = mesh.gi_mode
				mmi.sorting_offset = mesh.sorting_offset
				
				output_node.call_deferred(&"add_child", mmi, true)
				mmi.call_deferred(&"set_owner", output_node)
	

		var collision_instances := _get_chunk_SB(instance, add_dic, collision_shapes)
		for body: StaticBody3D in collision_instances:
			output_node.call_deferred(&"add_child", body, true)
			body.call_deferred(&"set_owner", output_node)
	
	_mutex.lock()
	(func(): generated_transforms[instance] = add_dic).call_deferred()
	_mutex.unlock()


func _delayed_mmi_mesh_set(ins: NodePainterMesh, node) -> void:
	if is_instance_valid(node):
		if node is MultiMeshInstance3D:
			node.multimesh.set_deferred(&"mesh", ins.billboard_mesh)
		elif node is MeshInstance3D:
			node.set_deferred(&"mesh", ins.billboard_mesh)


func _run_billboard_checks() -> void:
	for mesh: NodePainterMesh in meshes:
		if mesh.generate_billboards and mesh.max_billboard_distance > 0.0001:
			if not mesh.billboard_mesh:
				var gen := billboard_generator.instantiate()
				gen.sampling_done.connect(_retrive_billboards.bind(mesh))
				call_deferred(&"add_child", gen, true)
				gen.call_deferred(&"sample_billboard_arrays", mesh.scene, mesh.billboard_cull_margin, mesh.billboard_views)

func _retrive_billboards(dic: Dictionary, instance: NodePainterMesh) -> void:
	instance.billboard_map_albedo = dic["albedo"]
	instance.billboard_map_normal = dic["normal"]
	
	var fade := (float(terrainNode.region_size) * terrainNode.vertex_spacing / chunks_per_region) * (-0.5 + instance.billboard_radius)
	var mat := ShaderMaterial.new()
	mat.shader = billboard_shader
	mat.set_shader_parameter(&"views", instance.billboard_views)
	mat.set_shader_parameter(&"fade_distance", fade)
	mat.set_shader_parameter(&"texture_albedo", instance.billboard_map_albedo)
	mat.set_shader_parameter(&"texture_normal", instance.billboard_map_normal)
	
	var mesh := QuadMesh.new()
	mesh.size = dic["size"]
	mesh.center_offset.y = dic["y_offset"]
	mesh.material = mat
	
	instance.billboard_mesh = mesh

## Generates a MultiMeshInstance3D from the given pramaters for a specififc region that can be added to the scene tree
func _get_chunk_MMI(ins: NodePainterMesh, t_dic: Dictionary[String, Array], for_billboards := false, mesh: Mesh = null, scene_name := "Node", local_transform := Transform3D.IDENTITY) -> Array[MultiMeshInstance3D]:
	# Grouping
	var dickpick := _mmi_chunking(t_dic, for_billboards, local_transform)
	# MultiMesh generation
	var mmis : Array[MultiMeshInstance3D] = []
	for chunk in dickpick.keys():
		var transforms : Array[Transform3D] = dickpick[chunk]
		var chunk_coord := (Vector2(chunk) * terrainNode.region_size * terrainNode.vertex_spacing) / float(chunks_per_region)
		if for_billboards:
			chunk_coord *= 0.5
		
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.instance_count = transforms.size()
		mm.visible_instance_count = mm.instance_count
		if mesh:
			mm.mesh = mesh
		else:
			mm.mesh = PlaceholderMesh.new()
		
		var i := 0
		for t in transforms:
			t.origin -= Vector3(chunk_coord.x, 0.0, chunk_coord.y)
			mm.set_instance_transform(i, t)
			i += 1
		
		var mmi := MultiMeshInstance3D.new()
		mmis.push_back(mmi)
		mmi.multimesh = mm
		mmi.position = Vector3(chunk_coord.x, 0.0, chunk_coord.y)
		mmi.name = str(chunk)+scene_name+ ("Billboards" if for_billboards else "-MMI")
		
		if for_billboards:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.layers = ins.billboard_render_layer
		
	return mmis

func _get_chunk_SB(ins: NodePainterMesh, t_dic: Dictionary[String, Array], c_dic: Dictionary[Node3D, Array]) -> Array[StaticBody3D]:
	var chunked_transfroms := _mmi_chunking(t_dic, false)
	var return_array : Array[StaticBody3D] = []
	
	for chunk: Vector2i in chunked_transfroms.keys():
		var chunk_coord := (Vector2(chunk) * terrainNode.region_size * terrainNode.vertex_spacing * 0.5) / float(chunks_per_region)
		var transforms : Array[Transform3D] = chunked_transfroms[chunk]
		
		for b: StaticBody3D in c_dic.keys():
			var body := StaticBody3D.new()
			body.position.x = chunk_coord.x
			body.position.z = chunk_coord.y
			body.collision_layer = b.collision_layer
			body.collision_mask = b.collision_mask
			body.collision_priority = b.collision_priority
			body.physics_material_override = b.physics_material_override
			body.constant_angular_velocity = b.constant_angular_velocity
			body.constant_linear_velocity = b.constant_linear_velocity
			body.disable_mode = b.disable_mode
			body.axis_lock_angular_x = b.axis_lock_angular_x
			body.axis_lock_angular_y = b.axis_lock_angular_y
			body.axis_lock_angular_z = b.axis_lock_angular_z
			body.axis_lock_linear_x = b.axis_lock_linear_x
			body.axis_lock_linear_y = b.axis_lock_linear_y
			body.axis_lock_linear_z = b.axis_lock_linear_z
			
			for s: Node3D in c_dic[b]:
				for t in transforms:
					var shape: Node3D
					if s is CollisionPolygon3D and !s.disabled:
						shape = CollisionPolygon3D.new()
						shape.polygon = s.polygon
						shape.depth = s.depth
						shape.margin = s.margin
					elif s is CollisionShape3D and !s.disabled:
						shape = CollisionShape3D.new()
						shape.shape = s.shape
					
					t.origin -= Vector3(chunk_coord.x, 0.0, chunk_coord.y)
					t *= b.transform
					t *= s.transform
					
					shape.transform = t
					body.add_child(shape, true)
			
			body.set_meta(&"chunk", chunk)
			return_array.push_back(body)
	
	return return_array

func _mmi_chunking(t_dic: Dictionary[String, Array], for_billboards := false, local_transform := Transform3D.IDENTITY) -> Dictionary[Vector2i, Array]:
	var return_dic : Dictionary[Vector2i, Array] = {}
	var idx := 0
	for t: Transform3D in t_dic["transforms"]:
		var chunk : Vector2i = t_dic["chunks"][idx]
		if for_billboards:
			chunk /= 2
		
		if return_dic.has(chunk):
			return_dic[chunk].push_back(t * local_transform)
		else:
			var arrrr : Array[Transform3D] = [t * local_transform]
			return_dic[chunk] = arrrr
		idx += 1
	
	return return_dic

func _get_max_instance_radius() -> int:
	var r := 1
	for m: NodePainterMesh in meshes:
		r = max(m.billboard_radius, r)
	return r


@rpc("any_peer", "call_local", "reliable")
func _billboard_instance_hide(node: Node3D, billboard: MeshInstance3D) -> void:
	if is_instance_valid(billboard):
		billboard.visible = node.visible

@rpc("any_peer", "call_local", "reliable")
func _billboard_instance_free(billboard: MeshInstance3D) -> void:
	if is_instance_valid(billboard):
		billboard.queue_free()

@rpc("any_peer", "call_local", "reliable")
func _billboard_mmi_visibility_change(multimesh: MultiMesh, index: int, visibile:= false) -> void:
	var meta_str := "hidden_transfrom_"+str(index)
	
	if visibile and multimesh.has_meta(meta_str):
		var hidden_transform : Transform3D = multimesh.get_meta(meta_str, Transform3D.IDENTITY)
		var replacer_transform := multimesh.get_instance_transform(index)
		multimesh.call_deferred(&"set_instance_transform", multimesh.visible_instance_count, replacer_transform)
		multimesh.call_deferred(&"set_instance_transform", index, hidden_transform)
		multimesh.call_deferred(&"remove_meta", meta_str)
		
		multimesh.visible_instance_count += 1
		
	elif !multimesh.has_meta(meta_str):
		var replacer_transform := multimesh.get_instance_transform(multimesh.visible_instance_count - 1)
		var removed_transform := multimesh.get_instance_transform(index)
		multimesh.call_deferred(&"set_meta", meta_str, removed_transform)
		
		multimesh.call_deferred(&"set_instance_transform", index, replacer_transform)
		multimesh.set_deferred(&"visible_instance_count", multimesh.visible_instance_count - 1)
