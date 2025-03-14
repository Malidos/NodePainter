@tool
extends EditorNode3DGizmoPlugin


const target_node := preload("res://addons/node_painter_for_terrain3d/nodes/node_painter_shape.gd")
const path_res : float = 0.2
const cirle_div : int = 24


func _get_gizmo_name():
	return "NodePainterShape"

func _is_selectable_when_hidden():
	return true

func _has_gizmo(for_node_3d):
	return for_node_3d is target_node and for_node_3d.shape is NodePainterPath


func _init():
	create_material("main", Color.YELLOW)
	create_material("tangent", Color.ORANGE_RED)
	create_handle_material("handles")


func _redraw(gizmo):
	gizmo.clear()
	var node3d : target_node = gizmo.get_node_3d()
	var lines := PackedVector3Array([])
	var tangents := PackedVector3Array([])
	var handles := PackedVector3Array([])
	var sHandles := PackedVector3Array([])
	
	if node3d.shape.curve and node3d.shape.curve.get_baked_length() > 0.01:
		var curve : Curve3D = node3d.shape.curve
		var thickness : float = node3d.shape.thickness
		
		# Add Path lines relevant for the terrain
		for o in range(0, curve.get_baked_length() / path_res):
			var fpt : Transform3D = curve.sample_baked_with_rotation(o * path_res, true)
			var spt : Transform3D = curve.sample_baked_with_rotation((o+1) * path_res, true)
			
			var fp_side := fpt.basis.z.cross(Vector3.UP)
			var sp_side := spt.basis.z.cross(Vector3.UP)
			
			# Normal thickness_lines
			lines.push_back(fpt.origin + fp_side * thickness)
			lines.push_back(spt.origin + sp_side * thickness)
			lines.push_back(fpt.origin - fp_side * thickness)
			lines.push_back(spt.origin - sp_side * thickness)
			
			# Transition Lines
			lines.push_back(fpt.origin + fp_side * (thickness + node3d.shape.transition_size))
			lines.push_back(spt.origin + sp_side * (thickness + node3d.shape.transition_size))
			lines.push_back(fpt.origin - fp_side * (thickness + node3d.shape.transition_size))
			lines.push_back(spt.origin - sp_side * (thickness + node3d.shape.transition_size))
			
		# Rounded Ends
		if !curve.closed and curve.point_count > 1:
			var fpt : Transform3D = curve.sample_baked_with_rotation(0.0, true)
			var spt : Transform3D = curve.sample_baked_with_rotation(curve.get_baked_length(), true)
			
			var cirle_dir1 := fpt.basis.z.cross(Vector3.UP)
			var cirle_dir2 := -spt.basis.z.cross(Vector3.UP)
			
			var step := PI / cirle_div
			for i in range(cirle_div):
				var angle := i * step
				
				var ffv1 := cirle_dir1.rotated(Vector3.UP, angle)
				var ffv2 := cirle_dir1.rotated(Vector3.UP, angle + step)
				var sfv1 := cirle_dir2.rotated(Vector3.UP, angle)
				var sfv2 := cirle_dir2.rotated(Vector3.UP, angle + step)
				
				# Normal Size
				lines.push_back(fpt.origin + ffv1 * thickness)
				lines.push_back(fpt.origin + ffv2 * thickness)
				lines.push_back(spt.origin + sfv1 * thickness)
				lines.push_back(spt.origin + sfv2 * thickness)
				
				# Transition Size
				lines.push_back(fpt.origin + ffv1 * (thickness + node3d.shape.transition_size))
				lines.push_back(fpt.origin + ffv2 * (thickness + node3d.shape.transition_size))
				lines.push_back(spt.origin + sfv1 * (thickness + node3d.shape.transition_size))
				lines.push_back(spt.origin + sfv2 * (thickness + node3d.shape.transition_size))
		
		
		# Add Lines relevant for editing eg. tangents
		for i in range(0, curve.point_count):
			tangents.push_back(curve.get_point_position(i))
			tangents.push_back(curve.get_point_position(i) + curve.get_point_out(i))
			tangents.push_back(curve.get_point_position(i))
			tangents.push_back(curve.get_point_position(i) + curve.get_point_in(i))
			
			handles.push_back(curve.get_point_position(i))
			sHandles.push_back(curve.get_point_position(i) + curve.get_point_out(i))
			sHandles.push_back(curve.get_point_position(i) + curve.get_point_in(i))
	

		gizmo.add_lines(lines, get_material("main", gizmo))
		gizmo.add_lines(tangents, get_material("tangent", gizmo))
		gizmo.add_handles(handles, get_material("handles", gizmo), PackedInt32Array(range(curve.point_count)), true)
		gizmo.add_handles(sHandles, get_material("handles", gizmo), PackedInt32Array(range(curve.point_count * 2)), false, true)


# Handle Actions
func _get_handle_name(gizmo, handle_id, secondary):
	if secondary:
		return "point_tangent"
	else:
		return "point_position"


func _get_handle_value(gizmo, handle_id, secondary):
	var curve : Curve3D = gizmo.get_node_3d().shape.curve
	
	if secondary:
		if (handle_id / 2.0) - floor(handle_id / 2.0) > 0.0:
			return curve.get_point_in(floor(handle_id / 2))
		else:
			return curve.get_point_out(floor(handle_id / 2))
	else:
		return curve.get_point_position(handle_id)


func _set_handle(gizmo, handle_id, secondary, camera, screen_pos):
	var node : Node3D = gizmo.get_node_3d()
	var curve : Curve3D = node.shape.curve
	
	if !secondary:
		var global_handle_position := node.global_transform.translated_local(curve.get_point_position(handle_id)).origin
		var distance_to_camera: float = min(camera.global_position.distance_to(node.global_position), camera.global_position.distance_to(global_handle_position))
		var new_pos : Vector3 = camera.project_position(screen_pos, distance_to_camera)
		new_pos = node.global_transform.affine_inverse().translated_local(new_pos).origin
		curve.set_point_position(handle_id, new_pos)
	
	else:
		var base_point_position := curve.get_point_position(handle_id / 2)
		var global_handle_position := node.global_transform.translated_local(base_point_position + _get_handle_value(gizmo, handle_id, secondary)).origin
		var distance_to_camera: float = min(camera.global_position.distance_to(node.global_position), camera.global_position.distance_to(global_handle_position))
		var new_pos : Vector3 = camera.project_position(screen_pos, distance_to_camera)
		new_pos = node.global_transform.affine_inverse().translated_local(new_pos).origin - base_point_position

		if (handle_id / 2.0) - floor(handle_id / 2.0) > 0.0:
			curve.set_point_in(floor(handle_id / 2), new_pos)
			curve.set_point_out(floor(handle_id / 2), -new_pos)
		else:
			curve.set_point_out(floor(handle_id / 2), new_pos)
			curve.set_point_in(floor(handle_id / 2), -new_pos)
