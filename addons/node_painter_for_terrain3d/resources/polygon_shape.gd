@tool
## Draws a 2D Polygon on the terrain with a given interpolation size
class_name NodePainterPolygon
extends NodePainterBaseShape

## Points of the Polygon
@export var points := PackedVector2Array([Vector2(1.0, 0.0), Vector2(0.0, 1.0)]):
	set(value):
		points = value
		gizmo_relevant_update.emit()
		value_changed.emit()
