extends Node3D
class_name FishSystem

# Fish population settings
@export var max_fish_per_chunk: int = 8
@export var fish_spawn_chance: float = 0.8
@export var min_fish_depth: float = 0.5
@export var max_fish_depth: float = 10.0

# Fish behaviors
@export var fish_idle_speed: float = 0.8
@export var fish_flee_speed: float = 2.5
@export var fish_wander_radius: float = 5.0
@export var fish_update_interval: float = 0.2

# Spawn throttling
@export var max_spawns_per_frame: int = 4

# Refs / state
var water_system: Node = null
var fish_parent: Node3D
var active_fish: Array[CharacterBody3D] = []
var fish_chunks := {}                      # Dictionary[Vector2, Array]
var _pending_fish_spawns: Array[Dictionary] = []

# Timers
var update_timer: float = 0.0
var debug_fish_count_timer: float = 0.0

# DEBUG
var total_fish_created: int = 0

func _ready() -> void:
	# Find water system (parent)
	water_system = get_parent()
	if not water_system or not water_system.has_method("get_water_level"):
		push_error("FishSystem requires a parent water system with get_water_level()")
	
	# Create container
	fish_parent = Node3D.new()
	fish_parent.name = "FishParent"
	add_child(fish_parent)
	
	print("ImprovedFishSystem initialized")

func _process(delta: float) -> void:
	# Spawn queue
	if _pending_fish_spawns.size() > 0:
		process_pending_spawns()
	
	# Jump tick (rare)
	occasional_fish_jumps()
	
	# Behavior tick
	update_timer += delta
	if update_timer >= fish_update_interval:
		update_timer = 0.0
		update_fish_behaviors()
	
	# Debug counter
	debug_fish_count_timer += delta
	if debug_fish_count_timer >= 3.0:
		debug_fish_count_timer = 0.0
		print("Active fish: ", active_fish.size(), " Total created: ", total_fish_created)

# Spawn fish in a specific water chunk
func spawn_fish_in_chunk(chunk_pos: Vector2, _water_chunk_node: Node3D) -> int:
	# Already processed?
	if fish_chunks.has(chunk_pos):
		return 0
	
	var water_level: float = water_system.get_water_level()
	var chunk_size: float = water_system.get_chunk_size()
	var world_pos_x: float = chunk_pos.x * chunk_size
	var world_pos_z: float = chunk_pos.y * chunk_size
	
	# Random chance to skip
	if randf() > fish_spawn_chance:
		fish_chunks[chunk_pos] = []  # mark empty but processed
		return 0
	
	fish_chunks[chunk_pos] = []
	
	var num_fish: int = randi() % max_fish_per_chunk + 1
	var spawn_requests: Array[Dictionary] = []
	
	for i in range(num_fish):
		var spawn_x: float = randf_range(world_pos_x, world_pos_x + chunk_size)
		var spawn_z: float = randf_range(world_pos_z, world_pos_z + chunk_size)
		var spawn_y: float = water_level - randf_range(min_fish_depth, max_fish_depth)
		spawn_requests.append({
			"chunk_pos": chunk_pos,
			"position": Vector3(spawn_x, spawn_y, spawn_z)
		})
	
	if spawn_requests.size() > 0:
		_pending_fish_spawns.append_array(spawn_requests)
	
	return spawn_requests.size()

func process_pending_spawns() -> void:
	var spawned_this_frame: int = 0
	var spawn_limit: int = max(1, max_spawns_per_frame)
	
	while spawned_this_frame < spawn_limit and _pending_fish_spawns.size() > 0:
		var request: Dictionary = _pending_fish_spawns.pop_front()
		if request == null:
			continue
		
		var chunk_pos: Vector2 = request.get("chunk_pos", Vector2.ZERO)
		var position: Vector3 = request.get("position", Vector3.ZERO)
		
		var fish: CharacterBody3D = create_fish(position)
		if fish == null:
			continue
		
		fish_parent.add_child(fish)
		
		if fish_chunks.has(chunk_pos):
			fish_chunks[chunk_pos].append(fish)
		else:
			fish_chunks[chunk_pos] = [fish]
		
		active_fish.append(fish)
		total_fish_created += 1
		spawned_this_frame += 1
	
	if spawned_this_frame > 0:
		print("Spawned ", spawned_this_frame, " fish (deferred)")

# Create a fish instance
func create_fish(position: Vector3) -> CharacterBody3D:
	var fish: CharacterBody3D = CharacterBody3D.new()
	fish.name = "Fish"
	fish.position = position
	
	# Meta
	fish.set_meta("initial_position", position)
	fish.set_meta("speed", randf_range(0.8, 1.5))
	fish.set_meta("target_position", position)
	fish.set_meta("time_until_new_target", randf_range(3.0, 8.0))
	fish.set_meta("is_fleeing", false)
	fish.set_meta("is_jumping", false)
	fish.set_meta("jump_progress", 0.0)
	
	# Visuals
	var mesh_instance: MeshInstance3D = create_simple_fish_mesh()
	fish.add_child(mesh_instance)
	
	# Collision
	var collision: CollisionShape3D = CollisionShape3D.new()
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 0.2
	capsule.height = 0.6
	collision.shape = capsule
	collision.rotation_degrees.z = 90
	fish.add_child(collision)
	
	# Orientation
	fish.rotation.y = randf_range(0.0, TAU)
	
	return fish

# Simple colorful fish mesh
func create_simple_fish_mesh() -> MeshInstance3D:
	var fish_body: MeshInstance3D = MeshInstance3D.new()
	fish_body.name = "FishMesh"
	
	var body_mesh: PrismMesh = PrismMesh.new()
	body_mesh.size = Vector3(0.4, 0.15, 0.08)
	fish_body.mesh = body_mesh
	
	var material: StandardMaterial3D = StandardMaterial3D.new()
	var hue: float = randf_range(0.0, 1.0)
	var fish_color: Color = Color.from_hsv(hue, 0.8, 0.9)
	material.albedo_color = fish_color
	material.metallic = 0.7
	material.roughness = 0.2
	fish_body.material_override = material
	
	var tail_fin: MeshInstance3D = MeshInstance3D.new()
	tail_fin.name = "TailFin"
	var tail_mesh: PrismMesh = PrismMesh.new()
	tail_mesh.size = Vector3(0.2, 0.12, 0.04)
	tail_fin.mesh = tail_mesh
	tail_fin.position = Vector3(-0.3, 0, 0)
	tail_fin.material_override = material
	fish_body.add_child(tail_fin)
	
	fish_body.rotation_degrees.y = 90
	return fish_body

# Behavior update
func update_fish_behaviors() -> void:
	var player: Node3D = get_node_or_null("/root/TerrainGenerator/Player")
	var water_level: float = water_system.get_water_level()
	var ticks: int = Time.get_ticks_msec()
	var fish_to_remove: Array[CharacterBody3D] = []
	
	for fish in active_fish:
		if not is_instance_valid(fish):
			fish_to_remove.append(fish)
			continue
		
		# Jumping overrides normal swim
		if fish.get_meta("is_jumping"):
			continue_fish_jump(fish, fish_update_interval)
			continue
		
		var initial_position: Vector3 = fish.get_meta("initial_position")
		var speed: float = fish.get_meta("speed")
		var target_position: Vector3 = fish.get_meta("target_position")
		var time_until_new_target: float = fish.get_meta("time_until_new_target")
		var is_fleeing: bool = fish.get_meta("is_fleeing")
		
		time_until_new_target -= fish_update_interval
		
		# Player proximity → flee
		var player_too_close: bool = false
		if player and player.global_position.distance_to(fish.global_position) < 3.0:
			var flee_direction: Vector3 = (fish.global_position - player.global_position)
			flee_direction.y = 0.0
			flee_direction = flee_direction.normalized()
			target_position = fish.global_position + flee_direction * fish_wander_radius * 2.0
			player_too_close = true
			is_fleeing = true
		elif time_until_new_target <= 0.0 and not player_too_close:
			target_position = get_random_position_for_fish(fish)
			time_until_new_target = randf_range(3.0, 8.0)
			is_fleeing = false
		
		# Save meta back
		fish.set_meta("target_position", target_position)
		fish.set_meta("time_until_new_target", time_until_new_target)
		fish.set_meta("is_fleeing", is_fleeing)
		
		# Steering
		var direction: Vector3 = (target_position - fish.global_position).normalized()
		var target_angle: float = atan2(direction.x, direction.z)
		var current_angle: float = fish.rotation.y
		var angle_diff: float = fposmod(target_angle - current_angle + PI, TAU) - PI
		fish.rotation.y += angle_diff * 2.0 * fish_update_interval
		
		# Velocity
		var base_speed: float = fish_flee_speed if is_fleeing else fish_idle_speed
		var velocity: Vector3 = direction * base_speed * speed
		
		# Subtle vertical wobble
		velocity.y += sin(float(ticks) / 500.0) * 0.1
		
		# Water flow
		if water_system.has_method("get_flow_direction") and water_system.has_method("get_flow_strength"):
			var flow_direction: Vector3 = water_system.get_flow_direction()
			var flow_strength: float = water_system.get_flow_strength()
			velocity += flow_direction * flow_strength * 0.3
		
		# Collision-aware move
		var xf: Transform3D = fish.global_transform
		var will_collide: bool = fish.test_move(xf, velocity * fish_update_interval)
		if not will_collide:
			fish.position += velocity * fish_update_interval
		else:
			var reflection: Vector3 = velocity.bounce(Vector3.UP) # fallback normal
			fish.set_meta("target_position", fish.global_position + reflection.normalized() * 5.0)
		
		# Keep underwater
		if fish.position.y > water_level - 0.5:
			fish.position.y = water_level - 0.5
	
	# purge invalids AFTER the loop
	for dead in fish_to_remove:
		active_fish.erase(dead)

# Random swim target near initial position
func get_random_position_for_fish(fish: Node3D) -> Vector3:
	var initial_position: Vector3 = fish.get_meta("initial_position")
	var random_offset: Vector3 = Vector3(
		randf_range(-fish_wander_radius, fish_wander_radius),
		randf_range(-fish_wander_radius * 0.5, fish_wander_radius * 0.5),
		randf_range(-fish_wander_radius, fish_wander_radius)
	)
	var target: Vector3 = initial_position + random_offset
	
	if water_system.has_method("get_water_level"):
		var water_level: float = water_system.get_water_level()
		target.y = min(target.y, water_level - 0.5)
	
	return target

# Clear all fish in a specific chunk
func clear_fish_chunk(chunk_pos: Vector2) -> void:
	if not fish_chunks.has(chunk_pos):
		return
	
	var fish_list: Array = fish_chunks[chunk_pos]
	for fish in fish_list:
		if is_instance_valid(fish):
			active_fish.erase(fish)
			fish.queue_free()
	
	fish_chunks.erase(chunk_pos)
	
	# Remove pending spawns for this chunk
	for i in range(_pending_fish_spawns.size() - 1, -1, -1):
		var request: Dictionary = _pending_fish_spawns[i]
		if request.get("chunk_pos", Vector2.ZERO) == chunk_pos:
			_pending_fish_spawns.remove_at(i)

# ————— Jumping fish —————

func make_fish_jump() -> void:
	var candidates: Array[CharacterBody3D] = []
	var water_level: float = water_system.get_water_level()
	for fish in active_fish:
		if is_instance_valid(fish) and fish.position.y > water_level - 2.0 and not fish.get_meta("is_jumping"):
			candidates.append(fish)
	if candidates.size() > 0:
		var fish: CharacterBody3D = candidates[randi() % candidates.size()]
		start_fish_jump(fish)

func start_fish_jump(fish: Node3D) -> void:
	if fish.has_meta("is_jumping") and fish.get_meta("is_jumping"):
		return
	
	fish.set_meta("is_jumping", true)
	fish.set_meta("jump_progress", 0.0)
	
	var water_level: float = water_system.get_water_level()
	fish.set_meta("jump_start", fish.global_position)
	
	var jump_direction: Vector3 = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
	var jump_distance: float = randf_range(1.0, 3.0)
	var jump_height: float = randf_range(1.0, 3.0)
	var jump_duration: float = randf_range(0.8, 1.5)
	
	var jump_end: Vector3 = fish.global_position + jump_direction * jump_distance
	jump_end.y = water_level - randf_range(0.5, 1.5)
	
	fish.set_meta("jump_end", jump_end)
	fish.set_meta("jump_height", jump_height)
	fish.set_meta("jump_duration", jump_duration)
	
	if water_system.has_method("create_splash_effect"):
		var splash_pos: Vector3 = fish.global_position
		splash_pos.y = water_level
		water_system.create_splash_effect(splash_pos, 0.5)

func continue_fish_jump(fish: Node3D, delta: float) -> void:
	var jump_start: Vector3 = fish.get_meta("jump_start")
	var jump_end: Vector3 = fish.get_meta("jump_end")
	var jump_height: float = fish.get_meta("jump_height")
	var jump_duration: float = fish.get_meta("jump_duration")
	var jump_progress: float = fish.get_meta("jump_progress")
	
	jump_progress += delta / jump_duration
	
	if jump_progress >= 1.0:
		fish.set_meta("is_jumping", false)
		fish.global_position = jump_end
		if water_system.has_method("create_splash_effect"):
			var water_level: float = water_system.get_water_level()
			var splash_pos: Vector3 = fish.global_position
			splash_pos.y = water_level
			water_system.create_splash_effect(splash_pos, 0.5)
		return
	
	var t: float = jump_progress
	var horizontal_pos: Vector3 = jump_start.lerp(jump_end, t)
	var vertical_offset: float = jump_height * 4.0 * t * (1.0 - t)
	var water_level: float = water_system.get_water_level()
	var new_pos: Vector3 = horizontal_pos
	new_pos.y = water_level + vertical_offset
	fish.global_position = new_pos
	
	fish.set_meta("jump_progress", jump_progress)

func occasional_fish_jumps() -> void:
	# ~1% chance per frame to trigger
	if randf() < 0.01:
		make_fish_jump()
