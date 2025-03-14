@tool
## Draws a circle on the terrain with a given interpolation size
class_name NodePainterCircle
extends NodePainterBaseShape

## Radius of the Circle plateu
@export_range(0.1, 100.0, 0.01, "or_greater") var radius := 10.0:
	set(value):
		radius = value
		gizmo_relevant_update.emit()
		value_changed.emit()
