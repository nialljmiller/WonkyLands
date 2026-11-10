extends SceneTree
## Photometry + FITS round trip (headless, real catalog).
##   godot --headless --path . --script res://tests/test_photometry.gd
## Synthesises an Algol frame, measures Algol and a comparison, checks
## the calibrated magnitude recovers the catalog value within errors,
## writes FITS + truth sidecar (verified separately by
## tests/verify_fits.py with astropy) and exercises the CSV log and the
## period search on a synthetic Algol light curve.

const SkyCatalog = preload("res://telescope/SkyCatalog.gd")
const SkyModel = preload("res://telescope/SkyModel.gd")
const CCDSimulator = preload("res://telescope/CCDSimulator.gd")
const Photometry = preload("res://telescope/Photometry.gd")
const ObservingLog = preload("res://telescope/ObservingLog.gd")
const TelescopePanel = preload("res://telescope/TelescopePanel.gd")
const CoordinateTransforms = preload("res://astronomy/CoordinateTransforms.gd")

# Kept apart from the player's own user://observations.
const TEST_DIR: String = "user://test_observations"

var _fail: int = 0

func _initialize() -> void:
	var cat = SkyCatalog.new()
	if not cat.load_now():
		printerr(cat.error)
		quit(1)
		return
	var algol: int = cat.find_star("Algol")
	var jd: float = CoordinateTransforms.julian_date(2026, 11, 10, 23.0)
	var snap: Dictionary = {"jd": jd, "lst": SkyModel.lst_hours(jd, 0.0), "lat": 45.0, "lon": 0.0, "sun_alt_deg": -40.0, "moons": []}
	for band in ["V", "B", "i"]:
		var f: Dictionary = CCDSimulator.synthesize({"catalog": cat, "ra": cat.ra_rad[algol], "dec": cat.dec_rad[algol],
			"band": band, "exptime": 0.05, "snap": snap, "npix": 256, "fov_deg": 1.0, "aperture_m": 0.08, "qe": 0.8,
			"seeing_arcsec": 2.5, "defocus_px": 2.5, "read_noise": 8.0, "full_well": 100000.0, "seed": 11})
		f["target"] = {"name": "Algol", "star": algol}
		var m: Dictionary = Photometry.measure_frame(f, cat.bands[band], Vector2(126.0, 129.0))
		var truth: float = cat.star_mag_at(algol, band, jd)
		print("%s: Algol measured %.4f ± %.4f, truth %.4f, centroid (%.2f, %.2f), S/N %.0f" % [band, m["mag"], m["mag_err"], truth, m["x"], m["y"], m["snr"]])
		_check(m["name"] == "Algol", "clicked star identified")
		_check(Vector2(m["x"], m["y"]).distance_to(Vector2(127.5, 127.5)) < 0.1, "centroid")
		# Aperture 2×FWHM holds ~99.9% of a Gaussian: allow 5σ + 0.01 mag.
		_check(absf(m["mag"] - truth) < 5.0 * m["mag_err"] + 0.01, "%s calibrated mag" % band)
		if band == "V":
			# Differential vs the brightest other unsaturated star on chip.
			var other: Dictionary = {}
			for s in f["truth"]:
				if s["star"] != algol and s["x"] > 20 and s["x"] < 235 and s["y"] > 20 and s["y"] < 235 and (other.is_empty() or s["e"] > other["e"]):
					other = s
			var c: Dictionary = Photometry.measure_frame(f, cat.bands[band], Vector2(other["x"], other["y"]))
			var d: Vector2 = Photometry.differential(m, c)
			print("  diff vs %s (%.2f): %.4f ± %.4f, truth %.4f" % [c["name"], other["mag"], d.x, d.y, truth - other["mag"]])
			_check(absf(d.x - (truth - other["mag"])) < 5.0 * d.y + 0.02, "differential mag")
			var path: String = TelescopePanel.write_frame_fits(f, cat, TEST_DIR)
			_check(path != "", "FITS written")
			print("FITS ", ProjectSettings.globalize_path(path))
			var bytes: int = FileAccess.get_file_as_bytes(path).size()
			_check(bytes % 2880 == 0, "FITS size multiple of 2880 (%d)" % bytes)

	# A deep blank-ish field (no catalog star at the centre) for the
	# FITS check of many faint stars.
	var deep: Dictionary = CCDSimulator.synthesize({"catalog": cat, "ra": cat.ra_rad[algol] + 0.03, "dec": cat.dec_rad[algol] + 0.02,
		"band": "R", "exptime": 30.0, "snap": snap, "npix": 256, "fov_deg": 1.0, "aperture_m": 0.08, "qe": 0.8,
		"seeing_arcsec": 2.5, "defocus_px": 2.5, "read_noise": 8.0, "full_well": 100000.0, "seed": 5})
	deep["target"] = {"name": "Deep field", "star": -1}
	print("FITS ", ProjectSettings.globalize_path(TelescopePanel.write_frame_fits(deep, cat, TEST_DIR)))

	# Period search on a synthetic Algol light curve sampled at night-ish times.
	var vi: int = cat.variable_of_star(algol)
	var period_true: float = float(cat.variables[vi]["period_days"])
	var t := PackedFloat64Array()
	var mags := PackedFloat32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var tt: float = jd
	while t.size() < 160:
		tt += 0.02 + (0.6 if fposmod(tt, 1.0) > 0.3 else 0.0) * rng.randf()   # gaps
		t.append(tt)
		mags.append(cat.star_mag_at(algol, "V", tt) + rng.randfn(0.0, 0.01))
	var t0: int = Time.get_ticks_msec()
	var res: Dictionary = ObservingLog.period_search(t, mags, 0.5, 10.0)
	print("period search: best %.4f d (true %.4f), theta %.3f, %d ms" % [res["period"], period_true, res["theta"], Time.get_ticks_msec() - t0])
	_check(absf(res["period"] / period_true - 1.0) < 0.005, "period search recovers Algol period")

	print("PASS test_photometry" if _fail == 0 else "FAIL test_photometry (%d)" % _fail)
	quit(1 if _fail > 0 else 0)

func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("  FAIL: " + msg)
