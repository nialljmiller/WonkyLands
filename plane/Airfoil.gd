extends RefCounted
## Analytical airfoil polar. Cl(α) is linear up to the stall angle, then
## smoothly blends into flat-plate behavior (so a fully stalled wing still
## produces *some* lift from pressure difference, as it does in reality).
## Cd(α) is quadratic: Cd0 near the design point, rising rapidly past stall.
##
## Everything is in radians except the stall angle (stored in degrees for
## readability — bigger-picture tunable).

var cl_alpha: float = 2.0 * PI            # lift-curve slope (per radian; thin-airfoil value)
var cl_max: float = 1.5                   # max unstalled lift coefficient
var alpha_zero_lift_deg: float = -2.0     # cambered airfoil → nonzero lift at α=0
var stall_alpha_deg: float = 15.0
var stall_width_deg: float = 6.0          # how smoothly stall blends into flat-plate behavior
var cd0: float = 0.008                    # zero-lift profile drag

func cl(alpha_rad: float) -> float:
	var a_zero := deg_to_rad(alpha_zero_lift_deg)
	var a_eff: float = alpha_rad - a_zero
	var a_eff_deg: float = rad_to_deg(a_eff)
	var abs_a_deg: float = abs(a_eff_deg)

	var linear: float = clamp(cl_alpha * a_eff, -cl_max, cl_max)
	if abs_a_deg <= stall_alpha_deg:
		return linear

	# Post-stall: asymptote to flat-plate lift ≈ sin(2α) * k. k chosen so
	# fully stalled lift at ~45° matches ~0.6 * cl_max.
	var flat_plate: float = sin(2.0 * a_eff) * cl_max * 0.6
	var fade_t: float = clamp((abs_a_deg - stall_alpha_deg) / stall_width_deg, 0.0, 1.0)
	fade_t = smoothstep(0.0, 1.0, fade_t)
	return lerp(linear, flat_plate, fade_t)

func cd(alpha_rad: float) -> float:
	var a_zero := deg_to_rad(alpha_zero_lift_deg)
	var a_eff: float = alpha_rad - a_zero
	var abs_a_deg: float = rad_to_deg(abs(a_eff))

	if abs_a_deg <= stall_alpha_deg:
		# Low-AoA: just parasitic drag.
		return cd0

	# Post-stall drag climbs quadratically — a stalled wing is mostly a drag device.
	var over_frac: float = (abs_a_deg - stall_alpha_deg) / 90.0
	return cd0 + 2.0 * pow(over_frac, 1.4)
