extends RefCounted
## SkyModel — shared sky geometry and sky-brightness maths.
##
## Pure static functions used by the StarField (what the eye sees) and
## the telescope (what the CCD sees), so both agree on where every star
## is and how bright the sky behind it is.
##
## Frames: equatorial cartesian is x→(RA 0, Dec 0), y→(RA 6h, Dec 0),
## z→north celestial pole. The local horizon frame is the Godot one used
## by CoordinateTransforms: +Y up, +X east, −Z north.

const CoordinateTransforms = preload("res://astronomy/CoordinateTransforms.gd")

# Zenith twilight/daylight sky surface brightness (V mag/arcsec²) vs sun
# altitude (deg). Typical clear-sky luminances: day ~10⁴ cd/m², civil
# dusk ~1 cd/m², nautical ~10⁻² cd/m², converted with
# S = 12.58 − 2.5 log10(L). Below −18° the twilight term vanishes and
# the catalog's dark-sky value takes over.
const TWILIGHT_ALT: PackedFloat32Array = [-18.0, -12.0, -6.0, 0.0, 10.0, 30.0]
const TWILIGHT_MAG: PackedFloat32Array = [25.5, 17.5, 12.0, 7.0, 4.0, 3.0]
# Full Luna-like moon near the zenith brightens the sky to ~18 V mag/arcsec².
const FULL_MOON_SKY_MAG: float = 18.0
const LUNA_ALBEDO: float = 0.12
const LUNA_ANGULAR_RADIUS: float = 0.00452

# ---------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------
## Basis that rotates equatorial unit vectors into the local horizon
## frame for a given local sidereal time and latitude.
static func equatorial_basis(lst_hours: float, latitude_deg: float) -> Basis:
	var phi: float = deg_to_rad(latitude_deg)
	var theta: float = lst_hours * PI / 12.0
	# Columns: where the (hour-angle frame) x' = meridian∩equator,
	# y' = east point, z = celestial pole land in Godot coordinates.
	var lat_part := Basis(
		Vector3(0.0, cos(phi), sin(phi)),
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, sin(phi), -cos(phi)))
	# Equatorial → hour-angle frame: rotate about the pole by −LST.
	return lat_part * Basis(Vector3(0.0, 0.0, 1.0), -theta)

static func lst_hours(jd: float, longitude_deg: float) -> float:
	return CoordinateTransforms.lmst_hours(jd, longitude_deg)

static func radec_to_unit(ra_rad: float, dec_rad: float) -> Vector3:
	return Vector3(cos(dec_rad) * cos(ra_rad), cos(dec_rad) * sin(ra_rad), sin(dec_rad))

static func unit_to_radec(u: Vector3) -> Vector2:
	return Vector2(fposmod(atan2(u.y, u.x), TAU), asin(clampf(u.z, -1.0, 1.0)))

static func radec_to_dir(ra_rad: float, dec_rad: float, lst: float, lat_deg: float) -> Vector3:
	return equatorial_basis(lst, lat_deg) * radec_to_unit(ra_rad, dec_rad)

static func dir_to_radec(dir: Vector3, lst: float, lat_deg: float) -> Vector2:
	return unit_to_radec(equatorial_basis(lst, lat_deg).transposed() * dir.normalized())

## Kasten & Young (1989) airmass; capped below the horizon.
static func airmass(alt_rad: float) -> float:
	var h: float = rad_to_deg(alt_rad)
	if h <= -1.0:
		return 40.0
	return minf(1.0 / (sin(deg_to_rad(maxf(h, 0.0))) + 0.50572 * pow(maxf(h, 0.0) + 6.07995, -1.6364)), 40.0)

# ---------------------------------------------------------------------
# Snapshot of the engine state (plain data, safe to hand to a thread)
# ---------------------------------------------------------------------
static func snapshot(engine) -> Dictionary:
	var jd: float = engine.current_jd
	var lst: float = lst_hours(jd, engine.observer_longitude_deg)
	return {
		"jd": jd,
		"lst": lst,
		"lat": float(engine.observer_latitude_deg),
		"lon": float(engine.observer_longitude_deg),
		"sun_alt_deg": rad_to_deg(asin(clampf(engine.sun_dir.y, -1.0, 1.0))),
		"moons": [
			{"phase": engine.moon1_phase, "alt_deg": rad_to_deg(asin(clampf(engine.moon1_dir.y, -1.0, 1.0))),
			 "albedo": engine.moon1_albedo, "ang_radius": engine.moon1_angular_radius},
			{"phase": engine.moon2_phase, "alt_deg": rad_to_deg(asin(clampf(engine.moon2_dir.y, -1.0, 1.0))),
			 "albedo": engine.moon2_albedo, "ang_radius": engine.moon2_angular_radius},
		],
	}

# ---------------------------------------------------------------------
# Sky brightness
# ---------------------------------------------------------------------
static func _flux(mag: float) -> float:
	return pow(10.0, -0.4 * mag)

static func twilight_mag(sun_alt_deg: float) -> float:
	var n: int = TWILIGHT_ALT.size()
	if sun_alt_deg <= TWILIGHT_ALT[0]:
		return TWILIGHT_MAG[0] + (TWILIGHT_ALT[0] - sun_alt_deg)   # keeps fading
	if sun_alt_deg >= TWILIGHT_ALT[n - 1]:
		return TWILIGHT_MAG[n - 1]
	for i in range(1, n):
		if sun_alt_deg <= TWILIGHT_ALT[i]:
			var f: float = (sun_alt_deg - TWILIGHT_ALT[i - 1]) / (TWILIGHT_ALT[i] - TWILIGHT_ALT[i - 1])
			return lerpf(TWILIGHT_MAG[i - 1], TWILIGHT_MAG[i], f)
	return TWILIGHT_MAG[n - 1]

## Sky surface brightness (mag/arcsec²) in a band whose dark-sky value
## comes from the catalog, brightened by twilight and moonlight.
static func sky_mag_arcsec2(dark_mag: float, snap: Dictionary) -> float:
	var f: float = _flux(dark_mag) + _flux(twilight_mag(snap["sun_alt_deg"]))
	for m in snap["moons"]:
		var up: float = smoothstep(-2.0, 10.0, m["alt_deg"]) * sqrt(maxf(sin(deg_to_rad(m["alt_deg"])), 0.05))
		if up <= 0.0:
			continue
		var size: float = (float(m["albedo"]) / LUNA_ALBEDO) * pow(float(m["ang_radius"]) / LUNA_ANGULAR_RADIUS, 2.0)
		# Strong opposition surge: a quarter moon gives ~1/10 of full.
		f += _flux(FULL_MOON_SKY_MAG) * size * pow(float(m["phase"]), 3.0) * up
	return -2.5 * log(f) / log(10.0)

## Naked-eye limiting magnitude for a sky of `sky_v` V mag/arcsec²
## (Schaefer 1990-style fit: 6.5 under a 21.8 sky, ~3 in deep twilight).
static func naked_eye_limit(sky_v: float) -> float:
	return 7.93 - 5.0 * log(pow(10.0, 4.316 - sky_v / 5.0) + 1.0) / log(10.0)
