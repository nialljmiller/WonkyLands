extends CharacterBody3D
class_name PlaneController
## Pilotable aircraft with a lift-curve + induced-drag aero model, a
## separate taxi mode on the ground, and enter/exit-seat handling that
## reparents the camera cleanly.

# ---------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------
@export_category("Mass & geometry")
@export var mass: float = 1200.0
@export var wing_area: float = 16.0
@export var wing_span: float = 10.5
@export var air_density: float = 1.225

@export_category("Engine")
@export var max_thrust: float = 26000.0
@export var throttle_response: float = 1.8

@export_category("Aero")
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

# ---------------------------------------------------------------------
# State
# ---------------------------------------------------------------------
var throttle: float = 0.0
var current_speed: float = 0.0
var angular_velocity: Vector3 = Vector3.ZERO

var input_pitch: float = 0.0
var input_yaw: float = 0.0
var input_roll: float = 0.0
var input_brake: float = 0.0

var controlling_player: CharacterBody3D = null
var nearby_player: CharacterBody3D = null

var camera_mount: Marker3D = null
var seat_marker: Marker3D = null
var propeller: Node3D = null

var original_camera_parent: Node = null
var original_camera_transform: Transform3D = Transform3D.IDENTITY
var stored_player_visibility: bool = true
var disabled_colliders: Array[CollisionShape3D] = []

@onready var entry_area: Area3D = $EntryArea

# ---------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------
func _ready() -> void:
	camera_mount = $CameraMount
	seat_marker = $Seat
	propeller = $Propeller
	entry_area.body_entered.connect(_on_entry_body_entered)
	entry_area.body_exited.connect(_on_entry_body_exited)

func _physics_process(delta: float) -> void:
	_update_propeller(delta)
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

# ---------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------
func _handle_flight_input(delta: float) -> void:
	var t_in: float = Input.get_action_strength("plane_throttle_up") - Input.get_action_strength("plane_throttle_down")
	throttle = clamp(throttle + t_in * throttle_response * delta, 0.0, 1.0)
	input_pitch = Input.get_action_strength("plane_pitch_down") - Input.get_action_strength("plane_pitch_up")
	input_yaw   = Input.get_action_strength("plane_yaw_right") - Input.get_action_strength("plane_yaw_left")
	input_roll  = Input.get_action_strength("plane_roll_right") - Input.get_action_strength("plane_roll_left")
	input_brake = clamp(Input.get_action_strength("plane_brake"), 0.0, 1.0)

# ---------------------------------------------------------------------
# Flight physics
# ---------------------------------------------------------------------
func _apply_flight_physics(delta: float) -> void:
	var basis: Basis = global_transform.basis
	var fwd: Vector3 = -basis.z
	var right: Vector3 = basis.x

	var speed: float = velocity.length()
	current_speed = speed

	# Ground / taxi mode — simple, no aero fight, keyboard-steerable.
	if is_on_floor() and speed < taxi_max_speed * 1.3:
		var v_long: float = velocity.dot(fwd)
		var v_side: float = velocity.dot(right)

		var F_engine: Vector3 = fwd * (max_thrust * throttle)
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

	# Air mode
	var control_eff: float = 1.0
	if takeoff_speed > 0.0:
		control_eff = lerp(min_control_effectiveness, 1.0, clamp(speed / takeoff_speed, 0.0, 1.0))

	var v_local: Vector3 = basis.inverse() * velocity
	var aoa: float = 0.0
	var beta: float = 0.0
	if speed > 0.5:
		aoa = atan2(v_local.y, -v_local.z)
		beta = asin(clamp(v_local.x / speed, -1.0, 1.0))

	var stall_blend: float = 1.0
	var aoa_deg: float = rad_to_deg(aoa)
	if abs(aoa_deg) > stall_angle_deg:
		var recovery: float = max(stall_recovery_angle_deg - stall_angle_deg, 1.0)
		var over: float = min(abs(aoa_deg) - stall_angle_deg, recovery)
		stall_blend = clamp(1.0 - over / recovery, 0.0, 1.0)

	var cl: float = clamp(lift_curve_slope * aoa, -max_lift_coefficient, max_lift_coefficient) * stall_blend
	control_eff *= stall_blend

	var AR: float = 1.0
	if wing_area > 0.0:
		AR = (wing_span * wing_span) / wing_area
	var induced: float = 0.0
	if AR > 0.01:
		induced = (cl * cl) / (PI * AR)

	var q: float = 0.5 * air_density * speed * speed
	var cy: float = -side_force_coefficient * beta * stall_blend
	if takeoff_speed > 0.0:
		cy *= clamp(speed / takeoff_speed, 0.0, 1.0)

	var cd: float = base_drag_coefficient + induced_drag_factor * cl * cl + induced
	cd *= lerp(1.0, stall_drag_multiplier, 1.0 - stall_blend)

	var qS: float = q * wing_area
	var F_local: Vector3 = Vector3(cy * qS, cl * qS, -cd * qS)
	var F_aero: Vector3 = basis * F_local
	var F_thrust: Vector3 = fwd * (max_thrust * throttle)
	var F_grav: Vector3 = Vector3.DOWN * 9.81 * mass
	velocity += ((F_aero + F_thrust + F_grav) / mass) * delta
	if speed < 0.1:
		velocity += fwd * throttle * delta * 2.0

	# Torques
	# Use the aircraft's right vector to determine bank, not basis.z.y —
	# the latter couples pitch into roll stability and makes the plane
	# roll when the nose pitches up.
	var roll_level: float = -roll_stability * basis.x.y
	var ang_acc: Vector3 = Vector3(
		(input_pitch * elevator_authority * control_eff) + (-pitch_stability * aoa) - angular_velocity.x * angular_damping * control_eff,
		(input_yaw * rudder_authority * control_eff) + (-yaw_stability * beta) - angular_velocity.y * angular_damping * control_eff,
		(input_roll * aileron_authority * control_eff) + roll_level - angular_velocity.z * angular_damping * control_eff
	)
	angular_velocity += ang_acc * delta
	if angular_velocity.length() > max_angular_speed:
		angular_velocity = angular_velocity.normalized() * max_angular_speed

	rotate_object_local(Vector3.RIGHT,   angular_velocity.x * delta)
	rotate_y(                            angular_velocity.y * delta)
	rotate_object_local(Vector3.FORWARD, angular_velocity.z * delta)

# ---------------------------------------------------------------------
# Idle (no pilot)
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# Visual / util
# ---------------------------------------------------------------------
func _update_propeller(delta: float) -> void:
	if propeller != null:
		propeller.rotate_z(lerp(3.0, 40.0, throttle) * delta)

func lerp_angle(from_angle: float, to_angle: float, weight: float) -> float:
	var diff: float = wrapf(to_angle - from_angle, -180.0, 180.0)
	return from_angle + diff * clamp(weight, 0.0, 1.0)

# ---------------------------------------------------------------------
# Seat / enter / exit
# ---------------------------------------------------------------------
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
	angular_velocity = Vector3.ZERO
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

# ---------------------------------------------------------------------
# Entry proximity
# ---------------------------------------------------------------------
func _on_entry_body_entered(body: Node) -> void:
	if body is CharacterBody3D and body.name == "Player" and body != controlling_player:
		nearby_player = body

func _on_entry_body_exited(body: Node) -> void:
	if body == nearby_player:
		nearby_player = null
