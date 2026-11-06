extends RefCounted
## A wing (or stabilizer) computed via blade-element theory.
##
## Each wing is split into `strips` spanwise segments. Each strip computes
## its own local airspeed — including the plane's angular velocity — and
## its own AoA, then its own lift and drag from the airfoil polar. This
## is what gives us natural roll/pitch/yaw damping, honest ground effect,
## asymmetric stall, and flap/aileron effects localized to the right
## strips.
##
## Convention for `root_pos` + `span_direction`:
##   - `root_pos` is where the wing attaches to the fuselage, in plane-
##     local frame (CG at origin, nose at -Z, right wing at +X).
##   - `span_direction` is a normalized vector in plane-local frame along
##     which strips are distributed outward from the root. A right wing's
##     span_direction would be approximately (+1, +sin(dihedral), 0).
##   - A strip's position is `root_pos + span_direction * x`, where x
##     ranges from 0 (root) to `span` (tip).
##
## The chord direction is implicit: +Z (aft) is trailing edge, -Z is
## leading. Incidence tilts the chord about the span axis.

var name: String = "wing"
var airfoil = null                        # Airfoil
var root_pos: Vector3 = Vector3.ZERO      # plane-local, strip generation starts here
var span_direction: Vector3 = Vector3(1, 0, 0)
var span: float = 5.0                     # length along span_direction
var chord: float = 1.6                    # fore-aft dimension
var incidence_deg: float = 1.0            # positive = leading edge up
var strips: int = 8
var mirror: bool = false                  # true for the left wing — flips roll-input sign of surfaces

# Control surface metadata. If `surface_input` is empty, no control
# surface on this wing.
var surface_input: String = ""            # "pitch" / "roll" / "yaw" / "flaps"
var surface_sign: float = 1.0             # per-wing sign (ailerons: left = -1, right = +1)
var surface_span_start: float = 0.5       # fraction of span the surface covers
var surface_span_end: float = 1.0
var surface_max_deflection_deg: float = 20.0
var surface_effectiveness: float = 0.5    # fraction of Cl_max a fully-deflected surface adds

# Runtime: current normalized control input (-1..1), updated by the
# controller each physics tick.
var control_input: float = 0.0

func total_area() -> float:
	return span * chord

func accumulate_forces(
	plane_velocity_local: Vector3,
	plane_angular_velocity_local: Vector3,
	air_density: float,
	ground_effect_bonus: float,
	propwash_dynamic_pressure: float,
) -> Dictionary:
	# Returns {force: Vector3, torque: Vector3} in plane-local frame.
	# Caller transforms to world and integrates.
	var force_accum: Vector3 = Vector3.ZERO
	var torque_accum: Vector3 = Vector3.ZERO

	var strip_span: float = span / float(strips)
	var strip_area: float = strip_span * chord
	var span_dir: Vector3 = span_direction.normalized()
	var incidence: float = deg_to_rad(incidence_deg)

	# Wing-local axes: we treat the chord direction as plane-Z and the
	# lift direction as rotated from plane-Y by the incidence angle about
	# the span axis. For strip force computation we project velocity onto
	# the chord plane (ignoring spanwise component, which produces no
	# lift and essentially no drag in this model).

	for i in range(strips):
		var dist_along_span: float = (i + 0.5) * strip_span
		var strip_local_pos: Vector3 = root_pos + span_dir * dist_along_span

		# Local velocity at strip = plane velocity + angular × r  (the
		# contribution that gives us "rotating wing sees different AoA
		# on each side" damping for free).
		var v_at_strip: Vector3 = plane_velocity_local + plane_angular_velocity_local.cross(strip_local_pos)

		# For lift we only care about velocity components normal to the
		# span axis. Project out the spanwise component.
		var v_span: float = v_at_strip.dot(span_dir)
		var v_normal: Vector3 = v_at_strip - span_dir * v_span

		# Build a wing-chord frame: chord_dir is plane-local +Z rotated by
		# incidence about the span axis; lift_dir is +Y rotated by the same.
		var chord_dir: Vector3 = Vector3(0, -sin(incidence), cos(incidence))
		var lift_dir: Vector3 = Vector3(0, cos(incidence), sin(incidence))

		# Velocity components in wing frame:
		var v_chord: float = v_normal.dot(chord_dir)          # aft (+) / fwd (−)
		var v_lift: float  = v_normal.dot(lift_dir)           # down (+) / up (−)
		var v_mag_sq: float = v_chord * v_chord + v_lift * v_lift
		if v_mag_sq < 0.01:
			continue
		var v_mag: float = sqrt(v_mag_sq)

		# Angle of attack: velocity vector relative to the chord.
		# Forward motion = -v_chord > 0; positive AoA when v_lift < 0
		# (air coming from below the wing).
		var aoa: float = atan2(-v_lift, -v_chord)

		# Control surface contribution: if this strip falls within the
		# surface's span range, deflecting the surface adds an effective
		# ΔCl proportional to deflection * effectiveness.
		var dcl_surface: float = 0.0
		if surface_input != "":
			var frac: float = dist_along_span / span
			if frac >= surface_span_start and frac <= surface_span_end:
				var deflection: float = control_input * deg_to_rad(surface_max_deflection_deg) * surface_sign
				# Classical result: ΔCl per radian ≈ 2π · (control chord / wing chord), simplified here
				# via surface_effectiveness (0..1).
				dcl_surface = (deflection / deg_to_rad(surface_max_deflection_deg)) * surface_effectiveness * airfoil.cl_max

		var cl: float = airfoil.cl(aoa) + dcl_surface
		cl *= 1.0 + ground_effect_bonus
		var cd: float = airfoil.cd(aoa)

		# Dynamic pressure at this strip. Propwash boost applies only to
		# strips the propeller slipstream actually reaches — the caller
		# tells us how much extra q to add (0 for wings outside propwash).
		var q: float = 0.5 * air_density * v_mag_sq + propwash_dynamic_pressure

		var lift_mag: float = q * strip_area * cl
		var drag_mag: float = q * strip_area * cd

		# Lift direction: perpendicular to local velocity in the chord-
		# lift plane, pointing "upward" (away from the oncoming air).
		var vel_dir: Vector3 = (chord_dir * v_chord + lift_dir * v_lift) / v_mag
		# Perpendicular to velocity, in the chord/lift plane, opposing v_lift:
		var local_lift_dir: Vector3 = (lift_dir * v_chord - chord_dir * v_lift) / v_mag

		var strip_force: Vector3 = local_lift_dir * lift_mag + (-vel_dir) * drag_mag
		force_accum += strip_force
		torque_accum += strip_local_pos.cross(strip_force)

	return {"force": force_accum, "torque": torque_accum}
