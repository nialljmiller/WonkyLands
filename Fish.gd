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
var tail_pivot: Node3D = null           # child node used for wiggle animation
var _wiggle_phase: float = 0.0

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

	# Resolve water system via World — no tree walking.
	if typeof(World) != TYPE_NIL:
		water_system = World.get_water_system()


func _physics_process(delta):
	# Reduce timer for changing target
	time_until_new_target -= delta

	# Get player via World
	var player: Node = null
	if typeof(World) != TYPE_NIL:
		player = World.get_player()
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

	# Tail wiggle amplitude tracks swim speed so a fleeing fish flicks
	# harder than one drifting around its territory.
	if tail_pivot != null:
		var speed_frac: float = clamp(velocity.length() / max(swim_speed * flee_swim_multiplier, 0.1), 0.0, 1.0)
		var amp: float = deg_to_rad(10.0 + 25.0 * speed_frac)
		var freq: float = 6.0 + 6.0 * speed_frac   # Hz-ish
		_wiggle_phase += delta * freq * TAU
		tail_pivot.rotation.y = sin(_wiggle_phase) * amp

	# Apply water flow (ocean currents) — fish partially resist.
	if typeof(World) != TYPE_NIL:
		velocity += World.get_flow_direction() * World.get_flow_strength() * 0.3

	# Apply any depth preferences before moving
	_apply_depth_preferences(delta)

	# Move the fish
	move_and_slide()

	# Update lure visuals after movement
	_update_lure_emission(delta)


func create_fish_mesh():
	_remove_existing_mesh()
	tail_pivot = null

	# Fish-shape convention in this function:
	#   -Z = nose (forward), +Z = tail. Body extents:
	#   length along Z = fish_size.x, height along Y = fish_size.y,
	#   width along X = fish_size.z. (This matches how the fish Node3D
	#   rotates — its own -Z is forward.)
	var length: float = fish_size.x
	var height: float = fish_size.y
	var width: float = fish_size.z

	var body_mat := _make_body_material()
	var accent_mat := _make_accent_material(body_mat)

	var rig := Node3D.new()
	rig.name = "FishRig"

	# ---- Body: unit sphere scaled into an ellipsoid ----
	var body := MeshInstance3D.new()
	body.name = "Body"
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 10
	sphere.rings = 6
	body.mesh = sphere
	body.scale = Vector3(width, height, length)
	body.material_override = body_mat
	rig.add_child(body)

	# ---- Dorsal fin on top (flat triangular prism) ----
	var dorsal := MeshInstance3D.new()
	dorsal.name = "Dorsal"
	var dorsal_mesh := PrismMesh.new()
	dorsal_mesh.size = Vector3(width * 0.3, height * 0.7, length * 0.4)
	dorsal.mesh = dorsal_mesh
	dorsal.material_override = body_mat
	dorsal.position = Vector3(0.0, height * 0.55, length * 0.05)
	rig.add_child(dorsal)

	# ---- Pectoral fins on sides (angled flat flaps) ----
	for side in [-1.0, 1.0]:
		var fin := MeshInstance3D.new()
		fin.name = "PectoralFin"
		var fin_mesh := PrismMesh.new()
		fin_mesh.size = Vector3(length * 0.25, height * 0.05, width * 1.6)
		fin.mesh = fin_mesh
		fin.material_override = body_mat
		fin.position = Vector3(side * width * 0.55, -height * 0.05, -length * 0.1)
		fin.rotation_degrees = Vector3(0.0, 90.0 * side, -20.0 * side)
		rig.add_child(fin)

	# ---- Tail pivot + tail fin (pivot is animated by _physics_process) ----
	tail_pivot = Node3D.new()
	tail_pivot.name = "TailPivot"
	tail_pivot.position = Vector3(0.0, 0.0, length * 0.5)
	var tail_fin := MeshInstance3D.new()
	tail_fin.name = "TailFin"
	var tail_mesh := PrismMesh.new()
	tail_mesh.size = Vector3(width * 0.1, height * 1.1, length * 0.5)
	tail_fin.mesh = tail_mesh
	tail_fin.material_override = body_mat
	tail_fin.position = Vector3(0.0, 0.0, length * 0.25)
	tail_pivot.add_child(tail_fin)
	rig.add_child(tail_pivot)

	# ---- Eyes: 2 small black-glossy spheres near the nose ----
	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = Color(0.05, 0.05, 0.08)
	eye_mat.metallic = 0.5
	eye_mat.roughness = 0.2
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		eye.name = "Eye"
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = height * 0.18
		eye_mesh.height = height * 0.36
		eye_mesh.radial_segments = 6
		eye_mesh.rings = 3
		eye.mesh = eye_mesh
		eye.material_override = eye_mat
		eye.position = Vector3(side * width * 0.42, height * 0.15, -length * 0.35)
		rig.add_child(eye)

	# ---- Style-specific extras ----
	if mesh_style == MeshStyle.STRIPED:
		for offset in stripe_offsets:
			_add_stripe_v2(rig, offset, accent_mat, length, height, width)

	if lure_enabled:
		_create_lure_v2(rig, length, height, accent_mat)
	else:
		lure_mesh = null

	add_child(rig)


# ---------------------------------------------------------------------
# Materials — small helpers to keep create_fish_mesh readable.
# ---------------------------------------------------------------------
func _make_body_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = fish_color
	match mesh_style:
		MeshStyle.BASIC:
			mat.metallic = 0.6
			mat.roughness = 0.25
		MeshStyle.STRIPED:
			mat.metallic = 0.5
			mat.roughness = 0.3
		MeshStyle.DEEP_SEA:
			mat.metallic = 0.4
			mat.roughness = 0.5
	return mat

func _make_accent_material(base: StandardMaterial3D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = stripe_color
	mat.metallic = base.metallic
	mat.roughness = base.roughness
	return mat

# A visible band wrapped around the body along Z.
func _add_stripe_v2(parent: Node3D, position_z: float, material: StandardMaterial3D,
		length: float, height: float, width: float) -> void:
	var stripe := MeshInstance3D.new()
	stripe.name = "Stripe"
	var stripe_mesh := BoxMesh.new()
	stripe_mesh.size = Vector3(width * 1.02, height * 1.02, length * stripe_thickness)
	stripe.mesh = stripe_mesh
	stripe.material_override = material
	# position_z is from the old API in body-local Y units; we reinterpret
	# it as a fraction of length along Z so existing variants stay visual
	# without needing retuning.
	stripe.position = Vector3(0.0, 0.0, position_z * length * 2.0)
	parent.add_child(stripe)

# Deep-sea fish lure: emissive ball dangling in front of the nose.
func _create_lure_v2(parent: Node3D, length: float, height: float, _accent: StandardMaterial3D) -> void:
	lure_mesh = MeshInstance3D.new()
	lure_mesh.name = "Lure"
	var ball := SphereMesh.new()
	ball.radius = height * 0.25
	ball.height = height * 0.5
	ball.radial_segments = 8
	ball.rings = 4
	lure_mesh.mesh = ball
	var lure_material := StandardMaterial3D.new()
	lure_material.albedo_color = lure_color
	lure_material.emission_enabled = true
	lure_material.emission = lure_color
	lure_material.emission_energy_multiplier = lure_intensity
	lure_mesh.material_override = lure_material
	lure_mesh.position = Vector3(0.0, height * 0.35, -length * 0.7)
	parent.add_child(lure_mesh)


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
	# Covers current ("FishRig") and legacy ("FishBody") naming.
	for n_name in ["FishRig", "FishBody"]:
		var n = get_node_or_null(n_name)
		if n:
			n.queue_free()
	lure_mesh = null
	tail_pivot = null


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
	# Godot 4 renamed emission_energy → emission_energy_multiplier.
	var pulse = (1.0 + sin(Time.get_ticks_msec() / 500.0)) * 0.5
	lure_material.emission_energy_multiplier = lure_intensity + pulse * lure_intensity
