extends CharacterBody3D

class_name Fish

enum MeshStyle {
	BASIC,
	STRIPED,
	DEEP_SEA,
}

@export var swim_speed: float = 1.5
@export var turn_speed: float = 2.0
@export var wander_radius: float = 5.0
@export var flee_distance: float = 3.0
@export var school_distance: float = 2.0
@export var flee_swim_multiplier: float = 2.0

@export var fish_color: Color = Color(0.3, 0.5, 0.9)
@export var fish_size: Vector3 = Vector3(0.5, 0.2, 0.1)
@export var mesh_style: MeshStyle = MeshStyle.BASIC
@export var stripe_color: Color = Color(0.2, 0.2, 0.2)
@export var stripe_offsets: PackedFloat32Array = PackedFloat32Array([-0.15, 0.15])
@export var stripe_thickness: float = 0.2
@export var lure_enabled: bool = false
@export var lure_color: Color = Color(0.0, 0.9, 1.0, 1.0)
@export var lure_intensity: float = 3.0
@export var min_depth: float = 0.0
@export var preferred_depth: float = 0.0
@export var depth_response_strength: float = 0.5

var initial_position: Vector3
var target_position: Vector3
var time_until_new_target: float = 0.0
var default_swim_speed: float = 0.0

var water_system
var nearby_fish: Array = []
var lure_mesh: MeshInstance3D

func _ready():
	# Save initial spawn position as center of territory
	initial_position = global_position
	default_swim_speed = swim_speed

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
	elif time_until_new_target <= 0 and not player_too_close:
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

	# Apply any depth preferences before moving
	_apply_depth_preferences(delta)

	# Move the fish
	move_and_slide()

	# Update lure visuals after movement
	_update_lure_emission(delta)


func create_fish_mesh():
	_remove_existing_mesh()

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
	match mesh_style:
		MeshStyle.BASIC:
			fish_material.metallic = 0.7
			fish_material.roughness = 0.2
		MeshStyle.STRIPED:
			fish_material.metallic = 0.7
			fish_material.roughness = 0.2
		MeshStyle.DEEP_SEA:
			fish_material.metallic = 0.5
			fish_material.roughness = 0.3
	fish_body.material_override = fish_material

	_add_tail(fish_body, fish_material)

	if mesh_style == MeshStyle.STRIPED:
		var stripe_material = StandardMaterial3D.new()
		stripe_material.albedo_color = stripe_color
		stripe_material.metallic = fish_material.metallic
		stripe_material.roughness = fish_material.roughness
		for offset in stripe_offsets:
			_add_stripe(fish_body, offset, stripe_material)

	if lure_enabled:
		_create_lure(fish_body)
	else:
		lure_mesh = null

	# Add to main node (with rotation to face forward direction)
	fish_body.rotation_degrees.y = 90
	add_child(fish_body)


func get_random_target() -> Vector3:
	# Generate a random position within wander radius, but respect water boundaries
	var random_offset = Vector3(
		randf_range(-wander_radius, wander_radius),
		randf_range(-wander_radius / 2, wander_radius / 2),
		randf_range(-wander_radius, wander_radius)
	)

	var target = initial_position + random_offset

	# Make sure target is below water level
	if water_system:
		target.y = min(target.y, water_system.water_level - 0.5)

	return target


func apply_schooling_behavior():
	if nearby_fish.is_empty():
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
		swim_speed = default_swim_speed * flee_swim_multiplier
		time_until_new_target = 3.0


func _on_body_exited_detection(body):
	if body is Fish:
		nearby_fish.erase(body)
	elif body.name == "Player":
		# Return to normal speed when player leaves detection radius
		swim_speed = default_swim_speed
		time_until_new_target = randf_range(3.0, 8.0)


func _remove_existing_mesh():
	var existing_body = get_node_or_null("FishBody")
	if existing_body:
		existing_body.queue_free()
	lure_mesh = null


func _add_tail(fish_body: MeshInstance3D, base_material: StandardMaterial3D):
	var tail_fin = MeshInstance3D.new()
	tail_fin.name = "TailFin"

	var tail_mesh = PrismMesh.new()
	tail_mesh.size = Vector3(fish_size.x * 0.5, fish_size.y * 0.8, fish_size.z * 0.5)
	tail_fin.mesh = tail_mesh

	if mesh_style == MeshStyle.STRIPED:
		var tail_material = StandardMaterial3D.new()
		tail_material.albedo_color = stripe_color
		tail_material.metallic = base_material.metallic
		tail_material.roughness = base_material.roughness
		tail_fin.material_override = tail_material
	else:
		tail_fin.material_override = base_material

	tail_fin.position = Vector3(-fish_size.x * 0.7, 0, 0)
	fish_body.add_child(tail_fin)


func _add_stripe(parent: MeshInstance3D, position_y: float, material: StandardMaterial3D):
	var stripe = MeshInstance3D.new()
	stripe.name = "Stripe"

	var stripe_mesh = BoxMesh.new()
	stripe_mesh.size = Vector3(fish_size.x * 0.8, fish_size.y * stripe_thickness, fish_size.z * 1.01)
	stripe.mesh = stripe_mesh

	stripe.position.y = position_y
	stripe.material_override = material
	parent.add_child(stripe)


func _create_lure(parent: MeshInstance3D):
	lure_mesh = MeshInstance3D.new()
	lure_mesh.name = "Lure"

	var lure_sphere = SphereMesh.new()
	lure_sphere.radius = fish_size.x * 0.1
	lure_sphere.height = fish_size.x * 0.2
	lure_mesh.mesh = lure_sphere

	var lure_material = StandardMaterial3D.new()
	lure_material.albedo_color = lure_color
	lure_material.emission_enabled = true
	lure_material.emission = lure_color
	lure_material.emission_energy = lure_intensity
	lure_mesh.material_override = lure_material

	lure_mesh.position = Vector3(fish_size.x * 0.6, fish_size.y * 0.3, 0)
	parent.add_child(lure_mesh)


func _apply_depth_preferences(delta):
	if not water_system:
		return

	var enforce_min_depth = min_depth > 0.0
	var enforce_preferred_depth = preferred_depth > 0.0

	if not enforce_min_depth and not enforce_preferred_depth:
		return

	var current_depth = water_system.water_level - global_position.y

	if enforce_min_depth and current_depth < min_depth:
		velocity.y = -swim_speed * 2.0
		return

	if enforce_preferred_depth:
		var depth_difference = preferred_depth - current_depth
		if abs(depth_difference) > 0.5:
			var adjustment = sign(depth_difference) * swim_speed * depth_response_strength
			var blend = clamp(depth_response_strength * delta, 0.0, 1.0)
			velocity.y = lerp(velocity.y, adjustment, blend)


func _update_lure_emission(delta):
	if not lure_mesh:
		return

	var lure_material = lure_mesh.material_override
	if not lure_material:
		return

	var pulse = (1.0 + sin(Time.get_ticks_msec() / 500.0)) * 0.5
	lure_material.emission_energy = lure_intensity + pulse * lure_intensity
