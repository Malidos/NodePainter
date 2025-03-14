@tool
## Draws a circle on the terrain with a given interpolation size
class_name NodePainterRectangle
extends NodePainterBaseShape

## Size of the rectangular plateu
@export var size : Vector2 = Vector2(10.0, 10.0):
	set(value):
		size = value
		gizmo_relevant_update.emit()
		value_changed.emit()
