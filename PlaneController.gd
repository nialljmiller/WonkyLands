extends CharacterBody3D
class_name PlaneController
## Pilotable bush plane.
##
## Aerodynamics: lift-curve with smooth post-stall roll-off, induced drag
## from aspect ratio, sideslip side force, stability derivatives in pitch/
## yaw/roll. On top of that: ground effect, P-factor, propeller torque
## reaction, propwash over the tail, flaps, and density altitude.
##
## Visuals are assembled in code (no monster .tscn) with separate control
## surfaces that actually deflect from input. The scene file just carries
## collision + entry area + seat/camera markers.

# =====================================================================
# TUNABLES
# =====================================================================
@export_category("Mass & geometry")
@export var mass: float = 1200.0
@export var wing_area: float = 16.0
@export var wing_span: float = 10.5
@export var air_density_sea_level: float = 1.225
@export var density_scale_height: float = 8500.0   # m, exponential falloff

@export_category("Engine")
@export var max_thrust: float = 26000.0
@export var throttle_response: float = 1.8

@export_category("Aero — base")
@export var lift_curve_slope: float = 5.5
@export var max_lift_coefficient: float = 1.4
@export var base_drag_coefficient: float = 0.035
@export var induced_drag_factor: float = 0.045
@export var side_force_coefficient: float = 0.7
@export var stall_angle_deg: float = 16.0
@export var stall_recovery_angle_deg: float = 28.0
@export var stall_drag_multiplier: float = 4.0
@export var min_control_effectiveness: float = 0.2
@export var takeoff_speed: float = 32.0

@export_category("Ground effect")
@export var ground_effect_enabled: bool = true
@export var ground_effect_max_bonus: float = 0.3    # +30% lift at wheel height
@export var ground_effect_height_frac: float = 0.5  # fades out at (wingspan * this) above terrain

@export_category("Propeller effects")
@export var p_factor_gain: float = 0.6              # yaw moment per rad of AoA at full throttle
@export var torque_reaction_gain: float = 0.45      # roll moment at full throttle
@export var propwash_gain: float = 0.6              # fraction of control authority preserved by throttle at low airspeed

@export_category("Flaps")
@export var flap_deploy_speed: float = 0.8          # 0→1 in 1.25 s
@export var flap_cl_bonus: float = 0.6              # added to max_lift_coefficient when fully deployed
@export var flap_drag_bonus: float = 0.045          # added to drag coefficient when fully deployed
@export var flap_pitch_down_moment: float = 0.15    # nose-down torque from deploying flaps

@export_category("Controls")
@export var elevator_authority: float = 2.6
@export var rudder_authority: float = 2.0
@export var aileron_authority: float = 3.0
@export var angular_damping: float = 1.6
@export var pitch_stability: float = 0.8
@export var yaw_stability: float = 1.2
@export var roll_stability: float = 1.1
@export var max_angular_speed: float = 3.5
@export var ground_alignment_speed: float = 3.0

@export_category("Ground / taxi")
@export var taxi_max_speed: float = 12.0
@export var taxi_steer_gain: float = 1.8
@export var brake_force: float = 9000.0
@export var ground_lateral_damp: float = 6.0
@export var ground_long_damp: float = 1.2

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
var throttle: float = 0.0
var current_speed: float = 0.0
var angular_velocity: Vector3 = Vector3.ZERO

var input_pitch: float = 0.0
var input_yaw: float = 0.0
var input_roll: float = 0.0
var input_brake: float = 0.0

var flap_deployed: float = 0.0        # animated 0..1
var _flap_target: float = 0.0

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

# =====================================================================
# FLIGHT PHYSICS
# =====================================================================
func _apply_flight_physics(delta: float) -> void:
	var basis: Basis = global_transform.basis
	var fwd: Vector3 = -basis.z
	var right: Vector3 = basis.x

	var speed: float = velocity.length()
	current_speed = speed

	# Density altitude: air density falls off with height. Affects both
	# thrust (less air for the prop to bite) and aero forces.
	var altitude: float = max(global_position.y, 0.0)
	var rho: float = air_density_sea_level * exp(-altitude / density_scale_height)
	var thrust_density_scale: float = rho / air_density_sea_level

	# ---------- Taxi mode: low speed on ground, keyboard-steerable ----------
	if is_on_floor() and speed < taxi_max_speed * 1.3:
		var v_long: float = velocity.dot(fwd)
		var v_side: float = velocity.dot(right)

		var F_engine: Vector3 = fwd * (max_thrust * throttle * thrust_density_scale)
		var brake_limit: float = brake_force * input_brake
		var F_brake_mag: float = min(abs(v_long) * mass * ground_long_damp, brake_limit)
		var F_brake: Vector3 = Vector3.ZERO
		if F_brake_mag > 0.0:
			F_brake = -sign(v_long) * F_brake_mag * fwd
		var F_lat: Vector3 = -v_side * mass * ground_lateral_damp * right

		var cap: float = taxi_max_speed + 4.0 * (1.0 - input_brake)
		if speed > cap:
			F_engine = Vector3.ZERO

		var steer_cmd: float = clamp(input_yaw + 0.3 * input_roll, -1.0, 1.0)
		rotate_y(steer_cmd * taxi_steer_gain * delta)

		var F_total: Vector3 = F_engine + F_brake + F_lat + Vector3.DOWN * 9.81 * mass
		velocity += (F_total / mass) * delta
		angular_velocity = angular_velocity.lerp(Vector3.ZERO, 8.0 * delta)
		return

	# ---------- Air mode ----------
	# Control effectiveness normally falls off at low airspeed, but
	# propwash over the tail preserves authority when the throttle is up.
	# Propwash contribution scales with throttle and fades with forward
	# speed (at high speed the free-stream dominates anyway).
	var control_eff: float = 1.0
	if takeoff_speed > 0.0:
		control_eff = lerp(min_control_effectiveness, 1.0, clamp(speed / takeoff_speed, 0.0, 1.0))
	var propwash_boost: float = throttle * propwash_gain * (1.0 - clamp(speed / takeoff_speed, 0.0, 1.0))
	control_eff = clamp(control_eff + propwash_boost, 0.0, 1.0)

	var v_local: Vector3 = basis.inverse() * velocity
	var aoa: float = 0.0
	var beta: float = 0.0
	if speed > 0.5:
		aoa = atan2(v_local.y, -v_local.z)
		beta = asin(clamp(v_local.x / speed, -1.0, 1.0))

	# Stall roll-off
	var stall_blend: float = 1.0
	var aoa_deg: float = rad_to_deg(aoa)
	if abs(aoa_deg) > stall_angle_deg:
		var recovery: float = max(stall_recovery_angle_deg - stall_angle_deg, 1.0)
		var over: float = min(abs(aoa_deg) - stall_angle_deg, recovery)
		stall_blend = clamp(1.0 - over / recovery, 0.0, 1.0)

	var cl_max_now: float = max_lift_coefficient + flap_cl_bonus * flap_deployed
	var cl: float = clamp(lift_curve_slope * aoa, -cl_max_now, cl_max_now) * stall_blend

	# Ground effect — proximity to terrain boosts lift up to ~half span.
	var ge_bonus: float = 0.0
	if ground_effect_enabled and typeof(World) != TYPE_NIL:
		var ground_h: float = World.get_terrain_height(global_position.x, global_position.z)
		var height_agl: float = max(global_position.y - ground_h, 0.0)
		var ge_range: float = wing_span * ground_effect_height_frac
		if ge_range > 0.0 and height_agl < ge_range:
			# 1 at the deck, 0 at the fade-out height, smooth in between.
			var t: float = clamp(1.0 - height_agl / ge_range, 0.0, 1.0)
			ge_bonus = ground_effect_max_bonus * t * t
	cl *= 1.0 + ge_bonus

	control_eff *= stall_blend

	var AR: float = 1.0
	if wing_area > 0.0:
		AR = (wing_span * wing_span) / wing_area
	var induced: float = 0.0
	if AR > 0.01:
		induced = (cl * cl) / (PI * AR)

	var q: float = 0.5 * rho * speed * speed
	var cy: float = -side_force_coefficient * beta * stall_blend
	if takeoff_speed > 0.0:
		cy *= clamp(speed / takeoff_speed, 0.0, 1.0)

	var cd: float = base_drag_coefficient + induced_drag_factor * cl * cl + induced + flap_drag_bonus * flap_deployed
	cd *= lerp(1.0, stall_drag_multiplier, 1.0 - stall_blend)

	var qS: float = q * wing_area
	var F_local: Vector3 = Vector3(cy * qS, cl * qS, -cd * qS)
	var F_aero: Vector3 = basis * F_local
	var F_thrust: Vector3 = fwd * (max_thrust * throttle * thrust_density_scale)
	var F_grav: Vector3 = Vector3.DOWN * 9.81 * mass
	velocity += ((F_aero + F_thrust + F_grav) / mass) * delta
	if speed < 0.1:
		velocity += fwd * throttle * delta * 2.0

	# --- Torques ---
	# Right-vector .y encodes bank without coupling pitch.
	var roll_level: float = -roll_stability * basis.x.y

	# P-factor: at positive AoA with high throttle, descending prop blade
	# bites more air than ascending blade, producing a yaw moment. Sign
	# convention: positive AoA + CW prop → left yaw (−y for us).
	var p_factor_torque: float = -p_factor_gain * throttle * aoa

	# Torque reaction: the prop spins; the airframe wants to roll the
	# other way. Rolls around the longitudinal axis.
	var torque_reaction: float = -torque_reaction_gain * throttle

	# Flaps push the nose down slightly when deployed.
	var flap_pitch: float = -flap_pitch_down_moment * flap_deployed

	var ang_acc: Vector3 = Vector3(
		(input_pitch * elevator_authority * control_eff) + flap_pitch + (-pitch_stability * aoa) - angular_velocity.x * angular_damping * control_eff,
		(input_yaw * rudder_authority * control_eff) + p_factor_torque + (-yaw_stability * beta) - angular_velocity.y * angular_damping * control_eff,
		(input_roll * aileron_authority * control_eff) + torque_reaction + roll_level - angular_velocity.z * angular_damping * control_eff
	)
	angular_velocity += ang_acc * delta
	if angular_velocity.length() > max_angular_speed:
		angular_velocity = angular_velocity.normalized() * max_angular_speed

	rotate_object_local(Vector3.RIGHT,   angular_velocity.x * delta)
	rotate_y(                            angular_velocity.y * delta)
	rotate_object_local(Vector3.FORWARD, angular_velocity.z * delta)

# =====================================================================
# IDLE (no pilot)
# =====================================================================
func _apply_idle_physics(delta: float) -> void:
	throttle = lerp(throttle, 0.0, delta * 1.5)
	current_speed = lerp(current_speed, 0.0, delta * 1.2)
	angular_velocity = angular_velocity.lerp(Vector3.ZERO, delta * 2.0)

	var target := Vector3.ZERO
	if not is_on_floor():
		target.y = velocity.y - idle_gravity_force * delta
	velocity = velocity.lerp(target, delta * 3.0)

	if is_on_floor():
		var e: Vector3 = rotation_degrees
		e.x = lerp_angle(e.x, 0.0, delta * ground_alignment_speed)
		e.z = lerp_angle(e.z, 0.0, delta * ground_alignment_speed)
		rotation_degrees = e

# =====================================================================
# VISUAL UPDATES (per tick)
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
# SEAT / ENTER / EXIT
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
	angular_velocity = Vector3.ZERO

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
	angular_velocity = Vector3.ZERO
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_entry_body_entered(body: Node) -> void:
	if body is CharacterBody3D and body.name == "Player" and body != controlling_player:
		nearby_player = body

func _on_entry_body_exited(body: Node) -> void:
	if body == nearby_player:
		nearby_player = null

# =====================================================================
# VISUAL CONSTRUCTION
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

static func _sphere(radius: float, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	mi.mesh = mesh
	mi.material_override = mat
	return mi

func _build_visuals() -> void:
	_build_fuselage()
	_build_wings()
	_build_tail()
	_build_prop()
	_build_gear()

func _build_fuselage() -> void:
	# Main body: two overlapping boxes giving a slight taper (nose wider, tail narrower).
	var body := _box(Vector3(1.0, 1.0, 4.0), _mat_fuselage)
	body.name = "FuselageBody"
	body.position = Vector3(0, 0.1, 0.2)
	add_child(body)

	var belly := _box(Vector3(0.9, 0.5, 4.2), _mat_fuselage)
	belly.name = "FuselageBelly"
	belly.position = Vector3(0, -0.3, 0.2)
	add_child(belly)

	# Rear fuselage taper
	var tail_cone := _box(Vector3(0.55, 0.55, 1.6), _mat_fuselage)
	tail_cone.name = "TailCone"
	tail_cone.position = Vector3(0, 0.25, 2.1)
	add_child(tail_cone)

	# Engine cowl (nose) — slightly wider, accent-colored
	var cowl := _box(Vector3(1.05, 1.0, 1.0), _mat_accent)
	cowl.name = "EngineCowl"
	cowl.position = Vector3(0, 0.1, -2.1)
	add_child(cowl)

	# Canopy (transparent)
	var canopy := MeshInstance3D.new()
	canopy.name = "Canopy"
	var canopy_mesh := BoxMesh.new()
	canopy_mesh.size = Vector3(0.9, 0.7, 1.8)
	canopy.mesh = canopy_mesh
	canopy.material_override = _mat_glass
	canopy.position = Vector3(0, 0.9, -0.5)
	add_child(canopy)

	# Red stripe down the fuselage for character
	var stripe := _box(Vector3(1.01, 0.12, 3.8), _mat_accent)
	stripe.name = "FuselageStripe"
	stripe.position = Vector3(0, 0.1, 0.0)
	add_child(stripe)

func _build_wings() -> void:
	# High wing: sits above the fuselage with a slight dihedral.
	var half_span: float = wing_span * 0.5
	var chord: float = 1.6
	var thickness: float = 0.15
	var dihedral_deg: float = 4.0
	var root_y: float = 1.25
	var wing_offset_z: float = -0.2

	# Left wing panel
	var left_wing := _box(Vector3(half_span, thickness, chord), _mat_wing)
	left_wing.name = "LeftWing"
	left_wing.position = Vector3(-half_span * 0.5, root_y, wing_offset_z)
	left_wing.rotation_degrees.z = dihedral_deg
	add_child(left_wing)

	var right_wing := _box(Vector3(half_span, thickness, chord), _mat_wing)
	right_wing.name = "RightWing"
	right_wing.position = Vector3(half_span * 0.5, root_y, wing_offset_z)
	right_wing.rotation_degrees.z = -dihedral_deg
	add_child(right_wing)

	# Wing-root fairing
	var fairing := _box(Vector3(1.0, 0.25, chord * 0.8), _mat_fuselage)
	fairing.name = "WingFairing"
	fairing.position = Vector3(0, root_y - 0.05, wing_offset_z)
	add_child(fairing)

	# Lift struts (bush-plane characteristic, thin diagonals)
	for side in [-1.0, 1.0]:
		var strut := _cyl(0.04, 0.04, 1.6, _mat_metal, 6)
		strut.name = "Strut_%s" % ("L" if side < 0.0 else "R")
		strut.position = Vector3(side * 2.2, root_y * 0.5 + 0.1, wing_offset_z + 0.3)
		strut.rotation_degrees.z = -side * 30.0
		add_child(strut)

	# Flaps and ailerons: outer wing portion has ailerons, inner has flaps.
	# Each is a Node3D at the hinge (trailing edge of main wing), with a
	# BoxMesh offset back so the Node3D's rotation axis is the hinge line.
	var trailing_edge_z: float = wing_offset_z + chord * 0.5
	var ctrl_chord: float = 0.35
	var ctrl_thickness: float = thickness * 0.9

	var aileron_span: float = half_span * 0.4
	var flap_span: float = half_span * 0.4

	# Left aileron (outer)
	left_aileron = _make_control_surface(
		"LeftAileron",
		Vector3(-half_span * 0.75, root_y, trailing_edge_z),
		Vector3(aileron_span, ctrl_thickness, ctrl_chord),
		ctrl_chord * 0.5,
		dihedral_deg)
	add_child(left_aileron)

	right_aileron = _make_control_surface(
		"RightAileron",
		Vector3(half_span * 0.75, root_y, trailing_edge_z),
		Vector3(aileron_span, ctrl_thickness, ctrl_chord),
		ctrl_chord * 0.5,
		-dihedral_deg)
	add_child(right_aileron)

	# Flaps (inner)
	left_flap = _make_control_surface(
		"LeftFlap",
		Vector3(-half_span * 0.25, root_y, trailing_edge_z),
		Vector3(flap_span, ctrl_thickness, ctrl_chord),
		ctrl_chord * 0.5,
		dihedral_deg)
	add_child(left_flap)

	right_flap = _make_control_surface(
		"RightFlap",
		Vector3(half_span * 0.25, root_y, trailing_edge_z),
		Vector3(flap_span, ctrl_thickness, ctrl_chord),
		ctrl_chord * 0.5,
		-dihedral_deg)
	add_child(right_flap)

func _make_control_surface(n: String, hinge_pos: Vector3, mesh_size: Vector3, back_offset: float, roll_deg: float) -> Node3D:
	# Pivot Node3D sits on the hinge line. The mesh child is offset back
	# along +z so the pivot rotation axis aligns with the hinge.
	var pivot := Node3D.new()
	pivot.name = n
	pivot.position = hinge_pos
	pivot.rotation_degrees.z = roll_deg
	var mesh := _box(mesh_size, _mat_accent)
	mesh.position = Vector3(0, 0, back_offset)
	pivot.add_child(mesh)
	return pivot

func _build_tail() -> void:
	# Horizontal stabilizer
	var stab_z: float = 2.4
	var stab_span: float = 3.0
	var stab_chord: float = 0.9
	var stab_thick: float = 0.12
	var stab_y: float = 0.65

	var stab := _box(Vector3(stab_span, stab_thick, stab_chord), _mat_wing)
	stab.name = "HorizStabilizer"
	stab.position = Vector3(0, stab_y, stab_z)
	add_child(stab)

	# Elevator — single piece spanning the stabilizer, hinge at its leading edge.
	elevator = _make_control_surface(
		"Elevator",
		Vector3(0, stab_y, stab_z + stab_chord * 0.5),
		Vector3(stab_span, stab_thick * 0.9, 0.35),
		0.175,
		0.0)
	add_child(elevator)

	# Vertical fin
	var fin_h: float = 1.2
	var fin_c: float = 1.0
	var fin := _box(Vector3(0.1, fin_h, fin_c), _mat_fuselage)
	fin.name = "VerticalFin"
	fin.position = Vector3(0, stab_y + fin_h * 0.5, stab_z - 0.1)
	add_child(fin)

	# Rudder — hinges on Y axis at trailing edge of fin.
	var rudder_pivot := Node3D.new()
	rudder_pivot.name = "Rudder"
	rudder_pivot.position = Vector3(0, stab_y + fin_h * 0.5, stab_z - 0.1 + fin_c * 0.5)
	var rudder_mesh := _box(Vector3(0.1, fin_h, 0.4), _mat_accent)
	rudder_mesh.position = Vector3(0, 0, 0.2)
	rudder_pivot.add_child(rudder_mesh)
	add_child(rudder_pivot)
	rudder = rudder_pivot

func _build_prop() -> void:
	# Spinner cone
	var spinner := _cyl(0.0, 0.25, 0.35, _mat_accent, 12)
	spinner.name = "Spinner"
	spinner.position = Vector3(0, 0.1, -2.75)
	spinner.rotation_degrees.x = 90.0
	add_child(spinner)

	# Prop hub — a Node3D rotated so its own +Z axis points along the
	# plane's forward axis. Blades are children offset radially; rotating
	# the hub around its local Z spins all blades together.
	prop_hub = Node3D.new()
	prop_hub.name = "PropHub"
	prop_hub.position = Vector3(0, 0.1, -2.9)
	# Hub is already aligned with the fuselage Z axis — no additional rotation.
	add_child(prop_hub)

	# Three blades 120° apart
	for i in range(3):
		var blade := _box(Vector3(0.1, 1.1, 0.02), _mat_blade)
		blade.rotation_degrees.z = float(i) * 120.0
		# Offset blade center so one end is at hub (0,0,0) — rotate first, then translate
		# Use a nested Node3D to make geometry clear
		var blade_pivot := Node3D.new()
		blade_pivot.name = "Blade%d" % i
		blade_pivot.rotation_degrees.z = float(i) * 120.0
		var blade_mesh := _box(Vector3(0.1, 1.1, 0.03), _mat_blade)
		blade_mesh.position = Vector3(0, 0.6, 0)
		blade_pivot.add_child(blade_mesh)
		prop_hub.add_child(blade_pivot)

func _build_gear() -> void:
	# Main gear — two struts + tires, tailwheel configuration
	var main_z: float = -0.6
	var main_x: float = 1.0
	var gear_y: float = -0.85

	for side in [-1.0, 1.0]:
		var strut := _cyl(0.05, 0.05, 1.0, _mat_metal, 6)
		strut.name = "MainStrut_%s" % ("L" if side < 0.0 else "R")
		strut.position = Vector3(side * main_x * 0.5, gear_y + 0.5, main_z)
		strut.rotation_degrees.z = side * 10.0
		add_child(strut)

		var wheel := _cyl(0.3, 0.3, 0.2, _mat_rubber, 16)
		wheel.name = "MainWheel_%s" % ("L" if side < 0.0 else "R")
		wheel.position = Vector3(side * main_x, gear_y, main_z)
		wheel.rotation_degrees.z = 90.0
		add_child(wheel)

	# Tailwheel assembly
	var tail_strut := _cyl(0.03, 0.03, 0.4, _mat_metal, 6)
	tail_strut.name = "TailStrut"
	tail_strut.position = Vector3(0, -0.2, 2.6)
	add_child(tail_strut)

	var tail_wheel := _cyl(0.12, 0.12, 0.08, _mat_rubber, 12)
	tail_wheel.name = "TailWheel"
	tail_wheel.position = Vector3(0, -0.45, 2.7)
	tail_wheel.rotation_degrees.z = 90.0
	add_child(tail_wheel)
