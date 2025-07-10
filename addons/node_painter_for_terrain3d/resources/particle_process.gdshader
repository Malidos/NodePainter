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
uniform bool enable_projection;
uniform float projection_threshold = 0.8;
uniform float projection_angular_division = 2.0;

uniform bool enable_macro_variation = true;
uniform vec3 macro_variation1 = vec3(1.0);
uniform vec3 macro_variation2 = vec3(1.0);
uniform float macro_variation_slope : hint_range(0.0, 1.0) = 0.333333;
uniform float noise1_scale = 0.04;
uniform float noise1_angle = 0.0;
uniform vec2 noise1_offset = vec2(0.5);
uniform float noise2_scale = 0.076;
uniform float noise3_scale = 0.225;

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
uniform float _texture_detile_array[32];
uniform vec4 _texture_color_array[32];
uniform highp sampler2DArray _height_maps : repeat_disable, hint_default_black;
uniform highp sampler2DArray _control_maps : repeat_disable, hint_default_white;
uniform highp sampler2DArray _color_maps : repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform highp sampler2D noise_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

// Defined Constants
#define SKIP_PASS 0
#define VERTEX_PASS 1
#define FRAGMENT_PASS 2

struct Material {
	vec4 alb_ht;
	int base;
	int over;
	float blend;
};


ivec3 get_index_coord(const vec2 uv) {
	vec2 r_uv = round(uv);
	vec2 o_uv = mod(r_uv,_region_size);
	ivec2 pos;
	int bounds, layer_index = -1;
	for (int i = -1; i < 0; i++) {
		if ((layer_index == -1 && _background_mode == 0u) || i < 0) {
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

float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

// Moves a point around a pivot point.
vec2 rotate_around(vec2 point, vec2 pivot, float angle){
	float x = pivot.x + (point.x - pivot.x) * cos(angle) - (point.y - pivot.y) * sin(angle);
	float y = pivot.y + (point.x - pivot.x) * sin(angle) + (point.y - pivot.y) * cos(angle);
	return vec2(x, y);
}

vec4 height_blend(vec4 a_value, float a_height, vec4 b_value, float b_height, float blend) {
	float ma = max(a_height + (1.0 - blend), b_height + blend) - (1.001 - blend_sharpness);
	float b1 = max(a_height + (1.0 - blend) - ma, 0.0);
	float b2 = max(b_height + blend - ma, 0.0);
	return (a_value * b1 + b_value * b2) / (b1 + b2);
}

float blend_weights(float weight, float detail) {
	weight = smoothstep(0.0, 1.0, weight);
	weight = sqrt(weight * 0.5);
	float result = max(0.1 * weight, fma(10.0, (weight + detail), 1.0f - (detail + 10.0)));
	return result;
}

vec2 detiling(vec2 uv, vec2 uv_center, int mat_id, inout float normal_rotation){
	if (_texture_detile_array[mat_id] >= 0.001){
		uv_center = floor(uv_center) + 0.5;
		float detile = fma(random(uv_center), 2.0, -1.0) * TAU * _texture_detile_array[mat_id]; // -180deg to 180deg
		uv = rotate_around(uv, uv_center, detile);
		// Accumulate total rotation for normal rotation
		normal_rotation += detile;
	}
	return uv;
}

vec2 rotate_plane(vec2 plane, float angle) {
	float new_x = dot(vec2(cos(angle), sin(angle)), plane);
	angle = fma(PI, 0.5, angle);
	float new_y = dot(vec2(cos(angle), sin(angle)), plane);
	return vec2(new_x, new_y);
}

// 2-4 lookups ( 2-6 with dual scaling )
void get_material(vec2 base_uv, vec4 ddxy, uint control, ivec3 iuv_center, vec3 normal, out Material out_mat, vec3 v_vertex) {
	out_mat = Material(vec4(0.), 0, 0, 0.0);
	vec2 uv_center = vec2(iuv_center.xy);
	int region = iuv_center.z;

	// Enable Autoshader if outside regions or painted in regions, otherwise manual painted
	bool auto_shader = region < 0 || bool(control & 0x1u);
	out_mat.base = int(auto_shader) * auto_base_texture + int(!auto_shader) * int(control >>27u & 0x1Fu);
	out_mat.over = int(auto_shader) * auto_overlay_texture + int(!auto_shader) * int(control >> 22u & 0x1Fu);
	out_mat.blend = float(auto_shader) * clamp(
			round((auto_slope * 2. * ( normal.y - 1.) + 1.) * 255.0) * 0.003921568627450
			- auto_height_reduction * .01 * v_vertex.y // Reduce as vertices get higher
			, 0., 1.) +
			 float(!auto_shader) * float(control >>14u & 0xFFu) * 0.003921568627450; // 1./255.0

	// Control map scale & rotation, apply to both base and
	// uv_center. Translate uv center to the current region.
	uv_center += _region_locations[region] * _region_size;
	uv_center *= _vertex_spacing;
	// Define base scale from control map value as array index. 0.5 as baseline.
	float[8] scale_array = { 0.5, 0.4, 0.3, 0.2, 0.1, 0.8, 0.7, 0.6};
	float control_scale = scale_array[(control >>7u & 0x7u)];
	base_uv *= control_scale;
	uv_center *=  control_scale;
	ddxy *= control_scale;

	// Apply global uv rotation from control map
	float uv_rotation = float(control >>10u & 0xFu) / 16. * TAU;
	base_uv = rotate_around(base_uv, vec2(0), uv_rotation);
	uv_center = rotate_around(uv_center, vec2(0), uv_rotation);

	vec2 matUV = base_uv;
	vec4 albedo_ht = vec4(0.);
	float mat_scale = _texture_uv_scale_array[out_mat.base];
	float normal_angle = uv_rotation;
	vec4 dd1 = ddxy;

	// 2 lookups
	//each time we change scale, recalculate antitiling from baseline to maintain continuity.
	matUV = detiling(base_uv * mat_scale, uv_center * mat_scale, out_mat.base, normal_angle);
	dd1.xy = rotate_plane(ddxy.xy, -normal_angle);
	dd1.zw = rotate_plane(ddxy.zw, -normal_angle);
	dd1 *= mat_scale;
	albedo_ht = textureGrad(_texture_array_albedo, vec3(matUV, float(out_mat.base)), dd1.xy, dd1.zw);


	// Apply color to base
	albedo_ht.rgb *= _texture_color_array[out_mat.base].rgb;

	if (out_mat.blend > 0.) {
		// 2 lookups
		// Setup overlay texture to blend
		float mat_scale2 = _texture_uv_scale_array[out_mat.over];
		float normal_angle2 = uv_rotation;
		vec2 matUV2 = detiling(base_uv * mat_scale2, uv_center * mat_scale2, out_mat.over, normal_angle2);
		vec4 dd2 = ddxy * mat_scale2;
		dd2.xy = rotate_plane(dd2.xy, -normal_angle2);
		dd2.zw = rotate_plane(dd2.zw, -normal_angle2);
		vec4 albedo_ht2 = textureGrad(_texture_array_albedo, vec3(matUV2, float(out_mat.over)), dd2.xy, dd2.zw);

		// Apply color to overlay
		albedo_ht2.rgb *= _texture_color_array[out_mat.over].rgb;

		// Blend overlay and base
		albedo_ht = height_blend(albedo_ht, albedo_ht.a, albedo_ht2, albedo_ht2.a, out_mat.blend);
		out_mat.blend = height_blend(vec4(0.0), albedo_ht.a, vec4(1.0), albedo_ht2.a, out_mat.blend).x;
	}

	out_mat.alb_ht = albedo_ht;
	return;
}

vec2 project_uv_from_normal(vec3 normal, vec3 v_vertex) {
	ivec3 v_region = get_index_coord(v_vertex.xz);
	if (v_region.z < 0 || normal.y >= projection_threshold || !enable_projection) {
		return v_vertex.xz;
	}
	// Quantize the normal otherwise textures lose continuity across domains
	vec3 p_normal = normalize(round(normal * projection_angular_division));
	// Avoid potential singularity
	vec3 p_tangent = normalize(cross(p_normal, vec3(1e-6, 1e-6, 1.0)));
	return vec2(dot(v_vertex, p_tangent), dot(v_vertex, normalize(cross(p_tangent, p_normal))));
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
	const vec3 offsets = vec3(0, 1, 2);
	vec2 index_id = floor(position.xz * _vertex_density);
	vec2 weight = fract(position.xz * _vertex_density);
	vec2 invert = 1.0 - weight;
	vec4 weights = vec4(
		invert.x * weight.y, // 0
		weight.x * weight.y, // 1
		weight.x * invert.y, // 2
		invert.x * invert.y  // 3
	);

	ivec3 index[4];
	// Map lookups
	index[0] = get_index_coord(index_id + offsets.xy);
	index[1] = get_index_coord(index_id + offsets.yy);
	index[2] = get_index_coord(index_id + offsets.yx);
	index[3] = get_index_coord(index_id + offsets.xx);

	// Read control map
	uint control[4];
	control[0] = floatBitsToUint(texelFetch(_control_maps, index[0], 0).r);
	control[1] = floatBitsToUint(texelFetch(_control_maps, index[1], 0).r);
	control[2] = floatBitsToUint(texelFetch(_control_maps, index[2], 0).r);
	control[3] = floatBitsToUint(texelFetch(_control_maps, index[3], 0).r);

	float sdfm[4];
	sdfm[0] = texelFetch(_sdf_maps, index[0], 0).r; // 0 (0,1)
	sdfm[1] = texelFetch(_sdf_maps, index[1], 0).r; // 1 (1,1)
	sdfm[2] = texelFetch(_sdf_maps, index[2], 0).r; // 2 (1,0)
	sdfm[3] = texelFetch(_sdf_maps, index[3], 0).r; // 3 (0,0)

	highp float h[8];
	h[0] = texelFetch(_height_maps, index[0], 0).r; // 0 (0,1)
	h[1] = texelFetch(_height_maps, index[1], 0).r; // 1 (1,1)
	h[2] = texelFetch(_height_maps, index[2], 0).r; // 2 (1,0)
	h[3] = texelFetch(_height_maps, index[3], 0).r; // 3 (0,0)
	h[4] = texelFetch(_height_maps, get_index_coord(index_id + offsets.yz), 0).r; // 4 (1,2)
	h[5] = texelFetch(_height_maps, get_index_coord(index_id + offsets.zy), 0).r; // 5 (2,1)
	h[6] = texelFetch(_height_maps, get_index_coord(index_id + offsets.zx), 0).r; // 6 (2,0)
	h[7] = texelFetch(_height_maps, get_index_coord(index_id + offsets.xz), 0).r; // 7 (0,2)
	vec3 index_normal[4];
	index_normal[0] = vec3(h[0] - h[1], _vertex_spacing, h[0] - h[7]);
	index_normal[1] = vec3(h[1] - h[5], _vertex_spacing, h[1] - h[4]);
	index_normal[2] = vec3(h[2] - h[6], _vertex_spacing, h[2] - h[1]);
	index_normal[3] = vec3(h[3] - h[2], _vertex_spacing, h[3] - h[0]);
	vec3 w_normal = normalize(
		index_normal[0] * weights[0] +
		index_normal[1] * weights[1] +
		index_normal[2] * weights[2] +
		index_normal[3] * weights[3]);
	// End of Terrain 3D Lookups
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
	uvec4 v_control = uvec4(control[0], control[1], control[2], control[3]);
	bool hole = any(bvec4(v_control >> uvec4(2u) & uvec4(0x1u)));

	if (slope_restrict >= w_normal.y * sign(slope_restrict) + (r - 0.5) * condition_dithering
			|| position.y < min_height + (r - 0.5) * condition_dithering * 10.0
			|| sdf_value - r_alt * 0.96 < 0.00
			|| hole) {
		ACTIVE = false;
	}

	vec3 col = vec3(1.0);
	// Finished Position -> Colorsampling
	if (do_color_sampling && ACTIVE) {
		// Read color map
		#define COLOR_MAP vec4(1., 1., 1., 0.5)
		highp vec4 c[4];
		c[0] = index[0].z >= 0 ? texelFetch(_color_maps, index[0], 0) : COLOR_MAP; // 0 (0,1)
		c[1] = index[1].z >= 0 ? texelFetch(_color_maps, index[1], 0) : COLOR_MAP; // 1 (1,1)
		c[2] = index[2].z >= 0 ? texelFetch(_color_maps, index[2], 0) : COLOR_MAP; // 2 (1,0)
		c[3] = index[3].z >= 0 ? texelFetch(_color_maps, index[3], 0) : COLOR_MAP; // 3 (0,0)
		vec4 color_map =
			c[0] * weights[0] +
			c[1] * weights[1] +
			c[2] * weights[2] +
			c[3] * weights[3] ;

		Material mat[4];
		vec4 faked_derivatives = vec4(color_sampling_blur);
		get_material(project_uv_from_normal(index_normal[0], TRANSFORM[3].xyz), faked_derivatives, control[0], index[0], w_normal, mat[0], TRANSFORM[3].xyz);
		get_material(project_uv_from_normal(index_normal[1], TRANSFORM[3].xyz), faked_derivatives, control[1], index[1], w_normal, mat[1], TRANSFORM[3].xyz);
		get_material(project_uv_from_normal(index_normal[2], TRANSFORM[3].xyz), faked_derivatives, control[2], index[2], w_normal, mat[2], TRANSFORM[3].xyz);
		get_material(project_uv_from_normal(index_normal[3], TRANSFORM[3].xyz), faked_derivatives, control[3], index[3], w_normal, mat[3], TRANSFORM[3].xyz);

		// rebuild weights for detail and noise blending
		float noise3 = texture(noise_texture, TRANSFORM[3].xz * noise3_scale).r * blend_sharpness;
		#define PARABOLA(x) (4.0 * x * (1.0 - x))
		weights = smoothstep(0, 1, weights);
		weights = vec4(
			blend_weights(weights.x + PARABOLA(weights.x) * noise3, mat[0].alb_ht.a),
			blend_weights(weights.y + PARABOLA(weights.y) * noise3, mat[1].alb_ht.a),
			blend_weights(weights.z + PARABOLA(weights.z) * noise3, mat[2].alb_ht.a),
			blend_weights(weights.w + PARABOLA(weights.w) * noise3, mat[3].alb_ht.a)
		);
		#undef PARABOLA
		// renormalize weights
		weights *= 1.0 / (weights.x + weights.y + weights.z + weights.w);

		vec4 albedo_height =
			mat[0].alb_ht * weights[0] +
			mat[1].alb_ht * weights[1] +
			mat[2].alb_ht * weights[2] +
			mat[3].alb_ht * weights[3] ;

		uint base_allowed = _texture_restrictions >> uint(mat[3].base) & 0x1u;
		uint overlay_allowed = _texture_restrictions >> uint(mat[3].over) & 0x1u;

		if (mat[3].blend < 0.45 + (r - 0.5) * condition_dithering) {
			if(base_allowed == 0x1u) {ACTIVE = false;}
		} else {
			if(overlay_allowed == 0x1u) {ACTIVE = false;}
		}

		vec3 macrov = vec3(1.);
		if (enable_macro_variation) {
			float noise1 = texture(noise_texture, rotate_around(TRANSFORM[3].xz * noise1_scale * .1, vec2(0.0), noise1_angle) + noise1_offset).r;
			float noise2 = texture(noise_texture, TRANSFORM[3].xz * noise2_scale * .1).r;
			macrov = mix(macro_variation1, vec3(1.), noise1);
			macrov *= mix(macro_variation2, vec3(1.), noise2);
			macrov = mix(vec3(1.0), macrov, clamp(w_normal.y + macro_variation_slope, 0., 1.));
		}

		col = albedo_height.rgb * color_map.rgb * macrov;

	}

	COLOR = vec4(col, 1.0);
}

void process() {
	// Called every frame on existing particles (according to the Fixed FPS property).
}
