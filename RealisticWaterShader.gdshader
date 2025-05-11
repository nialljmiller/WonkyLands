shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_lambert, specular_schlick_ggx;

// ===== WATER COLORS AND TRANSPARENCY =====
uniform vec4 shallow_color : source_color = vec4(0.1, 0.4, 0.8, 0.7);
uniform vec4 deep_color : source_color = vec4(0.05, 0.2, 0.5, 0.8);
uniform float depth_factor = 0.3;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

// ===== WAVE PROPERTIES =====
uniform float wave_height = 0.2;
uniform float wave_speed = 1.0;
uniform float wave_scale = 20.0;
uniform float wave_clarity = 0.8;
uniform vec2 wave_direction1 = vec2(1.0, 0.0);
uniform vec2 wave_direction2 = vec2(0.6, 0.8);
uniform vec2 wave_direction3 = vec2(-0.3, 0.7);

// ===== FOAM PROPERTIES =====
uniform vec4 foam_color : source_color = vec4(1.0, 1.0, 1.0, 0.9);
uniform float foam_amount = 0.2;
uniform float foam_sharpness = 10.0;
uniform float edge_foam = 0.5;
uniform float foam_scale = 0.5;

// ===== MATERIAL PROPERTIES =====
uniform float metallic = 0.2;
uniform float roughness = 0.05;
uniform float specular = 0.6;
uniform float fresnel_power = 5.0;
uniform float refraction_amount = 0.1;

// ===== RIPPLE PROPERTIES =====
uniform sampler2D ripple_texture : hint_default_white, filter_linear_mipmap;
uniform bool enable_ripples = true;
uniform float ripple_strength = 0.25;

// ===== TIME =====
uniform float time = 0.0;

// ===== PRIVATE VARIABLES =====
varying vec3 world_pos;
varying vec3 vertex_normal;
varying float wave_height_at_point;

float get_waves(vec2 pos, float time_val) {
    // Three overlapping waves traveling in different directions
    float wave1 = sin(dot(wave_direction1, pos) * 0.05 + time_val * wave_speed);
    float wave2 = sin(dot(wave_direction2, pos) * 0.07 + time_val * wave_speed * 1.2);
    float wave3 = sin(dot(wave_direction3, pos) * 0.06 + time_val * wave_speed * 0.9);

    // Add smaller detail waves
    float detail1 = sin(pos.x * 0.3 + time_val * 2.0) * cos(pos.y * 0.3 + time_val * 1.5) * 0.15;
    float detail2 = sin(pos.x * 0.5 - time_val * 1.4) * cos(pos.y * 0.5 + time_val * 1.8) * 0.1;

    // Add very fine ripples
    float ripple1 = sin(pos.x * 1.2 + time_val * 3.5) * cos(pos.y * 1.1 + time_val * 3.2) * 0.05;
    float ripple2 = sin(pos.x * 1.3 - time_val * 4.0) * cos(pos.y * 1.4 - time_val * 3.8) * 0.03;

    // Combine all waves with different weights
    float big_waves = (wave1 * 0.5 + wave2 * 0.3 + wave3 * 0.2);
    float medium_waves = (detail1 + detail2);
    float small_waves = (ripple1 + ripple2);

    return (big_waves + medium_waves + small_waves) * wave_height;
}

// Helper function to create noise
float noise(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453123);
}

// Calculate wave normal based on height differences
vec3 calculate_normal(vec2 pos, float time_val) {
    float sample_distance = 0.1;

    // Sample heights at nearby points
    float height_center = get_waves(pos, time_val);
    float height_right = get_waves(pos + vec2(sample_distance, 0.0), time_val);
    float height_up = get_waves(pos + vec2(0.0, sample_distance), time_val);

    // Calculate tangent vectors
    vec3 tangent_right = normalize(vec3(sample_distance, height_right - height_center, 0.0));
    vec3 tangent_up = normalize(vec3(0.0, height_up - height_center, sample_distance));

    // Calculate normal using cross product
    return normalize(cross(tangent_up, tangent_right));
}

void vertex() {
    // Get world position for wave calculation
    world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

    // Calculate wave height at this point
    wave_height_at_point = get_waves(world_pos.xz, time);

    // Apply vertical displacement from waves
    VERTEX.y += wave_height_at_point;

    // Calculate new normal based on wave shape
    vec3 wave_normal = calculate_normal(world_pos.xz, time);

    // Blend original normal with wave normal
    vertex_normal = normalize(mix(NORMAL, wave_normal, wave_clarity));
    NORMAL = vertex_normal;
}

void fragment() {
    // ==== DEPTH CALCULATIONS ====
    // Get screen depth (simplified to avoid complex matrix math)
    float depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;

    // Simple approach to calculate water depth
    float water_depth = 0.0;
    if (depth < 1.0) {
        // Convert depth to linear depth
        water_depth = (1.0 - depth) * 100.0;
        water_depth = clamp(water_depth, 0.0, 50.0);
    } else {
        water_depth = 50.0; // Max depth
    }

    // Calculate depth-based color blend
    float depth_blend = exp(-water_depth * depth_factor);
    depth_blend = clamp(depth_blend, 0.0, 1.0);

    // ==== REFRACTION ====
    // Calculate refraction offset based on normal
    vec2 refraction_offset = vertex_normal.xz * refraction_amount;

    // Apply additional refraction from ripples if enabled
    if (enable_ripples) {
        vec2 ripple_uv = world_pos.xz * 0.05;
        float ripple_value = texture(ripple_texture, ripple_uv + vec2(time * 0.02, time * 0.03)).r * 2.0 - 1.0;
        refraction_offset += vec2(ripple_value) * ripple_strength;
    }

    // Get refracted color from screen
    vec2 refracted_uv = SCREEN_UV + refraction_offset;
    refracted_uv = clamp(refracted_uv, vec2(0.001), vec2(0.999)); // Prevent sampling outside texture
    vec4 refracted_color = texture(SCREEN_TEXTURE, refracted_uv);

    // ==== FOAM CALCULATION ====
    // Edge foam based on water depth
    float edge_foam_mask = 1.0 - smoothstep(0.0, foam_amount, water_depth);

    // Wave crest foam based on wave height
    float wave_height_normalized = (wave_height_at_point / wave_height + 1.0) * 0.5;
    float crest_foam_mask = smoothstep(0.65, 0.85, wave_height_normalized) * 0.7;

    // Noise for foam texture
    float foam_noise = noise(world_pos.xz * foam_scale + time * 0.2);
    foam_noise *= foam_noise; // Square for more contrast

    // Combine foam sources
    float foam_mask = max(edge_foam_mask * edge_foam, crest_foam_mask);
    foam_mask *= foam_noise;

    // ==== COLOR BLENDING ====
    // Mix water colors based on depth
    vec4 water_color = mix(deep_color, shallow_color, depth_blend);

    // Add foam
    water_color = mix(water_color, foam_color, foam_mask);

    // Mix with refracted color
    ALBEDO = mix(refracted_color.rgb, water_color.rgb, water_color.a);

    // ==== MATERIAL PROPERTIES ====
    METALLIC = metallic;
    ROUGHNESS = roughness;
    SPECULAR = specular;

    // Calculate fresnel effect for reflectivity
    float fresnel = pow(1.0 - clamp(dot(vertex_normal, VIEW), 0.0, 1.0), fresnel_power);

    // Apply combined opacity
    ALPHA = clamp(max(water_color.a, fresnel * 0.4), 0.0, 1.0);

    // Add subtle glow to foam
    EMISSION = foam_color.rgb * foam_mask * 0.2;
}