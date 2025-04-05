extends CharacterBody3D

class_name Fish

# Fish properties
@export var swim_speed: float = 1.5
@export var turn_speed: float = 2.0
@export var wander_radius: float = 5.0
@export var flee_distance: float = 3.0
@export var school_distance: float = 2.0

# Fish appearance
@export var fish_color: Color = Color(0.3, 0.5, 0.9)
@export var fish_size: Vector3 = Vector3(0.5, 0.2, 0.1)

# Movement
var initial_position: Vector3
var target_position: Vector3
var target_rotation: float
var time_until_new_target: float = 0

# References
var water_system
var nearby_fish = []

func _ready():
	# Save initial spawn position as center of territory
	initial_position = global_position
	
	# Set initial target
	target_position = get_random_target()
	
	# Create fish mesh
	create_fish_mesh()
	
	# Add collision shape
	var collision = CollisionShape3D.new()
	var shape = CapsuleShape3D.new()
	shape.radius = fish_size.x / 4
	shape.height = fish_size.x
	collision.shape = shape
	collision.rotation_degrees.z = 90  # Orient capsule along fish forward axis
	add_child(collision)
	
	# Add detection area for player and other fish
	var detection_area = Area3D.new()
	detection_area.name = "DetectionArea"
	
	var detection_shape = CollisionShape3D.new()
	var sphere_shape = SphereShape3D.new()
	sphere_shape.radius = flee_distance
	detection_shape.shape = sphere_shape
	
	detection_area.add_child(detection_shape)
	add_child(detection_area)
	
	# Connect signals
	detection_area.body_entered.connect(_on_body_entered_detection)
	detection_area.body_exited.connect(_on_body_exited_detection)
	
	# Find water system node
	water_system = get_node_or_null("/root/TerrainGenerator/WaterSystem")

	# Find water system node (improved method that tries multiple paths)
	water_system = get_node_or_null("/root/TerrainGenerator/WaterSystem")
	
	if not water_system:
		# Try alternative paths
		var terrain_gen = get_node_or_null("/root/TerrainGenerator")
		if terrain_gen:
			water_system = terrain_gen.get_node_or_null("WaterSystem")
		
		if not water_system:
			# Search the entire scene tree
			water_system = find_water_system_in_tree(get_tree().root)
			
	if not water_system:
		print("WARNING: Fish could not find WaterSystem node")


# Recursively search for WaterSystem in the scene tree
func find_water_system_in_tree(node):
	if node.name == "WaterSystem":
		return node
		
	for child in node.get_children():
		var result = find_water_system_in_tree(child)
		if result:
			return result
			
	return null








func _physics_process(delta):
	# Reduce timer for changing target
	time_until_new_target -= delta
	
	# Check if player is nearby to flee
	var player = get_node_or_null("/root/TerrainGenerator/Player")
	var player_too_close = false
	
	if player and player.global_position.distance_to(global_position) < flee_distance:
		# Flee from player
		var flee_direction = global_position - player.global_position
		flee_direction.y = 0  # Keep at same depth
		flee_direction = flee_direction.normalized()
		
		target_position = global_position + flee_direction * wander_radius * 2
		player_too_close = true
	elif time_until_new_target <= 0 and !player_too_close:
		# Time to choose a new target
		target_position = get_random_target()
		time_until_new_target = randf_range(3.0, 8.0)
	
	# Adjust for schooling behavior if there are nearby fish
	apply_schooling_behavior()
	
	# Calculate direction to target
	var direction = (target_position - global_position).normalized()
	
	# Calculate target rotation (fish looks in movement direction)
	var target_angle = atan2(direction.x, direction.z)
	
	# Smoothly interpolate current rotation to target rotation
	var current_angle = rotation.y
	var angle_diff = fposmod(target_angle - current_angle + PI, TAU) - PI
	rotation.y += angle_diff * turn_speed * delta
	
	# Move fish towards target
	velocity = direction * swim_speed
	
	# Apply small vertical wobble for natural movement
	velocity.y += sin(Time.get_ticks_msec() / 500.0) * 0.2
	
	# Apply water flow if in water system
	if water_system:
		var flow_direction = water_system.flow_direction
		var flow_strength = water_system.flow_strength
		
		# Apply river flow if in river
		for river in water_system.rivers:
			if river.get_node("RiverBody").overlaps_body(self):
				var river_material = river.material_override
				if river_material:
					flow_direction = river_material.get_shader_parameter("flow_direction")
					flow_strength = river_material.get_shader_parameter("flow_strength") * 0.5  # Fish resist flow partially
				break
		
		velocity += flow_direction * flow_strength * 0.3  # Fish partially resist water flow
	
	# Move the fish
	move_and_slide()

func create_fish_mesh():
	# Create basic fish shape using primitives
	var fish_body = MeshInstance3D.new()
	fish_body.name = "FishBody"
	
	# Create fish body (flattened cube)
	var body_mesh = PrismMesh.new()
	body_mesh.size = fish_size
	fish_body.mesh = body_mesh
	
	# Create material for fish
	var fish_material = StandardMaterial3D.new()
	fish_material.albedo_color = fish_color
	fish_material.metallic = 0.7
	fish_material.roughness = 0.2
	
	fish_body.material_override = fish_material
	
	# Add tail fin
	var tail_fin = MeshInstance3D.new()
	tail_fin.name = "TailFin"
	
	var tail_mesh = PrismMesh.new()
	tail_mesh.size = Vector3(fish_size.x * 0.5, fish_size.y * 0.8, fish_size.z * 0.5)
	tail_fin.mesh = tail_mesh
	
	# Position tail
	tail_fin.position = Vector3(-fish_size.x * 0.7, 0, 0)
	
	# Add to fish body
	fish_body.add_child(tail_fin)
	
	# Add to main node (with rotation to face forward direction)
	fish_body.rotation_degrees.y = 90
	add_child(fish_body)

func get_random_target() -> Vector3:
	# Generate a random position within wander radius, but respect water boundaries
	var random_offset = Vector3(
		randf_range(-wander_radius, wander_radius),
		randf_range(-wander_radius/2, wander_radius/2),
		randf_range(-wander_radius, wander_radius)
	)
	
	var target = initial_position + random_offset
	
	# Make sure target is below water level
	if water_system:
		target.y = min(target.y, water_system.water_level - 0.5)
	
	return target

func apply_schooling_behavior():
	if nearby_fish.size() == 0:
		return
	
	var center = Vector3.ZERO
	var separation = Vector3.ZERO
	var alignment = Vector3.ZERO
	
	var valid_fish_count = 0
	
	for fish in nearby_fish:
		if is_instance_valid(fish) and fish != self:
			var distance = global_position.distance_to(fish.global_position)
			
			if distance < school_distance:
				valid_fish_count += 1
				
				# Cohesion: move toward center of school
				center += fish.global_position
				
				# Separation: avoid getting too close
				var away = global_position - fish.global_position
				if distance < school_distance * 0.5:
					separation += away.normalized() / max(distance, 0.1)
				
				# Alignment: align with school's direction
				if fish is Fish:
					alignment += fish.velocity.normalized()
	
	if valid_fish_count > 0:
		# Calculate center of school
		center = center / valid_fish_count
		
		# Apply schooling rules to modify target
		var cohesion_factor = (center - global_position).normalized() * 0.3
		var separation_factor = separation.normalized() * 0.5
		var alignment_factor = alignment.normalized() * 0.2
		
		# Combine behaviors and add to current target
		var combined = (cohesion_factor + separation_factor + alignment_factor).normalized()
		target_position = global_position + combined * wander_radius
	
func _on_body_entered_detection(body):
	if body is Fish:
		nearby_fish.append(body)
	elif body.name == "Player":
		# Start fleeing if player enters detection radius
		var flee_direction = global_position - body.global_position
		flee_direction = flee_direction.normalized()
		target_position = global_position + flee_direction * wander_radius * 2
		
		# Faster swimming when fleeing
		swim_speed *= 2.0
		time_until_new_target = 3.0

func _on_body_exited_detection(body):
	if body is Fish:
		nearby_fish.erase(body)
	elif body.name == "Player":
		# Return to normal speed when player leaves detection radius
		swim_speed = 1.5
