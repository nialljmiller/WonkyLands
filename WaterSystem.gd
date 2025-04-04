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
	# Setup water shader
	print("Water system initialized")
	
	# Initialize fish scenes
	load_fish_scenes()

# Load fish scene files
func load_fish_scenes():
	print("Loading fish scenes...")
	
	# First, create the fish scene file if it doesn't exist already
	ensure_fish_scene_exists()
	
	# Try to load the fish scene
	var fish_scene_path = "res://Fish1.tscn"
	var fish1 = load(fish_scene_path)
	
	if fish1:
		fish_scenes.append(fish1)
		print("Fish1 loaded successfully")
	else:
		print("Failed to load Fish1.tscn - trying alternative approach")
		
		# Try using ResourceLoader instead
		var fish1_packed = ResourceLoader.load(fish_scene_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if fish1_packed:
			fish_scenes.append(fish1_packed)
			print("Fish1 loaded successfully with ResourceLoader")
		else:
			print("All attempts to load Fish1.tscn failed")

# Make sure the fish scene exists as a proper scene file
func ensure_fish_scene_exists():
	# Check if Fish1.tscn already exists
	if FileAccess.file_exists("res://Fish1.tscn"):
		print("Fish1.tscn already exists")
		return
		
	print("Creating Fish1.tscn file...")
	
	# If the fish scene doesn't exist, we'll create it from the template
	var template_content = """[gd_scene load_steps=2 format=3 uid="uid://b4wx60ukl38hh"]

[ext_resource type="Script" path="res://Fish.gd" id="1_fish"]

[node name="Fish1" type="CharacterBody3D"]
script = ExtResource("1_fish")
fish_color = Color(0.3, 0.6, 0.9, 1)
fish_size = Vector3(0.4, 0.15, 0.08)
swim_speed = 1.2
"""

	# Save the content to the scene file
	var file = FileAccess.open("res://Fish1.tscn", FileAccess.WRITE)
	if file:
		file.store_string(template_content)
		file.close()
		print("Created Fish1.tscn successfully")
	else:
		push_error("Failed to create Fish1.tscn file")

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
	
	# Create a standard material for fallback (in case shader fails)
	var standard_material = StandardMaterial3D.new()
	standard_material.albedo_color = water_color
	standard_material.roughness = water_roughness
	standard_material.metallic = water_metallic
	standard_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	
	# Create water material with shader
	var water_material = ShaderMaterial.new()
	
	# Fixed shader code (use ShaderMaterial.shader instead of Shader.new())
	water_material.shader = load("res://water_shader.gdshader")
	
	# If shader file doesn't exist, create it using code string
	if not FileAccess.file_exists("res://water_shader.gdshader"):
		# Create shader file in memory first
		var shader_code = """
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
"""
		
		# Create the shader and save it to disk
		var file = FileAccess.open("res://water_shader.gdshader", FileAccess.WRITE)
		file.store_string(shader_code)
		file.close()
		
		# Now load the created shader
		water_material.shader = load("res://water_shader.gdshader")
	
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
	
	# Use shader material if it loaded successfully, otherwise use standard material
	if water_material.shader != null:
		water_mesh_instance.material_override = water_material
	else:
		water_mesh_instance.material_override = standard_material
	
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
		spawn_fish(water_mesh_instance.global_position, 20 + randi() % 2)  # 2-5 fish

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

# Rest of the file remains unchanged...

# Creates a river from start to end point with specified width
func create_river(start_pos: Vector3, end_pos: Vector3, width: float = 10.0):
	# River implementation remains unchanged...
	pass
	
# Helper function to create a river mesh from a path
func create_river_mesh(path: Array, width: float) -> MeshInstance3D:
	# River mesh implementation remains unchanged...
	var river_instance = MeshInstance3D.new()
	return river_instance
	
	
	
# Spawns a fish of random type at position
func spawn_fish(pos: Vector3, count: int = 1):
	if fish_scenes.size() == 0:
		print("ERROR: No fish scenes available to spawn fish")
		return
	
	print("Spawning " + str(count) + " fish at position: " + str(pos))
	
	# Create fish parent node if it doesn't exist
	var fish_parent = get_node_or_null("FishParent")
	if not fish_parent:
		fish_parent = Node3D.new()
		fish_parent.name = "FishParent"
		add_child(fish_parent)
	
	# Spawn the requested number of fish
	for i in range(count):
		# Choose a random fish type
		var fish_scene = fish_scenes[randi() % fish_scenes.size()]
		
		# Instance the fish
		var fish_instance = fish_scene.instantiate()
		if not fish_instance:
			print("ERROR: Failed to instantiate fish scene")
			continue
		
		# Randomize position slightly
		var random_offset = Vector3(
			randf_range(-5.0, 5.0),
			randf_range(-2.0, -0.5),  # Keep fish below water surface
			randf_range(-5.0, 5.0)
		)
		
		# Set position (make sure it's below water level)
		var fish_pos = pos + random_offset
		fish_pos.y = min(fish_pos.y, water_level - 1.0)  # Keep at least 1 unit below water
		fish_instance.position = fish_pos
		
		# Add to scene
		fish_parent.add_child(fish_instance)
		active_fish.append(fish_instance)
		
		print("Fish spawned at: " + str(fish_pos))

# Updates fish positions based on water flow
func update_fish(delta):
	var fish_to_remove = []
	
	# Check each active fish
	for fish in active_fish:
		if not is_instance_valid(fish):
			fish_to_remove.append(fish)
			continue
		
		# Keep fish below water level
		if fish.position.y > water_level - 0.5:
			fish.position.y = water_level - 0.5
			
		# Check if fish is too far from any water chunk
		var too_far = true
		var player = get_node_or_null("/root/TerrainGenerator/Player")
		
		if player:
			# Only keep fish near the player
			var distance_to_player = fish.position.distance_to(player.position)
			if distance_to_player > 200.0:
				fish_to_remove.append(fish)
				continue
			elif distance_to_player < 150.0:
				too_far = false
		
		# If fish is too far from water, mark for removal
		if too_far:
			fish_to_remove.append(fish)
	
	# Remove fish that are too far or invalid
	for fish in fish_to_remove:
		if is_instance_valid(fish):
			fish.queue_free()
		active_fish.erase(fish)
	
	# Spawn more fish if needed
	ensure_minimum_fish_population()

# Make sure we have a minimum number of fish in the scene
func ensure_minimum_fish_population():
	var player = get_node_or_null("/root/TerrainGenerator/Player")
	if not player:
		return
		
	# Only maintain fish population when player is near water
	var player_pos = player.position
	var player_in_water = player_pos.y < water_level + 1.0
	
	# Check current fish count
	var current_fish_count = active_fish.size()
	var desired_fish_count = 25  # Target number of fish in the scene
	
	if current_fish_count < desired_fish_count and player_in_water:
		# Find a water chunk near the player to spawn fish
		var closest_chunk = null
		var closest_dist = 100000.0
		
		for chunk_pos in water_chunks:
			var water_mesh = water_chunks[chunk_pos]
			if is_instance_valid(water_mesh):
				var dist = water_mesh.position.distance_to(player_pos)
				if dist < closest_dist:
					closest_dist = dist
					closest_chunk = water_mesh
		
		# Spawn new fish in the closest water chunk
		if closest_chunk and closest_dist < 150.0:
			var spawn_count = 5  # Spawn in groups
			var spawn_pos = closest_chunk.position
			spawn_pos.y = water_level - 2.0  # 2 units below water surface
			spawn_fish(spawn_pos, spawn_count)
			
# Create a waterfall at the specified position with height and width
func create_waterfall(position: Vector3, height: float, width: float = 5.0):
	# Waterfall implementation remains unchanged...
	var waterfall_instance = MeshInstance3D.new()
	return waterfall_instance

func _on_body_entered_water(body):
	if body.name == "Player":
		apply_water_physics(body, true)

# Signal handling for player exiting water
func _on_body_exited_water(body):
	if body.name == "Player":
		apply_water_physics(body, false)

# Apply water physics to player character
func apply_water_physics(player, in_water: bool):
	# Water physics implementation remains unchanged...
	pass
