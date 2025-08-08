#[compute]
#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;


// Memory preperation
layout(set = 0, binding = 0, std430) restrict buffer TransformBuffer {
    uint count;
    float data[];
} transform_buffer;
layout(set = 1, binding = 0, std430) restrict readonly buffer RegionParameters {
    float vertex_density;
    float vertex_spacing;
    float region_size;
    float region_texel_size;
    float new_chunck_size;
    int region_map_size;
    int backround_mode;
    int region_map[1024];
} region_parameters;
layout(set = 1, binding = 1, std430) restrict readonly buffer ShapeParameters {
    int operations; // Amount of Shapes to be processed
    float data[]; // Data each shape needs is different coded in first as type
    // Cricle type == 0 (InterpolationSize, InterpolationType, Operation, Texture, Negative, XScale, YScale, Rotation, XPos, YPos, ZPos, Radius) 9
    // Rectangle type == 1 (InterpolationSize, InterpolationType, Operation, Texture, Negative, XScale, YScale, Rotation, XPos, YPos, ZPos, XRectSize, YRectSize, Radius) 10
    // Polygon type == 2 (InterpolationSize, InterpolationType, Operation, Texture, Negative, XScale, YScale, Rotation, XPos, YPos, ZPos, PointCount, [x,y]) > 9
    // Path type == 3 (InterpolationSize, InterpolationType, Operation, Texture, Negative, PathWidth, PointCount, [x, y, z]) > 4 (Points should be transformed into global space)
    // Stamp type == 4 (InterpolationSize, interpolType, Operation, Texture, Negative, XScale, YScale, Rotation, XPos, YPos, ZPos, HeightScale, StampSize, StampIndex) 11
} shape_data_buffer;
layout (set = 1, binding = 2) uniform sampler2DArray height_maps;
layout (set = 0, binding = 2) restrict readonly buffer RegionCoordinates {
    vec2 coord[];
} region_coords;
layout (set = 0, binding = 1) restrict readonly buffer InstanceParameters {
    int instance_id;
    float density;
    float slope_restriction;
    float normal_influence;
    float random_offset_factor;
    float random_scale_factor;
    float condition_randomness;
    int random_seed;
} instance_parameters;



float hash(uint n) {
	// integer hash copied from Hugo Elias
	n = (n << 12U) ^ n;
	n = n * (n * n * 15761U + 0x769221U) + 0x12761169U;
	return float(n & uint(0x7fffffffU)) / float(0x7fffffff);
}

ivec3 get_index_coord(vec2 uv) {
	vec2 r_uv = round(uv);
	vec2 o_uv = mod(r_uv,region_parameters.region_size);
	ivec2 pos;
	int bounds, layer_index = -1;
	for (int i = -1; i < 0; i++) {
		if ((layer_index == -1 && region_parameters.backround_mode == 0u) || i < 0) {
			r_uv -= i == -1 ? vec2(0.0) : vec2(float(o_uv.x <= o_uv.y), float(o_uv.y <= o_uv.x));
			pos = ivec2(floor((r_uv) * region_parameters.region_texel_size)) + (region_parameters.region_map_size / 2);
			bounds = int(uint(pos.x | pos.y) < uint(region_parameters.region_map_size));
			layer_index = (region_parameters.region_map[ pos.y * region_parameters.region_map_size + pos.x ] * bounds - 1);
		}
	}
	return ivec3(ivec2(mod(r_uv,region_parameters.region_size)), layer_index);
}

// SDF Functions for calculation1
vec2 translate(vec2 pos, vec2 offset) {
    return pos - offset;
}

vec2 rotate(vec2 pos, float rotation) {
    float rot = -rotation;
    float s = sin(rot);
    float c = cos(rot);
    return vec2(c * pos.x + s * pos.y, c * pos.y - s * pos.x);
}

vec2 scale(vec2 pos, vec2 scle) {
    return pos / scle;
}

vec2 transform(vec2 pos, vec2 o, vec2 s, float r) {
    vec2 p = translate(pos, o);
    p = rotate(p, r);
    p = scale(p, s);
    return p;
}

float circle(vec2 pos, float radius) {
    return length(pos) - radius;
}
float rectangle(vec2 pos, vec2 s) {
    vec2 h_size = s * 0.5;
    vec2 d = abs(pos) - h_size;
    float o_distance = length(max(d, 0));
    float i_distance = min( max(d.x, d.y), 0);
    return o_distance + i_distance;
}
// x component returns the actual sdf, y a value relevent for the height gradient calculation
vec2 segment(vec2 pos, vec2 a, vec2 b, float widht) {
    vec2 pa = pos-a, ba = b-a;
    float h = dot(pa, ba) / dot(ba, ba);
    float s = length(pa - ba * clamp(h, 0.0, 1.0)) - widht;
    return vec2(s, h);
}

// Interpolation functions for sdf values
float sdf_step(float sdf) {
    return step(sdf, 0.0);
}
float sdf_smoothstep(float sdf, float len) {
    return smoothstep(0.0, 1.0, sdf / len);
}
float sdf_linear(float sdf, float len) {
    return clamp(0.0, 1.0, sdf / len);
}
float sdf_ease_out(float sdf, float len) {
    float x = sdf / len;
    return clamp(x*x*x, 0.0, 1.0);
}
float sdf_ease_in(float sdf, float len) {
    float x = 1.0 - sdf / len;
    return clamp(1.0 - x*x*x, 0.0, 1.0);
}


void main() {
    // Grabs Instance Grid ID 
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
    
    // Calculate the current Instance global location
    vec2 global_loc = vec2(coords) * instance_parameters.density * region_parameters.vertex_spacing + region_coords.coord[gl_GlobalInvocationID.z] * region_parameters.vertex_spacing;

    // Generate Random values 0 - 1
    float primary_random = hash(uint( instance_parameters.random_seed + gl_GlobalInvocationID.x - gl_GlobalInvocationID.y * 2 + int(global_loc.y - global_loc.x) ));
    float secoundary_random = hash(uint( instance_parameters.random_seed + 2653 + gl_GlobalInvocationID.x + gl_GlobalInvocationID.y + int(length(global_loc)) - int(length(region_coords.coord[gl_GlobalInvocationID.z])) ));
    

    // Basic Random calculations
    float Rscale = clamp(1.0 + (fract(secoundary_random * 27.52) - 0.4) * instance_parameters.random_scale_factor, 0.1, 20.0);
    float Rrotation = secoundary_random * 12.5663706144; // = 4 * PI
    float rot = fract(secoundary_random * 64.0) * 6.2831853072;
    vec2 random_offset = vec2(cos(Rrotation), sin(Rrotation)) * sqrt(primary_random) * instance_parameters.random_offset_factor;

    global_loc += random_offset;

    float sdf_value = 0.0;
    // Shape Operation
    int read_idx = 0; // Index used to read the data buffer
    uint instance_uid = uint(instance_parameters.instance_id);
    for (int i = 0; i < shape_data_buffer.operations; i++) {
        // Retrive Shaoe parameters
        int type = int(shape_data_buffer.data[read_idx]);
        float local_density = shape_data_buffer.data[read_idx + 3];
        uint allowed_instances = uint(shape_data_buffer.data[read_idx + 4]);

        vec2 location = vec2(shape_data_buffer.data[read_idx + 9], shape_data_buffer.data[read_idx + 10]);
        float height = shape_data_buffer.data[read_idx + 11];
        vec2 scale = vec2(shape_data_buffer.data[read_idx + 6], shape_data_buffer.data[read_idx + 7]);
        float shape_rotation = shape_data_buffer.data[read_idx + 8];
        float interpol = shape_data_buffer.data[read_idx + 1];
        int interpolType = int(shape_data_buffer.data[read_idx + 2]);
        vec2 sample_pos = transform(global_loc, location, scale, shape_rotation);
        float negative_shape = shape_data_buffer.data[read_idx + 5];
        local_density *= -2.0 * (negative_shape - 0.5);

        // Rund SDF calculation by type
        float s_sdf = 0.0;
        bool included = (allowed_instances >> instance_uid & 0x1u) == 0x0u;

        if (type == 0) { // Circle
            float c_radius = shape_data_buffer.data[read_idx + 12];
            read_idx += 13;

            s_sdf = circle(sample_pos, c_radius);

        } else if (type == 1) { // Rectangle
            vec2 rec_size = vec2(shape_data_buffer.data[read_idx + 12], shape_data_buffer.data[read_idx + 13]);
            read_idx += 14;

            s_sdf = rectangle(sample_pos, rec_size);

        } else if (type == 2) { // Polygon
            int point_count = int(shape_data_buffer.data[read_idx + 12]);
            vec2 first_point = vec2(shape_data_buffer.data[read_idx + 13], shape_data_buffer.data[read_idx + 14]);

            // Polygon SDF calculation, cant be moved into a subroutnine because the array size is unknown
            float dis = dot(sample_pos - first_point, sample_pos - first_point);
            float s = 1.0;

            for (int i=0, j=point_count-1; i<point_count; j=i, i++) {
                vec2 cur = vec2(shape_data_buffer.data[read_idx + 13 + i*2], shape_data_buffer.data[read_idx + 14 + i*2]);
                vec2 prev = vec2(shape_data_buffer.data[read_idx + 13 + j*2], shape_data_buffer.data[read_idx + 14 + j*2]);

                vec2 e = prev - cur;
                vec2 w = sample_pos - cur;
                vec2 b = w - e*clamp( dot(w, e) / dot(e, e), 0.0, 1.0);
                dis = min( dis, dot(b,b));

                bvec3 cond = bvec3( sample_pos.y >= cur.y, sample_pos.y < prev.y, e.x*w.y > e.y*w.x);

                if ( all(cond) || all(not(cond))) {s = -s;}
            }

            read_idx += 13 + point_count * 2;
            s_sdf = s*sqrt(dis);


        } else if (type == 3) { // Path
            int point_count = int(shape_data_buffer.data[read_idx + 7]);
            // Regular Shape parameters are unusable except interpol variables
            float path_width = shape_data_buffer.data[read_idx + 6];

            s_sdf = length(vec2(shape_data_buffer.data[read_idx + 8], shape_data_buffer.data[read_idx + 10]) - global_loc);
            
            for (int i=0; i<point_count-1; i++) {
                vec3 first_point = vec3(shape_data_buffer.data[read_idx + i*3 + 8],
                                        shape_data_buffer.data[read_idx + i*3 + 9],
                                        shape_data_buffer.data[read_idx + i*3 + 10]);
                vec3 secound_point = vec3(shape_data_buffer.data[read_idx + i*3 + 11],
                                        shape_data_buffer.data[read_idx + i*3 + 12],
                                        shape_data_buffer.data[read_idx + i*3 + 13]);
                
                vec2 sdf_calc = segment(global_loc, first_point.xz, secound_point.xz, path_width);
                float height_gradient = mix(first_point.y, secound_point.y, sdf_calc.y);
                s_sdf = min(sdf_calc.x, s_sdf);
            }

            read_idx += 8 + point_count * 3;

        }


        // Shape Interpolation and blending
        if (interpolType == 1) {
            s_sdf = sdf_linear(s_sdf, interpol);
        } else if (interpolType == 2) {
            s_sdf = sdf_ease_in(s_sdf, interpol);
        } else if (interpolType == 3) {
            s_sdf = sdf_ease_out(s_sdf, interpol);
        } else {
            s_sdf = sdf_smoothstep(s_sdf, interpol);
        }

        if (included) {
           sdf_value = clamp(mix(local_density, sdf_value, s_sdf), 0.0, 1.0);
        }
    }

    // Terrain3D sampling
    const vec3 offsets = vec3(0, 1, 2);
	vec2 index_id = floor(global_loc * region_parameters.vertex_density);
	vec2 weight = fract(global_loc * region_parameters.vertex_density);
	vec2 invert = 1.0 - weight;
	vec4 weights = vec4(
		invert.x * weight.y, // 0
		weight.x * weight.y, // 1
		weight.x * invert.y, // 2
		invert.x * invert.y  // 3
	);
    
    ivec3 index[4];
	index[0] = get_index_coord(index_id + offsets.xy);
	index[1] = get_index_coord(index_id + offsets.yy);
	index[2] = get_index_coord(index_id + offsets.yx);
	index[3] = get_index_coord(index_id + offsets.xx);

    highp float h[8];
	h[0] = texelFetch(height_maps, index[0], 0).r; // 0 (0,1)
	h[1] = texelFetch(height_maps, index[1], 0).r; // 1 (1,1)
	h[2] = texelFetch(height_maps, index[2], 0).r; // 2 (1,0)
	h[3] = texelFetch(height_maps, index[3], 0).r; // 3 (0,0)
	h[4] = texelFetch(height_maps, get_index_coord(index_id + offsets.yz), 0).r; // 4 (1,2)
	h[5] = texelFetch(height_maps, get_index_coord(index_id + offsets.zy), 0).r; // 5 (2,1)
	h[6] = texelFetch(height_maps, get_index_coord(index_id + offsets.zx), 0).r; // 6 (2,0)
	h[7] = texelFetch(height_maps, get_index_coord(index_id + offsets.xz), 0).r; // 7 (0,2)
	vec3 index_normal[4];
	index_normal[0] = vec3(h[0] - h[1], region_parameters.vertex_spacing, h[0] - h[7]);
	index_normal[1] = vec3(h[1] - h[5], region_parameters.vertex_spacing, h[1] - h[4]);
	index_normal[2] = vec3(h[2] - h[6], region_parameters.vertex_spacing, h[2] - h[1]);
	index_normal[3] = vec3(h[3] - h[2], region_parameters.vertex_spacing, h[3] - h[0]);

	vec3 w_normal = normalize(index_normal[0] * weights[0] + index_normal[1] * weights[1] + index_normal[2] * weights[2] + index_normal[3] * weights[3]);
	float w_height = h[0] * weights[0] + h[1] * weights[1] + h[2] * weights[2] + h[3] * weights[3];
    vec3 weighted_normal = mix(vec3(0., 1., 0.), w_normal, clamp(instance_parameters.normal_influence + (fract(primary_random * 128.) - 0.5) * instance_parameters.condition_randomness * 0.25, 0.0, 1.0));


    // Run condition checks
    bool allowed_by_shape = sdf_value > fract(primary_random * 8.0);
    bool allowed_by_slope = instance_parameters.slope_restriction < w_normal.y * sign(instance_parameters.slope_restriction) + (primary_random - 0.5) * instance_parameters.condition_randomness;

    if (allowed_by_shape && allowed_by_slope) {
        vec2 foliage_chunk = floor(global_loc/region_parameters.new_chunck_size);

        uint dataIndex = atomicAdd(transform_buffer.count, 1);
        transform_buffer.data[dataIndex * 10] = global_loc.x;
        transform_buffer.data[dataIndex * 10 + 1] = w_height;
        transform_buffer.data[dataIndex * 10 + 2] = global_loc.y;
        transform_buffer.data[dataIndex * 10 + 3] = weighted_normal.x;
        transform_buffer.data[dataIndex * 10 + 4] = weighted_normal.y;
        transform_buffer.data[dataIndex * 10 + 5] = weighted_normal.z;
        transform_buffer.data[dataIndex * 10 + 6] = rot;
        transform_buffer.data[dataIndex * 10 + 7] = Rscale;
        transform_buffer.data[dataIndex * 10 + 8] = foliage_chunk.x;
        transform_buffer.data[dataIndex * 10 + 9] = foliage_chunk.y;
    }
}
