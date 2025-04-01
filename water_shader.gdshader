
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.1, 0.4, 0.8, 0.7);
uniform vec4 deep_color : source_color = vec4(0.05, 0.2, 0.5, 0.8);
uniform float metallic : hint_range(0.0, 1.0) = 0.2;
uniform float roughness : hint_range(0.0, 1.0) = 0.1;
uniform float wave_height : hint_range(0.0, 2.0) = 0.2;
uniform float wave_speed : hint_range(0.0, 5.0) = 1.0;
uniform float wave_scale : hint_range(1.0, 100.0) = 20.0;
uniform vec3 flow_direction = vec3(1.0, 0.0, 0.0);
uniform float flow_strength = 2.0;
uniform float time = 0.0;
uniform float depth_factor = 0.1;

void vertex() {
	// Get world position for wave calculation
	vec3 vertex_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	
	// Wave calculation - sum of several sine waves for natural look
	float wave1 = sin(vertex_pos.x / wave_scale + time * wave_speed) * 
				 cos(vertex_pos.z / wave_scale + time * wave_speed * 0.8);
	float wave2 = sin(vertex_pos.x / wave_scale * 0.8 + time * wave_speed * 1.2) * 
				 cos(vertex_pos.z / wave_scale * 0.6 + time * wave_speed);
	
	// Apply wave height to y position
	VERTEX.y += (wave1 + wave2) * 0.5 * wave_height;
	
	// Calculate normal for lighting
	NORMAL = normalize(vec3(
		wave1 * -wave_height / wave_scale,  // x derivative
		1.0,  // keep some y component
		wave2 * -wave_height / wave_scale   // z derivative
	));
}

void fragment() {
	// Mix colors based on depth
	ALBEDO = mix(deep_color.rgb, shallow_color.rgb, 0.5);
	
	// Apply transparency from color alpha
	ALPHA = mix(deep_color.a, shallow_color.a, 0.5);
	METALLIC = metallic;
	ROUGHNESS = roughness;
	
	// Add fresnel effect for realism
	float fresnel = pow(1.0 - dot(NORMAL, VIEW), 5.0);
	SPECULAR = 0.5 + fresnel * 0.2;
}
