extends SceneTree
## CCD synthesis sanity test (headless, real catalog).
##   godot --headless --path . --script res://tests/test_ccd.gd
## Checks flux bookkeeping, target placement, day blow-out, determinism
## of the field stars, and reports the synthesis time.

const SkyCatalog = preload("res://telescope/SkyCatalog.gd")
const SkyModel = preload("res://telescope/SkyModel.gd")
const CCDSimulator = preload("res://telescope/CCDSimulator.gd")
const CoordinateTransforms = preload("res://astronomy/CoordinateTransforms.gd")

var _fail: int = 0

func _snap(jd: float, sun_alt: float) -> Dictionary:
	return {"jd": jd, "lst": SkyModel.lst_hours(jd, 0.0), "lat": 45.0, "lon": 0.0,
		"sun_alt_deg": sun_alt, "moons": []}

func _req(cat, star: int, snap: Dictionary, t: float, band: String = "V") -> Dictionary:
	return {"catalog": cat, "ra": cat.ra_rad[star], "dec": cat.dec_rad[star], "band": band,
		"exptime": t, "snap": snap, "npix": 256, "fov_deg": 1.0, "aperture_m": 0.08, "qe": 0.8,
		"seeing_arcsec": 2.5, "defocus_px": 2.5, "read_noise": 8.0, "full_well": 100000.0, "seed": 7}

func _initialize() -> void:
	var cat = SkyCatalog.new()
	if not cat.load_now():
		printerr("catalog: " + cat.error)
		quit(1)
		return
	var algol: int = cat.find_star("Algol")
	_check(algol >= 0, "Algol in catalog")
	var jd: float = CoordinateTransforms.julian_date(2026, 11, 10, 23.0)   # Algol high
	var snap := _snap(jd, -40.0)

	var t0: int = Time.get_ticks_msec()
	var f: Dictionary = CCDSimulator.synthesize(_req(cat, algol, snap, 0.05))
	var ms: int = Time.get_ticks_msec() - t0
	print("synthesis: %d ms, %d stars, X=%.2f, FWHM %.2f px, sky %.2f mag/arcsec2" % [ms, f["truth"].size(), f["airmass"], f["fwhm_px"], f["sky_mag"]])
	var tgt: Dictionary = f["truth"][0]
	for s in f["truth"]:
		if s["star"] == algol:
			tgt = s
	_check(tgt["star"] == algol, "Algol on chip")
	_check(absf(tgt["x"] - 127.5) < 0.01 and absf(tgt["y"] - 127.5) < 0.01, "target at chip centre (%.2f, %.2f)" % [tgt["x"], tgt["y"]])
	var expect: float = CCDSimulator.star_electrons(cat.star_mag_at(algol, "V", jd), cat.bands["V"], f["airmass"], f["area_m2"], 0.05, 0.8)
	_check(absf(tgt["e"] / expect - 1.0) < 1e-6, "Algol electrons")
	# Flux bookkeeping: total minus sky ≈ sum of on-chip star flux.
	var img: PackedFloat32Array = f["image"]
	var total: float = 0.0
	for v in img:
		total += v
	var stars_e: float = 0.0
	for s in f["truth"]:
		if s["x"] > 8 and s["y"] > 8 and s["x"] < 247 and s["y"] < 247:
			stars_e += s["e"]
	var excess: float = total - f["sky_e"] * img.size()
	print("excess %.0f e vs stars %.0f e (edge stars excluded from the sum)" % [excess, stars_e])
	_check(excess > 0.95 * stars_e and excess < 1.2 * stars_e, "flux conserved")
	_check(f["saturated_frac"] == 0.0, "50 ms Algol unsaturated")

	# Same pointing → same field stars.
	var f2: Dictionary = CCDSimulator.synthesize(_req(cat, algol, snap, 0.05))
	_check(f2["truth"].size() == f["truth"].size(), "deterministic field")

	# Daytime: blown out.
	var day: Dictionary = CCDSimulator.synthesize(_req(cat, algol, _snap(jd, 40.0), 1.0))
	_check(day["saturated_frac"] > 0.9, "daylight frame saturates (%.2f)" % day["saturated_frac"])

	print("PASS test_ccd" if _fail == 0 else "FAIL test_ccd (%d)" % _fail)
	quit(1 if _fail > 0 else 0)

func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("  FAIL: " + msg)
