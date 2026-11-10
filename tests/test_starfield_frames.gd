extends SceneTree
## Frame-consistency test for the star field.
##   godot --headless --path . --script res://tests/test_starfield_frames.gd
##
## The StarField places stars by rotating equatorial unit vectors with a
## single basis (SkyModel.equatorial_basis). This checks that basis
## against CoordinateTransforms.equatorial_to_horizontal for Polaris and
## Vega (J2000 positions hard-coded, independent of the catalog), and
## that Polaris sits at altitude ≈ latitude, due north (−Z).

const CoordinateTransforms = preload("res://astronomy/CoordinateTransforms.gd")
const SkyModel = preload("res://telescope/SkyModel.gd")

const LAT: float = 45.0
const LON: float = 0.0
const STARS: Dictionary = {
	"Polaris": [37.954561, 89.264109],
	"Vega": [279.234735, 38.783689],
}

var _fail: int = 0

func _initialize() -> void:
	# Several epochs, including the astropy cross-check epoch.
	var jds: Array = [
		CoordinateTransforms.julian_date(2026, 6, 21, 0.0),
		CoordinateTransforms.julian_date(2026, 12, 1, 3.5),
		2451545.0 + 0.3,
	]
	for jd in jds:
		var lst: float = SkyModel.lst_hours(jd, LON)
		var basis: Basis = SkyModel.equatorial_basis(lst, LAT)
		for star_name in STARS:
			var ra: float = deg_to_rad(STARS[star_name][0])
			var dec: float = deg_to_rad(STARS[star_name][1])
			var a: Vector3 = basis * SkyModel.radec_to_unit(ra, dec)
			var hor: Vector2 = CoordinateTransforms.equatorial_to_horizontal(ra, dec, lst, deg_to_rad(LAT))
			var b: Vector3 = CoordinateTransforms.horizontal_to_direction(hor.x, hor.y)
			var sep_arcmin: float = rad_to_deg(a.angle_to(b)) * 60.0
			var alt: float = rad_to_deg(asin(a.y))
			var az: float = fposmod(rad_to_deg(atan2(a.x, -a.z)), 360.0)
			print("JD %.4f  %-8s alt %7.3f az %8.3f  |basis - CT| = %.4f arcmin" % [jd, star_name, alt, az, sep_arcmin])
			_check(sep_arcmin < 1.0, "%s basis vs CoordinateTransforms %.4f' >= 1'" % [star_name, sep_arcmin])
			# Round trip back to RA/Dec.
			var rd: Vector2 = SkyModel.dir_to_radec(a, lst, LAT)
			var rt: float = rad_to_deg(SkyModel.radec_to_unit(rd.x, rd.y).angle_to(SkyModel.radec_to_unit(ra, dec))) * 3600.0
			_check(rt < 1.0, "%s RA/Dec round trip %.3f\" off" % [star_name, rt])
			if star_name == "Polaris":
				# Polaris is 0.74° from the pole: alt within that of the
				# latitude, azimuth within ~1.1° of north.
				_check(absf(alt - LAT) < 0.8, "Polaris alt %.3f not ≈ %.1f" % [alt, LAT])
				_check(minf(az, 360.0 - az) < 1.1, "Polaris az %.3f not ≈ 0 (north = -Z)" % az)
				_check(a.z < 0.0, "Polaris not on the -Z (north) side")
	# The north celestial pole itself must be exactly at alt = lat, az = 0.
	var pole: Vector3 = SkyModel.equatorial_basis(7.3, LAT) * Vector3(0, 0, 1)
	var expect: Vector3 = CoordinateTransforms.horizontal_to_direction(deg_to_rad(LAT), 0.0)
	_check(rad_to_deg(pole.angle_to(expect)) * 3600.0 < 0.1, "pole misplaced")
	if _fail == 0:
		print("PASS test_starfield_frames")
	else:
		print("FAIL test_starfield_frames (%d)" % _fail)
	quit(1 if _fail > 0 else 0)

func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("  FAIL: " + msg)
