#[compute]
#version 450

// Invocations in the (x, y, z) dimension
// GPU runs a 8x8 Chunck on the texture
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;


// Memory preperation
layout(set = 0, binding = 0, r32f) restrict uniform image2D heightmap;
layout(set = 0, binding = 1, std430) restrict readonly buffer MapParameters {
    vec2 region_coord;
    float v_spacing;
} map_parameters;
layout(set = 0, binding = 2, std430) restrict readonly buffer ShapeParameters {
    int operations; // Amount of Shapes to be processed
    float data[]; // Data each shape needs is different coded in first as type
    // Cricle type == 0 (InterpolationSize, InterpolationType, XScale, YScale, Rotation, XPos, YPos, ZPos, Radius) 9
    // Rectangle type == 1 (InterpolationSize, InterpolationType, XScale, YScale, Rotation, XPos, YPos, ZPos, XRectSize, YRectSize, Radius) 10
    // Polygon type == 2 (InterpolationSize, InterpolationType, XScale, YScale, Rotation, XPos, YPos, ZPos, PointCount, [x,y]) > 9
    // Path type == 3 (InterpolationSize, InterpolationType, PathWidth, PointCount, [x, y, z]) > 4 (Points should be transformed into global space)
    // Stamp type == 4 (InterpolationSize, interpolType, XScale, YScale, Rotation, XPos, YPos, ZPos, HeightScale, StampSize, StampIndex) 11
} shape_data_buffer;
layout (set = 0, binding = 3) uniform sampler2DArray StampMaps;



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
    float map_height = imageLoad(heightmap, coords).r;
    ivec2 dimensions = imageSize(heightmap);
    vec2 global_size = vec2(dimensions) * map_parameters.v_spacing;
    
    // Calculate the current pixels global location
    vec2 global_loc = vec2(coords) * map_parameters.v_spacing + global_size * map_parameters.region_coord;
    vec2 region_center = global_size / 2.0 + global_size * map_parameters.region_coord;
    
    // Shape Operation
    int read_idx = 0; // Index used to read the data buffer
    for (int i = 0; i < shape_data_buffer.operations; i++) {
        // Retrive Shaoe parameters
        int type = int(shape_data_buffer.data[read_idx]);

        vec2 location = vec2(shape_data_buffer.data[read_idx + 6], shape_data_buffer.data[read_idx + 7]);
        float height = shape_data_buffer.data[read_idx + 8];
        vec2 scale = vec2(shape_data_buffer.data[read_idx + 3], shape_data_buffer.data[read_idx + 4]);
        float shape_rotation = shape_data_buffer.data[read_idx + 5];
        float interpol = shape_data_buffer.data[read_idx + 1];
        int interpolType = int(shape_data_buffer.data[read_idx + 2]);
        vec2 sample_pos = transform(global_loc, location, scale, shape_rotation);

        // Rund SDF calculation by type
        float s_sdf;
        if (type == 0) { // Circle
            float c_radius = shape_data_buffer.data[read_idx + 9];
            read_idx += 10;

            s_sdf = circle(sample_pos, c_radius);

        } else if (type == 1) { // Rectangle
            vec2 rec_size = vec2(shape_data_buffer.data[read_idx + 9], shape_data_buffer.data[read_idx + 10]);
            read_idx += 11;

            s_sdf = rectangle(sample_pos, rec_size);

        } else if (type == 2) { // Polygon
            int point_count = int(shape_data_buffer.data[read_idx + 9]);
            vec2 first_point = vec2(shape_data_buffer.data[read_idx + 10], shape_data_buffer.data[read_idx + 11]);

            // Polygon SDF calculation, cant be moved into a subroutnine because the array size is unknown
            float dis = dot(sample_pos - first_point, sample_pos - first_point);
            float s = 1.0;

            for (int i=0, j=point_count-1; i<point_count; j=i, i++) {
                vec2 cur = vec2(shape_data_buffer.data[read_idx + 10 + i*2], shape_data_buffer.data[read_idx + 11 + i*2]);
                vec2 prev = vec2(shape_data_buffer.data[read_idx + 10 + j*2], shape_data_buffer.data[read_idx + 11 + j*2]);

                vec2 e = prev - cur;
                vec2 w = sample_pos - cur;
                vec2 b = w - e*clamp( dot(w, e) / dot(e, e), 0.0, 1.0);
                dis = min( dis, dot(b,b));

                bvec3 cond = bvec3( sample_pos.y >= cur.y, sample_pos.y < prev.y, e.x*w.y > e.y*w.x);

                if ( all(cond) || all(not(cond))) {s = -s;}
            }

            read_idx += 10 + point_count * 2;
            s_sdf = s*sqrt(dis);


        } else if (type == 3) { // Path
            int point_count = int(shape_data_buffer.data[read_idx + 4]);
            // Regular Shape parameters are unusable except interpol variables
            float path_width = shape_data_buffer.data[read_idx + 3];

            s_sdf = length(vec2(shape_data_buffer.data[read_idx + 5], shape_data_buffer.data[read_idx + 7]) - global_loc);
            height = map_height;
            for (int i=0; i<point_count-1; i++) {
                vec3 first_point = vec3(shape_data_buffer.data[read_idx + i*3 + 5],
                                        shape_data_buffer.data[read_idx + i*3 + 6],
                                        shape_data_buffer.data[read_idx + i*3 + 7]);
                vec3 secound_point = vec3(shape_data_buffer.data[read_idx + i*3 + 8],
                                        shape_data_buffer.data[read_idx + i*3 + 9],
                                        shape_data_buffer.data[read_idx + i*3 + 10]);
                
                vec2 sdf_calc = segment(global_loc, first_point.xz, secound_point.xz, path_width);
                float height_gradient = mix(first_point.y, secound_point.y, sdf_calc.y);

                // Height End correction
                if (i == 0) {
                    sdf_calc.y = clamp(sdf_calc.y, 0.0, 9999999.99);
                } else if (i == point_count-2) {
                    sdf_calc.y = clamp(sdf_calc.y, -9999999.99, 1.0);
                }


                float a = length(secound_point-first_point) / interpol;
                float gradient_alpha = smoothstep(0.0, 1.0, 1.0 + a*0.5 - abs(sdf_calc.y - 0.5) * a);
                
                height = mix(height, height_gradient, step(sdf_calc.x - interpol, 0.001) * gradient_alpha);
                s_sdf = min(sdf_calc.x, s_sdf);
            }

            read_idx += 5 + point_count * 3;

        } else { // Stamp Type
            float height_s = shape_data_buffer.data[read_idx + 9];
            float stamp_scale = shape_data_buffer.data[read_idx + 10];
            float stamp_idx = shape_data_buffer.data[read_idx + 11];
            read_idx += 12;

            vec2 stamp_uv = (sample_pos / stamp_scale) * 0.5 + 0.5;
            float stamp_height = height + texture(StampMaps, vec3(stamp_uv.x, stamp_uv.y, stamp_idx)).r * height_s;
            height = stamp_height;

            s_sdf = rectangle(sample_pos, vec2(stamp_scale - interpol));


        }


        // Shape Interpolation and blending
        if (interpolType == 0) {
            s_sdf = sdf_smoothstep(s_sdf, interpol);
        } else if (interpolType == 1) {
            s_sdf = sdf_linear(s_sdf, interpol);
        } else if (interpolType == 2) {
            s_sdf = sdf_ease_in(s_sdf, interpol);
        } else if (interpolType == 3) {
            s_sdf = sdf_ease_out(s_sdf, interpol);
        }

        map_height = mix(height, map_height, s_sdf);
    }
    
    // Store the data back into the image
    imageStore(heightmap, coords, vec4(map_height, 0.0, 0.0, 1.0));
}
