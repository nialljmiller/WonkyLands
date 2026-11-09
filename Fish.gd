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
var lure_material: StandardMaterial3D = null
var tail_pivot: Node3D = null           # child node used for wiggle animation
var _wiggle_phase: float = 0.0
var _cached_player: Node3D = null
var _lure_update_accum: float = 0.0
var _detection_area: Area3D = null

# Resource caches — keyed by appearance signature so every fish instanced
# from the same species scene reuses the same meshes + materials instead
# of each one building its own with SurfaceTool at _ready.
static var _MESH_CACHE: Dictionary = {}
static var _MAT_CACHE: Dictionary = {}
# One eye/pupil material pair is shared across EVERY fish — eyes are the
# same regardless of species.
static var _EYE_WHITE_MAT: StandardMaterial3D = null
static var _PUPIL_MAT: StandardMaterial3D = null

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
	_detection_area = Area3D.new()
	_detection_area.name = "DetectionArea"

	var detection_shape = CollisionShape3D.new()
	var sphere_shape = SphereShape3D.new()
	sphere_shape.radius = flee_distance
	detection_shape.shape = sphere_shape

	_detection_area.add_child(detection_shape)
	add_child(_detection_area)

	# Connect signals
	_detection_area.body_entered.connect(_on_body_entered_detection)
	_detection_area.body_exited.connect(_on_body_exited_detection)

	# Resolve water system + player via World — no tree walking, no
	# repeated lookups in _physics_process.
	if typeof(World) != TYPE_NIL:
		water_system = World.get_water_system()
		_cached_player = World.get_player()
		# If the player hasn't registered yet, grab it as soon as it does.
		if _cached_player == null:
			World.player_registered.connect(func(p): _cached_player = p)


func _physics_process(delta):
	# Reduce timer for changing target
	time_until_new_target -= delta

	var player: Node = _cached_player if is_instance_valid(_cached_player) else null
	var player_too_close = false
	var flee_dist_sq: float = flee_distance * flee_distance

	if player and player.global_position.distance_squared_to(global_position) < flee_dist_sq:
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

	# Update lure visuals after movement (throttled — emission energy
	# doesn't need to be updated every frame; ~15 Hz is plenty).
	if lure_mesh != null:
		_lure_update_accum += delta
		if _lure_update_accum >= 0.066:
			_update_lure_emission(_lure_update_accum)
			_lure_update_accum = 0.0


func create_fish_mesh():
	_remove_existing_mesh()
	tail_pivot = null

	# Fish-shape convention:
	#   -Z = nose (forward), +Z = tail. Length along Z = fish_size.x,
	#   height along Y = fish_size.y, width along X = fish_size.z.
	var length: float = fish_size.x
	var height: float = fish_size.y
	var width: float = fish_size.z

	var sig: String = _appearance_signature()
	var mats: Dictionary = _get_or_build_materials(sig)
	var meshes: Dictionary = _get_or_build_meshes(sig, length, height, width)
	var body_mat: StandardMaterial3D = mats.body
	var accent_mat: StandardMaterial3D = mats.accent

	var rig := Node3D.new()
	rig.name = "FishRig"

	# ---- Body: proper tapered teardrop mesh ----
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = meshes.body
	body.material_override = body_mat
	rig.add_child(body)

	# ---- Dorsal fin: curved triangle on top ----
	var dorsal := MeshInstance3D.new()
	dorsal.name = "Dorsal"
	dorsal.mesh = meshes.dorsal
	dorsal.material_override = body_mat
	dorsal.position = Vector3(0.0, height * 0.42, length * 0.0)
	rig.add_child(dorsal)

	# ---- Pectoral fins on sides (angled flat flaps) ----
	for side in [-1.0, 1.0]:
		var fin := MeshInstance3D.new()
		fin.name = "PectoralFin"
		fin.mesh = meshes.fin
		fin.material_override = body_mat
		fin.position = Vector3(side * width * 0.42, -height * 0.05, -length * 0.08)
		fin.rotation_degrees = Vector3(0.0, 90.0 * side, -25.0 * side)
		rig.add_child(fin)

	# ---- Tail: pivot for wiggle, forked fin at the end ----
	tail_pivot = Node3D.new()
	tail_pivot.name = "TailPivot"
	tail_pivot.position = Vector3(0.0, 0.0, length * 0.45)
	var tail_fin := MeshInstance3D.new()
	tail_fin.name = "TailFin"
	tail_fin.mesh = meshes.tail
	tail_fin.material_override = body_mat
	tail_fin.position = Vector3(0.0, 0.0, length * 0.15)
	tail_pivot.add_child(tail_fin)
	rig.add_child(tail_pivot)

	# ---- Eyes with pupil + sclera (meshes + materials shared globally) ----
	var eye_white_mat: StandardMaterial3D = _get_eye_white_mat()
	var pupil_mat: StandardMaterial3D = _get_pupil_mat()
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		eye.name = "Eye"
		eye.mesh = meshes.eye
		eye.material_override = eye_white_mat
		eye.position = Vector3(side * width * 0.4, height * 0.15, -length * 0.33)
		rig.add_child(eye)

		var pupil := MeshInstance3D.new()
		pupil.name = "Pupil"
		pupil.mesh = meshes.pupil
		pupil.material_override = pupil_mat
		pupil.position = Vector3(side * width * 0.5, height * 0.15, -length * 0.36)
		rig.add_child(pupil)

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
# Appearance caches — every fish instanced from the same species scene
# has identical exports (color, size, style, stripe_color, lure_enabled),
# so one set of meshes + materials can be shared across every instance.
# Keyed on a stringified signature of those exports.
# ---------------------------------------------------------------------
func _appearance_signature() -> String:
	return "%s|%s|%d|%s|%d" % [
		fish_color.to_html(),
		str(fish_size),
		int(mesh_style),
		stripe_color.to_html(),
		int(lure_enabled),
	]

func _get_or_build_materials(sig: String) -> Dictionary:
	if _MAT_CACHE.has(sig):
		return _MAT_CACHE[sig]
	var body_mat := _make_body_material()
	var accent_mat := _make_accent_material(body_mat)
	var entry := {"body": body_mat, "accent": accent_mat}
	_MAT_CACHE[sig] = entry
	return entry

func _get_or_build_meshes(sig: String, length: float, height: float, width: float) -> Dictionary:
	if _MESH_CACHE.has(sig):
		return _MESH_CACHE[sig]
	var eye := SphereMesh.new()
	eye.radius = height * 0.17
	eye.height = height * 0.34
	eye.radial_segments = 8
	eye.rings = 4
	var pupil := SphereMesh.new()
	pupil.radius = height * 0.09
	pupil.height = height * 0.18
	pupil.radial_segments = 6
	pupil.rings = 3
	var entry := {
		"body":   _build_tapered_body(length, height, width),
		"dorsal": _build_dorsal_fin(length * 0.4, height * 0.55, width * 0.08),
		"fin":    _build_fin_blade(length * 0.22, width * 1.4, height * 0.04),
		"tail":   _build_forked_tail(length * 0.35, height * 1.1, width * 0.06),
		"eye":    eye,
		"pupil":  pupil,
	}
	_MESH_CACHE[sig] = entry
	return entry

# Called by FishSystem when the fish crosses the cull boundary. Flips
# the Area3D's overlap checks off at the same time as physics so the
# physics server doesn't keep testing 400+ sphere areas for a fish that
# isn't running anyway.
func set_awake(awake: bool) -> void:
	if is_physics_processing() != awake:
		set_physics_process(awake)
	if _detection_area != null:
		if _detection_area.monitoring != awake:
			_detection_area.monitoring = awake
		if _detection_area.monitorable != awake:
			_detection_area.monitorable = awake

static func _get_eye_white_mat() -> StandardMaterial3D:
	if _EYE_WHITE_MAT == null:
		_EYE_WHITE_MAT = StandardMaterial3D.new()
		_EYE_WHITE_MAT.albedo_color = Color(0.92, 0.88, 0.8)
		_EYE_WHITE_MAT.metallic = 0.1
		_EYE_WHITE_MAT.roughness = 0.5
	return _EYE_WHITE_MAT

static func _get_pupil_mat() -> StandardMaterial3D:
	if _PUPIL_MAT == null:
		_PUPIL_MAT = StandardMaterial3D.new()
		_PUPIL_MAT.albedo_color = Color(0.05, 0.05, 0.08)
		_PUPIL_MAT.metallic = 0.3
		_PUPIL_MAT.roughness = 0.2
	return _PUPIL_MAT


# ---------------------------------------------------------------------
# Procedural body: rings of vertices along Z, radii following a tapered
# teardrop profile. Welded into a watertight mesh via SurfaceTool.
# ---------------------------------------------------------------------
func _build_tapered_body(length: float, height: float, width: float) -> ArrayMesh:
	# (z_frac in [-0.5, +0.5], radius_frac in [0,1] of max width,
	#  height_frac in [0,1] of max height).
	# Front taper (nose) + mid bulge + narrowing peduncle at the tail.
	var profile := [
		[-0.50, 0.00, 0.00],
		[-0.46, 0.20, 0.24],
		[-0.38, 0.45, 0.55],
		[-0.25, 0.75, 0.85],
		[-0.08, 1.00, 1.00],
		[ 0.08, 0.96, 0.98],
		[ 0.22, 0.75, 0.82],
		[ 0.33, 0.45, 0.55],
		[ 0.42, 0.18, 0.28],
		[ 0.47, 0.06, 0.10],   # tail peduncle
	]
	var segments: int = 10

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var rings: Array = []
	for row in profile:
		var z: float = row[0] * length
		var rx: float = row[1] * width * 0.5
		var ry: float = row[2] * height * 0.5
		var ring: Array = []
		for i in range(segments):
			var a: float = TAU * float(i) / float(segments)
			ring.append(Vector3(rx * cos(a), ry * sin(a), z))
		rings.append(ring)

	for r in range(rings.size() - 1):
		var a: Array = rings[r]
		var b: Array = rings[r + 1]
		for i in range(segments):
			var j: int = (i + 1) % segments
			# two triangles per quad
			st.add_vertex(a[i])
			st.add_vertex(a[j])
			st.add_vertex(b[i])

			st.add_vertex(a[j])
			st.add_vertex(b[j])
			st.add_vertex(b[i])

	# Cap the nose (first ring is the tip itself; close off cone to tip)
	# — not needed since ring 0 has radius ~0 which collapses to a point.
	# Cap the back similarly.

	st.generate_normals()
	return st.commit()


# Dorsal fin: sloped triangle, taller at front, lower at back.
func _build_dorsal_fin(l: float, h: float, w: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Two-sided (double-sided triangle) so it's visible from both sides.
	var p0 := Vector3(-w, 0.0,  l * 0.5)   # root back
	var p1 := Vector3(-w, 0.0, -l * 0.5)   # root front
	var p2 := Vector3(-w, h,    -l * 0.1)  # tip (biased forward)
	var p0r := Vector3( w, 0.0,  l * 0.5)
	var p1r := Vector3( w, 0.0, -l * 0.5)
	var p2r := Vector3( w, h,   -l * 0.1)
	# left face
	st.add_vertex(p0); st.add_vertex(p1); st.add_vertex(p2)
	st.add_vertex(p0); st.add_vertex(p2); st.add_vertex(p1)
	# right face
	st.add_vertex(p0r); st.add_vertex(p2r); st.add_vertex(p1r)
	st.add_vertex(p0r); st.add_vertex(p1r); st.add_vertex(p2r)
	# Bridge top edge (thin quad between the two triangles)
	st.add_vertex(p2); st.add_vertex(p2r); st.add_vertex(p1)
	st.add_vertex(p1); st.add_vertex(p2r); st.add_vertex(p1r)
	st.generate_normals()
	return st.commit()


# Pectoral/general fin blade: flat elongated triangle.
func _build_fin_blade(l: float, w: float, _t: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p0 := Vector3(-w * 0.5, 0.0, -l * 0.5)   # root inner
	var p1 := Vector3(-w * 0.5, 0.0,  l * 0.5)   # root outer
	var p2 := Vector3( w * 0.5, 0.0,  0.0)       # tip
	# double-sided
	st.add_vertex(p0); st.add_vertex(p1); st.add_vertex(p2)
	st.add_vertex(p0); st.add_vertex(p2); st.add_vertex(p1)
	st.generate_normals()
	return st.commit()


# Forked tail fin: two triangle lobes meeting at the root (V shape).
func _build_forked_tail(l: float, h: float, _w: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Root point at local origin.
	var root := Vector3.ZERO
	# Upper lobe tip
	var upper := Vector3(0.0,  h * 0.55, l)
	# Lower lobe tip
	var lower := Vector3(0.0, -h * 0.55, l)
	# Center-of-fork point (slightly inset)
	var center := Vector3(0.0, 0.0, l * 0.5)
	# Upper triangle (root, upper, center) front + back faces
	st.add_vertex(root); st.add_vertex(upper); st.add_vertex(center)
	st.add_vertex(root); st.add_vertex(center); st.add_vertex(upper)
	# Lower triangle
	st.add_vertex(root); st.add_vertex(center); st.add_vertex(lower)
	st.add_vertex(root); st.add_vertex(lower); st.add_vertex(center)
	st.generate_normals()
	return st.commit()


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
