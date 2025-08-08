@tool
extends SubViewport


enum mode {SAMPLING_NOTHING, SAMPLING_ALBEDO, SAMPLING_NORMAL}

## When sampling has completed this signal will return the results. It will takes multiple frames after calling sample_billboard_arrays befor the signal is emited.
signal sampling_done(sampled_dic: Dictionary)


var intermid_pictures: Array[Image]
var extra_cull_margin := Vector2.ONE * 0.1
@export_storage var _views : int = 8:
	set(value):
		_views = value
		_step_rotation = (2.0*PI) / value
var _step_rotation := 0.25 * PI
var _executed_views : int = 0
var in_progress : mode = mode.SAMPLING_NOTHING

var _aabb_size := Vector2.ONE
var _y_offset := 0.0

## Pixels used on the billboard for one meter in worldspace
var base_resolution := 16
@onready var cameraP : Node3D = get_node(^"CameraPivot")

## Adds the given scene to a Subviewport and generates billboards from that. A result is returned through sampling_done.
func sample_billboard_arrays(scene: PackedScene, cull_margin := Vector2.ZERO, views := 8):
	extra_cull_margin = cull_margin
	_views = views
	var s := scene.instantiate()
	add_child(s)
	
	call_deferred(&"_take_billboard_pictures")


func _process(_delta):
	if in_progress == 1:
		debug_draw = Viewport.DEBUG_DRAW_DISABLED
		transparent_bg = true
		
		cameraP.rotation.y = _step_rotation * _executed_views
		_executed_views += 1
		call_deferred(&"_retrive_picture")
		
		if _executed_views == _views:
			_executed_views = 0
			in_progress = mode.SAMPLING_NORMAL
	
	elif in_progress == 2:
		debug_draw = Viewport.DEBUG_DRAW_NORMAL_BUFFER
		transparent_bg = false
		
		cameraP.rotation.y = _step_rotation * _executed_views
		_executed_views += 1
		call_deferred(&"_retrive_picture")
		
		if _executed_views == _views:
			_executed_views = 0
			in_progress = mode.SAMPLING_NOTHING
			call_deferred(&"_save_pictures")


func _take_billboard_pictures() -> void:
	# Retrive an approximate geometry size
	await RenderingServer.frame_post_draw
	var combined_aabb := AABB()
	for c: GeometryInstance3D in find_children("*", "GeometryInstance3D", true, false):
		var instance_aabb := c.get_aabb()
		instance_aabb.position += c.global_position
		combined_aabb = combined_aabb.merge(instance_aabb)
	
	# Vertical Centering
	var geometry_center := combined_aabb.get_center()
	cameraP.position.y = geometry_center.y
	_y_offset = geometry_center.y
	
	# Sizing
	_aabb_size = Vector2(max(combined_aabb.size.x, combined_aabb.size.z) ,combined_aabb.size.y)
	_aabb_size += extra_cull_margin
	_aabb_size.x += max(abs(geometry_center.x), abs(geometry_center.z))
	
	
	var cam := get_camera_3d()
	cam.size = _aabb_size.y
	var ratio := _aabb_size.x / _aabb_size.y
	var calc_size = Vector2i(ceili(_aabb_size.x * base_resolution) , ceili(_aabb_size.y * base_resolution))
	size = calc_size.max(Vector2i(floori(48.0 * ratio), 48)).max(Vector2i(32, 32))
	
	set_deferred("in_progress", 1)

func _retrive_picture() -> void:
	await RenderingServer.frame_post_draw
	intermid_pictures.append(get_texture().get_image())
	

func _save_pictures() -> void:
	await RenderingServer.frame_post_draw
	var img_array1 := Texture2DArray.new()
	var img_array2 := Texture2DArray.new()
	img_array1.create_from_images(intermid_pictures.slice(0, _views))
	img_array2.create_from_images(intermid_pictures.slice(_views))
	intermid_pictures.clear()
	
	var return_dic := {}
	return_dic["size"] = _aabb_size
	return_dic["y_offset"] = _y_offset
	return_dic["albedo"] = img_array1
	return_dic["normal"] = img_array2
	sampling_done.emit(return_dic)
	queue_free()
