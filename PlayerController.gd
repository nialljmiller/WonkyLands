extends CharacterBody3D
class_name PlayerController
## On-foot player controller.
##
## State machine: GROUNDED / AIRBORNE / SWIMMING. Mouse look is accumulated
## in _input and applied in _physics_process so camera motion stays consistent
## regardless of render framerate. Public API (enter_water, exit_water,
## is_in_water, set_control_enabled) is what other systems should call —
## no more get_meta backchannels.

# ---------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------
@export_category("Movement")
@export var walk_speed: float = 6.0
@export var sprint_speed: float = 10.0
@export var ground_accel: float = 40.0
@export var ground_friction: float = 30.0
@export var air_accel: float = 8.0
@export var air_friction: float = 1.5
@export var jump_strength: float = 8.0
@export var gravity: float = 24.0

@export_category("Swimming")
@export var swim_speed: float = 5.0
@export var swim_accel: float = 20.0
@export var swim_friction: float = 8.0
@export var swim_buoyancy: float = 1.5  # m/s drift toward surface when idle

@export_category("Look")
@export var mouse_sensitivity: float = 0.12  # degrees per pixel
@export var pitch_limit_deg: float = 89.0

# ---------------------------------------------------------------------
# State
# ---------------------------------------------------------------------
enum State { GROUNDED, AIRBORNE, SWIMMING }

var _state: int = State.AIRBORNE
var _in_water: bool = false
var _controls_enabled: bool = true
var _pending_look: Vector2 = Vector2.ZERO
var _yaw: float = 0.0
var _pitch: float = 0.0
var _camera: Camera3D = null

# ---------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------
func _ready() -> void:
	_camera = _find_or_create_camera()
	_yaw = rotation.y
	_pitch = _camera.rotation.x
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if typeof(World) != TYPE_NIL:
		World.register_player(self)

func _input(event: InputEvent) -> void:
	if not _controls_enabled:
		return
	if event is InputEventMouseMotion:
		_pending_look += event.relative
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		# toggle capture for debugging; harmless in gameplay
		Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED)

func _physics_process(delta: float) -> void:
	_apply_look()
	if not _controls_enabled:
		velocity = Vector3.ZERO
		move_and_slide()
		return
	_sync_water_state()
	_update_state()
	match _state:
		State.SWIMMING: _process_swimming(delta)
		State.GROUNDED: _process_grounded(delta)
		State.AIRBORNE: _process_airborne(delta)
	move_and_slide()

# ---------------------------------------------------------------------
# Public API — other systems call these, no meta backchannel.
# ---------------------------------------------------------------------
func enter_water() -> void:
	if _in_water:
		return
	_in_water = true
	if typeof(World) != TYPE_NIL:
		World.notify_player_entered_water(self)

func exit_water() -> void:
	if not _in_water:
		return
	_in_water = false
	if typeof(World) != TYPE_NIL:
		World.notify_player_exited_water(self)

func is_in_water() -> bool:
	return _in_water

# Authoritative per-tick check against the water plane. WaterSystem's
# Area3D still fires enter/exit for splash FX, but this is what drives
# swim-state transitions — no missed events when the player crosses the
# surface faster than one physics tick worth of collision overlap.
func _sync_water_state() -> void:
	if typeof(World) == TYPE_NIL:
		return
	var water_level: float = World.get_water_level()
	if water_level <= -1e8:
		return
	var submerged: bool = global_position.y < water_level
	if submerged and not _in_water:
		enter_water()
	elif not submerged and _in_water:
		exit_water()

func set_control_enabled(value: bool) -> void:
	_controls_enabled = value
	if not value:
		velocity = Vector3.ZERO

# ---------------------------------------------------------------------
# Look
# ---------------------------------------------------------------------
func _apply_look() -> void:
	if _pending_look == Vector2.ZERO:
		return
	_yaw -= deg_to_rad(_pending_look.x * mouse_sensitivity)
	_pitch -= deg_to_rad(_pending_look.y * mouse_sensitivity)
	_pitch = clamp(_pitch, -deg_to_rad(pitch_limit_deg), deg_to_rad(pitch_limit_deg))
	rotation.y = _yaw
	if _camera:
		_camera.rotation.x = _pitch
	_pending_look = Vector2.ZERO

# ---------------------------------------------------------------------
# State
# ---------------------------------------------------------------------
func _update_state() -> void:
	if _in_water:
		_state = State.SWIMMING
	elif is_on_floor():
		_state = State.GROUNDED
	else:
		_state = State.AIRBORNE

func _input_dir_planar() -> Vector3:
	# WASD in XZ plane, relative to current yaw.
	var ix := Input.get_action_strength("player_right") - Input.get_action_strength("player_left")
	var iz := Input.get_action_strength("player_back") - Input.get_action_strength("player_forward")
	var raw := Vector3(ix, 0.0, iz)
	if raw.length_squared() < 1e-6:
		return Vector3.ZERO
	return (Basis.from_euler(Vector3(0.0, _yaw, 0.0)) * raw).normalized()

# ---------------------------------------------------------------------
# Grounded
# ---------------------------------------------------------------------
func _process_grounded(delta: float) -> void:
	var speed: float = sprint_speed if Input.is_action_pressed("player_sprint") else walk_speed
	var dir := _input_dir_planar()
	var target := dir * speed
	var horiz := Vector3(velocity.x, 0.0, velocity.z)
	if dir == Vector3.ZERO:
		horiz = horiz.move_toward(Vector3.ZERO, ground_friction * delta)
	else:
		horiz = horiz.move_toward(target, ground_accel * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z
	if Input.is_action_just_pressed("player_jump"):
		velocity.y = jump_strength
	else:
		# tiny downward bias keeps is_on_floor() stable on slopes
		velocity.y = -0.5

# ---------------------------------------------------------------------
# Airborne
# ---------------------------------------------------------------------
func _process_airborne(delta: float) -> void:
	var dir := _input_dir_planar()
	var target := dir * walk_speed
	var horiz := Vector3(velocity.x, 0.0, velocity.z)
	if dir == Vector3.ZERO:
		horiz = horiz.move_toward(Vector3.ZERO, air_friction * delta)
	else:
		horiz = horiz.move_toward(target, air_accel * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z
	velocity.y -= gravity * delta

# ---------------------------------------------------------------------
# Swimming — full 3D, camera-relative, with slight upward buoyancy.
# ---------------------------------------------------------------------
func _process_swimming(delta: float) -> void:
	var ix := Input.get_action_strength("player_right") - Input.get_action_strength("player_left")
	var iz := Input.get_action_strength("player_back") - Input.get_action_strength("player_forward")
	var iy := Input.get_action_strength("player_swim_up") - Input.get_action_strength("player_swim_down")

	# Forward uses camera direction so look-down = swim-down.
	var cam_basis: Basis = _camera.global_transform.basis if _camera else global_transform.basis
	var fwd: Vector3 = -cam_basis.z
	var right: Vector3 = cam_basis.x
	var up: Vector3 = Vector3.UP

	var dir := (right * ix + fwd * -iz + up * iy)
	var target := Vector3.ZERO
	if dir.length_squared() > 1e-6:
		target = dir.normalized() * swim_speed

	if target == Vector3.ZERO:
		velocity = velocity.move_toward(Vector3(0.0, swim_buoyancy, 0.0), swim_friction * delta)
	else:
		velocity = velocity.move_toward(target, swim_accel * delta)

# ---------------------------------------------------------------------
# Camera setup — lenient so this works whether the scene provides a
# Camera3D child, a differently-named camera, or none at all.
# ---------------------------------------------------------------------
func _find_or_create_camera() -> Camera3D:
	for child in get_children():
		if child is Camera3D:
			return child
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = Vector3(0.0, 0.7, 0.0)
	add_child(cam)
	return cam
