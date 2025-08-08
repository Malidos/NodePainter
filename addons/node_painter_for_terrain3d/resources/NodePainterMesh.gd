@tool
## A resource used to set up scenes used for the Foliage Painter
class_name NodePainterMesh
extends Resource

enum grouping {INSTANCE_SCENES_ALLWAYS, INSTANCE_SCENES_BILLBOARDS, INSTANCE_SCENES_NEVER}

signal _billboard_changed()

@export var scene: PackedScene:
	set(value):
		scene = value
		emit_changed()
@export var instancing: grouping = grouping.INSTANCE_SCENES_BILLBOARDS:
	set(value):
		instancing = value
		emit_changed()

@export_subgroup("Lod Settings")
## When true the plugin assumes the scene doesn't contain any billboards and generates its own (recommended). When false the plugin tries to find what it assumes are billboards and uses them instead.
@export var generate_billboards := true:
	set(value):
		generate_billboards = value
		billboard_mesh = null
		emit_changed()
@export_range(1,16,1,"or_greater") var billboard_views := 8:
	set(value):
		billboard_views = value
		billboard_mesh = null
		emit_changed() 
@export var billboard_cull_margin := Vector2.ZERO:
	set(value):
		billboard_cull_margin = value
		billboard_mesh = null
		emit_changed() 
## The radius in chunks where billboards start to appear.
@export var billboard_radius := 2:
	set(value):
		billboard_radius = value
		emit_changed()
## Distance in meters where billboards disappear again. Set to 0 when no billboards should be used.
@export_range(0.0, 800.0, 5.0, "or_greater") var max_billboard_distance := 400.0
@export_flags_3d_render var billboard_render_layer := 1

@export_subgroup("Generation Settings")
@export_range(0.02, 2.0) var density := 0.15:
	set(value):
		density = value
		emit_changed()
## Negative values indicate that instances are only placed on a slope
@export_range(-1.0, 1.0) var slope_restriction := 0.2:
	set(value):
		slope_restriction = value
		emit_changed()
@export_range(0.0, 1.0) var terrain_normal_influence := 0.1:
	set(value):
		terrain_normal_influence = value
		emit_changed()
@export_range(0.0, 20.0,0.05, "or_greater") var random_offset := 4.0:
	set(value):
		random_offset = value
		emit_changed()
@export_range(0.0, 1.0, 0.05, "or_greater") var random_scale := 0.2:
	set(value):
		random_scale = value
		emit_changed()
@export_range(0.0, 1.0) var condition_randomness := 0.15:
	set(value):
		condition_randomness = value
		emit_changed()
## Refers to a randomized Basis in 3D. Usefull for Meshes that can be placed in any Orientation. Rotation around the y-Axis is always random to avoid repition.
@export_range(0.0, 1.0) var randomize_rotation := 0.0:
	set(value):
		randomize_rotation = value
		emit_changed()


@export_storage var billboard_map_albedo: Texture2DArray
@export_storage var billboard_map_normal: Texture2DArray
@export_storage var billboard_mesh: Mesh:
	set(value):
		billboard_mesh = value
		if billboard_mesh:
			_billboard_changed.emit()
