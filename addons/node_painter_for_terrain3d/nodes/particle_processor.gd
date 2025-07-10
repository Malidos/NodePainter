@tool
class_name NodePainterParticleProcessor
extends Node

@export var terrain3d: Terrain3D

@export_tool_button("Create Grid") var button = _create_grid

@export var mesh: Mesh

@export_flags_2d_navigation var disallowed_texture_ids := 0

@export_range(1.0, 1000.0) var view_distance := 50.0:
	set(value):
		view_distance = value
		grid_size = ceili(view_distance / chunk_size)
	
@export_range(8.0, 256.0) var chunk_size := 32.0:
	set(value):
		chunk_size = value
		grid_size = ceili(view_distance / chunk_size)
	
@export_range(0.125, 2.0) var instance_spacing := 1.0:
	set(value):
		instance_spacing = clamp(round(value * 16.0) / 16.0, 0.125, 2.0)

@export var process_material : Material

@export_subgroup("Particle Node Settings")
@export_range(1, 60) var particle_fps := 24

var last_pos := Vector2i.ZERO
var particle_instances : Dictionary[Vector2i, GPUParticles3D]
var grid_size : int = 1
var rows : int = 1


func _ready():
	_create_grid()


func _physics_process(_delta):
	if is_instance_valid(terrain3d):
		var camera := terrain3d.get_camera()
		if camera:
			var clipped_pos := Vector2i((Vector2(camera.global_position.x, camera.global_position.z) / chunk_size).snapped(Vector2.ONE))
			if clipped_pos != last_pos:
				_reposition_grid(clipped_pos)
				last_pos = clipped_pos
				

func _reposition_grid(center_chunk: Vector2i) -> void:
	var offset := center_chunk - last_pos
	
	var old_chunks : Array[Vector2i] = particle_instances.keys()
	var new_chunks := old_chunks.map(func(element): return element + offset)
	
	var removeC := old_chunks.filter(func(element): return !new_chunks.has(element))
	var move_toC := new_chunks.filter(func(element): return !old_chunks.has(element))
	
	var i := 0
	for key in removeC:
		var ctm : GPUParticles3D = particle_instances[key]
		particle_instances.erase(key)
		var position_to_move : Vector2i = move_toC[i]
		ctm.set_deferred("global_position", Vector3(position_to_move.x, 0.0, position_to_move.y) * chunk_size)
		ctm.call_deferred("restart", true)
		particle_instances[position_to_move] = ctm
		
		i += 1


func _create_grid() -> void:
	_destroy_grid()
	if not terrain3d:
		return
		
	var camera := terrain3d.get_camera()
	var base_pos := ( Vector3(camera.global_position.x, 0.0 ,camera.global_position.z) / chunk_size).snapped(Vector3.ONE)
	
	rows = maxi(ceili( chunk_size / instance_spacing), 1)
	var amount := rows * rows
	
	var hr := terrain3d.data.get_height_range()
	var s := Vector3(chunk_size, hr.x - hr.y ,chunk_size)
	var aabb := AABB(s * -0.5, s)
	aabb.position.y = hr.y
	
	_update_process_uniforms()
	
	var seed : int
	
	for x in range(-grid_size, grid_size + 1):
		for z in range(-grid_size, grid_size + 1):
			var particle_node := GPUParticles3D.new()
			particle_node.lifetime = 600.0
			particle_node.draw_pass_1 = mesh
			particle_node.amount = amount
			particle_node.process_material = ParticleProcessMaterial.new()
			particle_node.fixed_fps = particle_fps
			particle_node.preprocess = 1.0 / float(particle_fps)
			particle_node.custom_aabb = aabb
			particle_node.explosiveness = 1.0
			particle_node.process_material = process_material
			particle_node.use_fixed_seed = true
			
			if seed:
				particle_node.seed = seed
			else:
				seed = particle_node.seed
			
			self.add_child(particle_node)
			particle_node.global_position = (Vector3(x, 0.0, z) + base_pos) * chunk_size
			particle_instances[Vector2i(x + base_pos.x, z + base_pos.z)] = particle_node


func _destroy_grid() -> void:
	if particle_instances:
		for node: GPUParticles3D in particle_instances.values():
			if is_instance_valid(node):
				node.queue_free()
		particle_instances.clear()


func _update_process_uniforms() -> void:
	if process_material and terrain3d:
		var rid := process_material.get_rid()
		var params := terrain3d.material._shader_parameters
		
		RenderingServer.material_set_param(rid, "_texture_restrictions", disallowed_texture_ids)
		RenderingServer.material_set_param(rid, "_rows", rows)
		RenderingServer.material_set_param(rid, "_instance_spacing", instance_spacing)
		RenderingServer.material_set_param(rid, "_background_mode", terrain3d.material.world_background)
		RenderingServer.material_set_param(rid, "_vertex_spacing", terrain3d.vertex_spacing)
		RenderingServer.material_set_param(rid, "_vertex_density", 1.0 / terrain3d.vertex_spacing)
		RenderingServer.material_set_param(rid, "_region_size", terrain3d.region_size)
		RenderingServer.material_set_param(rid, "_region_texel_size", 1.0 / terrain3d.region_size)
		RenderingServer.material_set_param(rid, "_region_map_size", 32)
		RenderingServer.material_set_param(rid, "_region_map", terrain3d.data.get_region_map())
		RenderingServer.material_set_param(rid, "_region_locations", terrain3d.data.get_region_locations())
		
		
		RenderingServer.material_set_param(rid, "_texture_uv_scale_array", terrain3d.assets.get_texture_uv_scales())
		RenderingServer.material_set_param(rid, "_texture_detile_array", terrain3d.assets.get_texture_detiles())
		RenderingServer.material_set_param(rid, "_texture_color_array", terrain3d.assets.get_texture_colors())
		
		RenderingServer.material_set_param(rid, "_height_maps", terrain3d.data.get_height_maps_rid())
		RenderingServer.material_set_param(rid, "_control_maps", terrain3d.data.get_control_maps_rid())
		RenderingServer.material_set_param(rid, "_color_maps", terrain3d.data.get_color_maps_rid())
		RenderingServer.material_set_param(rid, "_texture_array_albedo", terrain3d.assets.get_albedo_array_rid())
		RenderingServer.material_set_param(rid, "noise_texture", params["noise_texture"])
		
		RenderingServer.material_set_param(rid, "blend_sharpness", params["blend_sharpness"])
		RenderingServer.material_set_param(rid, "auto_base_texture", params["auto_base_texture"])
		RenderingServer.material_set_param(rid, "auto_overlay_texture", params["auto_overlay_texture"])
		RenderingServer.material_set_param(rid, "auto_slope", params["auto_slope"])
		RenderingServer.material_set_param(rid, "auto_height_reduction", params["auto_height_reduction"])
		RenderingServer.material_set_param(rid, "enable_projection", params["enable_projection"])
		RenderingServer.material_set_param(rid, "projection_threshold", params["projection_threshold"])
		RenderingServer.material_set_param(rid, "projection_angular_division", params["projection_angular_division"])
		RenderingServer.material_set_param(rid, "enable_macro_variation", params["enable_macro_variation"])
		RenderingServer.material_set_param(rid, "macro_variation1", params["macro_variation1"])
		RenderingServer.material_set_param(rid, "macro_variation2", params["macro_variation2"])
		RenderingServer.material_set_param(rid, "macro_variation_slope", params["macro_variation_slope"])
		RenderingServer.material_set_param(rid, "noise1_scale", params["noise1_scale"])
		RenderingServer.material_set_param(rid, "noise1_angle", params["noise1_angle"])
		RenderingServer.material_set_param(rid, "noise1_offset", params["noise1_offset"])
		RenderingServer.material_set_param(rid, "noise2_scale", params["noise2_scale"])
		RenderingServer.material_set_param(rid, "noise3_scale", params["noise3_scale"])
