@tool
extends EditorNode3DGizmoPlugin


const target_node := preload("res://addons/node_painter_for_terrain3d/nodes/node_painter_shape.gd")
const cirle_div : int = 48

var used_material := "main"


func _get_gizmo_name():
	return "NodePainterShape"

func _is_selectable_when_hidden():
	return true

func _has_gizmo(for_node_3d):
	return for_node_3d is target_node and for_node_3d.shape is NodePainterCircle


func _init():
	create_material("main", Color.YELLOW)
	create_material("alt", Color.INDIAN_RED)
	create_handle_material("handles")


func _redraw(gizmo):
	gizmo.clear()
	var node3d : target_node = gizmo.get_node_3d()
	used_material = "alt" if node3d.negative_shape else "main"
	
	var lines := PackedVector3Array()
	
	# Circle Gizmo
	var radius : float = node3d.shape.radius
	var trans : float = node3d.shape.transition_size
	var step := (2*PI) / cirle_div
	
	for i in range(0, cirle_div):
		var angle := i * step
		# Normal Size
		lines.push_back(Vector3(cos(angle), 0.01, sin(angle)) * radius)
		lines.push_back(Vector3(cos(angle + step), 0.01, sin(angle + step)) * radius)
		
		# Transition
		lines.push_back(Vector3(cos(angle), 0.005, sin(angle)) * (radius + trans))
		lines.push_back(Vector3(cos(angle + step), 0.005, sin(angle + step)) * (radius + trans))
	
	gizmo.add_lines(lines, get_material(used_material, gizmo))
	
	var handles := PackedVector3Array( [Vector3(radius * 0.7071067812, 0.01, radius * 0.7071067812),
										Vector3((radius + trans) * 0.7071067812, 0.05, (radius + trans) * 0.7071067812)] )
	gizmo.add_handles(handles, get_material("handles", gizmo), PackedInt32Array([1,2]))

# Handle Actions
func _get_handle_name(gizmo, handle_id, _secondary):
	match handle_id:
		1: return "radius"
		2: return "transition size"


func _get_handle_value(gizmo, handle_id, secondary):
	var node : Node3D = gizmo.get_node_3d()
	
	match handle_id:
		1: return node.shape.radius
		2: return node.shape.transition_size


func _set_handle(gizmo, handle_id, secondary, camera, screen_pos):
	var node : Node3D = gizmo.get_node_3d()
	var node_pos : Vector2 = camera.unproject_position(node.global_position)
	var distance_to_camera := node.global_position.distance_to(camera.global_position)
	var distance : float = node_pos.distance_to(screen_pos) * distance_to_camera * 0.001
	
	match handle_id:
		1: node.shape.radius = distance
		2: node.shape.transition_size = distance - node.shape.radius
