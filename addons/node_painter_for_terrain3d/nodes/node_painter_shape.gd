@tool
## Main Node to effect the terrain generation.
## Select different shapes, rotate and scale them to change the way the terrain is generated.
class_name NodePainterShape
extends Node3D

signal shape_updated
signal about_to_exit_tree(node: NodePainterShape)

const container := preload("res://addons/node_painter_for_terrain3d/nodes/container.gd")


var parent_type : NodePainterContainer.ContainerType = 0:
	set(value):
		parent_type = value
		notify_property_list_changed()
var parent_container : NodePainterContainer

@export var shape: NodePainterBaseShape:
	set(value):
		if shape:
			shape.gizmo_relevant_update.disconnect(update_gizmos)
			shape.value_changed.disconnect(_emit_shape_update)
			clear_gizmos()
		
		shape = value
		
		update_gizmos()
		if shape:
			shape.gizmo_relevant_update.connect(update_gizmos)
			shape.value_changed.connect(_emit_shape_update)

# Use case dependent variables
var negative_shape : bool = false:
	set(value):
		negative_shape = value
		_emit_shape_update()
		update_gizmos()

var texture_id : int = 1:
	set(value):
		texture_id = value
		_emit_shape_update()
	get():
		return float(texture_id)

var mode: int = 0:
	set(value):
		mode = value
		_emit_shape_update()
	get():
		return float(mode)

var local_density := 1.0:
	set(value):
		local_density = value
		_emit_shape_update()

var ignored_meshes := 0b0:
	set(value):
		ignored_meshes = value
		_emit_shape_update()


func _get_property_list():
	if Engine.is_editor_hint():
		var ret := []
		
		match parent_type:
			1:
				ret.append({
					"name": &"texture_id",
					"type": TYPE_INT,
					"hint": PROPERTY_HINT_RANGE,
					"hint_string": "0,31,1",
					"usage": PROPERTY_USAGE_DEFAULT
				})
				ret.append({
					"name": &"mode",
					"type": TYPE_INT,
					"hint": PROPERTY_HINT_ENUM,
					"hint_string": "Height,Texture,Both",
					"usage": PROPERTY_USAGE_DEFAULT
				})
			
			2:
				ret.append({
					"name": &"negative_shape",
					"type": TYPE_BOOL,
					"usage": PROPERTY_USAGE_DEFAULT
				})
			
			3:
				ret.append({
					"name": &"negative_shape",
					"type": TYPE_BOOL,
					"usage": PROPERTY_USAGE_DEFAULT
				})
				ret.append({
					"name": &"local_density",
					"type": TYPE_FLOAT,
					"usage": PROPERTY_USAGE_DEFAULT,
					"hint": PROPERTY_HINT_RANGE,
					"hint_string": "0.01,1.0"
				})
				ret.append({
					"name": &"ignored_meshes",
					"type": TYPE_INT,
					"usage": PROPERTY_USAGE_DEFAULT,
					"hint": PROPERTY_HINT_LAYERS_2D_NAVIGATION
				})
		
		return ret


func _ready():
	update_configuration_warnings()
	tree_exited.connect(_on_exiting_tree)
	set_notify_local_transform(true)


func _get_configuration_warnings():
	if parent_container:
		return []
	else:
		return ["Node must be a child of a Node Painter Container."]

func _notification(what):
	match what:
		NOTIFICATION_LOCAL_TRANSFORM_CHANGED:
			_emit_shape_update()


func _emit_shape_update() -> void:
	if parent_container:
		parent_container.update_terrain()
	
	shape_updated.emit()

func get_ignored_encoded() -> float:
	return float(ignored_meshes)

func _on_exiting_tree() -> void:
	call_deferred(&"_emit_shape_update")
	about_to_exit_tree.emit(self)
	parent_type = 0
	parent_container = null
