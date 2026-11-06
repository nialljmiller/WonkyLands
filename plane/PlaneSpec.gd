extends RefCounted
## Complete plane configuration: mass + inertia tensor + wings + engine.
## PlaneController consumes a spec to drive physics and visuals.
##
## make_starter_cessna() produces the default "simple, forgiving" bush
## plane. Later, a plane-customization UI can mutate a spec (swap
## airfoil, change wing span, increase engine power) and hand it to the
## controller, and the sim adapts without any code change.

const Airfoil = preload("res://plane/Airfoil.gd")
const Wing    = preload("res://plane/Wing.gd")
const PlaneEngine = preload("res://plane/PlaneEngine.gd")

var display_name: String = "generic"

# Mass + principal moments of inertia (kg, kg·m²). Diagonal tensor —
# we ignore product-of-inertia terms, which is standard for aircraft.
var mass: float = 1200.0
var inertia: Vector3 = Vector3(1500.0, 2000.0, 1000.0)   # (pitch, yaw, roll)

# Components
var wings: Array = []         # Array[Wing]
var engine = null             # Engine
var wing_span_for_ground_effect: float = 10.5  # passed through for ground-effect range
var fuselage_drag_coefficient: float = 0.025
var fuselage_frontal_area: float = 1.4

# Visual-sync hints (used by the controller's mesh builder so geometry
# always matches aero).
var main_wing_half_span: float = 5.25
var main_wing_chord: float = 1.6
var main_wing_dihedral_deg: float = 4.0
var main_wing_y: float = 1.25
var main_wing_z: float = -0.2

var h_stab_half_span: float = 1.5
var h_stab_chord: float = 0.9
var h_stab_y: float = 0.65
var h_stab_z: float = 2.4

var v_stab_height: float = 1.2
var v_stab_chord: float = 1.0

# ---------------------------------------------------------------------
# Factory — the default starter Cessna-style high-wing bush plane.
# ---------------------------------------------------------------------
static func make_starter_cessna() -> Variant:
	var spec = (load("res://plane/PlaneSpec.gd") as GDScript).new()
	spec.display_name = "Starter Bush Plane"
	spec.mass = 1200.0
	spec.inertia = Vector3(1500.0, 2000.0, 1000.0)

	# Shared airfoils. The main wing uses a classic high-lift cambered
	# section; tail surfaces use a symmetric airfoil (no zero-α lift).
	var main_airfoil = Airfoil.new()
	main_airfoil.cl_alpha = 2.0 * PI * 0.9         # slightly below ideal thin-airfoil
	main_airfoil.cl_max = 1.45
	main_airfoil.alpha_zero_lift_deg = -2.0
	main_airfoil.stall_alpha_deg = 15.0
	main_airfoil.stall_width_deg = 6.0
	main_airfoil.cd0 = 0.009

	var tail_airfoil = Airfoil.new()
	tail_airfoil.cl_alpha = 2.0 * PI * 0.85
	tail_airfoil.cl_max = 1.1
	tail_airfoil.alpha_zero_lift_deg = 0.0         # symmetric
	tail_airfoil.stall_alpha_deg = 18.0
	tail_airfoil.stall_width_deg = 6.0
	tail_airfoil.cd0 = 0.008

	var half_span: float = spec.main_wing_half_span
	var chord: float = spec.main_wing_chord
	var dihedral: float = spec.main_wing_dihedral_deg
	var wing_y: float = spec.main_wing_y
	var wing_z: float = spec.main_wing_z

	# Main wings. Each panel has an inboard flap and an outboard aileron.
	# We implement these by making two wing objects per side: one carries
	# the flap (inboard half), one carries the aileron (outboard half).
	var dihedral_rad: float = deg_to_rad(dihedral)
	var right_span_dir: Vector3 = Vector3(cos(dihedral_rad), sin(dihedral_rad), 0.0)
	var left_span_dir: Vector3 = Vector3(-cos(dihedral_rad), sin(dihedral_rad), 0.0)

	# lift_axis for a dihedraled wing: rotate world-up (0,1,0) about the
	# fuselage axis (+Z) by the dihedral angle, with sign matching each
	# side. This is what makes dihedral produce the roll-restoring
	# moment under sideslip — the thing that makes the plane want to
	# stay wings-level instead of spiraling.
	var right_lift_axis: Vector3 = Vector3(-sin(dihedral_rad), cos(dihedral_rad), 0.0)
	var left_lift_axis:  Vector3 = Vector3( sin(dihedral_rad), cos(dihedral_rad), 0.0)

	# Right inboard (flap)
	var r_in = Wing.new()
	r_in.name = "RightInboard"
	r_in.airfoil = main_airfoil
	r_in.root_pos = Vector3(0.0, wing_y, wing_z)
	r_in.span_direction = right_span_dir
	r_in.lift_axis = right_lift_axis
	r_in.span = half_span * 0.5
	r_in.chord = chord
	r_in.incidence_deg = 1.5
	r_in.strips = 5
	r_in.surface_input = "flaps"
	r_in.surface_sign = 1.0
	r_in.surface_span_start = 0.0
	r_in.surface_span_end = 1.0
	r_in.surface_max_deflection_deg = 35.0
	r_in.surface_effectiveness = 0.25
	spec.wings.append(r_in)

	# Right outboard (aileron)
	var r_out = Wing.new()
	r_out.name = "RightOutboard"
	r_out.airfoil = main_airfoil
	r_out.root_pos = Vector3(half_span * 0.5 * cos(dihedral_rad), wing_y + half_span * 0.5 * sin(dihedral_rad), wing_z)
	r_out.span_direction = right_span_dir
	r_out.lift_axis = right_lift_axis
	r_out.span = half_span * 0.5
	r_out.chord = chord
	r_out.incidence_deg = 1.5
	r_out.strips = 5
	r_out.surface_input = "roll"
	r_out.surface_sign = -1.0           # right aileron: positive roll input → up → negative Cl bump
	r_out.surface_span_start = 0.0
	r_out.surface_span_end = 1.0
	r_out.surface_max_deflection_deg = 20.0
	r_out.surface_effectiveness = 0.12
	spec.wings.append(r_out)

	# Left inboard (flap)
	var l_in = Wing.new()
	l_in.name = "LeftInboard"
	l_in.airfoil = main_airfoil
	l_in.root_pos = Vector3(0.0, wing_y, wing_z)
	l_in.span_direction = left_span_dir
	l_in.lift_axis = left_lift_axis
	l_in.span = half_span * 0.5
	l_in.chord = chord
	l_in.incidence_deg = 1.5
	l_in.strips = 5
	l_in.mirror = true
	l_in.surface_input = "flaps"
	l_in.surface_sign = 1.0
	l_in.surface_span_start = 0.0
	l_in.surface_span_end = 1.0
	l_in.surface_max_deflection_deg = 35.0
	l_in.surface_effectiveness = 0.25
	spec.wings.append(l_in)

	# Left outboard (aileron, opposite sign to right)
	var l_out = Wing.new()
	l_out.name = "LeftOutboard"
	l_out.airfoil = main_airfoil
	l_out.root_pos = Vector3(-half_span * 0.5 * cos(dihedral_rad), wing_y + half_span * 0.5 * sin(dihedral_rad), wing_z)
	l_out.span_direction = left_span_dir
	l_out.lift_axis = left_lift_axis
	l_out.span = half_span * 0.5
	l_out.chord = chord
	l_out.incidence_deg = 1.5
	l_out.strips = 5
	l_out.mirror = true
	l_out.surface_input = "roll"
	l_out.surface_sign = 1.0            # left aileron: positive roll input → down → positive Cl bump
	l_out.surface_span_start = 0.0
	l_out.surface_span_end = 1.0
	l_out.surface_max_deflection_deg = 20.0
	l_out.surface_effectiveness = 0.12
	spec.wings.append(l_out)

	# Horizontal stabilizer — two halves with the elevator spanning both.
	# Incidence set negative so that in level flight the stab produces a
	# small downforce that balances nose-down tendency from the wing +
	# center-of-lift offset. This is what makes the aircraft trim at
	# positive AoA.
	var h_half: float = spec.h_stab_half_span
	var h_c: float = spec.h_stab_chord
	var h_y: float = spec.h_stab_y
	var h_z: float = spec.h_stab_z

	var h_right = Wing.new()
	h_right.name = "HStabRight"
	h_right.airfoil = tail_airfoil
	h_right.root_pos = Vector3(0.0, h_y, h_z)
	h_right.span_direction = Vector3(1, 0, 0)
	h_right.span = h_half
	h_right.chord = h_c
	h_right.incidence_deg = -2.0
	h_right.strips = 4
	h_right.surface_input = "pitch"
	# Positive pitch input (S key) = nose-down command. Tail must rise.
	# For the tail to rise, the stab needs more upward lift, so ΔCl > 0.
	h_right.surface_sign = 1.0
	h_right.surface_span_start = 0.0
	h_right.surface_span_end = 1.0
	h_right.surface_max_deflection_deg = 25.0
	h_right.surface_effectiveness = 0.25
	spec.wings.append(h_right)

	var h_left = Wing.new()
	h_left.name = "HStabLeft"
	h_left.airfoil = tail_airfoil
	h_left.root_pos = Vector3(0.0, h_y, h_z)
	h_left.span_direction = Vector3(-1, 0, 0)
	h_left.span = h_half
	h_left.chord = h_c
	h_left.incidence_deg = -2.0
	h_left.strips = 4
	h_left.surface_input = "pitch"
	h_left.surface_sign = 1.0
	h_left.surface_span_start = 0.0
	h_left.surface_span_end = 1.0
	h_left.surface_max_deflection_deg = 25.0
	h_left.surface_effectiveness = 0.25
	spec.wings.append(h_left)

	# Vertical stabilizer — span along +Y (up), lift_axis along +X so
	# "AoA" responds to sideslip. At β > 0 (nose yawed right of velocity,
	# air hitting plane's right side) the v-stab sees velocity with +X
	# component → negative AoA → lift in −X → force pushes tail left →
	# yaws nose right → aligned with velocity. Natural weathervaning.
	var v_stab = Wing.new()
	v_stab.name = "VStab"
	v_stab.airfoil = tail_airfoil
	v_stab.root_pos = Vector3(0.0, h_y + spec.v_stab_height * 0.1, h_z)
	v_stab.span_direction = Vector3(0, 1, 0)
	v_stab.lift_axis = Vector3(1, 0, 0)
	v_stab.chord_axis = Vector3(0, 0, 1)
	v_stab.span = spec.v_stab_height
	v_stab.chord = spec.v_stab_chord
	v_stab.incidence_deg = 0.0
	v_stab.strips = 4
	v_stab.surface_input = "yaw"
	# Positive yaw input (E key) = yaw right = nose rotates toward +X.
	# In standard physics that's negative τ_y (rotate_y with negative
	# ω_y). Rudder deflects such that v-stab Cl goes negative → side
	# force in -X at tail → torque r × F = (0, _, +z) × (-X, 0, 0) =
	# (0, -z*X, 0) which for z>0, X>0 gives τ_y < 0 → yaw right.
	v_stab.surface_sign = -1.0
	v_stab.surface_span_start = 0.0
	v_stab.surface_span_end = 1.0
	v_stab.surface_max_deflection_deg = 25.0
	v_stab.surface_effectiveness = 0.25
	spec.wings.append(v_stab)

	# Engine — bush-plane style, T/W ~0.47 so the plane actually clears
	# the 130 m runway with margin to spare. A real C172 at T/W ~0.25
	# needs 90 m ground run; our shorter effective runway + the drag
	# of a chunky bush-plane model wants more punch here.
	var eng = PlaneEngine.new()
	eng.max_thrust = 5500.0
	eng.throttle_response = 1.8
	eng.position = Vector3(0, 0.1, -2.9)
	eng.p_factor_gain = 350.0
	eng.torque_reaction_gain = 180.0
	eng.propwash_q_at_full = 250.0
	spec.engine = eng

	return spec
