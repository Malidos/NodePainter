@tool
## Base resource all other shapes inherit. By itself it doesn't do anything.
class_name NodePainterBaseShape
extends Resource

signal gizmo_relevant_update
signal value_changed

## The Shape is extended by that distance where the original height and shape height are interpolated. You could also call this a transition "steepness".
@export_range(0.1, 50.0, 0.01, "or_greater") var transition_size := 4.0:
	set(value):
		transition_size = max(0.1, value)
		gizmo_relevant_update.emit()
		value_changed.emit()

# Type of transition to use between the terrain and shape height
@export_enum("Smoothstep", "Linear", "Ease in", "Ease out") var transition_type := 0:
	set(value):
		transition_type = value
		value_changed.emit()
	get():
		return float(transition_type)
