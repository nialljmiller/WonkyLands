extends CharacterBody3D
class_name PlaneController
## Blade-element flight model driven by a PlaneSpec resource.
##
## Each physics tick:
##   1. Read inputs → update throttle + per-wing control_input.
##   2. Compute total aero force/torque by iterating every wing and
##      accumulating each strip's local lift + drag.
##   3. Add engine thrust, P-factor yaw moment, torque reaction roll
##      moment, fuselage parasitic drag, and gravity.
##   4. Linear: a = F / m. Angular: α = I⁻¹ · τ (diagonal tensor).
##   5. Integrate; apply to CharacterBody3D.
##
## No scalar `angular_damping` constant and no hard max-angular-speed
## clamp — rotational damping emerges from the blade-element math (a
## rolling wing sees different AoA on each side).

const PlaneSpec = preload("res://plane/PlaneSpec.gd")

# =====================================================================
# TUNABLES (coarse — fine tuning lives in the PlaneSpec)
# =====================================================================
@export_category("Engine")
@export var throttle_response: float = 1.8

@export_category("Atmosphere")
@export var air_density_sea_level: float = 1.225

@export_category("Ground effect")
@export var ground_effect_enabled: bool = true
@export var ground_effect_max_bonus: float = 0.3
@export var ground_effect_height_frac: float = 0.5

@export_category("Flaps")
@export var flap_deploy_speed: float = 0.8

@export_category("Ground / taxi")
@export var taxi_max_speed: float = 12.0
@export var taxi_steer_gain: float = 1.8
@export var brake_force: float = 9000.0
@export var ground_lateral_damp: float = 6.0
@export var ground_long_damp: float = 1.2
@export var takeoff_speed: float = 32.0

@export_category("Misc")
@export var idle_gravity_force: float = 18.0
@export var exit_offset: Vector3 = Vector3(-2.2, 0.5, -1.5)

@export_category("Visual deflection")
@export var max_elevator_deflection_deg: float = 25.0
@export var max_rudder_deflection_deg: float = 25.0
@export var max_aileron_deflection_deg: float = 20.0
@export var max_flap_deflection_deg: float = 35.0

# =====================================================================
# STATE
# =====================================================================
var spec: Variant = null

var throttle: float = 0.0
var current_speed: float = 0.0

var input_pitch: float = 0.0
var input_yaw: float = 0.0
var input_roll: float = 0.0
var input_brake: float = 0.0

var flap_deployed: float = 0.0
var _flap_target: float = 0.0

# Plane-local angular velocity in rad/s, components (pitch, yaw, roll).
var angular_velocity_local: Vector3 = Vector3.ZERO

var controlling_player: CharacterBody3D = null
var nearby_player: CharacterBody3D = null

var camera_mount: Marker3D = null
var seat_marker: Marker3D = null

# Visual references, created by _build_visuals().
var prop_hub: Node3D = null
var elevator: Node3D = null
var rudder: Node3D = null
var left_aileron: Node3D = null
var right_aileron: Node3D = null
var left_flap: Node3D = null
var right_flap: Node3D = null

var original_camera_parent: Node = null
var original_camera_transform: Transform3D = Transform3D.IDENTITY
var stored_player_visibility: bool = true
var disabled_colliders: Array[CollisionShape3D] = []

# Materials (initialised in _init_materials).
var _mat_fuselage: StandardMaterial3D
var _mat_wing: StandardMaterial3D
var _mat_accent: StandardMaterial3D
var _mat_metal: StandardMaterial3D
var _mat_rubber: StandardMaterial3D
var _mat_blade: StandardMaterial3D
var _mat_glass: StandardMaterial3D

@onready var entry_area: Area3D = $EntryArea

# =====================================================================
# LIFECYCLE
# =====================================================================
func _ready() -> void:
	camera_mount = $CameraMount
	seat_marker = $Seat
	entry_area.body_entered.connect(_on_entry_body_entered)
	entry_area.body_exited.connect(_on_entry_body_exited)
	spec = PlaneSpec.make_starter_cessna()
	_init_materials()
	_build_visuals()

func _physics_process(delta: float) -> void:
	_update_flaps(delta)
	_update_propeller(delta)
	_update_control_surface_visuals()

	if controlling_player != null:
		_attach_player_to_seat()
		_handle_flight_input(delta)
		_apply_flight_physics(delta)
		if Input.is_action_just_pressed("interact"):
			exit_plane()
	else:
		_apply_idle_physics(delta)
		if nearby_player != null and Input.is_action_just_pressed("interact"):
			enter_plane(nearby_player)
	move_and_slide()

# =====================================================================
# INPUT
# =====================================================================
func _handle_flight_input(delta: float) -> void:
	var t_in: float = Input.get_action_strength("plane_throttle_up") - Input.get_action_strength("plane_throttle_down")
	throttle = clamp(throttle + t_in * throttle_response * delta, 0.0, 1.0)
	input_pitch = Input.get_action_strength("plane_pitch_down") - Input.get_action_strength("plane_pitch_up")
	input_yaw   = Input.get_action_strength("plane_yaw_right") - Input.get_action_strength("plane_yaw_left")
	input_roll  = Input.get_action_strength("plane_roll_right") - Input.get_action_strength("plane_roll_left")
	input_brake = clamp(Input.get_action_strength("plane_brake"), 0.0, 1.0)
	if Input.is_action_just_pressed("plane_flaps"):
		_flap_target = 0.0 if _flap_target > 0.5 else 1.0

func _update_flaps(delta: float) -> void:
	flap_deployed = move_toward(flap_deployed, _flap_target, flap_deploy_speed * delta)

func _push_control_inputs_to_spec() -> void:
	# Map our input_* to each wing's control_input, respecting the
	# sign already baked into the wing's surface_sign.
	for wing in spec.wings:
		match wing.surface_input:
			"pitch":
				wing.control_input = input_pitch
			"roll":
				wing.control_input = input_roll
			"yaw":
				wing.control_input = input_yaw
			"flaps":
				wing.control_input = flap_deployed
			_:
				wing.control_input = 0.0

# =====================================================================
# FLIGHT PHYSICS (blade-element)
# =====================================================================
func _apply_flight_physics(delta: float) -> void:
	_push_control_inputs_to_spec()

	var basis: Basis = global_transform.basis
	var fwd: Vector3 = -basis.z

	# Plane-local velocity: everything downstream is cleaner in body frame.
	var v_world: Vector3 = velocity
	var v_local: Vector3 = basis.inverse() * v_world
	var speed: float = v_local.length()
	current_speed = speed

	# Density altitude: exponential falloff
	var altitude: float = max(global_position.y, 0.0)
	var air_density: float = air_density_sea_level * exp(-altitude / spec.engine.density_scale_height)

	# ---------- Taxi mode on ground at low speed ----------
	if is_on_floor() and speed < taxi_max_speed * 1.3:
		_apply_taxi_physics(delta, v_local, fwd, basis, air_density)
		return

	# ---------- Air mode ----------
	# AoA used for P-factor (lumped whole-plane AoA — the per-strip AoAs
	# are computed independently inside each wing).
	var aoa: float = 0.0
	if speed > 0.5:
		aoa = atan2(v_local.y, -v_local.z)

	# Ground effect — proximity to terrain. One number applied to every
	# wing strip (approximating the whole plane as being at CG altitude).
	var ge_bonus: float = 0.0
	if ground_effect_enabled and typeof(World) != TYPE_NIL:
		var ground_h: float = World.get_terrain_height(global_position.x, global_position.z)
		var h_agl: float = max(global_position.y - ground_h, 0.0)
		var ge_range: float = spec.wing_span_for_ground_effect * ground_effect_height_frac
		if ge_range > 0.0 and h_agl < ge_range:
			var t: float = clamp(1.0 - h_agl / ge_range, 0.0, 1.0)
			ge_bonus = ground_effect_max_bonus * t * t

	# Propwash dynamic pressure added to tail-surface strips. We compute
	# one number and the caller applies it only to strips in the prop's
	# slipstream — approximated here as the horizontal and vertical
	# stabilizers (the ones with names starting "HStab" or "VStab").
	var propwash_q: float = spec.engine.propwash_q(throttle, speed, takeoff_speed)

	var total_force_local: Vector3 = Vector3.ZERO
	var total_torque_local: Vector3 = Vector3.ZERO

	for wing in spec.wings:
		var is_tail: bool = wing.name.begins_with("HStab") or wing.name.begins_with("VStab")
		var wing_propwash_q: float = propwash_q if is_tail else 0.0
		var r: Dictionary = wing.accumulate_forces(
			v_local,
			angular_velocity_local,
			air_density,
			ge_bonus,
			wing_propwash_q,
		)
		total_force_local += r.force
		total_torque_local += r.torque

	# Fuselage parasitic drag — simple square-law along the velocity vector.
	var fuselage_drag_mag: float = 0.5 * air_density * speed * speed * spec.fuselage_frontal_area * spec.fuselage_drag_coefficient
	if speed > 1e-3:
		total_force_local += -(v_local / speed) * fuselage_drag_mag

	# Engine thrust
	total_force_local += spec.engine.thrust_force(throttle, altitude, air_density_sea_level)
	total_torque_local += spec.engine.thrust_torque(throttle, aoa)

	# Convert force to world frame and add gravity.
	var force_world: Vector3 = basis * total_force_local
	force_world += Vector3.DOWN * 9.81 * spec.mass

	# Linear integration
	var lin_accel: Vector3 = force_world / spec.mass
	velocity += lin_accel * delta

	# Angular integration (plane-local)
	var ang_accel: Vector3 = Vector3(
		total_torque_local.x / spec.inertia.x,
		total_torque_local.y / spec.inertia.y,
		total_torque_local.z / spec.inertia.z,
	)
	angular_velocity_local += ang_accel * delta

	# Apply rotation in body frame.
	rotate_object_local(Vector3.RIGHT,   angular_velocity_local.x * delta)   # pitch
	rotate_y(                            angular_velocity_local.y * delta)   # yaw
	rotate_object_local(Vector3.FORWARD, angular_velocity_local.z * delta)   # roll

func _apply_taxi_physics(
	delta: float,
	v_local: Vector3,
	fwd: Vector3,
	basis: Basis,
	air_density: float,
) -> void:
	# At taxi speeds the blade-element forces are tiny and jittery; use a
	# simple ground model instead.
	var v_long: float = velocity.dot(fwd)
	var right_vec: Vector3 = basis.x
	var v_side: float = velocity.dot(right_vec)

	var density_scale: float = exp(-max(global_position.y, 0.0) / spec.engine.density_scale_height)
	var F_engine: Vector3 = fwd * (spec.engine.max_thrust * throttle * density_scale)
	var brake_limit: float = brake_force * input_brake
	var F_brake_mag: float = min(abs(v_long) * spec.mass * ground_long_damp, brake_limit)
	var F_brake: Vector3 = Vector3.ZERO
	if F_brake_mag > 0.0:
		F_brake = -sign(v_long) * F_brake_mag * fwd
	var F_lat: Vector3 = -v_side * spec.mass * ground_lateral_damp * right_vec

	var cap: float = taxi_max_speed + 4.0 * (1.0 - input_brake)
	if velocity.length() > cap:
		F_engine = Vector3.ZERO

	var steer_cmd: float = clamp(input_yaw + 0.3 * input_roll, -1.0, 1.0)
	rotate_y(steer_cmd * taxi_steer_gain * delta)

	var F_total: Vector3 = F_engine + F_brake + F_lat + Vector3.DOWN * 9.81 * spec.mass
	velocity += (F_total / spec.mass) * delta
	angular_velocity_local = angular_velocity_local.lerp(Vector3.ZERO, 8.0 * delta)

# =====================================================================
# IDLE (no pilot)
# =====================================================================
func _apply_idle_physics(delta: float) -> void:
	throttle = lerp(throttle, 0.0, delta * 1.5)
	current_speed = lerp(current_speed, 0.0, delta * 1.2)
	angular_velocity_local = angular_velocity_local.lerp(Vector3.ZERO, delta * 2.0)

	var target := Vector3.ZERO
	if not is_on_floor():
		target.y = velocity.y - idle_gravity_force * delta
	velocity = velocity.lerp(target, delta * 3.0)

	if is_on_floor():
		var e: Vector3 = rotation_degrees
		e.x = lerp_angle(e.x, 0.0, delta * 3.0)
		e.z = lerp_angle(e.z, 0.0, delta * 3.0)
		rotation_degrees = e

# =====================================================================
# VISUAL UPDATES
# =====================================================================
func _update_propeller(delta: float) -> void:
	if prop_hub != null:
		prop_hub.rotate_z(lerp(3.0, 40.0, throttle) * delta)

func _update_control_surface_visuals() -> void:
	var el := deg_to_rad(max_elevator_deflection_deg) * input_pitch
	var rd := deg_to_rad(max_rudder_deflection_deg) * input_yaw
	var ai := deg_to_rad(max_aileron_deflection_deg) * input_roll
	var fl := deg_to_rad(max_flap_deflection_deg) * flap_deployed
	if elevator != null:
		elevator.rotation.x = el
	if rudder != null:
		rudder.rotation.y = rd
	if left_aileron != null:
		left_aileron.rotation.x = ai
	if right_aileron != null:
		right_aileron.rotation.x = -ai
	if left_flap != null:
		left_flap.rotation.x = fl
	if right_flap != null:
		right_flap.rotation.x = fl

func lerp_angle(from_angle: float, to_angle: float, weight: float) -> float:
	var diff: float = wrapf(to_angle - from_angle, -180.0, 180.0)
	return from_angle + diff * clamp(weight, 0.0, 1.0)

# =====================================================================
# SEAT / ENTER / EXIT (unchanged)
# =====================================================================
func _attach_player_to_seat() -> void:
	if controlling_player == null:
		return
	controlling_player.global_transform = seat_marker.global_transform
	controlling_player.velocity = Vector3.ZERO

func enter_plane(player: CharacterBody3D) -> void:
	if controlling_player != null:
		return
	controlling_player = player
	nearby_player = null

	input_pitch = 0.0
	input_yaw = 0.0
	input_roll = 0.0
	input_brake = 0.0
	angular_velocity_local = Vector3.ZERO

	if controlling_player.has_method("set_control_enabled"):
		controlling_player.set_control_enabled(false)

	stored_player_visibility = controlling_player.visible
	controlling_player.visible = false
	controlling_player.set_process_input(false)
	controlling_player.set_physics_process(false)

	disabled_colliders.clear()
	for child in controlling_player.get_children():
		if child is CollisionShape3D:
			var cs := child as CollisionShape3D
			cs.disabled = true
			disabled_colliders.append(cs)

	_attach_player_to_seat()

	var camera := controlling_player.get_node_or_null("Camera3D") as Camera3D
	if camera != null:
		original_camera_parent = camera.get_parent()
		original_camera_transform = camera.transform
		camera.get_parent().remove_child(camera)
		camera_mount.add_child(camera)
		camera.transform = Transform3D.IDENTITY
		camera.position = Vector3(0, 0.6, 0)
		camera.rotation_degrees = Vector3(-5, 0, 0)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func exit_plane() -> void:
	if controlling_player == null:
		return
	var player: CharacterBody3D = controlling_player

	var camera := camera_mount.get_node_or_null("Camera3D") as Camera3D
	if camera != null and original_camera_parent != null:
		camera_mount.remove_child(camera)
		original_camera_parent.add_child(camera)
		camera.transform = original_camera_transform

	player.visible = stored_player_visibility
	player.global_position = global_transform.origin + global_transform.basis * exit_offset
	player.velocity = Vector3.ZERO
	player.set_process_input(true)
	player.set_physics_process(true)
	if player.has_method("set_control_enabled"):
		player.set_control_enabled(true)

	for collider in disabled_colliders:
		if is_instance_valid(collider):
			collider.disabled = false
	disabled_colliders.clear()

	nearby_player = player
	controlling_player = null
	original_camera_parent = null
	original_camera_transform = Transform3D.IDENTITY
	throttle = 0.0
	current_speed = 0.0
	input_pitch = 0.0
	input_yaw = 0.0
	input_roll = 0.0
	input_brake = 0.0
	_flap_target = 0.0
	angular_velocity_local = Vector3.ZERO
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_entry_body_entered(body: Node) -> void:
	if body is CharacterBody3D and body.name == "Player" and body != controlling_player:
		nearby_player = body

func _on_entry_body_exited(body: Node) -> void:
	if body == nearby_player:
		nearby_player = null

# =====================================================================
# VISUAL CONSTRUCTION — unchanged from Phase 8, dimensions pulled from spec
# =====================================================================
func _init_materials() -> void:
	_mat_fuselage = _make_mat(Color(0.92, 0.9, 0.85), 0.45, 0.1)
	_mat_wing = _make_mat(Color(0.94, 0.92, 0.87), 0.5, 0.08)
	_mat_accent = _make_mat(Color(0.75, 0.15, 0.15), 0.4, 0.1)
	_mat_metal = _make_mat(Color(0.75, 0.75, 0.78), 0.3, 0.6)
	_mat_rubber = _make_mat(Color(0.12, 0.12, 0.12), 0.9, 0.0)
	_mat_blade = _make_mat(Color(0.08, 0.08, 0.08), 0.6, 0.2)
	_mat_glass = StandardMaterial3D.new()
	_mat_glass.albedo_color = Color(0.4, 0.55, 0.7, 0.35)
	_mat_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_glass.metallic = 0.4
	_mat_glass.roughness = 0.1

static func _make_mat(c: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = roughness
	m.metallic = metallic
	return m

static func _box(size: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	return mi

static func _cyl(radius_top: float, radius_bot: float, height: float, mat: StandardMaterial3D, segments: int = 12) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius_top
	mesh.bottom_radius = radius_bot
	mesh.height = height
	mesh.radial_segments = segments
	mi.mesh = mesh
	mi.material_override = mat
	return mi

func _build_visuals() -> void:
	_build_fuselage()
	_build_wings_from_spec()
	_build_tail_from_spec()
	_build_prop()
	_build_gear()

func _build_fuselage() -> void:
	var body := _box(Vector3(1.0, 1.0, 4.0), _mat_fuselage)
	body.position = Vector3(0, 0.1, 0.2)
	add_child(body)

	var belly := _box(Vector3(0.9, 0.5, 4.2), _mat_fuselage)
	belly.position = Vector3(0, -0.3, 0.2)
	add_child(belly)

	var tail_cone := _box(Vector3(0.55, 0.55, 1.6), _mat_fuselage)
	tail_cone.position = Vector3(0, 0.25, 2.1)
	add_child(tail_cone)

	var cowl := _box(Vector3(1.05, 1.0, 1.0), _mat_accent)
	cowl.position = Vector3(0, 0.1, -2.1)
	add_child(cowl)

	var canopy := MeshInstance3D.new()
	var canopy_mesh := BoxMesh.new()
	canopy_mesh.size = Vector3(0.9, 0.7, 1.8)
	canopy.mesh = canopy_mesh
	canopy.material_override = _mat_glass
	canopy.position = Vector3(0, 0.9, -0.5)
	add_child(canopy)

	var stripe := _box(Vector3(1.01, 0.12, 3.8), _mat_accent)
	stripe.position = Vector3(0, 0.1, 0.0)
	add_child(stripe)

func _build_wings_from_spec() -> void:
	var half_span: float = spec.main_wing_half_span
	var chord: float = spec.main_wing_chord
	var thickness: float = 0.15
	var dihedral_deg: float = spec.main_wing_dihedral_deg
	var root_y: float = spec.main_wing_y
	var wing_offset_z: float = spec.main_wing_z

	# Main wing panels
	var left_wing := _box(Vector3(half_span, thickness, chord), _mat_wing)
	left_wing.position = Vector3(-half_span * 0.5, root_y, wing_offset_z)
	left_wing.rotation_degrees.z = dihedral_deg
	add_child(left_wing)

	var right_wing := _box(Vector3(half_span, thickness, chord), _mat_wing)
	right_wing.position = Vector3(half_span * 0.5, root_y, wing_offset_z)
	right_wing.rotation_degrees.z = -dihedral_deg
	add_child(right_wing)

	var fairing := _box(Vector3(1.0, 0.25, chord * 0.8), _mat_fuselage)
	fairing.position = Vector3(0, root_y - 0.05, wing_offset_z)
	add_child(fairing)

	for side in [-1.0, 1.0]:
		var strut := _cyl(0.04, 0.04, 1.6, _mat_metal, 6)
		strut.position = Vector3(side * 2.2, root_y * 0.5 + 0.1, wing_offset_z + 0.3)
		strut.rotation_degrees.z = -side * 30.0
		add_child(strut)

	# Flaps + ailerons (visual only — the sim uses wing strips)
	var trailing_edge_z: float = wing_offset_z + chord * 0.5
	var ctrl_chord: float = 0.35
	var ctrl_thickness: float = thickness * 0.9
	var aileron_span: float = half_span * 0.4
	var flap_span: float = half_span * 0.4

	left_aileron = _make_control_surface("LeftAileron",
		Vector3(-half_span * 0.75, root_y, trailing_edge_z),
		Vector3(aileron_span, ctrl_thickness, ctrl_chord),
		ctrl_chord * 0.5, dihedral_deg)
	add_child(left_aileron)

	right_aileron = _make_control_surface("RightAileron",
		Vector3(half_span * 0.75, root_y, trailing_edge_z),
		Vector3(aileron_span, ctrl_thickness, ctrl_chord),
		ctrl_chord * 0.5, -dihedral_deg)
	add_child(right_aileron)

	left_flap = _make_control_surface("LeftFlap",
		Vector3(-half_span * 0.25, root_y, trailing_edge_z),
		Vector3(flap_span, ctrl_thickness, ctrl_chord),
		ctrl_chord * 0.5, dihedral_deg)
	add_child(left_flap)

	right_flap = _make_control_surface("RightFlap",
		Vector3(half_span * 0.25, root_y, trailing_edge_z),
		Vector3(flap_span, ctrl_thickness, ctrl_chord),
		ctrl_chord * 0.5, -dihedral_deg)
	add_child(right_flap)

func _make_control_surface(n: String, hinge_pos: Vector3, mesh_size: Vector3, back_offset: float, roll_deg: float) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = n
	pivot.position = hinge_pos
	pivot.rotation_degrees.z = roll_deg
	var mesh := _box(mesh_size, _mat_accent)
	mesh.position = Vector3(0, 0, back_offset)
	pivot.add_child(mesh)
	return pivot

func _build_tail_from_spec() -> void:
	var stab_span: float = spec.h_stab_half_span * 2.0
	var stab_chord: float = spec.h_stab_chord
	var stab_thick: float = 0.12
	var stab_y: float = spec.h_stab_y
	var stab_z: float = spec.h_stab_z

	var stab := _box(Vector3(stab_span, stab_thick, stab_chord), _mat_wing)
	stab.position = Vector3(0, stab_y, stab_z)
	add_child(stab)

	elevator = _make_control_surface("Elevator",
		Vector3(0, stab_y, stab_z + stab_chord * 0.5),
		Vector3(stab_span, stab_thick * 0.9, 0.35),
		0.175, 0.0)
	add_child(elevator)

	var fin_h: float = spec.v_stab_height
	var fin_c: float = spec.v_stab_chord
	var fin := _box(Vector3(0.1, fin_h, fin_c), _mat_fuselage)
	fin.position = Vector3(0, stab_y + fin_h * 0.5, stab_z - 0.1)
	add_child(fin)

	var rudder_pivot := Node3D.new()
	rudder_pivot.name = "Rudder"
	rudder_pivot.position = Vector3(0, stab_y + fin_h * 0.5, stab_z - 0.1 + fin_c * 0.5)
	var rudder_mesh := _box(Vector3(0.1, fin_h, 0.4), _mat_accent)
	rudder_mesh.position = Vector3(0, 0, 0.2)
	rudder_pivot.add_child(rudder_mesh)
	add_child(rudder_pivot)
	rudder = rudder_pivot

func _build_prop() -> void:
	var spinner := _cyl(0.0, 0.25, 0.35, _mat_accent, 12)
	spinner.position = Vector3(0, 0.1, -2.75)
	spinner.rotation_degrees.x = 90.0
	add_child(spinner)

	prop_hub = Node3D.new()
	prop_hub.name = "PropHub"
	prop_hub.position = Vector3(0, 0.1, -2.9)
	add_child(prop_hub)

	for i in range(3):
		var blade_pivot := Node3D.new()
		blade_pivot.rotation_degrees.z = float(i) * 120.0
		var blade_mesh := _box(Vector3(0.1, 1.1, 0.03), _mat_blade)
		blade_mesh.position = Vector3(0, 0.6, 0)
		blade_pivot.add_child(blade_mesh)
		prop_hub.add_child(blade_pivot)

func _build_gear() -> void:
	var main_z: float = -0.6
	var main_x: float = 1.0
	var gear_y: float = -0.85

	for side in [-1.0, 1.0]:
		var strut := _cyl(0.05, 0.05, 1.0, _mat_metal, 6)
		strut.position = Vector3(side * main_x * 0.5, gear_y + 0.5, main_z)
		strut.rotation_degrees.z = side * 10.0
		add_child(strut)

		var wheel := _cyl(0.3, 0.3, 0.2, _mat_rubber, 16)
		wheel.position = Vector3(side * main_x, gear_y, main_z)
		wheel.rotation_degrees.z = 90.0
		add_child(wheel)

	var tail_strut := _cyl(0.03, 0.03, 0.4, _mat_metal, 6)
	tail_strut.position = Vector3(0, -0.2, 2.6)
	add_child(tail_strut)

	var tail_wheel := _cyl(0.12, 0.12, 0.08, _mat_rubber, 12)
	tail_wheel.position = Vector3(0, -0.45, 2.7)
	tail_wheel.rotation_degrees.z = 90.0
	add_child(tail_wheel)
