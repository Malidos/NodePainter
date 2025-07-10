@tool
extends EditorNode3DGizmoPlugin


const target_node := preload("res://addons/node_painter_for_terrain3d/nodes/node_painter_shape.gd")
const cirle_div : int = 16
var used_material := "main"


func _get_gizmo_name():
	return "NodePainterShape"

func _is_selectable_when_hidden():
	return true

func _has_gizmo(for_node_3d):
	return for_node_3d is target_node and for_node_3d.shape is NodePainterPolygon


func _init():
	create_material("main", Color.YELLOW)
	create_material("alt", Color.INDIAN_RED)
	create_handle_material("handles")


func _redraw(gizmo):
	gizmo.clear()
	var node3d : target_node = gizmo.get_node_3d()
	used_material = "alt" if node3d.negative_shape else "main"
	
	var lines := PackedVector3Array([])
	var handles := PackedVector3Array([])
	
	# Rectangle Gizmo
	var polygon_points : PackedVector2Array = node3d.shape.points.duplicate()
	if polygon_points.size() > 1:
		polygon_points.push_back(polygon_points[0])
		polygon_points.push_back(polygon_points[1])
		var trans : float = node3d.shape.transition_size
	
		for i in range(polygon_points.size() - 2):
			var fpt := Vector3(polygon_points[i].x, 0.02, polygon_points[i].y)
			var spt := Vector3(polygon_points[i + 1].x, 0.02, polygon_points[i + 1].y)
			var tpt := Vector3(polygon_points[i + 2].x, 0.02, polygon_points[i + 2].y)
			
			
			# Normal Polygon
			lines.push_back(fpt)
			lines.push_back(spt)
		
			# Transition
			var spt_dir := (spt - fpt).normalized().cross(Vector3.DOWN) * trans
			lines.push_back( (fpt - spt).normalized().cross(Vector3.UP) * trans + fpt )
			lines.push_back( spt_dir + spt )
			
			# Transition Curve
			var angle := (spt - fpt).angle_to(tpt - spt)
			var step := -angle / cirle_div
			for j in range(cirle_div):
				lines.push_back(spt_dir.rotated(Vector3.UP, j*step) + spt)
				lines.push_back(spt_dir.rotated(Vector3.UP, j*step + step) + spt)
			
	
		for h in polygon_points:
			handles.push_back(Vector3(h.x, 0.021, h.y))
	
		gizmo.add_lines(lines, get_material(used_material, gizmo))
		gizmo.add_handles(handles, get_material("handles", gizmo), PackedInt32Array(range(0, polygon_points.size())))

# Handle Actions
func _get_handle_name(gizmo, handle_id, _secondary):
	match handle_id:
		1: return "point "+str(handle_id)


func _get_handle_value(gizmo, handle_id, _secondary):
	var node : Node3D = gizmo.get_node_3d()
	return node.shape.points[handle_id]


func _set_handle(gizmo, handle_id, secondary, camera, screen_pos):
	var node : Node3D = gizmo.get_node_3d()
	var global_handle_position := node.global_transform.translated_local( Vector3(node.shape.points[handle_id].x, 0.0, node.shape.points[handle_id].y) ).origin
	var distance_to_camera: float = min(camera.global_position.distance_to(node.global_position), camera.global_position.distance_to(global_handle_position))
	var new_pos : Vector3 = camera.project_position(screen_pos, distance_to_camera)
	new_pos = node.global_transform.affine_inverse().translated_local(new_pos).origin
	
	node.shape.points[handle_id] = Vector2(new_pos.x, new_pos.z)
