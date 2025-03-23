@tool
## Draws the given heightmap on the terrain directly simplifying heightmap import. And creating mountain ranges extremly easy.
class_name NodePainterStamp
extends NodePainterBaseShape

## Texture to be used as a heightmap. They will be converted by the plugin to a uniform Format using values in the range [0.0, 1.0].
## Recomended are exr images with 16-Bit or higher color depth. (PNGs can only be imported at 8 Bit!)
@export var heightmap: Image:
	set(value):
		heightmap = value
		value_changed.emit()

## Size of the heightmap stamp
@export_range(1.0, 4096.0, 0.01, "or_greater") var size : float = 512.0:
	set(value):
		size = value
		gizmo_relevant_update.emit()
		value_changed.emit()

## Height scale for the map.
@export_range(1.0, 1024.0, 0.01, "or_greater") var height : float = 20.0:
	set(value):
		height = value
		value_changed.emit()
