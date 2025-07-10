@tool
## Main Node to effect the terrain generation.
## Select different shapes, rotate and scale them to change the way the terrain is generated.
class_name NodePainterShape
extends Node3D

signal shape_updated
signal about_to_exit_tree(node: Node3D)

const container := preload("res://addons/node_painter_for_terrain3d/nodes/container.gd")


var parent_type : NodePainterContainer.ContainerType = 0:
	set(value):
		parent_type = value
		notify_property_list_changed()

@export var shape: NodePainterBaseShape:
	set(value):
		if shape:
			shape.gizmo_relevant_update.disconnect(update_gizmos)
			shape.value_changed.disconnect(_emit_shape_update)
			clear_gizmos()
		
		shape = value
		
		update_gizmos()
		if shape:
			shape.connect(&"gizmo_relevant_update", update_gizmos)
			shape.connect(&"value_changed", _emit_shape_update)

# Use case dependent variables
var negative_shape : bool = false:
	set(value):
		negative_shape = value
		shape_updated.emit()
		update_gizmos()

var texture_id : int = 1:
	set(value):
		texture_id = value
		shape_updated.emit()
	get():
		return float(texture_id)

var mode: int = 0:
	set(value):
		mode = value
		shape_updated.emit()
	get():
		return float(mode)


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
		
		return ret


func _enter_tree():
	if !editor_state_changed.is_connected(_emit_shape_update):
		editor_state_changed.connect(_emit_shape_update)
	set_notify_transform(true)

func _ready():
	update_configuration_warnings()

func _exit_tree():
	about_to_exit_tree.emit(self)

func _get_configuration_warnings():
	if shape_updated.has_connections():
		return []
	else:
		return ["Node must be a child of a Node Painter Container."]

func _notification(what):
	match what:
		NOTIFICATION_TRANSFORM_CHANGED:
			_emit_shape_update()


func _emit_shape_update() -> void:
	shape_updated.emit()
