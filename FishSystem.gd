extends Node3D

class_name FishSystem

# Fish population settings
@export var max_fish_per_chunk: int = 15
@export var fish_spawn_chance: float = 0.3
@export var min_fish_depth: float = 0.5  # Min depth below water
@export var max_fish_depth: float = 10.0  # Max depth below water
@export var min_fish_per_school: int = 3  # Minimum fish in a school
@export var max_fish_per_school: int = 7  # Maximum fish in a school

# Fish behaviors
@export var fish_idle_speed: float = 0.5  # Speed when idling
@export var fish_flee_speed: float = 2.0  # Speed when fleeing
@export var fish_wander_radius: float = 5.0  # How far fish can wander from spawn point
@export var fish_update_interval: float = 0.5  # How often to update fish behaviors

# References
var water_system = null  # Reference to parent water system
var terrain_generator = null  # Reference to terrain generator
var active_fish = []  # Active fish in the world
var fish_chunks = {}  # Tracks which chunks have fish
var fish_types = {}  # Different types of fish

# Basic fish configurations
var fish_configs = {
	"default": {
		"color": Color(0.3, 0.6, 0.9),
		"size": Vector3(0.4, 0.15, 0.08),
		"speed": 1.0,
		"depth_range": [0.5, 5.0],
		"biomes": ["TEMPERATE_FOREST", "SNOWY_MOUNTAINS"],
		"schooling": true,
		"school_size": [3, 8],
		"has_special_behavior": false
	},
	"tropical": {
		"color": Color(0.9, 0.5, 0.1),
		"size": Vector3(0.3, 0.12, 0.06),
		"speed": 1.2,
		"depth_range": [0.5, 3.0],
		"biomes": ["TROPICAL_JUNGLE"],
		"schooling": true,
		"school_size": [5, 12],
		"has_special_behavior": false
	},
	"deep": {
		"color": Color(0.1, 0.2, 0.4),
		"size": Vector3(0.6, 0.2, 0.1),
		"speed": 0.7,
		"depth_range": [5.0, 10.0],
		"biomes": ["TEMPERATE_FOREST", "TROPICAL_JUNGLE"],
		"schooling": false,
		"school_size": [1, 2],
		"has_special_behavior": false
	},
	"jumping": {
		"color": Color(0.7, 0.9, 0.3),
		"size": Vector3(0.45, 0.2, 0.1),
		"speed": 1.5,
		"depth_range": [0.2, 2.0],
		"biomes": ["TEMPERATE_FOREST", "TROPICAL_JUNGLE"],
		"schooling": false,
		"school_size": [1, 3],
		"has_special_behavior": true,
		"jump_interval": [5.0, 20.0],
		"jump_height": 3.0
	}
}

# Timer for fish updates
var update_timer: float = 0.0

func _ready():
	# Find water system (parent)
	water_system = get_parent()
	if not water_system or not water_system.has_method("get_water_level"):
		push_error("FishSystem requires a parent water system with get_water_level method")
	
	# Find terrain generator
	terrain_generator = get_node_or_null("/root/TerrainGenerator")
	
	# Create fish mesh resources
	create_fish_meshes()
	
	# Debug message
	print("FishSystem initialized with " + str(fish_types.size()) + " fish types")

func _process(delta):
	# Update timer for fish behaviors
	update_timer += delta
	if update_timer >= fish_update_interval:
		update_timer = 0.0
		update_fish_behaviors()
	
	# Check for player interactions with fish
	check_player_interactions()

func create_fish_meshes():
	# Create basic fish mesh
	var basic_fish = create_basic_fish_mesh()
	fish_types["default"] = basic_fish
	
	# Create tropical fish - more colorful variation
	var tropical_fish = create_basic_fish_mesh()
	var tropical_material = StandardMaterial3D.new()
	tropical_material.albedo_color = Color(0.9, 0.5, 0.1)
	tropical_material.roughness = 0.2
	tropical_material.metallic = 0.8
	tropical_fish.material_override = tropical_material
	fish_types["tropical"] = tropical_fish
	
	# Create deep water fish - darker, larger
	var deep_fish = create_basic_fish_mesh(1.5)  # Larger scale
	var deep_material = StandardMaterial3D.new()
	deep_material.albedo_color = Color(0.1, 0.2, 0.4)
	deep_material.roughness = 0.3
	deep_material.metallic = 0.5
	deep_material.emission_enabled = true
	deep_material.emission = Color(0.2, 0.4, 0.8)
	deep_material.emission_energy = 0.5
	deep_fish.material_override = deep_material
	fish_types["deep"] = deep_fish
	
	# Create jumping fish
	var jumping_fish = create_basic_fish_mesh()
	var jumping_material = StandardMaterial3D.new()
	jumping_material.albedo_color = Color(0.7, 0.9, 0.3)
	jumping_fish.material_override = jumping_material
	fish_types["jumping"] = jumping_fish

# Create a basic fish mesh that all fish can use
func create_basic_fish_mesh(scale_factor: float = 1.0) -> MeshInstance3D:
	var fish_body = MeshInstance3D.new()
	fish_body.name = "FishBody"
	
	# Create fish body (tapered shape)
	var fish_mesh = PrismMesh.new()
	fish_mesh.size = Vector3(0.4, 0.15, 0.08) * scale_factor
	fish_body.mesh = fish_mesh
	
	# Create default material
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.3, 0.6, 0.9)
	material.metallic = 0.7
	material.roughness = 0.2
	fish_body.material_override = material
	
	# Add tail fin
	var tail_fin = MeshInstance3D.new()
	tail_fin.name = "TailFin"
	
	var tail_mesh = PrismMesh.new()
	tail_mesh.size = Vector3(0.2, 0.12, 0.04) * scale_factor
	tail_fin.mesh = tail_mesh
	
	# Position tail
	tail_fin.position = Vector3(-0.3, 0, 0) * scale_factor
	tail_fin.material_override = material
	
	# Add to fish body
	fish_body.add_child(tail_fin)
	
	# Rotate to face forward direction
	fish_body.rotation_degrees.y = 90
	
	return fish_body

# Spawn fish in a specific water chunk
func spawn_fish_in_chunk(chunk_pos: Vector2, water_chunk_node: Node3D) -> int:
	# Skip if we already spawned fish in this chunk
	if fish_chunks.has(chunk_pos):
		return 0
	
	# Get water level
	var water_level = water_system.get_water_level()
	
	# Get chunk world position
	var chunk_size = water_system.get_chunk_size()
	var world_pos_x = chunk_pos.x * chunk_size
	var world_pos_z = chunk_pos.y * chunk_size
	
	# Determine biome at this position
	var biome_name = "TEMPERATE_FOREST"  # Default
	if terrain_generator and terrain_generator.has_method("determine_biome"):
		var biome_pos = Vector2(world_pos_x + chunk_size/2, world_pos_z + chunk_size/2)
		var biome_type = terrain_generator.determine_biome(biome_pos)
		if terrain_generator.has_method("biome_type_to_string"):
			biome_name = terrain_generator.biome_type_to_string(biome_type)
	
	# Only spawn fish with random chance
	if randf() > fish_spawn_chance:
		fish_chunks[chunk_pos] = []  # Mark as processed but empty
		return 0
	
	# Create a parent node for fish in this chunk
	var fish_parent = Node3D.new()
	fish_parent.name = "Fish_Chunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	water_chunk_node.add_child(fish_parent)
	
	# Track fish in this chunk
	fish_chunks[chunk_pos] = []
	
	# Determine how many schools of fish to spawn
	var num_schools = randi() % 3 + 1  # 1-3 schools per chunk
	var total_fish_spawned = 0
	
	# Spawn schools of fish
	for school_idx in range(num_schools):
		# Pick a fish type appropriate for this biome
		var valid_fish_types = []
		for fish_type in fish_configs.keys():
			var config = fish_configs[fish_type]
			if biome_name in config["biomes"]:
				valid_fish_types.append(fish_type)
		
		# If no valid fish for this biome, use default
		if valid_fish_types.size() == 0:
			valid_fish_types = ["default"]
		
		var fish_type = valid_fish_types[randi() % valid_fish_types.size()]
		var config = fish_configs[fish_type]
		
		# Choose a school size
		var school_size = randi() % (config["school_size"][1] - config["school_size"][0] + 1) + config["school_size"][0]
		school_size = min(school_size, max_fish_per_chunk - total_fish_spawned)
		
		if school_size <= 0:
			continue
		
		# Choose a spawn position within the chunk
		var spawn_x = randf_range(0, chunk_size) + world_pos_x
		var spawn_z = randf_range(0, chunk_size) + world_pos_z
		
		# Determine water depth at this position
		var spawn_y = water_level - randf_range(config["depth_range"][0], config["depth_range"][1])
		
		# Create the school
		for i in range(school_size):
			# Calculate offset from school center
			var offset_x = randf_range(-2.0, 2.0)
			var offset_y = randf_range(-0.5, 0.5)
			var offset_z = randf_range(-2.0, 2.0)
			
			# Create fish
			var fish = create_fish(fish_type, Vector3(spawn_x + offset_x, spawn_y + offset_y, spawn_z + offset_z))
			if fish != null:
				fish_parent.add_child(fish)
				fish_chunks[chunk_pos].append(fish)
				active_fish.append(fish)
				total_fish_spawned += 1
	
	return total_fish_spawned

# Create a fish with all components
func create_fish(fish_type: String, position: Vector3) -> Node3D:
	if not fish_types.has(fish_type):
		push_error("Unknown fish type: " + fish_type)
		return null
	
	# Create base fish node
	var fish = CharacterBody3D.new()
	fish.name = "Fish_" + fish_type
	fish.position = position
	
	# Store initial position and fish type
	fish.set_meta("initial_position", position)
	fish.set_meta("fish_type", fish_type)
	fish.set_meta("config", fish_configs[fish_type])
	
	# Add mesh instance
	var mesh_instance = fish_types[fish_type].duplicate()
	fish.add_child(mesh_instance)
	
	# Add collision shape
	var collision = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = 0.2
	capsule.height = 0.6
	collision.shape = capsule
	collision.rotation_degrees.z = 90  # Orient along fish forward direction
	fish.add_child(collision)
	
	# Set up movement variables
	fish.set_meta("speed", fish_configs[fish_type]["speed"])
	fish.set_meta("target_position", position)
	fish.set_meta("time_until_new_target", randf_range(3.0, 8.0))
	fish.set_meta("is_fleeing", false)
	
	# Special behavior for jumping fish
	if fish_configs[fish_type]["has_special_behavior"]:
		if fish_type == "jumping":
			fish.set_meta("jump_timer", randf_range(10.0, 30.0))
	
	return fish

# Update behaviors for all active fish
func update_fish_behaviors():
	var fish_to_remove = []
	
	for fish in active_fish:
		if not is_instance_valid(fish):
			fish_to_remove.append(fish)
			continue
		
		# Get fish metadata
		var initial_position = fish.get_meta("initial_position")
		var fish_type = fish.get_meta("fish_type")
		var config = fish.get_meta("config")
		var speed = fish.get_meta("speed")
		var target_position = fish.get_meta("target_position")
		var time_until_new_target = fish.get_meta("time_until_new_target")
		var is_fleeing = fish.get_meta("is_fleeing")
		
		# Reduce timer for changing target
		time_until_new_target -= fish_update_interval
		
		# Check if player is nearby to flee
		var player = get_node_or_null("/root/TerrainGenerator/Player")
		var player_too_close = false
		
		if player and player.global_position.distance_to(fish.global_position) < 3.0:
			# Flee from player
			var flee_direction = fish.global_position - player.global_position
			flee_direction.y = 0  # Keep at same depth
			flee_direction = flee_direction.normalized()
			
			target_position = fish.global_position + flee_direction * fish_wander_radius * 2
			player_too_close = true
			is_fleeing = true
		elif time_until_new_target <= 0 and !player_too_close:
			# Time to choose a new target
			target_position = get_random_position_for_fish(fish)
			time_until_new_target = randf_range(3.0, 8.0)
			is_fleeing = false
		
		# Update fish metadata
		fish.set_meta("target_position", target_position)
		fish.set_meta("time_until_new_target", time_until_new_target)
		fish.set_meta("is_fleeing", is_fleeing)
		
		# Calculate direction to target
		var direction = (target_position - fish.global_position).normalized()
		
		# Calculate target rotation (fish looks in movement direction)
		var target_angle = atan2(direction.x, direction.z)
		
		# Smoothly interpolate current rotation to target rotation
		var current_angle = fish.rotation.y
		var angle_diff = fposmod(target_angle - current_angle + PI, TAU) - PI
		fish.rotation.y += angle_diff * 2.0 * fish_update_interval
		
		# Move fish towards target
		var current_speed = fish_flee_speed if is_fleeing else fish_idle_speed
		var velocity = direction * current_speed * speed
		
		# Apply small vertical wobble for natural movement
		velocity.y += sin(Time.get_ticks_msec() / 500.0) * 0.2
		
		# Apply water flow if applicable
		if water_system.has_method("get_flow_direction") and water_system.has_method("get_flow_strength"):
			var flow_direction = water_system.get_flow_direction()
			var flow_strength = water_system.get_flow_strength()
			velocity += flow_direction * flow_strength * 0.3  # Fish partially resist flow
		
		# Set fish velocity
		fish.velocity = velocity
		fish.move_and_slide()
		
		# Process special behaviors
		if config["has_special_behavior"]:
			process_special_behavior(fish, fish_type)
	
	# Remove fish that are no longer valid
	for fish in fish_to_remove:
		active_fish.erase(fish)

# Generate a random position for a fish to swim to
func get_random_position_for_fish(fish: Node3D) -> Vector3:
	var initial_position = fish.get_meta("initial_position")
	
	# Generate a random position within wander radius
	var random_offset = Vector3(
		randf_range(-fish_wander_radius, fish_wander_radius),
		randf_range(-fish_wander_radius/2, fish_wander_radius/2),
		randf_range(-fish_wander_radius, fish_wander_radius)
	)
	
	var target = initial_position + random_offset
	
	# Make sure target is below water level
	if water_system.has_method("get_water_level"):
		var water_level = water_system.get_water_level()
		target.y = min(target.y, water_level - 0.5)  # Keep at least 0.5 units below water
	
	return target

# Process special behaviors for special fish types
func process_special_behavior(fish: Node3D, fish_type: String):
	# Jumping fish special behavior
	if fish_type == "jumping":
		var jump_timer = 0.0
		if fish.has_meta("jump_timer"):
			jump_timer = fish.get_meta("jump_timer")
		
		jump_timer -= fish_update_interval
		
		# Time to jump?
		if jump_timer <= 0:
			# Only jump if close to surface
			if water_system.has_method("get_water_level"):
				var water_level = water_system.get_water_level()
				if fish.global_position.y > water_level - 2.0:
					start_fish_jump(fish)
				
			# Reset timer for next jump
			var config = fish.get_meta("config")
			jump_timer = randf_range(config["jump_interval"][0], config["jump_interval"][1])
		
		# Update timer meta
		fish.set_meta("jump_timer", jump_timer)

# Start a jumping animation for a fish
func start_fish_jump(fish: Node3D):
	# Only start jump if not already jumping
	if fish.has_meta("is_jumping") and fish.get_meta("is_jumping"):
		return
	
	# Set jumping state
	fish.set_meta("is_jumping", true)
	fish.set_meta("jump_progress", 0.0)
	
	# Get water level
	var water_level = water_system.get_water_level()
	
	# Store jump start position
	fish.set_meta("jump_start", fish.global_position)
	
	# Calculate random jump arc
	var jump_direction = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
	var jump_distance = randf_range(1.0, 3.0)
	var jump_height = randf_range(1.0, 3.0)
	var jump_duration = randf_range(0.8, 1.5)
	
	# Calculate jump end position (back under water)
	var jump_end = fish.global_position + jump_direction * jump_distance
	jump_end.y = water_level - randf_range(0.5, 1.5)  # End below water
	
	# Store jump parameters
	fish.set_meta("jump_end", jump_end)
	fish.set_meta("jump_height", jump_height)
	fish.set_meta("jump_duration", jump_duration)
	
	# Create splash effect at jump start
	if water_system.has_method("create_splash_effect"):
		var splash_pos = fish.global_position
		splash_pos.y = water_level
		water_system.create_splash_effect(splash_pos, 0.5)

# Continue a jumping animation
func continue_fish_jump(fish: Node3D, delta: float):
	# Get jump parameters
	var jump_start = fish.get_meta("jump_start")
	var jump_end = fish.get_meta("jump_end")
	var jump_height = fish.get_meta("jump_height")
	var jump_duration = fish.get_meta("jump_duration")
	var jump_progress = fish.get_meta("jump_progress")
	
	# Update progress
	jump_progress += delta / jump_duration
	
	# Jump completed?
	if jump_progress >= 1.0:
		# End jump
		fish.set_meta("is_jumping", false)
		fish.global_position = jump_end
		
		# Create splash when landing
		if water_system.has_method("create_splash_effect"):
			var water_level = water_system.get_water_level()
			var splash_pos = fish.global_position
			splash_pos.y = water_level
			water_system.create_splash_effect(splash_pos, 0.5)
			
		return
	
	# Calculate position along jump arc
	var t = jump_progress
	
	# Horizontal movement (linear)
	var horizontal_pos = jump_start.lerp(jump_end, t)
	
	# Vertical movement (parabolic)
	var vertical_offset = jump_height * 4.0 * t * (1.0 - t)  # Parabola with max at t=0.5
	
	# Apply position
	var water_level = water_system.get_water_level()
	var new_pos = horizontal_pos
	new_pos.y = water_level + vertical_offset  # Jump above water
	fish.global_position = new_pos
	
	# Update rotation to follow jump arc
	var dir_up = Vector3(0, 1, 0)
	var dir_forward = (jump_end - jump_start).normalized()
	
	# Calculate angle based on arc position
	var arc_angle = (0.5 - abs(t - 0.5)) * 2.0 * PI/4  # Max angle at apex
	
	# Apply rotations
	fish.look_at(fish.global_position + dir_forward)
	fish.rotate_object_local(Vector3(1, 0, 0), arc_angle)
	
	# Update progress meta
	fish.set_meta("jump_progress", jump_progress)

# Check for player interactions with fish
func check_player_interactions():
	# Get player
	var player = get_node_or_null("/root/TerrainGenerator/Player")
	if not player:
		return
	
	# Check proximity with active fish
	for fish in active_fish:
		if not is_instance_valid(fish):
			continue
			
		# Update jumping fish
		if fish.has_meta("is_jumping") and fish.get_meta("is_jumping"):
			continue_fish_jump(fish, fish_update_interval)
			continue
			
		# If player is too close, make fish flee
		var distance = player.global_position.distance_to(fish.global_position)
		if distance < 3.0:
			fish.set_meta("is_fleeing", true)
			fish.set_meta("time_until_new_target", 0.0)  # Force new target

# Clear all fish in a specific chunk
func clear_fish_chunk(chunk_pos: Vector2):
	if not fish_chunks.has(chunk_pos):
		return
	
	# Get all fish in this chunk
	var fish_list = fish_chunks[chunk_pos]
	
	# Remove fish from active list and free them
	for fish in fish_list:
		if is_instance_valid(fish):
			active_fish.erase(fish)
			fish.queue_free()
	
	# Clear chunk from tracking
	fish_chunks.erase(chunk_pos)

# Get the water level
func get_water_level() -> float:
	if water_system and water_system.has_method("get_water_level"):
		return water_system.get_water_level()
	return 0.0

# Get the chunk size
func get_chunk_size() -> float:
	if water_system and water_system.has_method("get_chunk_size"):
		return water_system.get_chunk_size()
	return 128.0
