@tool
class_name NodePainter
extends EditorPlugin

const container_script = preload("res://addons/node_painter_for_terrain3d/nodes/node_painter_container.gd")
const shape_script = preload("res://addons/node_painter_for_terrain3d/nodes/node_painter_shape.gd")
const circleGizmoPlugin = preload("res://addons/node_painter_for_terrain3d/gizmos/circle_gizmo.gd")
const rectangleGizmoPlugin = preload("res://addons/node_painter_for_terrain3d/gizmos/rectangle_gizmo.gd")
const pathGizmoPlugin = preload("res://addons/node_painter_for_terrain3d/gizmos/path_gizmo.gd")
const polygonGizmoPlugin = preload("res://addons/node_painter_for_terrain3d/gizmos/polygon_gizmo.gd")

var gizmo_circle = circleGizmoPlugin.new()
var gizmo_rectangle = rectangleGizmoPlugin.new()
var gizmo_path = pathGizmoPlugin.new()
var gizmo_polygon = polygonGizmoPlugin.new()

func _enter_tree():
	# Initialization of the plugin goes here.
	if Engine.is_editor_hint() and !FileAccess.file_exists("res://addons/terrain_3d/terrain.gdextension"):
		push_warning("Terrain3D doesn't seem to exsist. Install it to make use of NodePainter.")
	
	# Add Resources
	add_custom_type("NodePainterBaseShape", "Resource", preload("res://addons/node_painter_for_terrain3d/resources/base_shape.gd"), EditorInterface.get_editor_theme().get_icon("CollisionShape2D", "EditorIcons"))
	add_custom_type("NodePainterCircle", "PaintShape", preload("res://addons/node_painter_for_terrain3d/resources/circle_shape.gd"), EditorInterface.get_editor_theme().get_icon("CircleShape2D", "EditorIcons"))
	add_custom_type("NodePainterRectangle", "PaintShape", preload("res://addons/node_painter_for_terrain3d/resources/rectangle_shape.gd"), EditorInterface.get_editor_theme().get_icon("RectangleShape2D", "EditorIcons"))
	add_custom_type("NodePainterPath", "PaintShape", preload("res://addons/node_painter_for_terrain3d/resources/path_shape.gd"), EditorInterface.get_editor_theme().get_icon("Path3D", "EditorIcons"))
	add_custom_type("NodePainterPolygon", "PaintShape", preload("res://addons/node_painter_for_terrain3d/resources/polygon_shape.gd"), EditorInterface.get_editor_theme().get_icon("CollisionPolygon2D", "EditorIcons"))

	# Add Script Types
	add_custom_type("NodePainterContainer", "Node3D", container_script, EditorInterface.get_editor_theme().get_icon("CanvasLayer", "EditorIcons"))
	add_custom_type("NodePainterShape", "Node3D", shape_script, EditorInterface.get_editor_theme().get_icon("CollisionShape3D", "EditorIcons"))
	
	# Add Gizmo Plugin
	add_node_3d_gizmo_plugin(gizmo_circle)
	add_node_3d_gizmo_plugin(gizmo_rectangle)
	add_node_3d_gizmo_plugin(gizmo_path)
	add_node_3d_gizmo_plugin(gizmo_polygon)


func _exit_tree():
	# Clean-up of the plugin
	remove_custom_type("NodePainterContainer")
	remove_custom_type("NodePainterShape")
	remove_custom_type("NodePainterRectangle")
	remove_custom_type("NodePainterCircle")
	remove_custom_type("NodePainterBaseShape")
	remove_custom_type("NodePainterPath")
	remove_custom_type("NodePainterPolygon")
	
	remove_node_3d_gizmo_plugin(gizmo_circle)
	remove_node_3d_gizmo_plugin(gizmo_rectangle)
	remove_node_3d_gizmo_plugin(gizmo_path)
	remove_node_3d_gizmo_plugin(gizmo_polygon)
