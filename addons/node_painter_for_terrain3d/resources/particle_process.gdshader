shader_type particles;
render_mode disable_force, disable_velocity;

uniform float position_randomness: hint_range(0.0, 2.0, 0.005) = 0.01;
uniform float normal_strength : hint_range(0.01, 1.0, 0.01) = 0.3;
uniform float random_scale: hint_range(0.0, 2.0, 0.01) = 0.1;
uniform bool do_color_sampling = true;
uniform float color_sampling_blur: hint_range(0.0, 4.0) = 0.3;

group_uniforms position_restriction;
uniform float condition_dithering: hint_range(0.0, 1.0) = 0.1;
uniform float slope_restrict: hint_range(-1.0, 1.0, 0.01) = 0.5;
uniform float min_height = -1.0;
uniform mediump sampler2DArray _sdf_maps: hint_default_white, filter_linear_mipmap, repeat_disable;
uniform highp uint _texture_restrictions = 0;

group_uniforms _Terrain_3D_Uniforms; // uniforms below are read from the Terrain3D Node
uniform float blend_sharpness: hint_range(0.0, 1.0) = 0.87;
uniform int auto_base_texture = 0;
uniform int auto_overlay_texture = 1;
uniform float auto_slope = 1.0;
uniform float auto_height_reduction = 0.1;
uniform bool vertical_projection = true;
uniform float projection_threshold = 0.8;

uniform bool macro_variation = true;
uniform vec3 macro_variation1 = vec3(1.0);
uniform vec3 macro_variation2 = vec3(1.0);
uniform float macro_variation_slope : hint_range(0.0, 1.0) = 0.333333;
uniform float noise1_scale = 0.04;
uniform float noise1_angle = 0.0;
uniform vec2 noise1_offset = vec2(0.5);
uniform float noise2_scale = 0.076;

uniform uint _rows = 1;
uniform float _instance_spacing = 1.0;
uniform uint _background_mode = 0u;
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0; // = 1/_vertex_spacing
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1/REGION_SIZE
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
uniform float _texture_uv_scale_array[32];
uniform vec2 _texture_detile_array[32];
uniform vec4 _texture_color_array[32];
uniform uint _texture_vertical_projections;
uniform highp sampler2DArray _height_maps : repeat_disable, hint_default_black;
uniform highp sampler2DArray _control_maps : repeat_disable, hint_default_white;
uniform highp sampler2DArray _color_maps : repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform highp sampler2DArray _texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform highp sampler2D noise_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

uniform float mipmap_bias : hint_range(0.5, 1.5, 0.01) = 1.0;
uniform float depth_blur : hint_range(0.0, 35.0, 0.1) = 0.0;
uniform float bias_distance : hint_range(0.0, 16384.0, 0.1) = 512.0;

// Defined Constants
#define SKIP_PASS 0
#define VERTEX_PASS 1
#define FRAGMENT_PASS 2

struct material {
	vec4 albedo_height;
	vec4 normal_rough;
	float normal_map_depth;
	float ao_strength;
	float total_weight;
};


#define DECODE_SCALE(control) (0.9 - float(((control >>7u & 0x7u) + 3u) % 8u + 1u) * 0.1)
#define DECODE_ANGLE(control) float(control >>10u & 0xFu) * -0.392699081698724
#define DECODE_BLEND(control) float(control >> 14u & 0xFFu) * 0.003921568627450
#define DECODE_HOLE(control) bool(control >>2u & 0x1u)
#define TEXTURE_ID_PROJECTED(id) bool((_texture_vertical_projections >> uint(id)) & 0x1u)


ivec3 get_index_coord(const vec2 uv, const int search) {
	vec2 r_uv = round(uv);
	vec2 o_uv = mod(r_uv,_region_size);
	ivec2 pos;
	int bounds, layer_index = -1;
	for (int i = -1; i < clamp(search, SKIP_PASS, FRAGMENT_PASS); i++) {
		if ((layer_index == -1 && _background_mode == 0u ) || i < 0) {
			r_uv -= i == -1 ? vec2(0.0) : vec2(float(o_uv.x <= o_uv.y), float(o_uv.y <= o_uv.x));
			pos = ivec2(floor((r_uv) * _region_texel_size)) + (_region_map_size / 2);
			bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
			layer_index = (_region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1);
		}
	}
	return ivec3(ivec2(mod(r_uv,_region_size)), layer_index);
}

mat3 align_to_vector(vec3 normal) {
	vec3 up = vec3(0.0, 1.0, 0.0);
	if (abs(dot(normal, up)) > 0.9999) { // Avoid singularity
		up = vec3(1.0, 0.0, 0.0);
	}
	vec3 tangent = normalize(cross(up, normal));
	vec3 bitangent = normalize(cross(tangent, normal));
	return mat3(tangent, normal, bitangent);
}

mat3 rotation_matrix(vec3 axis, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	float t = 1.0 - c;
	vec3 n = normalize(axis);
	float x = n.x;
	float y = n.y;
	float z = n.z;

	return mat3(
		vec3(t * x * x + c, t * x * y - z * s, t * x * z + y * s),
		vec3(t * x * y + z * s, t * y * y + c, t * y * z - x * s),
		vec3(t * x * z - y * s, t * y * z + x * s, t * z * z + c));
}

float hash(uint n) {
	// integer hash copied from Hugo Elias
	n = (n << 13U) ^ n;
	n = n * (n * n * 15731U + 0x789221U) + 0x13761289U;
	return float(n & uint(0x7fffffffU)) / float(0x7fffffff);
}

// Takes in descaled (world_space / region_size) world to region space XZ (UV2) coordinates, returns vec3 with:
// XY: (0. to 1.) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
vec3 get_index_uv(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int layer_index = _region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1;
	return vec3(uv2 - _region_locations[layer_index], float(layer_index));
}


float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 rotate_vec2(const vec2 v, const vec2 cs) {
	return vec2(fma(cs.x, v.x,  cs.y * v.y), fma(cs.x, v.y, -cs.y * v.x));
}

// 2-4 lookups ( 2-6 with dual scaling )
void accumulate_material(vec3 base_ddx, vec3 base_ddy, const float weight, const ivec3 index, const uint control,
			const vec2 texture_weight, const ivec2 texture_id, const vec3 i_normal, float h, inout material mat, vec3 v_vertex) {

	// Applying scaling before projection reduces the number of multiplys ops required.
	vec3 i_vertex = v_vertex;

	// Control map scale
	float control_scale = DECODE_SCALE(control);
	// tri scaling
	if (index.z < 0) {
		control_scale *= 0.3;
	}
	base_ddx *= control_scale;
	base_ddy *= control_scale;
	i_vertex *= control_scale;
	h *= control_scale;

	// Index position for detiling.
	vec2 i_pos = fma(_region_locations[index.z], vec2(_region_size), vec2(index.xy));
	i_pos *= _vertex_spacing * control_scale;

	// Projection
	vec2 i_uv = i_vertex.xz;
	vec4 i_dd = vec4(base_ddx.xz, base_ddy.xz);
	mat2 p_align = mat2(1.);
	vec2 p_uv = i_uv;
	vec4 p_dd = i_dd;
	vec2 p_pos = i_pos;
	if (i_normal.y <= projection_threshold && vertical_projection) {
		// Projected normal map alignment matrix
		p_align = mat2(vec2(i_normal.z, -i_normal.x), vec2(i_normal.x, i_normal.z));
		// Fast 45 degree snapping https://iquilezles.org/articles/noatan/
		vec2 xz = round(normalize(-i_normal.xz) * 1.3065629648763765); // sqrt(1.0 + sqrt(0.5))
		xz *= abs(xz.x) + abs(xz.y) > 1.5 ? 0.7071067811865475 : 1.0; // sqrt(0.5)
		xz = vec2(-xz.y, xz.x);
		p_pos = floor(vec2(dot(i_pos, xz), -h));
		p_uv = vec2(dot(i_vertex.xz, xz), -i_vertex.y);
		p_dd.xy = vec2(dot(base_ddx.xz, xz), -base_ddx.y);
		p_dd.zw = vec2(dot(base_ddy.xz, xz), -base_ddy.y);
	}

	// Control map rotation. Must be applied seperatley from detiling to maintain UV continuity.
	float c_angle = DECODE_ANGLE(control);
	vec2 c_cs_angle = vec2(cos(c_angle), sin(c_angle));
	i_uv = rotate_vec2(i_uv, c_cs_angle);
	i_pos = rotate_vec2(i_pos, c_cs_angle);
	p_uv = rotate_vec2(p_uv, c_cs_angle);
	p_pos = rotate_vec2(p_pos, c_cs_angle);

	// Blend adjustment of Higher ID from Lower ID normal map in world space.
	float world_normal = 1.;
	vec3 T = normalize(base_ddx), B = -normalize(base_ddy);
	// mat3 multiply, reduced to 2x fma and 1x mult.
	#define FAST_WORLD_NORMAL(n) fma(T, vec3(n.x), fma(B, vec3(n.z), i_normal * vec3(n.y)))

	float blend = DECODE_BLEND(control); // only used for branching.
	float sharpness = fma(56., blend_sharpness, 8.);


	// 1st Texture Asset ID
	if (blend < 1.0) {
		const int id = texture_id[0];
		bool projected = TEXTURE_ID_PROJECTED(id);
		const float id_w = texture_weight[0];
		float id_scale = _texture_uv_scale_array[id];
		vec4 id_dd = fma(p_dd, vec4(float(projected)), i_dd * vec4(float(!projected))) * id_scale;

		// Detiling and Control map rotation
		vec2 id_pos = fma(p_pos, vec2(float(projected)), i_pos * vec2(float(!projected)));
		vec2 uv_center = floor(fma(id_pos, vec2(id_scale), vec2(0.5)));
		vec2 id_detile = fma(random(uv_center), 2.0, -1.0) * _texture_detile_array[id] * TAU;
		vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
		// Apply UV rotation and shift around pivot.
		vec2 id_uv = fma(p_uv, vec2(float(projected)), i_uv * vec2(float(!projected)));
		id_uv = rotate_vec2(fma(id_uv, vec2(id_scale), -uv_center), id_cs_angle) + uv_center + id_detile.y - 0.5;
		// Manual transpose to rotate derivatives and normals counter to uv rotation whilst also
		// including control map rotation. avoids extra matrix op, and sin/cos calls.
		id_cs_angle = vec2(
			fma(id_cs_angle.x, c_cs_angle.x, -id_cs_angle.y * c_cs_angle.y),
			fma(id_cs_angle.y, c_cs_angle.x, id_cs_angle.x * c_cs_angle.y));
		// Align derivatives for correct anisotropic filtering
		id_dd.xy = rotate_vec2(id_dd.xy, id_cs_angle);
		id_dd.zw = rotate_vec2(id_dd.zw, id_cs_angle);

		vec4 alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		vec4 nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		alb.rgb *= _texture_color_array[id].rgb;
		// Unpack and rotate normal map.
		nrm.xyz = fma(nrm.xzy, vec3(2.0), vec3(-1.0));
		nrm.xz = rotate_vec2(nrm.xz, id_cs_angle);
		nrm.xz = fma((nrm.xz * p_align), vec2(float(projected)), nrm.xz * vec2(float(!projected)));

		world_normal = FAST_WORLD_NORMAL(nrm).y;

		float id_weight = exp2(sharpness * log2(weight + id_w + alb.a)) * weight;
		mat.albedo_height = fma(alb, vec4(id_weight), mat.albedo_height);
		mat.total_weight += id_weight;
	}

	// 2nd Texture Asset ID
	if (blend > 0.0) {
		const int id = texture_id[1];
		bool projected = TEXTURE_ID_PROJECTED(id);
		const float id_w = texture_weight[1];
		float id_scale = _texture_uv_scale_array[id];
		vec4 id_dd = fma(p_dd, vec4(float(projected)), i_dd * vec4(float(!projected))) * id_scale;

		// Detiling and Control map rotation
		vec2 id_pos = fma(p_pos, vec2(float(projected)), i_pos * vec2(float(!projected)));
		vec2 uv_center = floor(fma(id_pos, vec2(id_scale), vec2(0.5)));
		vec2 id_detile = fma(random(uv_center), 2.0, -1.0) * _texture_detile_array[id] * TAU;
		vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
		// Apply UV rotation and shift around pivot.
		vec2 id_uv = fma(p_uv, vec2(float(projected)), i_uv * vec2(float(!projected)));
		id_uv = rotate_vec2(fma(id_uv, vec2(id_scale), -uv_center), id_cs_angle) + uv_center + id_detile.y - 0.5;
		// Manual transpose to rotate derivatives and normals counter to uv rotation whilst also
		// including control map rotation. avoids extra matrix op, and sin/cos calls.
		id_cs_angle = vec2(
			fma(id_cs_angle.x, c_cs_angle.x, -id_cs_angle.y * c_cs_angle.y),
			fma(id_cs_angle.y, c_cs_angle.x, id_cs_angle.x * c_cs_angle.y));
		// Align derivatives for correct anisotropic filtering
		id_dd.xy = rotate_vec2(id_dd.xy, id_cs_angle);
		id_dd.zw = rotate_vec2(id_dd.zw, id_cs_angle);

		vec4 alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		alb.rgb *= _texture_color_array[id].rgb;

		float id_weight = exp2(sharpness * log2(weight + id_w + alb.a * clamp(world_normal, 0., 1.))) * weight;
		mat.albedo_height = fma(alb, vec4(id_weight), mat.albedo_height);
		mat.total_weight += id_weight;
	}
}


void start() {
	vec3 position = vec3(float(INDEX % _rows), 0.0, float(INDEX / _rows)) - float(_rows >> 1u);
	position.xz *= _instance_spacing;
	position.xz += EMISSION_TRANSFORM[3].xz;

	float r = hash(RANDOM_SEED + INDEX + uint(position.x + position.y));
	float r_alt = hash(RANDOM_SEED - INDEX * 2u + uint(position.x - position.y) + 251u);
	float rand_angle = r_alt * 2.0 * PI;
	vec2 rand_offset = vec2(cos(rand_angle), sin(rand_angle)) * position_randomness;
	position.xz += rand_offset;

	// Part from Terrain3D
	// Lookup offsets, ID and blend weight
	vec2 uv = position.xz * _vertex_density;
	vec2 uv2 = fma(uv, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));

	vec3 region_uv = get_index_uv(uv2);
	const vec3 offsets = vec3(0, 1, 2);
	vec2 index_id = floor(uv);
	vec2 weight = fract(uv);
	vec2 invert = 1.0 - weight;
	vec4 weights = vec4(
		invert.x * weight.y, // 0
		weight.x * weight.y, // 1
		weight.x * invert.y, // 2
		invert.x * invert.y  // 3
	);

	ivec3 index[4];
	// Map lookups
	index[0] = get_index_coord(index_id + offsets.xy, 2);
	index[1] = get_index_coord(index_id + offsets.yy, 2);
	index[2] = get_index_coord(index_id + offsets.yx, 2);
	index[3] = get_index_coord(index_id + offsets.xx, 2);

	vec3 base_ddx = vec3(color_sampling_blur);//dFdxCoarse(v_vertex);
	vec3 base_ddy = vec3(color_sampling_blur);//dFdyCoarse(v_vertex);

	// Terrain normals
	vec3 index_normal[4];
	float h[4];
	// allows additional derivatives, eg world noise, brush previews etc
	float u = 0.0;
	float v = 0.0;

	// Read control map
	uvec4 control = uvec4(
		floatBitsToUint(texelFetch(_control_maps, index[0], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[1], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[2], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[3], 0).r));

	float sdfm[4];
	sdfm[0] = texelFetch(_sdf_maps, index[0], 0).r; // 0 (0,1)
	sdfm[1] = texelFetch(_sdf_maps, index[1], 0).r; // 1 (1,1)
	sdfm[2] = texelFetch(_sdf_maps, index[2], 0).r; // 2 (1,0)
	sdfm[3] = texelFetch(_sdf_maps, index[3], 0).r; // 3 (0,0)

	// Re-use index[] for the first lookups, skipping some math. 3 lookups
	h[3] = texelFetch(_height_maps, index[3], 0).r; // 0 (0,0)
	h[2] = texelFetch(_height_maps, index[2], 0).r; // 1 (1,0)
	h[1] = texelFetch(_height_maps, index[1], 0).r; // 3 (1,1)
	h[0] = texelFetch(_height_maps, index[0], 0).r; // 2 (0,1)


	// Adjust derivatives for mipmap bias and depth blur effect
	float bias = mix(mipmap_bias,
		depth_blur + 1.,
		smoothstep(0.0, 1.0, (1.0 - bias_distance) * 0.0009765625));
	base_ddx *= bias;
	base_ddy *= bias;

	float h_4 = texelFetch(_height_maps, get_index_coord(index_id + offsets.yz, 2), 0).r; // 4 (1,2)
	float h_5 = texelFetch(_height_maps, get_index_coord(index_id + offsets.zy, 2), 0).r; // 5 (2,1)
	float h_6 = texelFetch(_height_maps, get_index_coord(index_id + offsets.zx, 2), 0).r; // 6 (2,0)
	float h_7 = texelFetch(_height_maps, get_index_coord(index_id + offsets.xz, 2), 0).r; // 7 (0,2)

	// Calculate the normal for the remaining index ids.
	index_normal[0] = normalize(vec3(h[0] - h[1] + u, _vertex_spacing, h[0] - h_7 + v));
	index_normal[1] = normalize(vec3(h[1] - h_5 + u, _vertex_spacing, h[1] - h_4 + v));
	index_normal[2] = normalize(vec3(h[2] - h_6 + u, _vertex_spacing, h[2] - h[1] + v));
	index_normal[3] = normalize(vec3(h[3] - h[2] + u, _vertex_spacing, h[3] - h[0] + v));

	vec3 w_normal = normalize(
		index_normal[0] * weights[0] +
		index_normal[1] * weights[1] +
		index_normal[2] * weights[2] +
		index_normal[3] * weights[3]);

	position.y =
		h[0] * weights[0] +
		h[1] * weights[1] +
		h[2] * weights[2] +
		h[3] * weights[3] ;

	float sdf_value =
		sdfm[0] * weights[0] +
		sdfm[1] * weights[1] +
		sdfm[2] * weights[2] +
		sdfm[3] * weights[3] ;


	vec3 orientation = mix(vec3(0., 1., 0.), w_normal, normal_strength);
	mat3 alignment = align_to_vector(orientation);
	TRANSFORM = mat4(alignment);

	mat3 rot = rotation_matrix(orientation, rand_angle * 364.34 - 235.1);
	TRANSFORM = mat4(rot) * TRANSFORM;

	float scale = 1.0 + (rand_angle - 0.5) * random_scale;
	TRANSFORM[0] *= scale;
	TRANSFORM[1] *= scale;
	TRANSFORM[2] *= scale;

	TRANSFORM[3].xyz = position;

	// Particle Filtering
	bool hole = any(bvec4(control >> uvec4(2u) & uvec4(0x1u)));

	if (slope_restrict >= w_normal.y * sign(slope_restrict) + (r - 0.5) * condition_dithering
			|| position.y < min_height + (r - 0.5) * condition_dithering * 10.0
			|| sdf_value - r_alt * 0.96 < 0.00
			|| hole) {
		ACTIVE = false;
	}

	vec3 col = vec3(1.0);
	// Finished Position -> Colorsampling
	if (do_color_sampling && ACTIVE) {
		vec4 col_map[4];
		#define COLOR_MAP_DEF vec4(1.0, 1.0, 1.0, 0.5)
		col_map[3] = texelFetch(_color_maps, index[3], 0);
		col_map[0] = texelFetch(_color_maps, index[0], 0);
		col_map[1] = texelFetch(_color_maps, index[1], 0);
		col_map[2] = texelFetch(_color_maps, index[2], 0);

		vec4 color_map =
			col_map[0] * weights[0] +
			col_map[1] * weights[1] +
			col_map[2] * weights[2] +
			col_map[3] * weights[3] ;

		{
			// Auto blend calculation
			float auto_blend = clamp(fma(auto_slope * 2.0, (w_normal.y - 1.0), 1.0)
				- auto_height_reduction * 0.01 * position.y, 0.0, 1.0);
			// Enable Autoshader if outside regions or painted in regions, otherwise manual painted
			uvec4 is_auto = (control & uvec4(0x1u)) | uvec4(uint(region_uv.z < 0.0));
			uint u_auto =
				((uint(auto_base_texture) & 0x1Fu) << 27u) |
				((uint(auto_overlay_texture) & 0x1Fu) << 22u) |
				((uint(fma(auto_blend, 255.0 , 0.5)) & 0xFFu) << 14u);
			control = control * (1u - is_auto) + u_auto * is_auto;
		}

		// Texture weights
		// Vectorised Deocode of all texture IDs, then swizzle to per index mapping.
		// Passed to accumulate_material to avoid repeated decoding.
		ivec4 t_id[2] = {ivec4(control >> uvec4(27u) & uvec4(0x1Fu)),
			ivec4(control >> uvec4(22u) & uvec4(0x1Fu))};
		ivec2 texture_ids[4] = ivec2[4](
			ivec2(t_id[0].x, t_id[1].x),
			ivec2(t_id[0].y, t_id[1].y),
			ivec2(t_id[0].z, t_id[1].z),
			ivec2(t_id[0].w, t_id[1].w));

		// uninterpolated weights.
		vec4 weights_id_1 = vec4(control >> uvec4(14u) & uvec4(0xFFu)) * 0.003921568627450;
		vec4 weights_id_0 = 1.0 - weights_id_1;
		vec2 t_weights[4] = vec2[4](
					vec2(weights_id_0[0], weights_id_1[0]),
					vec2(weights_id_0[1], weights_id_1[1]),
					vec2(weights_id_0[2], weights_id_1[2]),
					vec2(weights_id_0[3], weights_id_1[3]));
		// interpolated weights
		#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
		t_weights = {vec2(0), vec2(0), vec2(0), vec2(0)};
		weights_id_0 *= weights;
		weights_id_1 *= weights;
		for (int i = 0; i < 4; i++) {
			vec2 w_0 = vec2(weights_id_0[i]);
			vec2 w_1 = vec2(weights_id_1[i]);
			ivec2 id_0 = texture_ids[i].xx;
			ivec2 id_1 = texture_ids[i].yy;
			t_weights[0] += fma(w_0, vec2(equal(texture_ids[0], id_0)), w_1 * vec2(equal(texture_ids[0], id_1)));
			t_weights[1] += fma(w_0, vec2(equal(texture_ids[1], id_0)), w_1 * vec2(equal(texture_ids[1], id_1)));
			t_weights[2] += fma(w_0, vec2(equal(texture_ids[2], id_0)), w_1 * vec2(equal(texture_ids[2], id_1)));
			t_weights[3] += fma(w_0, vec2(equal(texture_ids[3], id_0)), w_1 * vec2(equal(texture_ids[3], id_1)));
		}
		#endif

		uint base_allowed = _texture_restrictions >> uint(texture_ids[3][0]) & 0x1u;
		uint overlay_allowed = _texture_restrictions >> uint(texture_ids[3][1]) & 0x1u;

		if (DECODE_BLEND(control[3]) < 0.45 + (r - 0.5) * condition_dithering) {
			if(base_allowed == 0x1u) {ACTIVE = false;}
		} else {
			if(overlay_allowed == 0x1u) {ACTIVE = false;}
		}

		// Struct to accumulate all texture data.
		material mat = material(vec4(0.0), vec4(0.0), 0., 0., 0.);

		accumulate_material(base_ddx, base_ddy, weights[3], index[3], control[3], t_weights[3],
			texture_ids[3], index_normal[3], h[3], mat, position);
		accumulate_material(base_ddx, base_ddy, weights[2], index[2], control[2], t_weights[2],
			texture_ids[2], index_normal[2], h[2], mat, position);
		accumulate_material(base_ddx, base_ddy, weights[1], index[1], control[1], t_weights[1],
			texture_ids[1], index_normal[1], h[1], mat, position);
		accumulate_material(base_ddx, base_ddy, weights[0], index[0], control[0], t_weights[0],
			texture_ids[0], index_normal[0], h[0], mat, position);

		// normalize accumulated values back to 0.0 - 1.0 range.
		float weight_inv = 1.0 / mat.total_weight;
		mat.albedo_height *= weight_inv;

		// Macro variation. 2 lookups
		vec3 macrov = vec3(1.);
		if (macro_variation) {
			float noise1 = texture(noise_texture, rotate_vec2(fma(uv, vec2(noise1_scale * .1), noise1_offset) , vec2(cos(noise1_angle), sin(noise1_angle)))).r;
			float noise2 = texture(noise_texture, uv * noise2_scale * .1).r;
			macrov = mix(macro_variation1, vec3(1.), noise1);
			macrov *= mix(macro_variation2, vec3(1.), noise2);
			macrov = mix(vec3(1.0), macrov, clamp(w_normal.y + macro_variation_slope, 0., 1.));
		}

		col = mat.albedo_height.rgb * color_map.rgb * macrov;

	}

	COLOR = vec4(col, 1.0);
}