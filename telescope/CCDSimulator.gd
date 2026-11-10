extends RefCounted
## CCDSimulator — synthesises one CCD frame from the catalog.
##
## Pure function of a plain-data request (safe on a WorkerThreadPool
## thread; the catalog is only read). Physics:
##   electrons = zp_photons_s_m2 · 10^(−0.4 (m + k·X)) · area · t · QE
## with zp, k and dark-sky brightness from the catalog's band metadata,
## a pixel-integrated Gaussian PSF (seeing degrading with airmass, plus
## the telescope's deliberate defocus), sky from SkyModel (dark sky +
## twilight + moonlight), Poisson + read noise, and full-well clipping.
##
## Image layout: row-major, row 0 = BOTTOM (FITS order), north up, east
## left. Pixel (x, y) are 0-based with pixel centres at integers.

const SkyModel = preload("res://telescope/SkyModel.gd")

const ARCSEC_PER_RAD: float = 206264.806

# Galactic north pole (J2000) for the field-star latitude term.
const NGP_RA_DEG: float = 192.85948
const NGP_DEC_DEG: float = 27.12825
# Field-star tiles: deterministic per patch of sky, so re-pointing
# shows the same faint stars.
const TILE_DEG: float = 0.5

## QE to apply: the catalog's g/r/i curves already include the detector
## ("curve_components" contains "qe"), the Johnson ones don't.
static func effective_qe(band: Dictionary, qe: float) -> float:
	return 1.0 if String(band.get("curve_components", "")).find("qe") >= 0 else qe

## Photo-electrons collected from a star of magnitude m.
static func star_electrons(m: float, band: Dictionary, airmass: float, area_m2: float, exptime: float, qe: float) -> float:
	return float(band["zp_photons_s_m2"]) * pow(10.0, -0.4 * (m + float(band["extinction_k"]) * airmass)) \
		* area_m2 * exptime * effective_qe(band, qe)

## Inverse: calibrated magnitude from measured electrons.
static func electrons_to_mag(e: float, band: Dictionary, airmass: float, area_m2: float, exptime: float, qe: float) -> float:
	var norm: float = float(band["zp_photons_s_m2"]) * area_m2 * exptime * effective_qe(band, qe)
	return -2.5 * log(maxf(e, 1e-9) / norm) / log(10.0) - float(band["extinction_k"]) * airmass

## req keys: catalog, ra, dec (rad), band (name), exptime, snap
## (SkyModel.snapshot), npix, fov_deg, aperture_m, qe, seeing_arcsec,
## defocus_px, read_noise, full_well, seed.
static func synthesize(req: Dictionary) -> Dictionary:
	var cat = req["catalog"]
	var band_name: String = req["band"]
	var band: Dictionary = cat.bands[band_name]
	var snap: Dictionary = req["snap"]
	var n: int = int(req["npix"])
	var scale_rad: float = deg_to_rad(float(req["fov_deg"])) / n         # rad / px
	var scale_as: float = scale_rad * ARCSEC_PER_RAD
	var ra0: float = req["ra"]
	var dec0: float = req["dec"]
	var t: float = req["exptime"]
	var area: float = PI * pow(float(req["aperture_m"]) * 0.5, 2.0)
	var qe: float = req["qe"]
	var jd: float = snap["jd"]

	var center: Vector3 = SkyModel.radec_to_unit(ra0, dec0)
	var dir: Vector3 = SkyModel.equatorial_basis(snap["lst"], snap["lat"]) * center
	var alt: float = asin(clampf(dir.y, -1.0, 1.0))
	var X: float = SkyModel.airmass(alt)
	var seeing_px: float = float(req["seeing_arcsec"]) * pow(X, 0.6) / scale_as
	var fwhm_px: float = sqrt(seeing_px * seeing_px + pow(float(req["defocus_px"]), 2.0))
	var sigma: float = fwhm_px / 2.3548

	var sky_mag: float = SkyModel.sky_mag_arcsec2(float(band["sky_dark_mag_arcsec2"]), snap)
	var sky_e: float = star_electrons(sky_mag, band, 0.0, area, t, qe) * scale_as * scale_as

	var img := PackedFloat32Array()
	img.resize(n * n)
	img.fill(sky_e)
	var truth: Array = []
	var cx: float = (n - 1) * 0.5
	var half_fov: float = deg_to_rad(float(req["fov_deg"])) * 0.75   # covers the corners
	var cos_lim: float = cos(half_fov)

	# --- Catalog stars ---
	for i in cat.unit_eq.size():
		if cat.unit_eq[i].dot(center) < cos_lim:
			continue
		var p: Vector2 = _project(cat.ra_rad[i], cat.dec_rad[i], ra0, dec0, scale_rad, cx)
		var m: float = cat.star_mag_at(i, band_name, jd)
		var e: float = star_electrons(m, band, X, area, t, qe)
		if _add_star(img, n, p, e, sigma):
			truth.append({"x": p.x, "y": p.y, "mag": m, "e": e, "name": cat.star_name(i), "star": i})

	# --- Faint field stars from the luminosity function ---
	var field: Array = _field_stars(cat, ra0, dec0, half_fov)
	for f in field:
		var p: Vector2 = _project(f[0], f[1], ra0, dec0, scale_rad, cx)
		var tpl: Dictionary = cat.field_templates[f[3]]
		var m: float = f[2] + float(tpl["mags_minus_V"].get(band_name, 0.0))
		var e: float = star_electrons(m, band, X, area, t, qe)
		if _add_star(img, n, p, e, sigma):
			truth.append({"x": p.x, "y": p.y, "mag": m, "e": e, "name": "", "star": -1})

	# --- Noise + saturation ---
	var rng := RandomNumberGenerator.new()
	rng.seed = int(req["seed"])
	var rn: float = req["read_noise"]
	var well: float = req["full_well"]
	var saturated: int = 0
	for k in n * n:
		var lam: float = img[k]
		var v: float
		if lam < 25.0:
			v = _poisson_small(rng, lam)
		else:
			v = rng.randfn(lam, sqrt(lam))
		v += rng.randfn(0.0, rn)
		if v >= well:
			v = well
			saturated += 1
		img[k] = v

	return {
		"image": img, "npix": n, "truth": truth,
		"airmass": X, "alt_deg": rad_to_deg(alt), "fwhm_px": fwhm_px,
		"scale_arcsec": scale_as, "sky_mag": sky_mag, "sky_e": sky_e,
		"saturated_frac": float(saturated) / float(n * n),
		"ra": ra0, "dec": dec0, "band": band_name, "exptime": t, "jd": jd,
		"area_m2": area, "qe": qe, "full_well": well, "read_noise": rn,
		"lat": snap["lat"], "lon": snap["lon"],
	}

## Gnomonic (TAN) projection, east left / north up, row 0 = bottom.
static func _project(ra: float, dec: float, ra0: float, dec0: float, scale_rad: float, c: float) -> Vector2:
	var dra: float = ra - ra0
	var cosc: float = sin(dec0) * sin(dec) + cos(dec0) * cos(dec) * cos(dra)
	var xi: float = cos(dec) * sin(dra) / cosc
	var eta: float = (cos(dec0) * sin(dec) - sin(dec0) * cos(dec) * cos(dra)) / cosc
	return Vector2(c - xi / scale_rad, c + eta / scale_rad)

## Inverse of _project: pixel → (ra, dec) radians.
static func unproject(p: Vector2, ra0: float, dec0: float, scale_rad: float, c: float) -> Vector2:
	var xi: float = -(p.x - c) * scale_rad
	var eta: float = (p.y - c) * scale_rad
	var rho: float = sqrt(xi * xi + eta * eta)
	if rho < 1e-12:
		return Vector2(ra0, dec0)
	var cc: float = atan(rho)
	var dec: float = asin(cos(cc) * sin(dec0) + eta * sin(cc) * cos(dec0) / rho)
	var ra: float = ra0 + atan2(xi * sin(cc), rho * cos(dec0) * cos(cc) - eta * sin(dec0) * sin(cc))
	return Vector2(fposmod(ra, TAU), dec)

## Adds a pixel-integrated Gaussian; returns false if off the chip.
static func _add_star(img: PackedFloat32Array, n: int, p: Vector2, e: float, sigma: float) -> bool:
	if p.x < -3.0 or p.y < -3.0 or p.x > n + 2.0 or p.y > n + 2.0 or e <= 0.0:
		return false
	# Wider stamp for brighter stars so their wings aren't chopped.
	var r: int = int(ceil(sigma * clampf(3.0 + 0.5 * log(maxf(e, 1.0)) / log(10.0), 3.5, 7.0)))
	var x0: int = maxi(int(round(p.x)) - r, 0)
	var x1: int = mini(int(round(p.x)) + r, n - 1)
	var y0: int = maxi(int(round(p.y)) - r, 0)
	var y1: int = mini(int(round(p.y)) + r, n - 1)
	if x1 < x0 or y1 < y0:
		return false
	var k: float = 1.0 / (sigma * sqrt(2.0))
	var wx := PackedFloat32Array()
	wx.resize(x1 - x0 + 1)
	for x in range(x0, x1 + 1):
		wx[x - x0] = 0.5 * (_erf((x + 0.5 - p.x) * k) - _erf((x - 0.5 - p.x) * k))
	for y in range(y0, y1 + 1):
		var wy: float = e * 0.5 * (_erf((y + 0.5 - p.y) * k) - _erf((y - 0.5 - p.y) * k))
		if wy < 1e-4:
			continue
		var row: int = y * n
		for x in range(x0, x1 + 1):
			img[row + x] += wy * wx[x - x0]
	return true

## Abramowitz & Stegun 7.1.26 (|error| < 1.5e-7).
static func _erf(x: float) -> float:
	var s: float = signf(x)
	var a: float = absf(x)
	var t: float = 1.0 / (1.0 + 0.3275911 * a)
	var y: float = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-a * a)
	return s * y

static func _poisson_small(rng: RandomNumberGenerator, lam: float) -> float:
	if lam <= 0.0:
		return 0.0
	var l: float = exp(-lam)
	var k: int = 0
	var p: float = 1.0
	while true:
		p *= rng.randf()
		if p <= l:
			break
		k += 1
	return float(k)

# ---------------------------------------------------------------------
# Field stars
# ---------------------------------------------------------------------
## Galactic latitude (rad) of an equatorial position.
static func galactic_latitude(ra: float, dec: float) -> float:
	var ngp: Vector3 = SkyModel.radec_to_unit(deg_to_rad(NGP_RA_DEG), deg_to_rad(NGP_DEC_DEG))
	return asin(clampf(SkyModel.radec_to_unit(ra, dec).dot(ngp), -1.0, 1.0))

## Faint stars in every tile touching the field: [ra, dec, V, template].
## Counts follow meta.field_luminosity_function
##   log10 N(<V) [deg⁻²] = a + b·V + c·(1 − sin|b_gal|)
## from the catalog's faintest star down to `field_v_max`; colours come
## from field_templates, drawn with the catalog's own Teff/logg mix.
static func _field_stars(cat, ra0: float, dec0: float, radius: float) -> Array:
	var lf: Dictionary = cat.meta.get("field_luminosity_function", {})
	if lf.is_empty() or cat.field_templates.is_empty():
		return []
	var a: float = float(lf.get("a", -3.3))
	var b: float = float(lf.get("b", 0.4))
	var c: float = float(lf.get("c", 0.0))
	var valid: Array = lf.get("valid_v", [6.0, 20.0])
	var v_min: float = maxf(float(valid[0]), cat.faintest_v)
	var v_max: float = minf(float(valid[1]), cat.field_v_max)
	var out: Array = []
	var tile: float = deg_to_rad(TILE_DEG)
	var di0: int = int(floor((dec0 - radius + PI * 0.5) / tile))
	var di1: int = int(floor((dec0 + radius + PI * 0.5) / tile))
	for di in range(di0, di1 + 1):
		var dlo: float = di * tile - PI * 0.5
		var dhi: float = dlo + tile
		if dhi <= -PI * 0.5 or dlo >= PI * 0.5:
			continue
		dlo = maxf(dlo, -PI * 0.5)
		dhi = minf(dhi, PI * 0.5)
		var dmid: float = 0.5 * (dlo + dhi)
		var ncell: int = maxi(1, int(floor(TAU * cos(dmid) / tile)))
		var cell: float = TAU / ncell
		var span: float = radius / maxf(cos(maxf(absf(dlo), absf(dhi))), 1e-3)
		var cells: Array = []
		if span * 2.0 >= TAU or absf(dmid) + tile > PI * 0.5 - radius:
			cells = range(ncell)
		else:
			var j0: int = int(floor((ra0 - span) / cell))
			var j1: int = int(floor((ra0 + span) / cell))
			for j in range(j0, j1 + 1):
				cells.append(posmod(j, ncell))
		for j in cells:
			var rlo: float = j * cell
			var area_deg2: float = rad_to_deg(cell) * rad_to_deg(sin(dhi) - sin(dlo))
			var gb: float = galactic_latitude(rlo + cell * 0.5, dmid)
			var log_n_max: float = a + b * v_max + c * (1.0 - absf(sin(gb)))
			var log_n_min: float = a + b * v_min + c * (1.0 - absf(sin(gb)))
			var expected: float = (pow(10.0, log_n_max) - pow(10.0, log_n_min)) * area_deg2
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(Vector2i(di, j))
			var count: int = _poisson_count(rng, expected)
			var u_min: float = pow(10.0, b * (v_min - v_max))
			for _s in count:
				# Inverse CDF of N(<V) ∝ 10^(bV) between v_min and v_max.
				var v: float = v_max + log(rng.randf_range(u_min, 1.0)) / log(10.0) / b
				var ra: float = rlo + rng.randf() * cell
				var dec: float = asin(rng.randf_range(sin(dlo), sin(dhi)))
				var tpl: int = cat.template_for_star[rng.randi() % cat.template_for_star.size()]
				if SkyModel.radec_to_unit(ra, dec).dot(SkyModel.radec_to_unit(ra0, dec0)) >= cos(radius):
					out.append([ra, dec, v, tpl])
	return out

static func _poisson_count(rng: RandomNumberGenerator, lam: float) -> int:
	if lam > 30.0:
		return maxi(0, int(round(rng.randfn(lam, sqrt(lam)))))
	return int(_poisson_small(rng, lam))
