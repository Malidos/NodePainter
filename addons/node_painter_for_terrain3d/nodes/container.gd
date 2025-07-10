@tool
## A Node to contain all NodePainter Shapes. Nodes are processed in order of the SceneTree.
## This class handles connection to other nodes. Actual functionallity is handled by inherting classes.
class_name NodePainterContainer
extends Node3D

enum ContainerType {TYPE_DEFAULT = 0, TYPE_HEIGHT = 1, TYPE_PARTICLES = 2, TYPE_FOLIAGE = 3}


var terrainNode: Terrain3D
var largest_image : int = 16
var images : Array[Image]

# Stops a wave of updates while moving nodes or using sliders
## Indicates Container Type to shapes
var container_type := ContainerType.TYPE_DEFAULT
var update_scheduled := false
var ticks_waiting_on_update := 0
const ticks_waiting := 12
const paint_node := preload("res://addons/node_painter_for_terrain3d/nodes/node_painter_shape.gd")

const path_tesselation_stages := 6
const path_tesselation_degrees := 3


func _init():
	tree_entered.connect(_on_entered_tree)
	tree_exiting.connect(_on_exiting_tree)
	set_physics_process_internal(true)

func _on_entered_tree():
	if Engine.is_editor_hint():
		child_entered_tree.connect(_child_entered_tree)
		
		set_notify_transform(true)


func _get_configuration_warnings():
	if !(get_parent_node_3d() is Terrain3D):
		return ["Node Painter must be child of a Terrain3D Node!"]
	elif find_children("*", &"NodePainterShape").size() < 1:
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
		
		NOTIFICATION_INTERNAL_PHYSICS_PROCESS:
			if update_scheduled:
				if ticks_waiting_on_update > ticks_waiting:
					call_deferred("_procedual_update")
					update_scheduled = false
					ticks_waiting_on_update = 0
				else:
					ticks_waiting_on_update += 1

func _child_entered_tree(node: Node) -> void:
	node.child_entered_tree.connect(_child_entered_tree)
	
	if node is NodePainterShape:
		node.shape_updated.connect(update_terrain)
		node.about_to_exit_tree.connect(_child_exiting)
		node.parent_type = container_type
	
	for child in node.find_children("*", &"NodePainterShape"):
		child.shape_updated.connect(update_terrain)
		child.about_to_exit_tree.connect(_child_exiting)
		child.parent_type = container_type

func _child_exiting(node: Node3D) -> void:
	node.shape_updated.disconnect(update_terrain)
	node.about_to_exit_tree.disconnect(_child_exiting)
	update_terrain()

## Use this function to schedule a terrain update as it protects againts multiple updates in quick succsession.
func update_terrain() -> void:
	if Engine.is_editor_hint():
		ticks_waiting_on_update = 0
		update_scheduled = true


## Called after any parameters or shapes have changed
func _procedual_update() -> void:
	pass # programmed in inherting classes

func _on_exiting_tree():
	child_entered_tree.disconnect(_child_entered_tree)
	
	tree_entered.disconnect(_on_entered_tree)
	tree_exiting.disconnect(_on_exiting_tree)

## Returns dictonary containing the encoded shapes and heightmaps used,
## 'ShapeBuffer' can directly be turned into a storage buffer, while from 'Format' and 'Data' an RDTexture can be generated using texture_create() on the local rendering device
func get_shape_data_buffer(exclude_stamps: bool = false) -> Dictionary:
	var edit_nodes := find_children("*", "NodePainterShape")
	images = []
	largest_image = 128
	
	# Generate the shape buffer data
	var shape_count : int = 0
	var shape_data_buffer := PackedFloat32Array([])
	for shape: Node3D in edit_nodes:
		if shape.shape is NodePainterCircle:
			shape_count += 1
			
			shape_data_buffer.push_back(0.0) # Shape is type Circle
			shape_data_buffer.push_back(shape.shape.transition_size)
			shape_data_buffer.push_back( float(shape.shape.transition_type) ) # "Transition Type"
			shape_data_buffer.push_back( float(shape.mode) )
			shape_data_buffer.push_back( float(shape.texture_id) )
			shape_data_buffer.push_back( float(shape.negative_shape) )
			shape_data_buffer.push_back(shape.scale.x)
			shape_data_buffer.push_back(shape.scale.z)
			shape_data_buffer.push_back(shape.global_rotation.y)
			shape_data_buffer.push_back(shape.global_position.x)
			shape_data_buffer.push_back(shape.global_position.z)
			shape_data_buffer.push_back(shape.global_position.y)
			shape_data_buffer.push_back(shape.shape.radius)
			
		elif shape.shape is NodePainterRectangle:
			shape_count += 1
			
			shape_data_buffer.push_back(1.0) # Shape is type Rectangle
			shape_data_buffer.push_back(shape.shape.transition_size)
			shape_data_buffer.push_back( float(shape.shape.transition_type) )
			shape_data_buffer.push_back( float(shape.mode) )
			shape_data_buffer.push_back( float(shape.texture_id) )
			shape_data_buffer.push_back( float(shape.negative_shape) )
			shape_data_buffer.push_back(shape.scale.x)
			shape_data_buffer.push_back(shape.scale.z)
			shape_data_buffer.push_back(shape.global_rotation.y)
			shape_data_buffer.push_back(shape.global_position.x)
			shape_data_buffer.push_back(shape.global_position.z)
			shape_data_buffer.push_back(shape.global_position.y)
			shape_data_buffer.push_back(shape.shape.size.x)
			shape_data_buffer.push_back(shape.shape.size.y)
		
		elif shape.shape is NodePainterPolygon:
			shape_count += 1
			var polygons : PackedVector2Array = shape.shape.points
			
			shape_data_buffer.push_back(2.0) # Shape is type Polygon
			shape_data_buffer.push_back(shape.shape.transition_size)
			shape_data_buffer.push_back( float(shape.shape.transition_type) )
			shape_data_buffer.push_back( float(shape.mode) )
			shape_data_buffer.push_back( float(shape.texture_id) )
			shape_data_buffer.push_back( float(shape.negative_shape) )
			shape_data_buffer.push_back(shape.scale.x)
			shape_data_buffer.push_back(shape.scale.z)
			shape_data_buffer.push_back(shape.global_rotation.y)
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
			shape_data_buffer.push_back( float(shape.mode) )
			shape_data_buffer.push_back( float(shape.texture_id) )
			shape_data_buffer.push_back( float(shape.negative_shape) )
			shape_data_buffer.push_back(shape.shape.thickness)
			shape_data_buffer.push_back(path_points.size())
			
			for p in path_points:
				shape_data_buffer.push_back(p.x)
				shape_data_buffer.push_back(p.y)
				shape_data_buffer.push_back(p.z)
		
		elif shape.shape is NodePainterStamp and shape.shape.heightmap != null and !exclude_stamps:
			shape_count += 1
			var img : Image = shape.shape.heightmap
			
			shape_data_buffer.push_back(4.0) # Shape is type Stamp
			shape_data_buffer.push_back(shape.shape.transition_size)
			shape_data_buffer.push_back( float(shape.shape.transition_type) ) # "Transition Type"
			shape_data_buffer.push_back( float(shape.mode) )
			shape_data_buffer.push_back( float(shape.texture_id) )
			shape_data_buffer.push_back( float(shape.negative_shape) )
			shape_data_buffer.push_back(shape.scale.x)
			shape_data_buffer.push_back(shape.scale.z)
			shape_data_buffer.push_back(shape.global_rotation.y)
			shape_data_buffer.push_back(shape.global_position.x)
			shape_data_buffer.push_back(shape.global_position.z)
			shape_data_buffer.push_back(shape.global_position.y)
			shape_data_buffer.push_back(shape.shape.height)
			shape_data_buffer.push_back(shape.shape.size)
			
			if images.has(img):
				shape_data_buffer.push_back(images.find(img))
			else:
				shape_data_buffer.push_back(images.size())
				images.push_back(img)
			
			largest_image = max(largest_image, max(img.get_height(), img.get_width()))
	
	var shape_bytes := PackedInt32Array([shape_count]).to_byte_array()
	shape_bytes.append_array( shape_data_buffer.to_byte_array() )
	
	var stamp_data := {}
	
	if !exclude_stamps:
		stamp_data = _get_stamps()
	stamp_data["ShapeBuffer"] = shape_bytes
	
	return stamp_data


func _get_stamps() -> Dictionary:
	var usable_images : Array[Image] = []
	var mimaps := 1
	
	for textur: Image in images:
		var img := textur
		var img_format := img.get_format()
		var err := OK
		
		if img:
			if img.is_compressed():
				err = img.decompress()
			if img_format != Image.FORMAT_RF:
				img.convert(Image.FORMAT_RF)
			if !img.has_mipmaps():
				img.generate_mipmaps()
		
			img.resize(largest_image, largest_image, Image.INTERPOLATE_TRILINEAR)
		
			if err == OK:
				usable_images.push_back(img)
				mimaps = img.get_mipmap_count() + 1
	
	var data : Array[PackedByteArray] = []
	
	if usable_images.is_empty():
		var ph_img := Image.create_empty(largest_image, largest_image, false, Image.FORMAT_RF)
		data.push_back(ph_img.get_data())
	
	for img in usable_images:
		data.push_back(img.get_data())
	
	var stamp_format := RDTextureFormat.new()
	stamp_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	stamp_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	stamp_format.height = largest_image
	stamp_format.width = largest_image
	stamp_format.array_layers = max(usable_images.size(), 1)
	stamp_format.mipmaps = mimaps
	stamp_format.is_discardable = true
	stamp_format.usage_bits = \
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	
	return {"Format": stamp_format, "Data": data}
