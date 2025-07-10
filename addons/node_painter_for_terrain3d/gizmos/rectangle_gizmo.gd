@tool
extends EditorNode3DGizmoPlugin


const target_node := preload("res://addons/node_painter_for_terrain3d/nodes/node_painter_shape.gd")
var used_material := "main"


func _get_gizmo_name():
	return "NodePainterShape"

func _is_selectable_when_hidden():
	return true

func _has_gizmo(for_node_3d):
	return for_node_3d is target_node and for_node_3d.shape is NodePainterRectangle


func _init():
	create_material("main", Color.YELLOW)
	create_material("alt", Color.INDIAN_RED)
	create_handle_material("handles")


func _redraw(gizmo):
	gizmo.clear()
	var node3d : target_node = gizmo.get_node_3d()
	used_material = "alt" if node3d.negative_shape else "main"
	var lines := PackedVector3Array()

	# Rectangle Gizmo
	var size : Vector2 = node3d.shape.size / 2.0
	var trans : float = node3d.shape.transition_size
	
	var handles := PackedVector3Array( [Vector3(size.x, 0.01, size.y), Vector3(size.x + trans, 0.005, size.y + trans)] )
	
	# Normal Size
	lines.push_back(Vector3(size.x, 0.01, size.y))
	lines.push_back(Vector3(size.x, 0.01, -size.y))
	lines.push_back(Vector3(-size.x, 0.01, size.y))
	lines.push_back(Vector3(-size.x, 0.01, -size.y))
	lines.push_back(Vector3(-size.x, 0.01, size.y))
	lines.push_back(Vector3(size.x, 0.01, size.y))
	lines.push_back(Vector3(-size.x, 0.01, -size.y))
	lines.push_back(Vector3(size.x, 0.01, -size.y))
	# Transition
	size += Vector2.ONE * trans
	lines.push_back(Vector3(size.x, 0.005, size.y))
	lines.push_back(Vector3(size.x, 0.005, -size.y))
	lines.push_back(Vector3(-size.x, 0.005, size.y))
	lines.push_back(Vector3(-size.x, 0.005, -size.y))
	lines.push_back(Vector3(-size.x, 0.005, size.y))
	lines.push_back(Vector3(size.x, 0.005, size.y))
	lines.push_back(Vector3(-size.x, 0.005, -size.y))
	lines.push_back(Vector3(size.x, 0.005, -size.y))

	gizmo.add_lines(lines, get_material(used_material, gizmo))
	gizmo.add_handles(handles, get_material("handles", gizmo), PackedInt32Array([1,2]))

# Handle Actions
func _get_handle_name(gizmo, handle_id, _secondary):
	match handle_id:
		1: return "size"
		2: return "transition size"


func _get_handle_value(gizmo, handle_id, secondary):
	var node : Node3D = gizmo.get_node_3d()
	match handle_id:
		1: return node.shape.size
		2: return node.shape.transition_size


func _set_handle(gizmo, handle_id, secondary, camera, screen_pos):
	var node : Node3D = gizmo.get_node_3d()
	var node_pos : Vector2 = camera.unproject_position(node.global_position)
	var distance_to_camera := node.global_position.distance_to(camera.global_position)
	var distance : float = node_pos.distance_to(screen_pos) * distance_to_camera * 0.001

	match handle_id:
		1: 
			var diff : Vector2 = (screen_pos - node_pos) * distance_to_camera * 0.002
			var new_size : Vector2 = abs(diff * camera.global_basis.x.x + Vector2(diff.y, diff.x) * camera.global_basis.x.z)
			node.shape.size = new_size
		2: 
			node.shape.transition_size = clamp(distance - node.shape.size.length() * 0.5, 0.0, INF)
