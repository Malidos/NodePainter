@tool
## Draws a path on the terrain with a curve
class_name NodePainterPath
extends NodePainterBaseShape

## Curve used for terrain generation
@export var curve: Curve3D:
	set(value):
		if curve:
			curve.changed.disconnect(_emit_update)
		
		curve = value
		if value:
			value.changed.connect(_emit_update)

## Width of the curve drawn on the terrain. You could call this the width of the path.
@export_range(0.1, 50.0, 0.01, "or_greater") var thickness := 5.0:
	set(value):
		thickness = value
		gizmo_relevant_update.emit()
		value_changed.emit()

## Calling this functions emits all relevant Signals for the plugin
func _emit_update() -> void:
	gizmo_relevant_update.emit()
	value_changed.emit()
