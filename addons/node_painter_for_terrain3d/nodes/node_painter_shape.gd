@tool
## Main Node to effect the terrain generation.
## Select different shapes, rotate and scale them to change the way the terrain is generated.
class_name NodePainterShape
extends Node3D

signal shape_updated

const container := preload("res://addons/node_painter_for_terrain3d/nodes/node_painter_container.gd")

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


func _enter_tree():
	if !editor_state_changed.is_connected(_emit_shape_update):
		editor_state_changed.connect(_emit_shape_update)
	set_notify_transform(true)

func _get_configuration_warnings():
	if get_parent_node_3d() is container:
		return []
	else:
		return ["Node must be a child of a Node Painter Container."]

func _notification(what):
	match what:
		NOTIFICATION_TRANSFORM_CHANGED:
			_emit_shape_update()


func _emit_shape_update() -> void:
	shape_updated.emit()
