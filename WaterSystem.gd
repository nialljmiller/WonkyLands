extends Node3D

class_name WaterSystem

# Water Properties
@export var water_level: float = -5.0  # Global water level
@export var water_chunk_size: int = 128  # Match terrain chunk size

# Water appearance
@export_category("Appearance")
@export var water_color: Color = Color(0.1, 0.4, 0.8, 0.7)  # Semi-transparent blue
@export var deep_water_color: Color = Color(0.05, 0.2, 0.5, 0.8)  # Darker for deep water
@export var water_metallic: float = 0.2
@export var water_roughness: float = 0.05
@export var water_specular: float = 0.6
@export var water_fresnel: float = 5.0

# Wave settings
@export_category("Waves")
@export var waves_enabled: bool = true
@export var wave_height: float = 0.2
@export var wave_speed: float = 1.0
@export var wave_scale: float = 20.0  # Lower = larger waves
@export var wave_direction1: Vector2 = Vector2(1.0, 0.0)
@export var wave_direction2: Vector2 = Vector2(0.6, 0.8)
@export var wave_direction3: Vector2 = Vector2(-0.3, 0.7)

# Foam settings
@export_category("Foam")
@export var foam_color: Color = Color(1.0, 1.0, 1.0, 0.9)
@export var foam_amount: float = 0.2
@export var edge_foam: float = 0.5

# Flow settings
@export_category("Flow")
@export var flow_direction: Vector3 = Vector3(1.0, 0.0, 0.0)  # Direction of water flow
@export var flow_strength: float = 0.5  # Strength of the flow

# Physical properties
@export_category("Physics")
@export var water_density: float = 1.0
@export var water_drag: float = 0.7
@export var water_angular_drag: float = 0.8
@export var buoyancy_force: float = 9.8

# Ocean/Lake water chunks
var water_chunks = {}
var water_plane_mesh: PlaneMesh

# Cached shader resource and timing information
const WATER_SHADER_PATH := "res://RealisticWaterShader.gdshader"
var water_shader: Shader
var wave_time: float = 0.0
@export var shader_update_interval: float = 0.0
var _shader_update_timer: float = 0.0

# Subsystems
var fish_system: FishSystem
var ripple_system: RippleSystem

# Debug info
var debug_enabled: bool = false

func _ready():
        print("Realistic water system initializing...")

        # Initialize subsystems
        initialize_subsystems()

        ensure_water_shader()

        print("Water system initialized!")

func _process(delta):
        # Update water waves using time and shader parameters
        if waves_enabled:
                wave_time += delta * wave_speed
                _shader_update_timer += delta

                if shader_update_interval <= 0.0 or _shader_update_timer >= shader_update_interval:
                        update_water_shaders()
                        _shader_update_timer = 0.0

# Initialize subsystems (fish, ripples, etc.)
func initialize_subsystems():
	# Initialize fish system
	fish_system = FishSystem.new()
	fish_system.name = "FishSystem"
	add_child(fish_system)
	
	# Initialize ripple system
	ripple_system = RippleSystem.new()
	ripple_system.name = "RippleSystem"
	add_child(ripple_system)

# Update shader parameters for all water chunks
func update_water_shaders():
        for chunk_pos in water_chunks:
                var water_mesh = water_chunks[chunk_pos]
                if water_mesh and is_instance_valid(water_mesh):
                        var material = water_mesh.material_override
                        if material and material is ShaderMaterial:
                                # Apply shared wave time for all chunks
                                material.set_shader_parameter("time", wave_time)

func ensure_water_shader():
        if water_shader:
                return

        if not FileAccess.file_exists(WATER_SHADER_PATH):
                create_water_shader()

        water_shader = load(WATER_SHADER_PATH)

# Creates a water chunk at the specified position
func create_water_chunk(chunk_pos: Vector2, terrain_generator = null):
	var world_pos_x = chunk_pos.x * water_chunk_size
	var world_pos_z = chunk_pos.y * water_chunk_size
	
        # Create or reuse water mesh
        if water_plane_mesh == null:
                water_plane_mesh = PlaneMesh.new()
                water_plane_mesh.size = Vector2(water_chunk_size, water_chunk_size)
                water_plane_mesh.subdivide_width = 16
                water_plane_mesh.subdivide_depth = 16
	
        var water_mesh_instance = MeshInstance3D.new()
        water_mesh_instance.mesh = water_plane_mesh
	water_mesh_instance.name = "WaterChunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	
	# Create a standard material for fallback (in case shader fails)
	var standard_material = StandardMaterial3D.new()
	standard_material.albedo_color = water_color
	standard_material.roughness = water_roughness
	standard_material.metallic = water_metallic
	standard_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	
	# Create water material with shader
        ensure_water_shader()

        var water_material = ShaderMaterial.new()
        water_material.shader = water_shader
	
	# Set shader parameters
	water_material.set_shader_parameter("shallow_color", water_color)
	water_material.set_shader_parameter("deep_color", deep_water_color)
	water_material.set_shader_parameter("depth_factor", 0.3)
	
	# Wave parameters
	water_material.set_shader_parameter("wave_height", wave_height)
	water_material.set_shader_parameter("wave_speed", wave_speed)
	water_material.set_shader_parameter("wave_scale", wave_scale)
	water_material.set_shader_parameter("wave_clarity", 0.8)
	water_material.set_shader_parameter("wave_direction1", wave_direction1)
	water_material.set_shader_parameter("wave_direction2", wave_direction2)
	water_material.set_shader_parameter("wave_direction3", wave_direction3)
	
	# Foam parameters
	water_material.set_shader_parameter("foam_color", foam_color)
	water_material.set_shader_parameter("foam_amount", foam_amount)
	water_material.set_shader_parameter("edge_foam", edge_foam)
	
	# Material properties
	water_material.set_shader_parameter("metallic", water_metallic)
	water_material.set_shader_parameter("roughness", water_roughness)
	water_material.set_shader_parameter("specular", water_specular)
	water_material.set_shader_parameter("fresnel_power", water_fresnel)
	
	# Flow parameters
	water_material.set_shader_parameter("flow_direction", flow_direction)
	water_material.set_shader_parameter("flow_strength", flow_strength)
	
	# Initial time value
        water_material.set_shader_parameter("time", wave_time)
	
	# Apply material
	water_mesh_instance.material_override = water_material if water_material.shader != null else standard_material
	
	# Position water at the water level
	water_mesh_instance.position = Vector3(world_pos_x, water_level, world_pos_z)
	
	# Add collision for water interaction
	var water_body = Area3D.new()
	water_body.name = "WaterBody"
	
	var water_collision = CollisionShape3D.new()
	var water_box = BoxShape3D.new()
	water_box.size = Vector3(water_chunk_size, 2.0, water_chunk_size)  # 2 units thick
	water_collision.shape = water_box
	water_collision.position.y = -1.0  # Center the box shape vertically
	
	water_body.add_child(water_collision)
	water_mesh_instance.add_child(water_body)
	
	# Connect signals for water interaction
	water_body.body_entered.connect(_on_body_entered_water)
	water_body.body_exited.connect(_on_body_exited_water)
	
	# Add water to scene
	add_child(water_mesh_instance)
	
	# Store reference in dictionary
	water_chunks[chunk_pos] = water_mesh_instance
	
	# Spawn fish in this chunk (via fish system)
	if fish_system:
		fish_system.spawn_fish_in_chunk(chunk_pos, water_mesh_instance)

# Create the water shader file
func create_water_shader():
	# Read shader code from the water-shader artifact we created
	# For simplicity in this example, we'll put a simplified version here
	var shader_code = """shader_type spatial;
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
	float foam_noise = noise(world_pos.xz * 0.5 + time * 0.2);
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
"""
	
	# Write the shader to a file
	var file = FileAccess.open("res://RealisticWaterShader.gdshader", FileAccess.WRITE)
	if file:
		file.store_string(shader_code)
		file.close()
		print("Created realistic water shader file")
	else:
		push_error("Failed to create water shader file")

# Removes a water chunk
func remove_water_chunk(chunk_pos: Vector2):
	if water_chunks.has(chunk_pos):
		var water_mesh = water_chunks[chunk_pos]
		if is_instance_valid(water_mesh):
			water_mesh.queue_free()
		
		# Remove fish in this chunk
		if fish_system:
			fish_system.clear_fish_chunk(chunk_pos)
		
		water_chunks.erase(chunk_pos)

# Updates which water chunks are visible
func update_water_chunks(player_pos: Vector3, view_distance: int, chunk_size: int):
	var center_chunk_x = floor(player_pos.x / chunk_size)
	var center_chunk_z = floor(player_pos.z / chunk_size)
	
	# Track which chunks should remain loaded
	var chunks_to_keep = {}
	
	# Generate all chunks within view distance
	for x in range(center_chunk_x - view_distance, center_chunk_x + view_distance + 1):
		for z in range(center_chunk_z - view_distance, center_chunk_z + view_distance + 1):
			var chunk_pos = Vector2(x, z)
			chunks_to_keep[chunk_pos] = true
			
			# If chunk doesn't exist, generate it
			if not water_chunks.has(chunk_pos):
				create_water_chunk(chunk_pos, null)
	
	# Remove chunks outside view distance
	var chunks_to_remove = []
	for chunk_pos in water_chunks.keys():
		if not chunks_to_keep.has(chunk_pos):
			chunks_to_remove.append(chunk_pos)
	
	for chunk_pos in chunks_to_remove:
		remove_water_chunk(chunk_pos)

# Signal handling for objects entering water
func _on_body_entered_water(body):
	if body.name == "Player":
		apply_water_physics(body, true)
		
		# Create splash effect
		var splash_position = body.global_position
		splash_position.y = water_level
		
		# Calculate splash intensity based on velocity
		var velocity = Vector3.ZERO
		if body is CharacterBody3D:
			velocity = body.velocity
		
		var impact_velocity = abs(velocity.y)  # Use absolute value of vertical velocity
		var splash_intensity = clamp(impact_velocity / 10.0, 0.3, 2.0)
		
		# Create splash
		create_splash_effect(splash_position, splash_intensity)
		
		# Add ripple via ripple system
		if ripple_system:
			ripple_system.add_splash_ripple(splash_position, splash_intensity)
		
		# Trigger player's water entry method if it exists
		if body.has_method("_on_enter_water"):
			body._on_enter_water()

# Signal handling for objects exiting water
func _on_body_exited_water(body):
	if body.name == "Player":
		apply_water_physics(body, false)
		
		# Create small splash when exiting water
		var splash_position = body.global_position
		splash_position.y = water_level
		
		# Calculate splash intensity based on velocity
		var velocity = Vector3.ZERO
		if body is CharacterBody3D:
			velocity = body.velocity
		
		var impact_velocity = velocity.y  # Positive Y is upward when exiting
		if impact_velocity > 3.0:  # Only splash if moving upward significantly
			var splash_intensity = clamp(impact_velocity / 10.0, 0.1, 1.0)
			create_splash_effect(splash_position, splash_intensity)
			
			# Add ripple
			if ripple_system:
				ripple_system.add_splash_ripple(splash_position, splash_intensity * 0.7)

# Apply water physics to objects
func apply_water_physics(body, in_water: bool):
	# Set swimming state
	body.set_meta("is_swimming", in_water)
	
	if in_water:
		# Apply buoyancy and water resistance for RigidBody
		if body is RigidBody3D:
			body.gravity_scale = 0.1  # Reduced gravity in water
			body.linear_damp = water_drag
			body.angular_damp = water_angular_drag
		
		# Apply different movement mechanics for CharacterBody3D
		if body is CharacterBody3D:
			# Store original move speed if not already stored
			if not body.has_meta("original_move_speed") and body.get("move_speed") != null:
				body.set_meta("original_move_speed", body.move_speed)
			
			if not body.has_meta("original_jump_strength") and body.get("jump_strength") != null:
				body.set_meta("original_jump_strength", body.jump_strength)
			
			# Apply swimming speed
			if body.get("swim_speed") != null:
				body.move_speed = body.swim_speed
			else:
				# If no swim_speed defined, use 60% of normal speed
				if body.has_meta("original_move_speed"):
					body.move_speed = body.get_meta("original_move_speed") * 0.6
			
			# Disable normal jumping in water
			if body.get("jump_strength") != null:
				body.jump_strength = 0
	else:
		# Restore normal physics
		if body is RigidBody3D:
			body.gravity_scale = 1.0
			body.linear_damp = 0.0
			body.angular_damp = 0.05
		
		# Restore original movement values
		if body is CharacterBody3D:
			if body.has_meta("original_move_speed"):
				body.move_speed = body.get_meta("original_move_speed")
			
			if body.has_meta("original_jump_strength"):
				body.jump_strength = body.get_meta("original_jump_strength")

# Create a splash effect at the specified position
func create_splash_effect(position: Vector3, intensity: float = 1.0):
	# Create particle system for splash
	var splash = GPUParticles3D.new()
	splash.name = "WaterSplash"
	
	# Configure particle system
	var particle_material = ParticleProcessMaterial.new()
	particle_material.direction = Vector3(0, 1, 0)
	particle_material.spread = 45.0
	particle_material.initial_velocity_min = 2.0 * intensity
	particle_material.initial_velocity_max = 5.0 * intensity
	particle_material.gravity = Vector3(0, -9.8, 0)
	particle_material.scale_min = 0.1
	particle_material.scale_max = 0.3
	particle_material.color = Color(0.7, 0.8, 1.0, 0.8)
	
	splash.process_material = particle_material
	
	# Create splash mesh
	var splash_mesh = SphereMesh.new()
	splash_mesh.radius = 0.05
	splash_mesh.height = 0.1
	
	splash.draw_pass_1 = splash_mesh
	splash.amount = int(50 * intensity)
	splash.lifetime = 1.0
	splash.explosiveness = 0.8
	splash.one_shot = true
	
	# Add to scene at the correct position
	add_child(splash)
	splash.global_position = position
	splash.emitting = true
	
	# Set up timer to remove splash
	var timer = Timer.new()
	timer.wait_time = 2.0
	timer.one_shot = true
	timer.autostart = true
	splash.add_child(timer)
	timer.timeout.connect(func(): splash.queue_free())

# Calculate wave height at a specific position (for buoyancy)
func get_wave_height_at_position(world_pos: Vector3) -> float:
	# Basic implementation - could be more accurate with shader code
	if not waves_enabled:
		return water_level
	
	# Calculate wave height from the same formula as shader
	var time_val = Time.get_ticks_msec() / 1000.0 * wave_speed
	var pos = Vector2(world_pos.x, world_pos.z)
	
	# Sum of several sine waves
	var wave1 = sin(dot(wave_direction1, pos) * 0.05 + time_val * wave_speed)
	var wave2 = sin(dot(wave_direction2, pos) * 0.07 + time_val * wave_speed * 1.2)
	var wave3 = sin(dot(wave_direction3, pos) * 0.06 + time_val * wave_speed * 0.9)
	
	var wave_height_at_point = (wave1 * 0.5 + wave2 * 0.3 + wave3 * 0.2) * wave_height
	
	return water_level + wave_height_at_point

# Utility function for dot product in GDScript
func dot(v1: Vector2, v2: Vector2) -> float:
	return v1.x * v2.x + v1.y * v2.y

# Apply ripple texture to all water chunks
func apply_ripple_texture(texture: Texture2D):
	for chunk_pos in water_chunks:
		var water_mesh = water_chunks[chunk_pos]
		if water_mesh and is_instance_valid(water_mesh):
			var material = water_mesh.material_override
			if material and material is ShaderMaterial:
				material.set_shader_parameter("ripple_texture", texture)
				material.set_shader_parameter("enable_ripples", true)

# Get water level (for external systems)
func get_water_level() -> float:
	return water_level

# Get chunk size (for external systems)
func get_chunk_size() -> float:
	return water_chunk_size

# Get flow direction (for fish)
func get_flow_direction() -> Vector3:
	return flow_direction

# Get flow strength (for fish)
func get_flow_strength() -> float:
	return flow_strength

# Debug functions
func toggle_debug():
	debug_enabled = !debug_enabled
	
	# Toggle debug in subsystems
	if ripple_system:
		ripple_system.debug_enabled = debug_enabled
