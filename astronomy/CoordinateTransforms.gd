extends RefCounted
## Pure-math coordinate transforms for astronomy.
##
## All angles stored in radians internally unless suffixed _deg or _hours.
## RA (right ascension): celestial longitude, 0–2π (or 0–24h).
## Dec (declination):    celestial latitude,  -π/2 to +π/2.
## Alt (altitude):       angle above horizon, -π/2 to +π/2.
## Az (azimuth):         angle from north clockwise, 0–2π.
##
## Julian Date (JD) is the standard astronomical timekeeping scalar —
## continuous days since noon UT Jan 1, 4713 BC. J2000.0 epoch = JD
## 2451545.0 = 2000 Jan 1 12:00 UT, the reference for most formulae here.

const J2000_JD: float = 2451545.0
const SECONDS_PER_DAY: float = 86400.0

# ---------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------
# Standard Fliegel–Van Flandern formula for Julian Date from Gregorian.
# hours is the fractional hour-of-day (0..24, UT).
static func julian_date(year: int, month: int, day: int, hours: float) -> float:
	var a: int = (14 - month) / 12
	var y: int = year + 4800 - a
	var m: int = month + 12 * a - 3
	var jdn: int = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
	return float(jdn) + (hours - 12.0) / 24.0

# Greenwich Mean Sidereal Time in hours (0..24) at a given JD.
# IAU 1982 formula, accurate to < 1 second for the J2000 era.
static func gmst_hours(jd: float) -> float:
	var d: float = jd - J2000_JD
	var gmst: float = 18.697374558 + 24.06570982441908 * d
	return fposmod(gmst, 24.0)

# Local Mean Sidereal Time in hours for an observer at a given longitude
# (positive east, negative west).
static func lmst_hours(jd: float, longitude_deg: float) -> float:
	return fposmod(gmst_hours(jd) + longitude_deg / 15.0, 24.0)

# Obliquity of the ecliptic in radians (angle between equator and ecliptic).
# Slowly changing; for J2000 era linear approximation is fine.
static func obliquity_rad(jd: float) -> float:
	var t: float = (jd - J2000_JD) / 36525.0  # Julian centuries from J2000
	return deg_to_rad(23.4392911 - 0.0130042 * t)

# ---------------------------------------------------------------------
# Coordinate transforms
# ---------------------------------------------------------------------
# Equatorial (RA, Dec) → horizontal (altitude, azimuth) for observer at
# given latitude and LST. All inputs in radians except lst_hours.
# Returns Vector2(alt_rad, az_rad).
static func equatorial_to_horizontal(ra_rad: float, dec_rad: float, lst_hours: float, latitude_rad: float) -> Vector2:
	var ha: float = lst_hours * PI / 12.0 - ra_rad   # local hour angle
	var sin_alt: float = sin(dec_rad) * sin(latitude_rad) + cos(dec_rad) * cos(latitude_rad) * cos(ha)
	sin_alt = clampf(sin_alt, -1.0, 1.0)
	var alt: float = asin(sin_alt)
	var y: float = -cos(dec_rad) * sin(ha)
	var x: float = sin(dec_rad) - sin(latitude_rad) * sin_alt
	x = x / maxf(cos(latitude_rad), 1e-10)
	var az: float = atan2(y, x)
	if az < 0.0:
		az += TAU
	return Vector2(alt, az)

# Horizontal (alt, az) → Godot direction vector in the observer's local
# tangent frame. Convention: +Y = up, +X = east, -Z = north (matches
# Godot's "forward is -Z" world).
static func horizontal_to_direction(alt_rad: float, az_rad: float) -> Vector3:
	# az is measured from north, clockwise through east.
	var x: float = cos(alt_rad) * sin(az_rad)          # east component
	var z: float = -cos(alt_rad) * cos(az_rad)         # -Z is north
	var y: float = sin(alt_rad)
	return Vector3(x, y, z).normalized()

# Ecliptic (λ longitude, β latitude) → equatorial (RA, Dec). All radians.
static func ecliptic_to_equatorial(lambda_rad: float, beta_rad: float, obliquity_rad_val: float) -> Vector2:
	var sin_e: float = sin(obliquity_rad_val)
	var cos_e: float = cos(obliquity_rad_val)
	var sin_dec: float = sin(beta_rad) * cos_e + cos(beta_rad) * sin_e * sin(lambda_rad)
	sin_dec = clampf(sin_dec, -1.0, 1.0)
	var dec: float = asin(sin_dec)
	var y: float = sin(lambda_rad) * cos_e - tan(beta_rad) * sin_e
	var x: float = cos(lambda_rad)
	var ra: float = atan2(y, x)
	if ra < 0.0:
		ra += TAU
	return Vector2(ra, dec)

# ---------------------------------------------------------------------
# Kepler's equation
# ---------------------------------------------------------------------
# Solve M = E - e·sin(E) for E (eccentric anomaly) via Newton-Raphson.
static func solve_kepler(mean_anomaly_rad: float, eccentricity: float, tolerance: float = 1e-8, max_iter: int = 15) -> float:
	var e: float = eccentricity
	var m: float = fposmod(mean_anomaly_rad, TAU)
	# Good initial guess
	var ecc_anom: float = m if e < 0.8 else PI
	for _i in range(max_iter):
		var delta: float = (ecc_anom - e * sin(ecc_anom) - m) / (1.0 - e * cos(ecc_anom))
		ecc_anom -= delta
		if absf(delta) < tolerance:
			break
	return ecc_anom

# True anomaly ν from eccentric anomaly E.
static func true_anomaly(ecc_anom_rad: float, eccentricity: float) -> float:
	var e: float = eccentricity
	return 2.0 * atan2(
		sqrt(1.0 + e) * sin(ecc_anom_rad * 0.5),
		sqrt(1.0 - e) * cos(ecc_anom_rad * 0.5)
	)
