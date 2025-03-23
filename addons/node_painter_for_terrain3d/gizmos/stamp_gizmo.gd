@tool
extends EditorNode3DGizmoPlugin


const target_node := preload("res://addons/node_painter_for_terrain3d/nodes/node_painter_shape.gd")


func _get_gizmo_name():
	return "NodePainterShape"

func _is_selectable_when_hidden():
	return true

func _has_gizmo(for_node_3d):
	return for_node_3d is target_node and for_node_3d.shape is NodePainterStamp


func _init():
	create_material("main", Color.YELLOW)
	create_handle_material("handles")


func _redraw(gizmo):
	gizmo.clear()
	var node3d : target_node = gizmo.get_node_3d()
	var lines := PackedVector3Array()

	# Rectangle Gizmo
	var size : float = node3d.shape.size / 2.0
	var trans : float = node3d.shape.transition_size
	
	size -= trans * 0.5
	
	# Normal Size
	lines.push_back(Vector3(size, 0.01, size))
	lines.push_back(Vector3(size, 0.01, -size))
	lines.push_back(Vector3(-size, 0.01, size))
	lines.push_back(Vector3(-size, 0.01, -size))
	lines.push_back(Vector3(-size, 0.01, size))
	lines.push_back(Vector3(size, 0.01, size))
	lines.push_back(Vector3(-size, 0.01, -size))
	lines.push_back(Vector3(size, 0.01, -size))
	# Transition
	size += trans
	lines.push_back(Vector3(size, 0.005, size))
	lines.push_back(Vector3(size, 0.005, -size))
	lines.push_back(Vector3(-size, 0.005, size))
	lines.push_back(Vector3(-size, 0.005, -size))
	lines.push_back(Vector3(-size, 0.005, size))
	lines.push_back(Vector3(size, 0.005, size))
	lines.push_back(Vector3(-size, 0.005, -size))
	lines.push_back(Vector3(size, 0.005, -size))

	gizmo.add_lines(lines, get_material("main", gizmo))
