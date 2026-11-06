extends RefCounted
## Engine + propeller. Produces thrust along the plane's forward axis,
## and three secondary effects that give light prop planes their
## distinctive feel:
##
## - P-factor: at positive AoA the descending propeller blade on one
##   side bites more air than the ascending blade on the other, producing
##   a yaw moment at high power.
## - Torque reaction: Newton's third law on the spinning propeller — the
##   airframe rolls opposite to the prop's rotation sense.
## - Propwash: the slipstream behind the prop increases dynamic pressure
##   over tail surfaces, preserving control authority at low airspeeds
##   with the throttle up.

var max_thrust: float = 3200.0            # N — GA default; the spec may override
var throttle_response: float = 1.8        # 0→1 per second
var position: Vector3 = Vector3(0, 0, -2.9)   # plane-local (CG at origin)
var p_factor_gain: float = 350.0          # N·m per radian of AoA at full throttle
var torque_reaction_gain: float = 180.0   # N·m at full throttle
var propwash_q_at_full: float = 250.0     # Pa added to tail-surface dynamic pressure at full throttle
var density_scale_height: float = 8500.0

func thrust_force(throttle: float, altitude: float, air_density_sea_level: float) -> Vector3:
	var density_scale: float = exp(-max(altitude, 0.0) / density_scale_height)
	# Thrust along plane -Z (forward), applied at the prop position.
	return Vector3(0, 0, -max_thrust * throttle * density_scale)

func thrust_torque(throttle: float, aoa: float) -> Vector3:
	# P-factor (yaw) + torque reaction (roll) in standard-physics sign.
	# Convention: tractor prop spinning CW viewed from pilot →
	#   * P-factor at positive AoA + power yaws nose LEFT (+τ_y)
	#   * Reaction rolls airframe LEFT (+τ_z)
	var p_factor_yaw: float = p_factor_gain * throttle * aoa
	var torque_react_roll: float = torque_reaction_gain * throttle
	return Vector3(0.0, p_factor_yaw, torque_react_roll)

func propwash_q(throttle: float, airspeed: float, takeoff_speed: float) -> float:
	# Slipstream Q falls off as free-stream speed rises — at cruise the
	# prop isn't accelerating the air much relative to the free-stream.
	var fade: float = clamp(1.0 - airspeed / (takeoff_speed * 1.5), 0.0, 1.0)
	return propwash_q_at_full * throttle * fade
