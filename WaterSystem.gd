extends Node3D

# Water Properties
@export var water_level: float = -5.0  # Global water level
@export var water_chunk_size: int = 128  # Match terrain chunk size
@export var water_color: Color = Color(0.1, 0.4, 0.8, 0.7)  # Semi-transparent blue
@export var deep_water_color: Color = Color(0.05, 0.2, 0.5, 0.8)  # Darker for deep water
@export var water_roughness: float = 0.1
@export var water_metallic: float = 0.2
@export var waves_enabled: bool = true
@export var wave_height: float = 0.2
@export var wave_speed: float = 1.0
@export var wave_scale: float = 20.0  # Lower = larger waves
@export var flow_direction: Vector3 = Vector3(1.0, 0, 0)  # Direction of water flow
@export var flow_strength: float = 2.0  # Strength of the flow

# Ocean/Lake water chunks
var water_chunks = {}

# Rivers
var rivers = []

# Fish
var fish_scenes = []
var active_fish = []

func _ready():
	# Load fish scenes for spawning
	# You'll need to create these scenes separately
	# fish_scenes.append(load("res://Fish1.tscn"))
	# fish_scenes.append(load("res://Fish2.tscn"))
	
	# Setup water shader
	pass

func _process(delta):
	# Update water waves using time and shader parameters
	if waves_enabled:
		for chunk_pos in water_chunks:
			var water_mesh = water_chunks[chunk_pos]
			if water_mesh and is_instance_valid(water_mesh):
				var material = water_mesh.material_override
				if material:
					material.set_shader_parameter("time", Time.get_ticks_msec() / 1000.0 * wave_speed)

	# Update fish positions based on water flow
	update_fish(delta)

# Creates a water chunk at the specified position
func create_water_chunk(chunk_pos: Vector2, terrain_generator):
	var world_pos_x = chunk_pos.x * water_chunk_size
	var world_pos_z = chunk_pos.y * water_chunk_size
	
	# Create water mesh
	var water_plane = PlaneMesh.new()
	water_plane.size = Vector2(water_chunk_size, water_chunk_size)
	water_plane.subdivide_width = 16  # Subdivide for wave effect
	water_plane.subdivide_depth = 16
	
	var water_mesh_instance = MeshInstance3D.new()
	water_mesh_instance.mesh = water_plane
	water_mesh_instance.name = "WaterChunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	
	# Create water material with shader
	var water_material = ShaderMaterial.new()
	var water_shader = Shader.new()
	
	# Water shader with transparency, waves, depth-based color, and flow
	water_shader.code = """
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
	
	varying vec3 vertex_pos;
	
	void vertex() {
		// Get world position for wave calculation
		vertex_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		
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
		// Calculate flow effect based on time
		vec2 flow_uv_offset = vec2(flow_direction.x, flow_direction.z) * flow_strength * time;
		
		// Get depth-based factor for color blending
		float depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;
		vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth * 2.0 - 1.0);
		vec4 world_pos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		world_pos /= world_pos.w;
		float depth_blend = clamp(exp(-depth_factor * world_pos.z), 0.0, 1.0);
		
		// Mix colors based on depth
		ALBEDO = mix(deep_color.rgb, shallow_color.rgb, depth_blend);
		
		// Apply transparency and other properties
		ALPHA = mix(deep_color.a, shallow_color.a, depth_blend);
		METALLIC = metallic;
		ROUGHNESS = roughness;
		
		// Add fresnel effect for realism
		float fresnel = pow(1.0 - dot(NORMAL, VIEW), 5.0);
		SPECULAR = 0.5 + fresnel * 0.2;
	}
	"""
	
	water_material.shader = water_shader
	
	# Set shader parameters
	water_material.set_shader_parameter("shallow_color", water_color)
	water_material.set_shader_parameter("deep_color", deep_water_color)
	water_material.set_shader_parameter("metallic", water_metallic)
	water_material.set_shader_parameter("roughness", water_roughness)
	water_material.set_shader_parameter("wave_height", wave_height)
	water_material.set_shader_parameter("wave_speed", wave_speed)
	water_material.set_shader_parameter("wave_scale", wave_scale)
	water_material.set_shader_parameter("flow_direction", flow_direction)
	water_material.set_shader_parameter("flow_strength", flow_strength)
	water_material.set_shader_parameter("time", 0.0) # Will be updated in _process
	
	water_mesh_instance.material_override = water_material
	
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
	
	# Spawn fish in this water chunk (with random chance)
	if randf() < 0.3 and len(fish_scenes) > 0:  # 30% chance to spawn fish
		spawn_fish(water_mesh_instance.global_position, 2 + randi() % 4)  # 2-5 fish

# Removes a water chunk
func remove_water_chunk(chunk_pos: Vector2):
	if water_chunks.has(chunk_pos):
		var water_mesh = water_chunks[chunk_pos]
		if is_instance_valid(water_mesh):
			water_mesh.queue_free()
		water_chunks.erase(chunk_pos)

# Checks if specific terrain positions should have water
# Override this to create custom water bodies
func should_have_water(global_position: Vector3) -> bool:
	# By default, any position below water_level has water
	return global_position.y < water_level

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

# Creates a river from start to end point with specified width
func create_river(start_pos: Vector3, end_pos: Vector3, width: float = 10.0):
	# Create a path for the river to follow
	var river_path = []
	var direction = (end_pos - start_pos).normalized()
	var length = start_pos.distance_to(end_pos)
	
	# Generate path with some variation
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.frequency = 0.05
	
	var segments = int(length / 10.0)  # One point every 10 units
	for i in range(segments + 1):
		var progress = float(i) / float(segments)
		var pos = start_pos.lerp(end_pos, progress)
		
		# Add some noise to the path for natural winding
		var noise_val_x = noise.get_noise_1d(progress * 100.0) * 20.0
		var noise_val_z = noise.get_noise_1d(progress * 100.0 + 500.0) * 20.0
		
		# Don't add noise to y (keep flowing downhill)
		pos.x += noise_val_x
		pos.z += noise_val_z
		
		# Make sure we're at water level
		pos.y = water_level
		
		river_path.append(pos)
	
	# Create river mesh
	var river_mesh = create_river_mesh(river_path, width)
	
	# Set up flow direction along the river
	var river_direction = (end_pos - start_pos).normalized()
	
	# Add to scene
	add_child(river_mesh)
	rivers.append(river_mesh)
	
	# Set up water flow (stronger in rivers)
	var material = river_mesh.material_override
	if material:
		material.set_shader_parameter("flow_direction", Vector3(river_direction.x, 0, river_direction.z))
		material.set_shader_parameter("flow_strength", 5.0)  # Stronger flow in rivers

# Helper function to create a river mesh from a path
func create_river_mesh(path: Array, width: float) -> MeshInstance3D:
	var surface_tool = SurfaceTool.new()
	var mesh = ArrayMesh.new()
	
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Generate river mesh from path
	for i in range(path.size() - 1):
		var start = path[i]
		var end = path[i+1]
		
		var direction = (end - start).normalized()
		var perpendicular = Vector3(-direction.z, 0, direction.x).normalized()
		
		var left_start = start + perpendicular * width/2
		var right_start = start - perpendicular * width/2
		var left_end = end + perpendicular * width/2
		var right_end = end - perpendicular * width/2
		
		# First triangle
		surface_tool.add_vertex(left_start)
		surface_tool.add_vertex(right_start)
		surface_tool.add_vertex(left_end)
		
		# Second triangle
		surface_tool.add_vertex(right_start)
		surface_tool.add_vertex(right_end)
		surface_tool.add_vertex(left_end)
	
	surface_tool.generate_normals()
	mesh = surface_tool.commit()
	
	# Create mesh instance
	var river_instance = MeshInstance3D.new()
	river_instance.mesh = mesh
	
	# Use same water material with adjusted flow parameters
	var water_material = ShaderMaterial.new()
	var water_shader = Shader.new()
	water_shader.code = """
	shader_type spatial;
	render_mode blend_mix, depth_draw_always, cull_back, diffuse_lambert, specular_schlick_ggx;
	
	uniform vec4 shallow_color : source_color = vec4(0.1, 0.4, 0.8, 0.7);
	uniform vec4 deep_color : source_color = vec4(0.05, 0.2, 0.5, 0.8);
	uniform float metallic : hint_range(0.0, 1.0) = 0.2;
	uniform float roughness : hint_range(0.0, 1.0) = 0.1;
	uniform float wave_height : hint_range(0.0, 2.0) = 0.1;
	uniform float wave_speed : hint_range(0.0, 5.0) = 2.0;
	uniform float wave_scale : hint_range(1.0, 100.0) = 5.0;
	uniform vec3 flow_direction = vec3(1.0, 0.0, 0.0);
	uniform float flow_strength = 5.0;
	uniform float time = 0.0;
	
	varying vec3 vertex_pos;
	
	void vertex() {
		vertex_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		
		// Small ripples along flow direction
		float wave = sin(vertex_pos.x / wave_scale + vertex_pos.z / wave_scale + time * wave_speed * 2.0);
		VERTEX.y += wave * wave_height;
	}
	
	void fragment() {
		// Use a brighter blue for rivers
		ALBEDO = mix(deep_color.rgb, shallow_color.rgb, 0.7);
		ALPHA = shallow_color.a;
		METALLIC = metallic;
		ROUGHNESS = roughness;
		SPECULAR = 0.7;
	}
	"""
	
	water_material.shader = water_shader
	
	# Set shader parameters - similar to ocean but faster flow
	water_material.set_shader_parameter("shallow_color", Color(0.2, 0.5, 0.9, 0.7))  # Brighter blue
	water_material.set_shader_parameter("deep_color", Color(0.1, 0.3, 0.6, 0.8))
	water_material.set_shader_parameter("metallic", water_metallic)
	water_material.set_shader_parameter("roughness", water_roughness)
	water_material.set_shader_parameter("wave_height", 0.1)  # Smaller waves in river
	water_material.set_shader_parameter("wave_speed", 2.0)   # Faster waves in river
	water_material.set_shader_parameter("wave_scale", 5.0)   # Smaller wave scale
	
	river_instance.material_override = water_material
	
	# Add collision for water interaction
	var water_body = Area3D.new()
	water_body.name = "RiverBody"
	
	var water_collision = CollisionShape3D.new()
	var water_box = BoxShape3D.new()
	
	# Calculate river bounds
	var min_x = INF
	var max_x = -INF
	var min_z = INF
	var max_z = -INF
	var mid_y = 0
	
	for point in path:
		min_x = min(min_x, point.x - width/2)
		max_x = max(max_x, point.x + width/2)
		min_z = min(min_z, point.z - width/2)
		max_z = max(max_z, point.z + width/2)
		mid_y += point.y
	
	mid_y /= path.size()
	
	water_box.size = Vector3(max_x - min_x, 2.0, max_z - min_z)
	water_collision.shape = water_box
	
	water_collision.position = Vector3(
		(min_x + max_x) / 2,
		mid_y - 1.0, # Position slightly below surface
		(min_z + max_z) / 2
	)
	
	water_body.add_child(water_collision)
	river_instance.add_child(water_body)
	
	# Connect signals for water interaction
	water_body.body_entered.connect(_on_body_entered_water)
	water_body.body_exited.connect(_on_body_exited_water)
	
	return river_instance

# Spawns a fish of random type at position
func spawn_fish(pos: Vector3, count: int = 1):
	if len(fish_scenes) == 0:
		return
	
	for i in range(count):
		# Random position within 10 units of spawn point
		var fish_pos = pos + Vector3(
			randf_range(-10, 10),
			randf_range(-1, -0.5),  # Slightly below water surface
			randf_range(-10, 10)
		)
		
		# Ensure fish is below water level
		fish_pos.y = min(fish_pos.y, water_level - 0.5)
		
		# Random fish type
		var fish_type = fish_scenes[randi() % fish_scenes.size()]
		var fish_instance = fish_type.instantiate()
		
		# Set fish position and random rotation
		fish_instance.position = fish_pos
		fish_instance.rotation.y = randf() * TAU  # Random direction
		
		add_child(fish_instance)
		active_fish.append(fish_instance)

# Updates fish positions based on water flow
func update_fish(delta):
	for fish in active_fish:
		if is_instance_valid(fish):
			# Apply water flow to fish position
			var flow_effect = flow_direction * flow_strength * delta
			
			# Check if fish is in river for stronger flow
			var in_river = false
			for river in rivers:
				if river.get_node("RiverBody").overlaps_body(fish):
					in_river = true
					# Get river-specific flow direction
					var river_material = river.material_override
					if river_material:
						var river_flow_dir = river_material.get_shader_parameter("flow_direction")
						var river_flow_strength = river_material.get_shader_parameter("flow_strength")
						flow_effect = river_flow_dir * river_flow_strength * delta
					break
			
			# Apply flow effect
			fish.position += flow_effect
			
			# Make fish face direction of movement
			if flow_effect.length() > 0.01:
				fish.look_at(fish.position + flow_effect, Vector3.UP)
			
			# Add random movement
			if randf() < 0.01:  # 1% chance each frame
				fish.rotation.y = randf() * TAU
			
			# Occasional small vertical adjustment
			if randf() < 0.02:
				fish.position.y += randf_range(-0.5, 0.5)
				# Keep fish below water surface but above terrain
				fish.position.y = clamp(fish.position.y, fish.position.y - 1.0, water_level - 0.5)

# Create a waterfall at the specified position with height and width
func create_waterfall(position: Vector3, height: float, width: float = 5.0):
	# Waterfall is a vertical water plane with particles
	var waterfall_mesh = PlaneMesh.new()
	waterfall_mesh.size = Vector2(width, height)
	
	var waterfall_instance = MeshInstance3D.new()
	waterfall_instance.mesh = waterfall_mesh
	
	# Rotate to face forward (waterfall flows down)
	waterfall_instance.rotation_degrees.x = -90
	
	# Center mesh at position
	waterfall_instance.position = position
	waterfall_instance.position.y += height / 2
	
	# Create waterfall material with shader
	var waterfall_material = ShaderMaterial.new()
	var waterfall_shader = Shader.new()
	
	waterfall_shader.code = """
	shader_type spatial;
	render_mode blend_mix, depth_draw_always, cull_back, diffuse_lambert, specular_schlick_ggx;
	
	uniform vec4 water_color : source_color = vec4(0.3, 0.5, 0.9, 0.8);
	uniform float flow_speed = 3.0;
	uniform float ripple_strength = 0.2;
	uniform float time = 0.0;
	
	void vertex() {
		// Add ripple effect to make waterfall look dynamic
		VERTEX.x += sin(VERTEX.y * 10.0 + time * flow_speed) * ripple_strength;
	}
	
	void fragment() {
		// Scrolling flow texture coordinates
		vec2 flow_uv = UV;
		flow_uv.y -= time * flow_speed;
		
		// Create subtle vertical stripe pattern
		float stripe = sin(flow_uv.y * 50.0) * 0.5 + 0.5;
		
		// Apply color with transparency based on flow
		ALBEDO = water_color.rgb;
		ALPHA = water_color.a * (0.7 + stripe * 0.3);
		
		// Add some variation based on height
		ALPHA *= clamp(1.0 - UV.y * 0.2, 0.7, 1.0);
		
		METALLIC = 0.3;
		ROUGHNESS = 0.2;
		SPECULAR = 0.7;
	}
	"""
	
	waterfall_material.shader = waterfall_shader
	
	# Set shader parameters
	waterfall_material.set_shader_parameter("water_color", Color(0.3, 0.5, 0.9, 0.8))
	waterfall_material.set_shader_parameter("flow_speed", 3.0)
	waterfall_material.set_shader_parameter("ripple_strength", 0.2)
	waterfall_material.set_shader_parameter("time", 0.0)
	
	waterfall_instance.material_override = waterfall_material
	
	# Create splash particles at bottom of waterfall
	var particles = GPUParticles3D.new()
	particles.position = Vector3(0, -height/2, 0)
	
	var particle_material = ParticleProcessMaterial.new()
	particle_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	particle_material.emission_box_extents = Vector3(width/2, 0.1, 0.5)
	particle_material.direction = Vector3(0, 1, 0)
	particle_material.spread = 45.0
	particle_material.initial_velocity_min = 3.0
	particle_material.initial_velocity_max = 6.0
	particle_material.gravity = Vector3(0, -9.8, 0)
	particle_material.scale_min = 0.1
	particle_material.scale_max = 0.3
	particle_material.color = Color(0.7, 0.8, 1.0, 0.7)
	
	particles.process_material = particle_material
	
	# Create splash mesh
	var splash_mesh = SphereMesh.new()
	splash_mesh.radius = 0.05
	splash_mesh.height = 0.1
	
	particles.draw_pass_1 = splash_mesh
	particles.amount = 100
	particles.lifetime = 1.0
	particles.explosiveness = 0.0
	particles.randomness = 0.5
	
	waterfall_instance.add_child(particles)
	
	# Add to scene
	add_child(waterfall_instance)
	
	return waterfall_instance

# WATER PHYSICS INTERACTIONS

# Signal handling for player entering water
func _on_body_entered_water(body):
	if body.name == "Player":
		apply_water_physics(body, true)

# Signal handling for player exiting water
func _on_body_exited_water(body):
	if body.name == "Player":
		apply_water_physics(body, false)

# Apply water physics to player character
func apply_water_physics(player, in_water: bool):
	if in_water:
		# Apply buoyancy effect when in water
		if player.has_method("set_gravity_scale"):
			player.set_gravity_scale(0.3)  # Lower gravity underwater for buoyancy
		else:
			# For custom gravity implementations
			if "gravity_magnitude" in player:
				player.gravity_magnitude = player.gravity_magnitude * 0.3
		
		# Slow down movement in water
		if "move_speed" in player:
			player.move_speed = player.move_speed * 0.6
		
		# Add upward force for buoyancy
		if player.has_method("add_constant_central_force"):
			player.add_constant_central_force(Vector3.UP * 10.0)
		
		# Enable swimming controls
		player.set_meta("is_swimming", true)
		
		# Play splash sound
		# var splash_sound = AudioStreamPlayer3D.new()
		# splash_sound.stream = load("res://sounds/splash.wav")
		# splash_sound.autoplay = true
		# add_child(splash_sound)
	else:
		# Restore normal physics when leaving water
		if player.has_method("set_gravity_scale"):
			player.set_gravity_scale(1.0)
		else:
			if "gravity_magnitude" in player:
				player.gravity_magnitude = 30.0  # Restore default from PlayerController.gd
		
		# Restore normal movement speed
		if "move_speed" in player:
			player.move_speed = 10.0  # Restore default from PlayerController.gd
		
		# Remove buoyancy force
		if player.has_method("add_constant_central_force"):
			player.add_constant_central_force(Vector3.ZERO)
		
		# Disable swimming controls
		player.set_meta("is_swimming", false)
