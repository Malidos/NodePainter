shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, alpha_to_coverage;

uniform sampler2DArray texture_albedo : source_color, filter_nearest, repeat_disable, hint_default_white;
uniform int views = 8;
uniform float fade_distance = 50;

uniform sampler2DArray texture_normal : hint_roughness_normal, filter_nearest, repeat_disable;

varying flat float blend_value;
varying flat float fd;

const vec2 bb_ref = vec2(0.0, 1.0);

void vertex() {
	fd = length((VIEW_MATRIX * MODEL_MATRIX[3]));
	fd = clamp(smoothstep(fade_distance - 5.0, fade_distance, fd), 0.0, 1.0);
	vec3 bill_axis = MODEL_MATRIX[1].xyz;

	// Billboard Mode: Y-Billboard
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(normalize(cross(bill_axis, MAIN_CAM_INV_VIEW_MATRIX[2].xyz)), 0.0),
			vec4(bill_axis, 0.0),
			vec4(normalize(cross(MAIN_CAM_INV_VIEW_MATRIX[0].xyz, bill_axis)), 0.0),
			MODEL_MATRIX[3]);

	// Billboard Keep Scale: Enabled
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);

	float dot1 = dot(MAIN_CAM_INV_VIEW_MATRIX[0].xz, bb_ref);
	float det1 = determinant(mat2(MAIN_CAM_INV_VIEW_MATRIX[0].xz, bb_ref));
	float dot2 = dot(MODEL_MATRIX[0].xz, bb_ref);
	float det2 = determinant(mat2(MODEL_MATRIX[0].xz, bb_ref));

	float f_views = float(views);
	float rel_angle = atan(det1, dot1) - atan(det2, dot2);
	rel_angle /= PI*2.0;

	rel_angle = fract(rel_angle + PI / (f_views*8.0));
	blend_value = rel_angle * f_views;

	//NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {

	{
		// Use interleaved gradient noise, which is fast but still looks good.
		const vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
		// Use a hard cap to prevent a few stray pixels from remaining when past the fade-out distance.
		if (fd < 0.001 || fd < fract(magic.z * fract(dot(FRAGCOORD.xy, magic.xy)))) {
			discard;
		}
	}

	float direction_id = floor(blend_value);

	vec4 albedo_tex = texture(texture_albedo, vec3(UV, direction_id));
	ALBEDO = albedo_tex.rgb;

	// Normal Map: Enabled
	NORMAL_MAP = texture(texture_normal, vec3(UV, direction_id)).rgb;
	NORMAL_MAP_DEPTH = 1.0;
	ALPHA = albedo_tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALPHA_TEXTURE_COORDINATE = UV;
}
