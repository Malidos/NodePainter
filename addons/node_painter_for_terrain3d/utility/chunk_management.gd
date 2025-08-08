@tool
extends Node

@export var _terrainNode : Terrain3D
@export_storage var _chunk_count: int = 1
@export_storage var _radius: int = 2
var _managed_nodes : Dictionary[Vector2i, Array] = {}

var _cameraNode : Camera3D
@export var _current_chunk := Vector2i.ZERO
var _current_active_chunks: Array[Vector2i] = []

func _ready():
	if _terrainNode:
		var cam := _terrainNode.get_camera()
		if is_instance_valid(cam):
			_cameraNode = cam
	
	child_entered_tree.connect(_child_entered)
	child_exiting_tree.connect(_child_exiting)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(_delta):
	if is_instance_valid(_cameraNode) and is_node_ready():
		var c := _calculate_chunk(_cameraNode.global_position)
		if c != _current_chunk:
			_current_chunk = c
			_update_active_chunks()
		
	else:
		if _terrainNode:
			var cam := _terrainNode.get_camera()
			if is_instance_valid(cam):
				_cameraNode = cam

func _update_active_chunks() -> void:
	var center := _current_chunk
	
	var new_cs := _get_active_chunks(center)
	var remove_chunks := _current_active_chunks.filter(func(value): return not new_cs.has(value))
	var activate_chunks :=  new_cs.filter(func(value): return not _current_active_chunks.has(value))
	
	for a: Vector2i in activate_chunks:
		if _managed_nodes.has(a):
			for node: Node in _managed_nodes[a]:
				if is_instance_valid(node):
					node.set_deferred(&"process_mode", Node.PROCESS_MODE_INHERIT)
	
	for d: Vector2i in remove_chunks:
		if _managed_nodes.has(d):
			for node: Node in _managed_nodes[d]:
				if is_instance_valid(node):
					node.set_deferred(&"process_mode", Node.PROCESS_MODE_DISABLED)
	
	_current_active_chunks = new_cs


func _calculate_chunk(global_pos: Vector3) -> Vector2i:
	var region_space := global_pos * _chunk_count  / (float(_terrainNode.region_size) * _terrainNode.vertex_spacing)
	
	return Vector2i(
		floori(region_space.x),
		floori(region_space.z)
	)


func _get_active_chunks(center: Vector2i) -> Array[Vector2i]:
	var candidate_grid : Array[Vector2i] = []
	for x in range(-_radius, _radius + 1):
		for y in range(-_radius, _radius + 1):
			candidate_grid.push_back(
				center + Vector2i(x,y)
			)
	
	var radius2 := _radius * _radius
	var final_chunks := candidate_grid.filter(func(value: Vector2i):
		return (value - center).length_squared() < radius2
		)
	
	return final_chunks


func _child_entered(child: Node) -> void:
	if child.has_meta(&"chunk"):
		var chunk : Vector2i = child.get_meta(&"chunk", Vector2i.ZERO)
		
		if _managed_nodes.has(chunk):
			_managed_nodes[chunk].push_back(child)
		
		else:
			var arr : Array[Node] = [child]
			_managed_nodes[chunk] = arr

func _child_exiting(child: Node) -> void:
	if child.has_meta(&"chunk"):
		var chunk : Vector2i = child.get_meta(&"chunk", Vector2i.ZERO)
		if _managed_nodes.has(chunk):
			_managed_nodes[chunk].erase(child)

func setup(TerrainNode: Terrain3D, ChunkSize: int, radius: int) -> void:
	_terrainNode = TerrainNode
	_chunk_count = ChunkSize
	_radius = max(2, radius)
