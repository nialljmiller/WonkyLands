extends Node3D

class_name FishSystem

# Fish population settings
@export var max_fish_per_chunk: int = 8
@export var fish_spawn_chance: float = 0.8  # Higher chance to make sure fish spawn
@export var min_fish_depth: float = 0.5  # Min depth below water
@export var max_fish_depth: float = 10.0  # Max depth below water

# Fish behaviors
@export var fish_idle_speed: float = 0.8  # Speed when idling
@export var fish_flee_speed: float = 2.5  # Speed when fleeing
@export var fish_wander_radius: float = 5.0  # How far fish can wander from spawn point
@export var fish_update_interval: float = 0.2  # How often to update fish behaviors

# References
var water_system = null  # Reference to parent water system
var active_fish = []  # Active fish in the world
var fish_chunks = {}  # Tracks which chunks have fish

# Timer for fish updates
var update_timer: float = 0.0
var fish_parent: Node3D

# DEBUG - used to count fish instances
var total_fish_created = 0
var debug_fish_count_timer = 0.0

func _ready():
	# Find water system (parent)
	water_system = get_parent()
	if not water_system or not water_system.has_method("get_water_level"):
		push_error("FishSystem requires a parent water system with get_water_level method")
	
	# Create a parent node for all fish
	fish_parent = Node3D.new()
	fish_parent.name = "FishParent"
	add_child(fish_parent)
	
	# Debug message
	print("ImprovedFishSystem initialized")

func _process(delta):
	# Update timer for fish behaviors
	update_timer += delta
	if update_timer >= fish_update_interval:
		update_timer = 0.0
		update_fish_behaviors()
	
	# Debug fish count
	debug_fish_count_timer += delta
	if debug_fish_count_timer >= 3.0:
		debug_fish_count_timer = 0.0
		print("Active fish: ", active_fish.size(), " Total created: ", total_fish_created)

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
	
	# Only spawn fish with random chance
	if randf() > fish_spawn_chance:
		fish_chunks[chunk_pos] = []  # Mark as processed but empty
		return 0
	
	# Track fish in this chunk
	fish_chunks[chunk_pos] = []
	
	# Determine how many fish to spawn (reduced to avoid overwhelming)
	var num_fish = randi() % max_fish_per_chunk + 1
	var total_fish_spawned = 0
	
	# Spawn individual fish
	for i in range(num_fish):
		# Choose a spawn position within the chunk
		var spawn_x = randf_range(world_pos_x, world_pos_x + chunk_size)
		var spawn_z = randf_range(world_pos_z, world_pos_z + chunk_size)
		
		# Set depth below water level
		var spawn_y = water_level - randf_range(min_fish_depth, max_fish_depth)
		
		# Create fish
		var fish = create_fish(Vector3(spawn_x, spawn_y, spawn_z))
		if fish != null:
			fish_parent.add_child(fish)
			fish_chunks[chunk_pos].append(fish)
			active_fish.append(fish)
			total_fish_spawned += 1
			total_fish_created += 1
	
	print("Spawned ", total_fish_spawned, " fish in chunk ", chunk_pos)
	return total_fish_spawned

# Create a fish with all components
func create_fish(position: Vector3) -> Node3D:
	# Create base fish node
	var fish = CharacterBody3D.new()
	fish.name = "Fish"
	fish.position = position
	
	# Store initial position and fish type
	fish.set_meta("initial_position", position)
	fish.set_meta("speed", randf_range(0.8, 1.5))
	fish.set_meta("target_position", position)
	fish.set_meta("time_until_new_target", randf_range(3.0, 8.0))
	fish.set_meta("is_fleeing", false)
	
	# Create a simple fish mesh
	var mesh_instance = create_simple_fish_mesh()
	fish.add_child(mesh_instance)
	
	# Add collision shape
	var collision = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = 0.2
	capsule.height = 0.6
	collision.shape = capsule
	collision.rotation_degrees.z = 90  # Orient along fish forward direction
	fish.add_child(collision)
	
	# Randomize initial rotation
	fish.rotation.y = randf_range(0, TAU)
	
	return fish

# Create a simple colorful fish mesh
func create_simple_fish_mesh() -> MeshInstance3D:
	var fish_body = MeshInstance3D.new()
	fish_body.name = "FishMesh"
	
	# Create body
	var body_mesh = PrismMesh.new()
	body_mesh.size = Vector3(0.4, 0.15, 0.08)
	fish_body.mesh = body_mesh
	
	# Create material with random colorful fish
	var material = StandardMaterial3D.new()
	
	# Generate a bright, saturated color
	var hue = randf_range(0.0, 1.0)
	var fish_color = Color.from_hsv(hue, 0.8, 0.9)
	
	material.albedo_color = fish_color
	material.metallic = 0.7
	material.roughness = 0.2
	fish_body.material_override = material
	
	# Add tail fin
	var tail_fin = MeshInstance3D.new()
	tail_fin.name = "TailFin"
	
	var tail_mesh = PrismMesh.new()
	tail_mesh.size = Vector3(0.2, 0.12, 0.04)
	tail_fin.mesh = tail_mesh
	
	# Position tail behind body
	tail_fin.position = Vector3(-0.3, 0, 0)
	tail_fin.material_override = material
	
	# Add to fish body
	fish_body.add_child(tail_fin)
	
	# Rotate to face forward direction
	fish_body.rotation_degrees.y = 90
	
	return fish_body

# Update behaviors for all active fish
func update_fish_behaviors():
	var fish_to_remove = []
	
	for fish in active_fish:
		if not is_instance_valid(fish):
			fish_to_remove.append(fish)
			continue
		
		# Get fish metadata
		var initial_position = fish.get_meta("initial_position")
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
		velocity.y += sin(Time.get_ticks_msec() / 500.0) * 0.1
		
		# Apply water flow if applicable
		if water_system.has_method("get_flow_direction") and water_system.has_method("get_flow_strength"):
			var flow_direction = water_system.get_flow_direction()
			var flow_strength = water_system.get_flow_strength()
			velocity += flow_direction * flow_strength * 0.3  # Fish partially resist flow
		
		# Set fish velocity
		fish.velocity = velocity
		
		# Move the fish
		# First check for walls or obstacles
		var collision = fish.move_and_collide(velocity * fish_update_interval, true)
		if collision:
			# If we would hit something, change direction
			var reflection = velocity.bounce(collision.get_normal())
			fish.velocity = reflection
			fish.set_meta("target_position", fish.global_position + reflection.normalized() * 5.0)
		else:
			# No collision, proceed with movement
			fish.position += velocity * fish_update_interval
		
		# Make sure fish stay underwater
		var water_level = water_system.get_water_level()
		if fish.position.y > water_level - 0.5:
			fish.position.y = water_level - 0.5
	
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

# Add random jumping fish behavior
func make_fish_jump():
	# Find a random fish near the surface to make jump
	var candidates = []
	var water_level = water_system.get_water_level()
	
	for fish in active_fish:
		if is_instance_valid(fish) and fish.position.y > water_level - 2.0:
			candidates.append(fish)
	
	if candidates.size() > 0:
		var fish = candidates[randi() % candidates.size()]
		start_fish_jump(fish)

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

# Continue a jumping animation during updates
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
	
	# Update progress meta
	fish.set_meta("jump_progress", jump_progress)

# Trigger some jumping fish every now and then
func occasional_fish_jumps():
	# 1% chance per update to make a fish jump
	if randf() < 0.01:
		make_fish_jump()
