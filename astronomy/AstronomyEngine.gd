extends Node
## AstronomyEngine — the physics-of-the-sky layer.
##
## This never renders anything. It maintains:
##  * the observer's position on an Earth-like fictional planet
##    (configurable lat/lon, axial tilt, orbital period, sidereal day)
##  * the current Julian Date, advanced by delta·time_scale each frame
##  * apparent (alt/az) direction of the sun and moons from the observer
##  * apparent angular radius of each body (from real radius / real
##    distance)
##  * phase geometry (sun-to-moon direction for lambertian shading)
##
## The SkyRenderer consumes this to draw a visually accurate sky.
## A future Observatory module will consume the same state (plus a star
## catalog) to synthesise CCD images for photometry work.
##
## Everything astronomical is in SI-ish units (km, days, radians). The
## render layer projects onto a sky dome of its own choice — the
## apparent angular size is what both layers agree on.

const CoordinateTransforms = preload("res://astronomy/CoordinateTransforms.gd")

# ---------------------------------------------------------------------
# Observer planet
# ---------------------------------------------------------------------
@export_category("Observer planet")
@export var planet_name: String = "Hearth"
@export var planet_radius_km: float = 6371.0
@export var planet_axial_tilt_deg: float = 23.44
@export var planet_sidereal_day_hours: float = 23.9345
@export var planet_orbital_period_days: float = 365.25
@export_range(-90.0, 90.0) var observer_latitude_deg: float = 45.0
@export_range(-180.0, 180.0) var observer_longitude_deg: float = 0.0
@export var observer_altitude_m: float = 0.0

@export_category("Time")
@export var start_year: int = 2026
@export var start_month: int = 6
@export var start_day: int = 21
@export var start_hour_ut: float = 8.0
# How many game seconds elapse per real wall-clock second.
# 60 = 1 real-minute = 1 game-hour. 3600 = 1 real-second = 1 game-hour.
@export var time_scale: float = 60.0
# How often we recompute celestial positions. At time_scale = 60 the sun
# moves ~1 arcminute per real second — recomputing at 10 Hz still gives
# subarcsecond sampling between updates. Kepler's equation is iterative,
# so cutting this from 60 Hz to 10 Hz is a solid CPU save.
@export var update_hz: float = 10.0
var _update_accum: float = 0.0

# ---------------------------------------------------------------------
# Sun — the system's primary star.
# ---------------------------------------------------------------------
@export_category("Sun")
@export var sun_radius_km: float = 695700.0           # real Sol radius
@export var sun_distance_km: float = 149_597_870.7    # real 1 AU
@export var sun_absolute_magnitude: float = 4.83      # real Sol M_V
@export var sun_color: Color = Color(1.0, 0.98, 0.92)

# ---------------------------------------------------------------------
# Primary moon — Luna-like
# ---------------------------------------------------------------------
@export_category("Primary moon")
@export var moon1_name: String = "Luna"
@export var moon1_radius_km: float = 1737.4
@export var moon1_orbit_km: float = 384_400.0         # semi-major axis
@export var moon1_eccentricity: float = 0.0549
@export var moon1_inclination_deg: float = 5.145      # to planet's equator
@export var moon1_orbital_period_days: float = 27.321
@export var moon1_mean_anomaly_at_epoch_deg: float = 135.27
@export var moon1_longitude_ascending_node_deg: float = 125.08
@export var moon1_albedo: float = 0.12
@export var moon1_color: Color = Color(0.92, 0.9, 0.85)

# ---------------------------------------------------------------------
# Secondary moon — fictional smaller/closer body
# ---------------------------------------------------------------------
@export_category("Secondary moon")
@export var moon2_name: String = "Lume"
@export var moon2_radius_km: float = 420.0
@export var moon2_orbit_km: float = 95_000.0
@export var moon2_eccentricity: float = 0.015
@export var moon2_inclination_deg: float = 12.0
@export var moon2_orbital_period_days: float = 4.6
@export var moon2_mean_anomaly_at_epoch_deg: float = 40.0
@export var moon2_longitude_ascending_node_deg: float = 210.0
@export var moon2_albedo: float = 0.18
@export var moon2_color: Color = Color(0.85, 0.82, 0.78)

# ---------------------------------------------------------------------
# State
# ---------------------------------------------------------------------
var current_jd: float = 2451545.0
# Apparent direction (unit Vector3) of each body from observer, in the
# player's local horizontal frame. Updated each physics tick.
var sun_dir: Vector3 = Vector3.DOWN
var moon1_dir: Vector3 = Vector3.DOWN
var moon2_dir: Vector3 = Vector3.DOWN
# Apparent angular radius (half the angular diameter), in radians.
var sun_angular_radius: float = 0.0
var moon1_angular_radius: float = 0.0
var moon2_angular_radius: float = 0.0
# Illumination fraction (0..1): 0 = new, 1 = full.
var moon1_phase: float = 0.0
var moon2_phase: float = 0.0

# ---------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------
func _ready() -> void:
	current_jd = CoordinateTransforms.julian_date(start_year, start_month, start_day, start_hour_ut)
	_update_all()
	if typeof(World) != TYPE_NIL:
		World.register_astronomical_system(self)

func _process(delta: float) -> void:
	# JD advances every frame so time-of-day reads are always current,
	# but we only recompute the (expensive) celestial positions at
	# update_hz. Between updates, sun_dir / moon_dir stay put — which is
	# fine since 100 ms of game-time = well under an arcminute of motion.
	current_jd += delta * time_scale / CoordinateTransforms.SECONDS_PER_DAY
	_update_accum += delta
	var period: float = 1.0 / maxf(update_hz, 0.001)
	if _update_accum >= period:
		_update_accum = 0.0
		_update_all()
		if typeof(World) != TYPE_NIL:
			var frac_day: float = current_jd - floor(current_jd - 0.5) - 0.5
			var hours: float = fposmod(frac_day * 24.0 + 12.0, 24.0)
			World.notify_time_changed(hours, int(current_jd))
			World.notify_sun_direction(sun_dir)

# ---------------------------------------------------------------------
# Per-tick computation
# ---------------------------------------------------------------------
func _update_all() -> void:
	var lat_rad: float = deg_to_rad(observer_latitude_deg)
	var lst: float = CoordinateTransforms.lmst_hours(current_jd, observer_longitude_deg)
	var obl: float = CoordinateTransforms.obliquity_rad(current_jd)

	# --- Sun apparent position ---
	# Standard simplified solar position (accurate to ~0.01° for the
	# J2000 era, which is well under the sun's 0.5° angular diameter).
	var n: float = current_jd - CoordinateTransforms.J2000_JD
	var L: float = fposmod(deg_to_rad(280.460) + deg_to_rad(0.9856474) * n, TAU)
	var g: float = fposmod(deg_to_rad(357.528) + deg_to_rad(0.9856003) * n, TAU)
	var ecl_long: float = L + deg_to_rad(1.915) * sin(g) + deg_to_rad(0.020) * sin(2.0 * g)
	var sun_eq: Vector2 = CoordinateTransforms.ecliptic_to_equatorial(ecl_long, 0.0, obl)
	var sun_hor: Vector2 = CoordinateTransforms.equatorial_to_horizontal(sun_eq.x, sun_eq.y, lst, lat_rad)
	sun_dir = CoordinateTransforms.horizontal_to_direction(sun_hor.x, sun_hor.y)
	sun_angular_radius = atan(sun_radius_km / sun_distance_km)

	# --- Moon positions ---
	# Use simplified Keplerian orbits around the planet, in the planet's
	# equatorial frame (so inclinations are to the equator, not to the
	# ecliptic — adequate for a fictional world).
	var moon1_pos_km: Vector3 = _moon_position_equatorial(
		moon1_orbit_km, moon1_eccentricity,
		moon1_inclination_deg, moon1_longitude_ascending_node_deg,
		moon1_mean_anomaly_at_epoch_deg, moon1_orbital_period_days)
	var moon2_pos_km: Vector3 = _moon_position_equatorial(
		moon2_orbit_km, moon2_eccentricity,
		moon2_inclination_deg, moon2_longitude_ascending_node_deg,
		moon2_mean_anomaly_at_epoch_deg, moon2_orbital_period_days)

	var m1_apparent: Dictionary = _apparent_from_equatorial_pos(moon1_pos_km, lst, lat_rad)
	var m2_apparent: Dictionary = _apparent_from_equatorial_pos(moon2_pos_km, lst, lat_rad)
	moon1_dir = m1_apparent.dir
	moon2_dir = m2_apparent.dir
	moon1_angular_radius = atan(moon1_radius_km / m1_apparent.dist_km)
	moon2_angular_radius = atan(moon2_radius_km / m2_apparent.dist_km)

	# --- Phase (illumination fraction) ---
	# phase = (1 - cos(angle_between_sun_and_moon_as_seen_from_observer))/2
	# But for a moon, the correct formula uses the sun-moon-observer
	# triangle. For moon distances << sun distance, the angle at the
	# moon between sun-direction and observer-direction is ≈ 180° minus
	# the angle at observer between sun-direction and moon-direction.
	# Phase k = (1 + cos(phase_angle_at_moon)) / 2.
	# We use the latter for clarity.
	moon1_phase = _illumination_fraction(sun_dir, moon1_dir)
	moon2_phase = _illumination_fraction(sun_dir, moon2_dir)

# Returns {dir: Vector3, dist_km: float} for a body at a given
# equatorial-frame position relative to the observer (approximate —
# ignores observer-on-planet vs planet-center offset, which for a moon
# at 384 000 km and an observer on a 6371 km planet is a <1° correction).
func _apparent_from_equatorial_pos(pos_km: Vector3, lst_hours: float, latitude_rad: float) -> Dictionary:
	# Convert cartesian equatorial → RA/Dec
	var dist: float = pos_km.length()
	var ra: float = atan2(pos_km.y, pos_km.x)
	if ra < 0.0:
		ra += TAU
	var dec: float = asin(clampf(pos_km.z / maxf(dist, 1.0), -1.0, 1.0))
	var hor: Vector2 = CoordinateTransforms.equatorial_to_horizontal(ra, dec, lst_hours, latitude_rad)
	return {
		"dir": CoordinateTransforms.horizontal_to_direction(hor.x, hor.y),
		"dist_km": dist,
	}

# Position of a moon in the planet's equatorial frame (cartesian km).
# Uses Keplerian two-body orbit; ignores precession and other
# perturbations (fine for a game, fine for the observatory until we
# care about sub-arcsecond accuracy).
func _moon_position_equatorial(a_km: float, e: float, incl_deg: float,
		raan_deg: float, mean_anom_at_epoch_deg: float,
		period_days: float) -> Vector3:
	var n_rad_per_day: float = TAU / period_days      # mean motion
	var days_from_epoch: float = current_jd - CoordinateTransforms.J2000_JD
	var M: float = deg_to_rad(mean_anom_at_epoch_deg) + n_rad_per_day * days_from_epoch
	var E: float = CoordinateTransforms.solve_kepler(M, e)
	var nu: float = CoordinateTransforms.true_anomaly(E, e)
	var r: float = a_km * (1.0 - e * cos(E))
	# Position in perifocal frame (orbital plane, periapsis on +X).
	var x_p: float = r * cos(nu)
	var y_p: float = r * sin(nu)
	# Rotate into planet's equatorial frame via inclination + RAAN.
	# (Omitting argument of periapsis — folded into mean anomaly epoch.)
	var i: float = deg_to_rad(incl_deg)
	var omega: float = deg_to_rad(raan_deg)
	var cos_o: float = cos(omega)
	var sin_o: float = sin(omega)
	var cos_i: float = cos(i)
	var sin_i: float = sin(i)
	return Vector3(
		cos_o * x_p - sin_o * cos_i * y_p,
		sin_o * x_p + cos_o * cos_i * y_p,
		sin_i * y_p
	)

# Illumination fraction: 0 = new moon (sun side away), 1 = full moon.
static func _illumination_fraction(sun_direction: Vector3, moon_direction: Vector3) -> float:
	# Angle between the two as seen from observer.
	var cos_angle: float = clampf(sun_direction.dot(moon_direction), -1.0, 1.0)
	# At cos = -1 (opposite) → full moon. At cos = +1 (same direction) → new moon.
	return (1.0 - cos_angle) * 0.5

# Public API — used by World.get_sun_direction() etc.
func get_sun_direction() -> Vector3:
	# Convention used by TerrainGenerator etc.: direction FROM sun TO
	# observer (i.e. the light-propagation direction). Our sun_dir
	# points FROM observer TO sun, so negate for that interface.
	return -sun_dir
