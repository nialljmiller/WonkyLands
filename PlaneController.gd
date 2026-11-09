extends CharacterBody3D
class_name PlaneController
## Lumped-force 6DOF flight model for a starter GA bush plane.
##
## Replaces the earlier blade-element implementation. Design goals:
##   * Correctness first: a single whole-plane AoA / sideslip, scalar
##     Cl/Cd/Cy polars, explicit damping. No per-strip sign puzzles.
##   * Unified ground/air loop: ground reaction is a force, not a mode.
##   * Direct control-authority mapping: elevator/rudder/aileron each
##     produce a torque scaled by dynamic pressure (with propwash), so
##     controls work from the moment the prop starts moving air.
##   * Keep PlaneSpec as a loose config bag so we can still customize
##     later, but we don't rely on a tower of per-wing math.
##
## Body-frame convention (matches Godot CharacterBody3D defaults):
##   +X = right wing, +Y = up, +Z = aft, -Z = forward (nose).
##   angular_velocity_local = (pitch_rate, yaw_rate, roll_rate) where
##     pitch_rate > 0  ⇒ nose up
##     yaw_rate   > 0  ⇒ nose left (right-hand rule about +Y)
##     roll_rate  > 0  ⇒ right wing down
##
## Input convention (flight-sim):
##   S (plane_pitch_up)   → input_pitch > 0 → nose up
##   W (plane_pitch_down) → input_pitch < 0 → nose down
##   A (plane_roll_left)  → input_roll < 0  → left wing down
##   D (plane_roll_right) → input_roll > 0  → right wing down
##   Q (plane_yaw_left)   → input_yaw  < 0  → nose left
##   E (plane_yaw_right)  → input_yaw  > 0  → nose right

const PlaneSpec = preload("res://plane/PlaneSpec.gd")

# =====================================================================
# TUNABLES
# =====================================================================
@export_category("Engine")
@export var throttle_response: float = 1.5

@export_category("Atmosphere")
@export var air_density_sea_level: float = 1.225

@export_category("Aero coefficients (lumped whole-plane)")
# Lift curve.  Cl = cl_alpha * (α − α0) up to stall, then fades to flat-plate.
@export var cl_alpha: float = 5.5              # per radian
@export var cl_max: float = 1.45
@export var alpha_zero_lift_deg: float = -3.0  # negative → wing lifts at α = 0
@export var alpha_stall_deg: float = 15.0
@export var stall_fade_deg: float = 5.0
# Drag.  Parasitic + induced (k * Cl²).
@export var cd_min: float = 0.032
@export var k_induced: float = 0.055
# Sideslip.  β produces a side force (weathervane) and a small roll
# coupling through dihedral.
@export var cy_beta: float = 0.9               # per radian of sideslip
@export var dihedral_roll_coeff: float = 0.8   # roll torque from β

@export_category("Reference areas")
@export var wing_area: float = 16.0
@export var h_tail_area: float = 2.0
@export var v_tail_area: float = 1.5

@export_category("Control authority (torque per rad per unit q)")
# Each control surface produces τ = coeff * q * input, where q = ½ρv² (+propwash).
@export var elevator_authority: float = 0.9
@export var aileron_authority: float = 1.0
@export var rudder_authority: float = 0.8

@export_category("Stability (restoring + damping)")
# Pitch stability: a positive AoA offset generates a nose-down pitching moment
# so the plane trims at some small positive α (static stability / tailplane trim).
@export var pitch_stiffness: float = 1.8       # per rad of (α − α_trim), scaled by q
@export var alpha_trim_deg: float = 3.0
# Per-axis angular damping torque = −k * ω * q  (q-scaled so damping grows with speed).
@export var pitch_damping: float = 6.0
@export var yaw_damping: float = 3.0
@export var roll_damping: float = 4.0
# Extra viscous damping (unscaled) that works even at zero airspeed.
@export var pitch_viscous: float = 0.6
@export var yaw_viscous: float = 0.4
@export var roll_viscous: float = 1.0

@export_category("Engine extras")
@export var p_factor_gain: float = 180.0       # N·m yaw moment per rad of α at full throttle
@export var torque_reaction_gain: float = 90.0 # N·m roll moment at full throttle
@export var propwash_q_at_full: float = 220.0  # Pa dynamic-pressure boost over tail at full throttle

@export_category("Ground effect")
@export var ground_effect_enabled: bool = true
@export var ground_effect_max_bonus: float = 0.25
@export var ground_effect_height_frac: float = 0.6

@export_category("Flaps")
@export var flap_deploy_speed: float = 0.8
@export var flap_cl_bonus: float = 0.5
@export var flap_cd_bonus: float = 0.03

@export_category("Ground / taxi")
@export var takeoff_speed_ref: float = 28.0    # for propwash fade
@export var wheel_rolling_resistance: float = 0.03   # fraction of weight resisting forward motion
@export var wheel_lateral_grip: float = 9.0          # how firmly tyres resist side-slip (1/s damping)
@export var brake_force: float = 15000.0
@export var ground_leveling_torque: float = 60.0     # tyres damp roll/pitch while on floor

@export_category("Misc")
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

# Signs follow the input convention in the header above.
var input_pitch: float = 0.0
var input_yaw: float = 0.0
var input_roll: float = 0.0
var input_brake: float = 0.0

var flap_deployed: float = 0.0
var _flap_target: float = 0.0

# Plane-local angular velocity in rad/s, components (pitch_rate, yaw_rate, roll_rate).
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

# Throttled ground-height sample for ground effect. Terrain height
# changes slowly as the plane moves; resampling at ~10 Hz is plenty.
var _ground_effect_h_cached: float = 0.0
var _ground_effect_h_accum: float = 999.0

# Visual deflection state — skip writing unchanged node rotations.
var _vis_last_pitch: float = 1e9
var _vis_last_yaw: float = 1e9
var _vis_last_roll: float = 1e9
var _vis_last_flap: float = 1e9

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
	# S = pitch_up = nose up → input_pitch positive.
	input_pitch = Input.get_action_strength("plane_pitch_up") - Input.get_action_strength("plane_pitch_down")
	# D = roll_right = right wing down → input_roll positive.
	input_roll  = Input.get_action_strength("plane_roll_right") - Input.get_action_strength("plane_roll_left")
	# E = yaw_right = nose right → input_yaw positive.
	input_yaw   = Input.get_action_strength("plane_yaw_right") - Input.get_action_strength("plane_yaw_left")
	input_brake = clamp(Input.get_action_strength("plane_brake"), 0.0, 1.0)
	if Input.is_action_just_pressed("plane_flaps"):
		_flap_target = 0.0 if _flap_target > 0.5 else 1.0

func _update_flaps(delta: float) -> void:
	flap_deployed = move_toward(flap_deployed, _flap_target, flap_deploy_speed * delta)

# =====================================================================
# FLIGHT PHYSICS — lumped-force 6DOF
# =====================================================================
func _apply_flight_physics(delta: float) -> void:
	var basis: Basis = global_transform.basis
	var v_world: Vector3 = velocity
	# For an orthonormal rotation basis, inverse == transpose; Godot's
	# Basis.inverse() is general-purpose and does a full 3x3 inverse —
	# transposed() is cheaper and correct here (character bodies don't
	# scale their basis).
	var v_local: Vector3 = basis.transposed() * v_world
	var speed: float = v_local.length()
	current_speed = speed

	# ---------- Atmospheric density ----------
	var altitude: float = max(global_position.y, 0.0)
	var density_scale_h: float = 8500.0
	var air_density: float = air_density_sea_level * exp(-altitude / density_scale_h)

	# ---------- Body-frame airflow ----------
	# "Airspeed vector" in body frame — what the wing sees. v_local has
	#   v_local.z < 0 when moving nose-forward, v_local.y < 0 when the
	#   plane is moving horizontally while nose-up (air hits the belly).
	# AoA = atan2(-v_local.y, -v_local.z): nose-up body attitude in
	#   level flight ⇒ v_local.y negative ⇒ α positive. Correct physical
	#   sign.
	var aoa: float = 0.0
	var beta: float = 0.0
	if speed > 0.5:
		var v_fwd: float = -v_local.z
		aoa = atan2(-v_local.y, maxf(v_fwd, 0.1))
		# β: positive when nose is yawed left of velocity (air hits right side).
		# v_local.x > 0 means plane is moving to its own right ⇒ air comes from
		# the plane's left ⇒ sideslip is to the left. Sign: β = atan2(v_local.x, v_fwd).
		beta = atan2(v_local.x, maxf(v_fwd, 0.1))

	# ---------- Dynamic pressure ----------
	var q: float = 0.5 * air_density * speed * speed

	# Propwash adds q only over tail surfaces. Fade as airspeed rises.
	var propwash_fade: float = clamp(1.0 - speed / (takeoff_speed_ref * 1.6), 0.0, 1.0)
	var propwash_q: float = propwash_q_at_full * throttle * propwash_fade
	var q_tail: float = q + propwash_q

	# Ground contact — used throughout to gate ground-only physics.
	var body_up: Vector3 = basis.y
	var ground_contact: bool = is_on_floor()
	if speed > 8.0:
		floor_snap_length = 0.0
	else:
		floor_snap_length = 0.4

	# ---------- Ground effect ----------
	var ge_bonus: float = 0.0
	if ground_effect_enabled and typeof(World) != TYPE_NIL:
		# Resample terrain at ~10 Hz. At 60 m/s that's 6 m between samples
		# — well under the wingspan the effect cares about.
		_ground_effect_h_accum += delta
		if _ground_effect_h_accum > 0.1:
			_ground_effect_h_accum = 0.0
			_ground_effect_h_cached = World.get_terrain_height(global_position.x, global_position.z)
		var h_agl: float = max(global_position.y - _ground_effect_h_cached, 0.0)
		var ge_range: float = spec.wing_span_for_ground_effect * ground_effect_height_frac
		if ge_range > 0.0 and h_agl < ge_range:
			var t: float = clamp(1.0 - h_agl / ge_range, 0.0, 1.0)
			ge_bonus = ground_effect_max_bonus * t * t

	# ---------- Lift / drag / sideforce coefficients ----------
	var cl: float = _cl(aoa) + flap_cl_bonus * flap_deployed
	cl *= 1.0 + ge_bonus
	var cd: float = cd_min + k_induced * cl * cl + flap_cd_bonus * flap_deployed
	var cy: float = -cy_beta * beta   # positive β → force toward −X (restoring)

	# ---------- Aerodynamic forces in body frame ----------
	# Lift acts along +Y (body up) at positive α.  More precisely it is
	# perpendicular to the free-stream in the x-z plane, but for a GA-
	# scale lumped model aligning it with body-up is accurate within a
	# few percent at the AoAs we care about and keeps signs trivial.
	var force_body: Vector3 = Vector3.ZERO
	force_body.y += cl * q * wing_area
	force_body.x += cy * q * v_tail_area
	# Drag opposes the velocity vector in body frame.
	if speed > 0.1:
		force_body += -(v_local / speed) * cd * q * wing_area

	# ---------- Engine thrust ----------
	var thrust_mag: float = spec.engine.max_thrust * throttle * (air_density / air_density_sea_level)
	force_body.z += -thrust_mag   # forward is -Z

	# ---------- Control torques ----------
	# Elevator: input_pitch > 0 (S) ⇒ pull up ⇒ +pitch torque about +X.
	# Aileron:  input_roll  > 0 (D) ⇒ right wing down ⇒ +roll torque about +Z.
	# Rudder:   input_yaw   > 0 (E) ⇒ nose right ⇒ −yaw torque about +Y.
	var tau_pitch: float = elevator_authority * q_tail * input_pitch * h_tail_area
	var tau_roll: float  = aileron_authority * q * input_roll * wing_area * 0.5
	var tau_yaw: float   = -rudder_authority * q_tail * input_yaw * v_tail_area

	# ---------- Stability torques ----------
	# Longitudinal static stability + horizontal-tail trim: trim at a small
	# positive α so hands-off, the plane settles into gentle climb or level.
	# We clamp the effective (α − α_trim) so a stall doesn't produce
	# enormous nose-down moments that overpower elevator authority.
	var a_trim: float = deg_to_rad(alpha_trim_deg)
	var a_err: float = clampf(aoa - a_trim, deg_to_rad(-12.0), deg_to_rad(12.0))
	tau_pitch += -pitch_stiffness * a_err * q * h_tail_area

	# Weathervaning: sideslip produces a yaw torque that aligns the nose
	# with the free-stream.
	var b_err: float = clampf(beta, deg_to_rad(-15.0), deg_to_rad(15.0))
	tau_yaw += -cy_beta * b_err * q * v_tail_area * 1.2

	# Dihedral: sideslip produces a roll torque that rolls away from the slip.
	tau_roll += -dihedral_roll_coeff * b_err * q * wing_area * 0.25

	# ---------- Angular damping (IMPLICIT) ----------
	# Damping is held out of tau_* and applied as an implicit integration
	# step at the end:   ω ← ω / (1 + c·dt).  This is unconditionally
	# stable; the earlier explicit version shook itself apart at ~150+ m/s
	# because `damping * q * dt / I` exceeded 2, which blows up Euler.
	# Compute the per-axis decay coefficients now so we can use them below.
	var damp_coeff_pitch: float = (pitch_damping * q + pitch_viscous) * h_tail_area / spec.inertia.x
	var damp_coeff_yaw:   float = (yaw_damping   * q + yaw_viscous)   * v_tail_area / spec.inertia.y
	var damp_coeff_roll:  float = (roll_damping  * q + roll_viscous)  * wing_area * 0.5 / spec.inertia.z

	# ---------- Engine secondary effects ----------
	# P-factor: at high power + high AoA the prop yaws the nose left.
	# (positive ω_y = nose left in body frame, so +gain * α * throttle.)
	tau_yaw  += p_factor_gain * throttle * aoa
	# Torque reaction: prop rotation rolls the airframe LEFT (left wing
	# down in level flight) — only when airborne; on the ground the gear
	# transfers the reaction torque to the earth.
	if not ground_contact:
		tau_roll += -torque_reaction_gain * throttle

	# ---------- Ground reaction ----------
	# Unified model: apply tyre forces whenever we're touching the ground.
	if ground_contact:
		# Rolling resistance along forward axis.
		var rolling_mu: float = wheel_rolling_resistance
		if input_brake > 0.0:
			# Strong longitudinal damping when braking.
			force_body.z += -v_local.z * spec.mass * 2.0 * input_brake
			rolling_mu += 0.15 * input_brake
		# Rolling resistance = μ * weight, opposing forward motion.
		var fwd_v: float = -v_local.z
		if absf(fwd_v) > 0.05:
			force_body.z += signf(fwd_v) * rolling_mu * spec.mass * 9.81

		# Lateral tyre grip: kill sideways motion (no skating on the runway).
		force_body.x += -v_local.x * spec.mass * wheel_lateral_grip

		# Keep the plane roughly level on the ground using basis vectors
		# (robust past the Euler gimbal lock).  Measures: how much the right-
		# wing axis tilts out of the horizontal plane, and how much the
		# forward axis tilts out of the horizontal plane.
		#
		# For pitch, we clamp to a shallow range on the ground: elevator can
		# raise the nose a few degrees (tail-down → rotation attitude) but
		# the gear prevents pitching past ~8°.  Past rotation speed the
		# plane leaves the ground and this constraint goes away.
		var body_right: Vector3 = basis.x
		var body_fwd: Vector3 = -basis.z
		var roll_err: float = body_right.y
		var nose_up: float = body_fwd.y         # +1 = straight up, 0 = level
		var max_ground_nose_up: float = 0.14    # sin(8°)
		var pitch_err: float = 0.0
		if nose_up > max_ground_nose_up:
			pitch_err = nose_up - max_ground_nose_up
		elif nose_up < -0.05:
			pitch_err = nose_up + 0.05
		tau_roll  += -roll_err * ground_leveling_torque * 14.0
		tau_pitch += -pitch_err * ground_leveling_torque * 10.0
		# Also strongly damp pitch rate so we never oscillate.
		tau_pitch += -angular_velocity_local.x * 180.0

	# ---------- Gravity (world frame) ----------
	var force_world: Vector3 = basis * force_body
	force_world += Vector3.DOWN * 9.81 * spec.mass

	# ---------- Linear integration ----------
	velocity += (force_world / spec.mass) * delta

	# ---------- Angular integration ----------
	# 1. Explicit step for the driving torques (controls + stability + engine).
	# 2. Implicit decay for the damping term, unconditionally stable.
	var ang_accel: Vector3 = Vector3(
		tau_pitch / spec.inertia.x,
		tau_yaw   / spec.inertia.y,
		tau_roll  / spec.inertia.z,
	)
	angular_velocity_local += ang_accel * delta
	angular_velocity_local.x /= 1.0 + damp_coeff_pitch * delta
	angular_velocity_local.y /= 1.0 + damp_coeff_yaw * delta
	angular_velocity_local.z /= 1.0 + damp_coeff_roll * delta

	# Clamp rates.  On the ground, pitch rate is strongly limited so the
	# gear can't be levered out of alignment.  In the air, allow spirited
	# maneuvering but prevent numerical runaway.
	if ground_contact:
		angular_velocity_local.x = clampf(angular_velocity_local.x, -0.4, 0.4)
		angular_velocity_local.z = clampf(angular_velocity_local.z, -0.6, 0.6)
	else:
		angular_velocity_local.x = clampf(angular_velocity_local.x, -2.5, 2.5)
		angular_velocity_local.z = clampf(angular_velocity_local.z, -4.0, 4.0)
	angular_velocity_local.y = clampf(angular_velocity_local.y, -2.0, 2.0)

	# ---------- Apply rotation in body frame ----------
	# RIGHT = +X: positive ω_x rotates nose up (pitch-up) ✓
	# UP    = +Y: positive ω_y rotates nose left ✓
	# BACK  = +Z: positive ω_z rotates right wing down (roll-right) ✓
	rotate_object_local(Vector3.RIGHT, angular_velocity_local.x * delta)
	rotate_object_local(Vector3.UP,    angular_velocity_local.y * delta)
	rotate_object_local(Vector3.BACK,  angular_velocity_local.z * delta)

	# ---------- Ground attitude constraint (hard) ----------
	# While the wheels are on the ground, physically prevent the gear from
	# being levered up past a shallow pitch/roll.  Soft torques alone can't
	# win against full elevator at high q, and the alternative is the
	# runaway tumble we see without this.
	if ground_contact:
		var MAX_GROUND_PITCH_DEG: float = 12.0
		var MAX_GROUND_ROLL_DEG: float  = 3.0
		var b: Basis = global_transform.basis
		var fwd: Vector3 = -b.z
		var right_v: Vector3 = b.x
		var nose_up_sin: float = fwd.y
		var max_sin: float = sin(deg_to_rad(MAX_GROUND_PITCH_DEG))
		var min_sin: float = sin(deg_to_rad(-3.0))
		if nose_up_sin > max_sin:
			var excess: float = asin(clampf(nose_up_sin, -1.0, 1.0)) - deg_to_rad(MAX_GROUND_PITCH_DEG)
			rotate_object_local(Vector3.RIGHT, -excess)
			angular_velocity_local.x = min(angular_velocity_local.x, 0.0)
		elif nose_up_sin < min_sin:
			var deficit: float = asin(clampf(nose_up_sin, -1.0, 1.0)) - deg_to_rad(-3.0)
			rotate_object_local(Vector3.RIGHT, -deficit)
			angular_velocity_local.x = max(angular_velocity_local.x, 0.0)
		# Roll clamp
		var right_tilt: float = right_v.y    # +1 = right wing straight up
		var max_roll_sin: float = sin(deg_to_rad(MAX_GROUND_ROLL_DEG))
		if right_tilt > max_roll_sin:
			var e_r: float = asin(clampf(right_tilt, -1.0, 1.0)) - deg_to_rad(MAX_GROUND_ROLL_DEG)
			rotate_object_local(Vector3.BACK, -e_r)
			angular_velocity_local.z = min(angular_velocity_local.z, 0.0)
		elif right_tilt < -max_roll_sin:
			var e_r2: float = asin(clampf(right_tilt, -1.0, 1.0)) + deg_to_rad(MAX_GROUND_ROLL_DEG)
			rotate_object_local(Vector3.BACK, -e_r2)
			angular_velocity_local.z = max(angular_velocity_local.z, 0.0)

func _cl(aoa_rad: float) -> float:
	var a_zero: float = deg_to_rad(alpha_zero_lift_deg)
	var a_eff: float = aoa_rad - a_zero
	var a_eff_deg: float = rad_to_deg(a_eff)
	var abs_deg: float = absf(a_eff_deg)
	var linear: float = clampf(cl_alpha * a_eff, -cl_max, cl_max)
	if abs_deg <= alpha_stall_deg:
		return linear
	# Post-stall: fade to flat-plate ~sin(2α) * 0.6 * cl_max.
	var flat_plate: float = sin(2.0 * a_eff) * cl_max * 0.6
	var t: float = clampf((abs_deg - alpha_stall_deg) / stall_fade_deg, 0.0, 1.0)
	t = smoothstep(0.0, 1.0, t)
	return lerp(linear, flat_plate, t)

# =====================================================================
# IDLE (no pilot)
# =====================================================================
func _apply_idle_physics(delta: float) -> void:
	throttle = lerp(throttle, 0.0, delta * 1.5)
	current_speed = lerp(current_speed, 0.0, delta * 1.2)
	angular_velocity_local = angular_velocity_local.lerp(Vector3.ZERO, delta * 4.0)

	# Simple gravity + ground.  No "lerp velocity to zero" — gravity does it.
	velocity.y -= 9.81 * delta
	# Light ground-level stabilization.
	if is_on_floor():
		velocity.x = lerp(velocity.x, 0.0, delta * 6.0)
		velocity.z = lerp(velocity.z, 0.0, delta * 6.0)
		velocity.y = max(velocity.y, 0.0)
		var e: Vector3 = rotation
		rotation.x = lerp_angle(e.x, 0.0, delta * 4.0)
		rotation.z = lerp_angle(e.z, 0.0, delta * 4.0)


# =====================================================================
# VISUAL UPDATES
# =====================================================================
func _update_propeller(delta: float) -> void:
	if prop_hub != null:
		prop_hub.rotate_z(lerp(3.0, 40.0, throttle) * delta)

func _update_control_surface_visuals() -> void:
	# No-op when inputs + flap target are unchanged from last frame. Idle
	# plane with no pilot stays in this branch forever.
	if (input_pitch == _vis_last_pitch and input_yaw == _vis_last_yaw
			and input_roll == _vis_last_roll and flap_deployed == _vis_last_flap):
		return
	_vis_last_pitch = input_pitch
	_vis_last_yaw = input_yaw
	_vis_last_roll = input_roll
	_vis_last_flap = flap_deployed
	var el := deg_to_rad(max_elevator_deflection_deg) * input_pitch
	var rd := -deg_to_rad(max_rudder_deflection_deg) * input_yaw
	var ai := deg_to_rad(max_aileron_deflection_deg) * input_roll
	var fl := deg_to_rad(max_flap_deflection_deg) * flap_deployed
	if elevator != null:
		elevator.rotation.x = el
	if rudder != null:
		rudder.rotation.y = rd
	if left_aileron != null:
		left_aileron.rotation.x = -ai
	if right_aileron != null:
		right_aileron.rotation.x = ai
	if left_flap != null:
		left_flap.rotation.x = fl
	if right_flap != null:
		right_flap.rotation.x = fl

func lerp_angle(from_angle: float, to_angle: float, weight: float) -> float:
	var diff: float = wrapf(to_angle - from_angle, -PI, PI)
	return from_angle + diff * clampf(weight, 0.0, 1.0)

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
