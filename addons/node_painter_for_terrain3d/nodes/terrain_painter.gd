@tool
## Processes the shapes into a Heightmap for Terrain3D.
## Nodes are processed in order of the SceneTree and Textures will be rescaled to the largest appearing size.
class_name TerrainPainter
extends NodePainterContainer


## Base height of the Terrain. When no shape effects the terrain it will have this height.
@export_range(-20.0, 50.0) var base_height := 0.0:
	set(value):
		base_height = value
		update_terrain()
@export_range(0, 31, 1) var base_texture : int = 0:
	set(value):
		base_texture = value
		update_terrain()


var rd_device: RenderingDevice
var shader: RID
const compute_shader_file := preload("res://addons/node_painter_for_terrain3d/resources/heightmap_compute.glsl")


func _enter_tree():
	if !Engine.is_editor_hint():
		queue_free()
	
	container_type = ContainerType.TYPE_HEIGHT
	rd_device = RenderingServer.create_local_rendering_device()
	var spriv := compute_shader_file.get_spirv()
	shader = rd_device.shader_create_from_spirv(spriv, "TerrainPaintCircleCompute")

func _exit_tree():
	# Perform GPU cleanup
	if rd_device == null:
		return
	
	rd_device.free_rid(shader)
	rd_device.free()
	rd_device = null


func _procedual_update() -> void:
	# TODO: Seperate in smaller functions

	# Create Computation Pipeline
	var pipeline := rd_device.compute_pipeline_create(shader)
	var heightmaps : Dictionary[Terrain3DRegion, RID] = {}
	var control_maps : Dictionary[Terrain3DRegion, RID] = {}
	var rids : Array[RID] = []
	
	var shape_data := get_shape_data_buffer()
	
	var shape_buffer := rd_device.storage_buffer_create(shape_data["ShapeBuffer"].size(), shape_data["ShapeBuffer"])
	rids.push_back(shape_buffer)
	
	var shape_uniform := RDUniform.new()
	shape_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	shape_uniform.binding = 2
	shape_uniform.add_id(shape_buffer)
	
	var stamps := rd_device.texture_create(shape_data["Format"], RDTextureView.new(), shape_data["Data"])
	rids.push_back(stamps)
	
	var stamp_sampler := RDSamplerState.new()
	stamp_sampler.repeat_u = 3
	stamp_sampler.repeat_v = 3
	stamp_sampler.repeat_w = 3
	var ssid := rd_device.sampler_create(stamp_sampler)
	rids.push_back(ssid)
	
	var stamp_uniform := RDUniform.new()
	stamp_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	stamp_uniform.binding = 3
	stamp_uniform.add_id(ssid)
	stamp_uniform.add_id(stamps)
	
	
	if terrainNode and shape_data["ShapeBuffer"].size() > 8:
		# retrive Region data
		var regions := terrainNode.data.get_regions_active()
		var rg_size := 256
		if regions.size() > 0:
			rg_size = regions.front().region_size
		
		for region: Terrain3DRegion in regions:
			# Generate Region specific parameters
			var region_data := PackedFloat32Array([float(region.location.x), float(region.location.y), region.vertex_spacing, float(base_texture)]).to_byte_array()
			var region_buffer := rd_device.storage_buffer_create(region_data.size(), region_data)
			rids.push_back(region_buffer)
			
			var region_uniform := RDUniform.new()
			region_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			region_uniform.binding = 1
			region_uniform.add_id(region_buffer)
			
			# Generate Heightmap parameter
			var heightmap_format := RDTextureFormat.new()
			heightmap_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
			heightmap_format.width = region.region_size
			heightmap_format.height = region.region_size
			heightmap_format.usage_bits = \
				RenderingDevice.TEXTURE_USAGE_STORAGE_BIT + \
				RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT + \
				RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
			
			var heightmap_image := Image.create_empty(region.region_size, region.region_size, false, Image.FORMAT_RF)
			heightmap_image.fill(Color(base_height, base_height, base_height, 1.0))
			
			var heightmap_rid := rd_device.texture_create(heightmap_format, RDTextureView.new(), [heightmap_image.get_data()])
			rids.push_back(heightmap_rid)
			heightmaps[region] = heightmap_rid
			
			var heightmap_uniform := RDUniform.new()
			heightmap_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			heightmap_uniform.binding = 0
			heightmap_uniform.add_id(heightmap_rid)
			
			# Get Control Map
			var control_format := RDTextureFormat.new()
			control_format.format = RenderingDevice.DATA_FORMAT_R32_UINT
			control_format.width = region.region_size
			control_format.height = region.region_size
			control_format.usage_bits = \
				RenderingDevice.TEXTURE_USAGE_STORAGE_BIT + \
				RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT + \
				RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
			
			var control_img := region.get_map(Terrain3DRegion.TYPE_CONTROL)
			var control_rid := rd_device.texture_create(control_format, RDTextureView.new(), [control_img.get_data()])
			rids.push_back(control_rid)
			control_maps[region] = control_rid
			
			var control_map_uniform := RDUniform.new()
			control_map_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			control_map_uniform.binding = 4
			control_map_uniform.add_id(control_rid)
			
			
			var region_set := rd_device.uniform_set_create([heightmap_uniform, region_uniform, shape_uniform, stamp_uniform, control_map_uniform], shader, 0)
			
			# Attatch the region to the compute pipeline
			var compute_list := rd_device.compute_list_begin()
			rd_device.compute_list_bind_compute_pipeline(compute_list, pipeline)
			rd_device.compute_list_bind_uniform_set(compute_list, region_set, 0)
			rd_device.compute_list_dispatch(compute_list, region.region_size / 8, region.region_size / 8, 1)
			rd_device.compute_list_end()
		
		
		# Dispatch the Region Computations
		rd_device.submit()
		
		# TODO: Moving the following to a subthread would be ideal
		rd_device.sync()
		
		# Retrive processed heightmaps
		for region: Terrain3DRegion in heightmaps.keys():
			var hm_rid := heightmaps[region]
			var output_bytes := rd_device.texture_get_data(hm_rid, 0)
			var output_image := Image.create_from_data(rg_size, rg_size, false, Image.FORMAT_RF, output_bytes)
			
			if region.validate_map_size(output_image):
				region.set_map(Terrain3DRegion.TYPE_HEIGHT, output_image)
			
			# Contol Map retriving
			var ctrl_rid := control_maps[region]
			output_bytes = rd_device.texture_get_data(ctrl_rid, 0)
			output_image = Image.create_from_data(rg_size, rg_size, false, Image.FORMAT_RF, output_bytes)
			
			if region.validate_map_size(output_image):
				region.set_map(Terrain3DRegion.TYPE_CONTROL, output_image)
		
		
		terrainNode.data.update_maps(Terrain3DRegion.TYPE_HEIGHT)
		terrainNode.data.update_maps(Terrain3DRegion.TYPE_CONTROL)
		
		
		# Free used rids
		heightmaps.clear()
	for rid in rids:
		rd_device.free_rid(rid)
