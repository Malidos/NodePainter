#[compute]
#version 450

// Invocations in the (x, y, z) dimension
// GPU runs a 8x8 Chunck on the texture
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;


// Memory preperation
layout(set = 0, binding = 0, r16f) restrict uniform image2D sdfmap;
layout(set = 0, binding = 1, std430) restrict readonly buffer MapParameters {
    vec2 region_coord;
    float v_spacing;
    float invert_map;
} map_parameters;
layout(set = 0, binding = 2, std430) restrict readonly buffer ShapeParameters {
    int operations; // Amount of Shapes to be processed
    float data[]; // Data each shape needs is different coded in first as type
    // Cricle type == 0 (InterpolationSize, InterpolationType, Operation, Texture, Negative, XScale, YScale, Rotation, XPos, YPos, ZPos, Radius) 9
    // Rectangle type == 1 (InterpolationSize, InterpolationType, Operation, Texture, Negative, XScale, YScale, Rotation, XPos, YPos, ZPos, XRectSize, YRectSize, Radius) 10
    // Polygon type == 2 (InterpolationSize, InterpolationType, Operation, Texture, Negative, XScale, YScale, Rotation, XPos, YPos, ZPos, PointCount, [x,y]) > 9
    // Path type == 3 (InterpolationSize, InterpolationType, Operation, Texture, Negative, PathWidth, PointCount, [x, y, z]) > 4 (Points should be transformed into global space)
    // Stamp type == 4 (InterpolationSize, interpolType, Operation, Texture, Negative, XScale, YScale, Rotation, XPos, YPos, ZPos, HeightScale, StampSize, StampIndex) 11
} shape_data_buffer;



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
    // Grabs image coordinates, dimension and information
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);

    float map_value = 0.0;

    ivec2 dimensions = imageSize(sdfmap);
    vec2 global_size = vec2(dimensions) * map_parameters.v_spacing;
    
    // Calculate the current pixels global location
    vec2 global_loc = vec2(coords) * map_parameters.v_spacing + global_size * map_parameters.region_coord;
    vec2 region_center = global_size / 2.0 + global_size * map_parameters.region_coord;
    
    // Shape Operation
    int read_idx = 0; // Index used to read the data buffer
    for (int i = 0; i < shape_data_buffer.operations; i++) {
        // Retrive Shaoe parameters
        int type = int(shape_data_buffer.data[read_idx]);

        vec2 location = vec2(shape_data_buffer.data[read_idx + 9], shape_data_buffer.data[read_idx + 10]);
        vec2 scale = vec2(shape_data_buffer.data[read_idx + 6], shape_data_buffer.data[read_idx + 7]);
        float shape_rotation = shape_data_buffer.data[read_idx + 8];
        float interpol = shape_data_buffer.data[read_idx + 1];
        int interpolType = int(shape_data_buffer.data[read_idx + 2]);
        vec2 sample_pos = transform(global_loc, location, scale, shape_rotation);
        bool negative_shape = bool(shape_data_buffer.data[read_idx + 5]);

        // Rund SDF calculation by type
        float s_sdf;
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


        } else { // Path
            int point_count = int(shape_data_buffer.data[read_idx + 7]);
            // Regular Shape parameters are unusable except interpol variables
            float path_width = shape_data_buffer.data[read_idx + 6];

            s_sdf = length(vec2(shape_data_buffer.data[read_idx + 8], shape_data_buffer.data[read_idx + 10]) - global_loc);
            for (int i=0; i<point_count-1; i++) {
                vec2 first_point = vec2(shape_data_buffer.data[read_idx + i*3 + 8],
                                        shape_data_buffer.data[read_idx + i*3 + 10]);
                vec2 secound_point = vec2(shape_data_buffer.data[read_idx + i*3 + 11],
                                        shape_data_buffer.data[read_idx + i*3 + 13]);
                
                vec2 sdf_calc = segment(global_loc, first_point.xy, secound_point.xy, path_width);
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

        if (negative_shape) {
            map_value = mix(0.0, map_value, s_sdf);
        } else {
            map_value = mix(1.0, map_value, s_sdf);
        }
        
    }

    if (map_parameters.invert_map > 0.5) {
        map_value = 1.0 - map_value;
    }
    
    // Store the data back into the image
    map_value = clamp(map_value, 0.0, 1.0);
    lowp vec4 col = vec4(map_value, map_value, map_value, 1.0);
    imageStore(sdfmap, coords, col);
}
