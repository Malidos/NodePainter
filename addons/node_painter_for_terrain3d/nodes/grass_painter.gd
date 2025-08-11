@tool
##Spawns the Mesh under the given cirumstances.
##Updates to the particles happen only when a chunk becomes visible, so changes might not happen instantly
class_name GrassPainter
extends NodePainterContainer

var rd_device: RenderingDevice
var shader: RID
const compute_shader_file := preload("res://addons/node_painter_for_terrain3d/resources/particle_sdf_compute.glsl")


@export var shapes_destroy_instances: bool = false:
	set(value):
		shapes_destroy_instances = value
		if is_node_ready(): 
			update_terrain()

@export var mesh: Mesh:
	set(value):
		mesh = value
		call_deferred("update_grid")

@export_flags_3d_render var layers := 1
@export var shadow_casting : GeometryInstance3D.ShadowCastingSetting = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

@export_subgroup("Chunck Settings")
## Used for Chunk calculation. Transitional Effects have to be provided by the Mesh itself.
@export_range(5.0, 100.0) var view_distance: float = 20.0:
	set(value):
		view_distance = value
		grid_size = ceili(view_distance / chunk_size)
		call_deferred("update_grid")

@export_range(6.0, 80.0, 2.0) var chunk_size: float = 16.0:
	set(value):
		chunk_size = value
		grid_size = ceili(view_distance / chunk_size)
		call_deferred("update_grid")

@export_range(0.125, 2.0) var instance_spacing := 0.2:
	set(value):
		var new := clamp(round(value * 16.0) / 16.0, 0.125, 2.0)
		if new != instance_spacing:
			call_deferred("update_grid")
		instance_spacing = new

@export_subgroup("Randomness")
@export_placeholder("Fixed Seed") var gen_seed: String = "":
	set(value):
		gen_seed = value
		call_deferred("update_grid")
		
@export_range(0.0, 2.0, 0.01, "or_greater") var position_randomness := 0.2:
	set(value):
		position_randomness = value
		call_deferred("update_grid")

@export_range(0.0, 2.0) var random_scale := 0.05:
	set(value):
		random_scale = value
		call_deferred("update_grid")

@export_range(0.0, 1.0) var condition_dithering := 0.1:
	set(value):
		condition_dithering = value
		call_deferred("update_grid")

@export_subgroup("Placement Restricions")
@export_range(-20.0,100.0,0.1,"or_less") var min_height: float = -5.0:
	set(value):
		min_height = value
		call_deferred("update_grid")

@export_flags_2d_navigation var disallowed_textures: int = 0:
	set(value):
		disallowed_textures = value
		call_deferred("update_grid")
		
@export_range(0.01, 1.0, 0.01) var normal_influence := 0.8:
	set(value):
		normal_influence = value
		call_deferred("update_grid")
		
## Negative angles mean particles only appear on a slope.
@export_range(-1.0,1.0,0.05) var slope := 0.5:
	set(value):
		slope = value
		call_deferred("update_grid")
		
## Can be accesed in the Instance Shader as COLOR.
@export var color_sampling := true:
	set(value):
		color_sampling = value
		call_deferred("update_grid")
		
@export_range(0.0,4.0,0.1) var color_blur := 0.5:
	set(value):
		color_blur = value
		call_deferred("update_grid")

@export_storage var _sdf_maps: Texture2DArray
@export_storage var process_material: ShaderMaterial

const gpu_shader : Shader = preload("res://addons/node_painter_for_terrain3d/resources/particle_process.gdshader")
const particle_fps := 20
var last_pos := Vector2i.ZERO
@export var particle_instances : Dictionary[Vector2i, GPUParticles3D]
var grid_size : int = 1
var rows : int = 1
var __create_new_grid := false



func _enter_tree():
	if Engine.is_editor_hint():
		container_type = ContainerType.TYPE_PARTICLES
		rd_device = RenderingServer.create_local_rendering_device()
		var spriv := compute_shader_file.get_spirv()
		shader = rd_device.shader_create_from_spirv(spriv, "GrassSDFMapCompute")
		terrainNode.data.height_maps_changed.connect(update_grid)
	
	if process_material == null:
		var gpu_mat := ShaderMaterial.new()
		gpu_mat.shader = gpu_shader
		process_material = gpu_mat


func _physics_process(_delta):
	if is_instance_valid(terrainNode):
		var camera := terrainNode.get_camera()
		if camera:
			var clipped_pos := Vector2i((Vector2(camera.global_position.x, camera.global_position.z) / chunk_size).snapped(Vector2.ONE))
			if clipped_pos != last_pos:
				_reposition_grid(clipped_pos)
				last_pos = clipped_pos
		
		if __create_new_grid:
			_create_grid()
			__create_new_grid = false



func _exit_tree():
	terrainNode.data.height_maps_changed.disconnect(update_grid)
	_destroy_grid()
	# Perform GPU cleanup
	if rd_device == null:
		return
	
	rd_device.free_rid(shader)
	rd_device.free()
	rd_device = null


func update_grid() -> void:
	__create_new_grid = true

# -- SDF Map generation
func _procedual_update() -> void:
	# Create Computation Pipeline
	var pipeline := rd_device.compute_pipeline_create(shader)
	var sdfmaps : Dictionary[Terrain3DRegion, RID] = {}
	var maps_data : Dictionary[Terrain3DRegion, Image] = {}
	var rids : Array[RID] = []
	rids.push_back(pipeline)
	
	# Read the Shape Data
	var shape_data := get_shape_data_buffer(true)
	var shape_buffer := rd_device.storage_buffer_create(shape_data["ShapeBuffer"].size(), shape_data["ShapeBuffer"])
	rids.push_back(shape_buffer)
	
	var shape_uniform := RDUniform.new()
	shape_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	shape_uniform.binding = 2
	shape_uniform.add_id(shape_buffer)
	
	if terrainNode and shape_data["ShapeBuffer"].size() > 8:
		# retrive Region data
		var regions := terrainNode.data.get_regions_active()
		var rg_size := 256
		if regions.size() > 0:
			rg_size = regions.front().region_size
		
		for region: Terrain3DRegion in regions:
			# Generate Region specific parameters
			var region_data := PackedFloat32Array([float(region.location.x), float(region.location.y), region.vertex_spacing, 1.0 if shapes_destroy_instances else 0.0]).to_byte_array()
			var region_buffer := rd_device.storage_buffer_create(region_data.size(), region_data)
			rids.push_back(region_buffer)
			
			var region_uniform := RDUniform.new()
			region_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			region_uniform.binding = 1
			region_uniform.add_id(region_buffer)
			
			
			# Generate SDF Map parameter
			var sdfmap_format := RDTextureFormat.new()
			sdfmap_format.format = RenderingDevice.DATA_FORMAT_R8_UNORM
			sdfmap_format.width = rg_size
			sdfmap_format.height = rg_size
			sdfmap_format.usage_bits = \
				RenderingDevice.TEXTURE_USAGE_STORAGE_BIT + \
				RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT + \
				RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
			
			var sdfmap_image := Image.create_empty(rg_size, rg_size, false, Image.FORMAT_R8)
			sdfmap_image.fill(Color.GRAY)
			
			var sdfmap_rid := rd_device.texture_create(sdfmap_format, RDTextureView.new(), [sdfmap_image.get_data()])
			rids.push_back(sdfmap_rid)
			sdfmaps[region] = sdfmap_rid
			maps_data[region] = sdfmap_image
			
			var sdfmap_uniform := RDUniform.new()
			sdfmap_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			sdfmap_uniform.binding = 0
			sdfmap_uniform.add_id(sdfmap_rid)
			
			# Create Unfiorm Set
			var region_set := rd_device.uniform_set_create([sdfmap_uniform, region_uniform, shape_uniform], shader, 0)
			
			# Attatch the region to the compute pipeline
			var compute_list := rd_device.compute_list_begin()
			rd_device.compute_list_bind_compute_pipeline(compute_list, pipeline)
			rd_device.compute_list_bind_uniform_set(compute_list, region_set, 0)
			rd_device.compute_list_dispatch(compute_list, rg_size / 8, rg_size / 8, 1)
			rd_device.compute_list_end()
	
		# Dispatch the Region Computations
		rd_device.submit()
		
		rd_device.sync()
		
		# Retrive processed heightmaps
		for region: Terrain3DRegion in sdfmaps.keys():
			var srid := sdfmaps[region]
			var output_image : Image = maps_data[region]
			var output_bytes := rd_device.texture_get_data(srid, 0)
			output_image.set_data(rg_size, rg_size, false, Image.FORMAT_R8, output_bytes)
			output_image.generate_mipmaps()
			
		var out_texture := Texture2DArray.new()
		var err := out_texture.create_from_images(maps_data.values())
		
		if err != OK:
			push_warning("Error while combining SDF Maps: ", err)
		else:
			_sdf_maps = out_texture
			call_deferred("update_grid")
		
		
	# Free used rids
	maps_data.clear()
	sdfmaps.clear()
	
	for rid in rids:
		rd_device.free_rid(rid)



# -- Particle Grid Handeling
func _reposition_grid(center_chunk: Vector2i) -> void:
	var offset := center_chunk - last_pos
	
	var old_chunks : Array[Vector2i] = particle_instances.keys()
	var new_chunks := old_chunks.map(func(element): return element + offset)
	
	var removeC := old_chunks.filter(func(element): return !new_chunks.has(element))
	var move_toC := new_chunks.filter(func(element): return !old_chunks.has(element))
	
	var i := 0
	for key in removeC:
		var ctm : GPUParticles3D = particle_instances[key]
		particle_instances.erase(key)
		var position_to_move : Vector2i = move_toC[i]
		ctm.set_deferred("global_position", Vector3(position_to_move.x, 0.0, position_to_move.y) * chunk_size)
		ctm.call_deferred("restart", true)
		particle_instances[position_to_move] = ctm
		
		i += 1


func _create_grid() -> void:
	_destroy_grid()
	if not terrainNode:
		return
		
	var camera := terrainNode.get_camera()
	
	var base_pos := Vector3.ZERO
	if camera:
		base_pos = ( Vector3(camera.global_position.x, 0.0 ,camera.global_position.z) / chunk_size).snapped(Vector3.ONE)
	
	rows = maxi(ceili( chunk_size / instance_spacing), 1)
	var amount := rows * rows
	
	var hr := terrainNode.data.get_height_range()
	var s := Vector3(chunk_size, hr.x - hr.y ,chunk_size)
	var aabb := AABB(s * -0.5, s)
	aabb.position.y = hr.y
	
	_update_process_uniforms()
	
	var seed : int
	if gen_seed.length() > 0:
		if gen_seed.is_valid_int():
			seed = gen_seed.to_int()
		else:
			seed = gen_seed.hash()
	
	for x in range(-grid_size, grid_size + 1):
		for z in range(-grid_size, grid_size + 1):
			var particle_node := GPUParticles3D.new()
			particle_node.lifetime = 600.0
			particle_node.draw_pass_1 = mesh
			particle_node.amount = amount
			particle_node.process_material = ParticleProcessMaterial.new()
			particle_node.fixed_fps = particle_fps
			particle_node.preprocess = 1.0 / float(particle_fps)
			particle_node.custom_aabb = aabb
			particle_node.explosiveness = 1.0
			particle_node.process_material = process_material
			particle_node.use_fixed_seed = true
			particle_node.cast_shadow = shadow_casting
			particle_node.visibility_range_end = view_distance + chunk_size
			particle_node.layers = layers
			
			if seed:
				particle_node.seed = seed
			else:
				seed = particle_node.seed
			
			self.add_child(particle_node)
			particle_node.global_position = (Vector3(x, 0.0, z) + base_pos) * chunk_size
			particle_instances[Vector2i(x + base_pos.x, z + base_pos.z)] = particle_node


func _destroy_grid() -> void:
	if particle_instances:
		for node: GPUParticles3D in particle_instances.values():
			if is_instance_valid(node):
				node.free()
		particle_instances.clear()


func _update_process_uniforms() -> void:
	if process_material and terrainNode:
		var rid := process_material.get_rid()
		var params := terrainNode.material._shader_parameters
		
		RenderingServer.material_set_param(rid, "_texture_restrictions", disallowed_textures)
		RenderingServer.material_set_param(rid, "normal_strength", normal_influence)
		RenderingServer.material_set_param(rid, "random_scale", random_scale)
		RenderingServer.material_set_param(rid, "do_color_sampling", color_sampling)
		RenderingServer.material_set_param(rid, "color_sampling_blur", color_blur)
		RenderingServer.material_set_param(rid, "condition_dithering", condition_dithering)
		RenderingServer.material_set_param(rid, "position_randomness", position_randomness)
		RenderingServer.material_set_param(rid, "slope_restrict", slope)
		RenderingServer.material_set_param(rid, "min_height", min_height)
		
		
		RenderingServer.material_set_param(rid, "_rows", rows)
		RenderingServer.material_set_param(rid, "_instance_spacing", instance_spacing)
		RenderingServer.material_set_param(rid, "_background_mode", terrainNode.material.world_background)
		RenderingServer.material_set_param(rid, "_vertex_spacing", terrainNode.vertex_spacing)
		RenderingServer.material_set_param(rid, "_vertex_density", 1.0 / terrainNode.vertex_spacing)
		RenderingServer.material_set_param(rid, "_region_size", terrainNode.region_size)
		RenderingServer.material_set_param(rid, "_region_texel_size", 1.0 / terrainNode.region_size)
		RenderingServer.material_set_param(rid, "_region_map_size", 32)
		RenderingServer.material_set_param(rid, "_region_map", terrainNode.data.get_region_map())
		RenderingServer.material_set_param(rid, "_region_locations", terrainNode.data.get_region_locations())
		
		
		RenderingServer.material_set_param(rid, "_texture_uv_scale_array", terrainNode.assets.get_texture_uv_scales())
		RenderingServer.material_set_param(rid, "_texture_detile_array", terrainNode.assets.get_texture_detiles())
		RenderingServer.material_set_param(rid, "_texture_color_array", terrainNode.assets.get_texture_colors())
		
		RenderingServer.material_set_param(rid, "_height_maps", terrainNode.data.get_height_maps_rid())
		RenderingServer.material_set_param(rid, "_control_maps", terrainNode.data.get_control_maps_rid())
		RenderingServer.material_set_param(rid, "_color_maps", terrainNode.data.get_color_maps_rid())
		RenderingServer.material_set_param(rid, "_texture_array_albedo", terrainNode.assets.get_albedo_array_rid())
		RenderingServer.material_set_param(rid, "_texture_array_normal", terrainNode.assets.get_normal_array_rid())
		RenderingServer.material_set_param(rid, "_texture_vertical_projections", terrainNode.assets.get_texture_vertical_projections())
		RenderingServer.material_set_param(rid, "noise_texture", params["noise_texture"].get_rid())
		
		RenderingServer.material_set_param(rid, "blend_sharpness", params["blend_sharpness"])
		RenderingServer.material_set_param(rid, "auto_base_texture", params["auto_base_texture"])
		RenderingServer.material_set_param(rid, "auto_overlay_texture", params["auto_overlay_texture"])
		RenderingServer.material_set_param(rid, "auto_slope", params["auto_slope"])
		RenderingServer.material_set_param(rid, "auto_height_reduction", params["auto_height_reduction"])
		RenderingServer.material_set_param(rid, "vertical_projection", params["vertical_projection"])
		RenderingServer.material_set_param(rid, "projection_threshold", params["projection_threshold"])
		RenderingServer.material_set_param(rid, "enable_macro_variation", params["macro_variation"])
		RenderingServer.material_set_param(rid, "macro_variation1", params["macro_variation1"])
		RenderingServer.material_set_param(rid, "macro_variation2", params["macro_variation2"])
		RenderingServer.material_set_param(rid, "macro_variation_slope", params["macro_variation_slope"])
		RenderingServer.material_set_param(rid, "noise1_scale", params["noise1_scale"])
		RenderingServer.material_set_param(rid, "noise1_angle", params["noise1_angle"])
		RenderingServer.material_set_param(rid, "noise1_offset", params["noise1_offset"])
		RenderingServer.material_set_param(rid, "noise2_scale", params["noise2_scale"])
		
		if _sdf_maps:
			process_material.set_shader_parameter("_sdf_maps", _sdf_maps)
