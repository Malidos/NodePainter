@tool
## A Node to contain all NodePainter Shapes and to process them into a Heightmap for Terrain3D.
## Nodes are processed in order of the SceneTree.
class_name NodePainterContainer
extends Node3D

## Stops adjusting the height map for manual adjustments on the terrain.
@export var disabled := false
## Base height of the Terrain. When no shape effects the terrain it will have this height.
@export_range(-20.0, 50.0) var base_height := 0.0:
	set(value):
		base_height = value
		update_terrain()

var terrainNode: Terrain3D
var rd_device: RenderingDevice
var shader: RID

# Stops a wave of updates while moving nodes or using sliders
var update_scheduled := false
var ticks_waiting_on_update := 0
const ticks_waiting := 12

const paint_node := preload("res://addons/node_painter_for_terrain3d/nodes/node_painter_shape.gd")
const compute_shader_file := preload("res://addons/node_painter_for_terrain3d/resources/heightmap_compute.glsl")
const path_tesselation_stages := 6
const path_tesselation_degrees := 3

func _enter_tree():
	if Engine.is_editor_hint():
		child_entered_tree.connect(_child_entered_tree)
		child_exiting_tree.connect(_child_exitied_tree)
		
		set_notify_transform(true)
		rd_device = RenderingServer.create_local_rendering_device()
		var spriv := compute_shader_file.get_spirv()
		shader = rd_device.shader_create_from_spirv(spriv, "TerrainPaintCircleCompute")
	else:
		queue_free()

func _get_configuration_warnings():
	if !(get_parent_node_3d() is Terrain3D):
		return ["Node Painter must be child of a Terrain3D Node!"]
	elif get_children().filter(func(node): return node is NodePainterShape).size() < 1:
		return ["Node Painter has no Shape Childs."]
	else:
		return []


func _notification(what):
	match what:
		NOTIFICATION_PARENTED:
			update_configuration_warnings()
			
			var parent := get_parent_node_3d()
			if parent is Terrain3D:
				terrainNode = parent
			else:
				terrainNode = null
		
		NOTIFICATION_TRANSFORM_CHANGED:
			transform = Transform3D.IDENTITY

func _child_entered_tree(node: Node) -> void:
	if node is NodePainterShape:
		node.shape_updated.connect(update_terrain)

func _child_exitied_tree(node: Node) -> void:
	if node is NodePainterShape:
		node.shape_updated.disconnect(update_terrain)
		update_terrain()

## Use this function to schedule a terrain update as it protects againts multiple updates in quick succsession.
func update_terrain() -> void:
	if !disabled:
		ticks_waiting_on_update = 0
		update_scheduled = true

func _physics_process(_delta):
	if update_scheduled:
		if ticks_waiting_on_update > ticks_waiting:
			call_deferred("_generate_new_heightmap")
			update_scheduled = false
			ticks_waiting_on_update = 0
		else:
			ticks_waiting_on_update += 1


func _generate_new_heightmap() -> void:
	# TODO: Seperate in smaller functions

	# Create Computation Pipeline
	var pipeline := rd_device.compute_pipeline_create(shader)
	var heightmaps : Dictionary[Terrain3DRegion, RID] = {}
	var rids : Array[RID] = []
	
	var shape_data_buffer := get_shape_data_buffer()
	var shape_buffer := rd_device.storage_buffer_create(shape_data_buffer.size(), shape_data_buffer)
	rids.push_back(shape_buffer)
	
	var shape_uniform := RDUniform.new()
	shape_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	shape_uniform.binding = 2
	shape_uniform.add_id(shape_buffer)
	
	
	if terrainNode and shape_data_buffer.size() > 8:
		# retrive Region data
		var regions := terrainNode.data.get_regions_active()
		var rg_size := 256
		if regions.size() > 0:
			rg_size = regions.front().region_size
		
		for region: Terrain3DRegion in regions:
			# Generate Region specific parameters
			var region_data := PackedFloat32Array([float(region.location.x), float(region.location.y), region.vertex_spacing]).to_byte_array()
			var region_buffer := rd_device.storage_buffer_create(region_data.size(), region_data)
			rids.push_back(region_buffer)
			
			var region_uniform := RDUniform.new()
			region_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			region_uniform.binding = 1
			region_uniform.add_id(region_buffer)
			
			# Generate Heightmap parameter
			var heightmap_format := RDTextureFormat.new()
			heightmap_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
			heightmap_format.width = region.region_size
			heightmap_format.height = region.region_size
			heightmap_format.usage_bits = \
				RenderingDevice.TEXTURE_USAGE_STORAGE_BIT + \
				RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT + \
				RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
			
			var heightmap_image := Image.create_empty(region.region_size, region.region_size, false, Image.FORMAT_RF)
			heightmap_image.fill(Color(base_height, base_height, base_height, 1.0))
			
			var heightmap_rid := rd_device.texture_create(heightmap_format, RDTextureView.new(), [heightmap_image.get_data()])
			rids.push_back(heightmap_rid)
			heightmaps[region] = heightmap_rid
			
			var heightmap_uniform := RDUniform.new()
			heightmap_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			heightmap_uniform.binding = 0
			heightmap_uniform.add_id(heightmap_rid)
			
			var region_set := rd_device.uniform_set_create([heightmap_uniform, region_uniform, shape_uniform], shader, 0)
			
			# Attatch the region to the compute pipeline
			var compute_list := rd_device.compute_list_begin()
			rd_device.compute_list_bind_compute_pipeline(compute_list, pipeline)
			rd_device.compute_list_bind_uniform_set(compute_list, region_set, 0)
			rd_device.compute_list_dispatch(compute_list, region.region_size / 8, region.region_size / 8, 1)
			rd_device.compute_list_end()
		
		
		# Dispatch the Region Computations
		rd_device.submit()
		
		# TODO: Moving the following to a subthread would be ideal
		rd_device.sync()
		
		# Retrive processed heightmaps
		for region: Terrain3DRegion in heightmaps.keys():
			var hm_rid := heightmaps[region]
			var output_bytes := rd_device.texture_get_data(hm_rid, 0)
			var output_image := Image.create_from_data(rg_size, rg_size, false, Image.FORMAT_RF, output_bytes)
			
			if region.validate_map_size(output_image):
				region.set_map(Terrain3DRegion.TYPE_HEIGHT, output_image)
		terrainNode.data.force_update_maps(Terrain3DRegion.TYPE_HEIGHT)
		
		
		# Free used rids
		heightmaps.clear()
	for rid in rids:
		rd_device.free_rid(rid)


func _exit_tree():
	# Perform GPU cleanup
	if rd_device == null:
		return
	
	rd_device.free_rid(shader)
	rd_device.free()
	rd_device = null
	
	child_entered_tree.disconnect(_child_entered_tree)
	child_exiting_tree.disconnect(_child_exitied_tree)


func get_shape_data_buffer() -> PackedByteArray:
	var childs := get_children()
	var edit_nodes := childs.filter(func(node): return node is NodePainterShape and node.shape)
	
	# Generate the shape buffer data
	var shape_count : int = 0
	var shape_data_buffer := PackedFloat32Array([])
	for shape: Node3D in edit_nodes:
		if shape.shape is NodePainterCircle:
			shape_count += 1
			
			shape_data_buffer.push_back(0.0) # Shape is type Circle
			shape_data_buffer.push_back(shape.shape.transition_size)
			shape_data_buffer.push_back( float(shape.shape.transition_type) ) # "Transition Type"
			shape_data_buffer.push_back(shape.scale.x)
			shape_data_buffer.push_back(shape.scale.z)
			shape_data_buffer.push_back(shape.rotation.y)
			shape_data_buffer.push_back(shape.global_position.x)
			shape_data_buffer.push_back(shape.global_position.z)
			shape_data_buffer.push_back(shape.global_position.y)
			shape_data_buffer.push_back(shape.shape.radius)
			
		elif shape.shape is NodePainterRectangle:
			shape_count += 1
			
			shape_data_buffer.push_back(1.0) # Shape is type Rectangle
			shape_data_buffer.push_back(shape.shape.transition_size)
			shape_data_buffer.push_back( float(shape.shape.transition_type) )
			shape_data_buffer.push_back(shape.scale.x)
			shape_data_buffer.push_back(shape.scale.z)
			shape_data_buffer.push_back(shape.rotation.y)
			shape_data_buffer.push_back(shape.global_position.x)
			shape_data_buffer.push_back(shape.global_position.z)
			shape_data_buffer.push_back(shape.global_position.y)
			shape_data_buffer.push_back(shape.shape.size.x) # A negative value here indicates a rectangle for the compute shader
			shape_data_buffer.push_back(shape.shape.size.y)
		
		elif shape.shape is NodePainterPolygon:
			shape_count += 1
			var polygons : PackedVector2Array = shape.shape.points
			
			shape_data_buffer.push_back(2.0) # Shape is type Polygon
			shape_data_buffer.push_back(shape.shape.transition_size)
			shape_data_buffer.push_back( float(shape.shape.transition_type) )
			shape_data_buffer.push_back(shape.scale.x)
			shape_data_buffer.push_back(shape.scale.z)
			shape_data_buffer.push_back(shape.rotation.y)
			shape_data_buffer.push_back(shape.global_position.x)
			shape_data_buffer.push_back(shape.global_position.z)
			shape_data_buffer.push_back(shape.global_position.y)
			
			shape_data_buffer.push_back(polygons.size())
			for p in polygons:
				shape_data_buffer.push_back(p.x)
				shape_data_buffer.push_back(p.y)
		
		elif shape.shape is NodePainterPath:
			shape_count += 1
			var path_points : PackedVector3Array = shape.shape.curve.tessellate(path_tesselation_stages, path_tesselation_degrees)
			# Transform all Curve points into global space for easier SDF calculation
			var node_transform := shape.global_transform
			path_points = PackedVector3Array( Array(path_points).map(func(pt): return node_transform.translated_local(pt).origin) )
			
			shape_data_buffer.push_back(3.0) # Shape is type Path
			shape_data_buffer.push_back(shape.shape.transition_size)
			shape_data_buffer.push_back( float(shape.shape.transition_type) )
			shape_data_buffer.push_back(shape.shape.thickness)
			shape_data_buffer.push_back(path_points.size())
			
			for p in path_points:
				shape_data_buffer.push_back(p.x)
				shape_data_buffer.push_back(p.y)
				shape_data_buffer.push_back(p.z)
	
	var shape_bytes := PackedInt32Array([shape_count]).to_byte_array()
	shape_bytes.append_array( shape_data_buffer.to_byte_array() )
	
	return shape_bytes
