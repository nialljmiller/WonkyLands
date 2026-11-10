extends RefCounted
## Photometry — centroid + aperture photometry on a CCD frame.
##
## Frame layout as CCDSimulator: row-major, row 0 = bottom, gain 1
## (values are electrons). Error from the CCD equation:
##   σ² = F + n_ap·(1 + n_ap/n_sky)·(sky + RN²)

const CCDSimulator = preload("res://telescope/CCDSimulator.gd")

## Background-subtracted first moment in a box, iterated.
static func centroid(img: PackedFloat32Array, n: int, p: Vector2, half: int = 5) -> Vector2:
	var c: Vector2 = p
	for _it in 3:
		var x0: int = clampi(int(round(c.x)) - half, 0, n - 1)
		var x1: int = clampi(int(round(c.x)) + half, 0, n - 1)
		var y0: int = clampi(int(round(c.y)) - half, 0, n - 1)
		var y1: int = clampi(int(round(c.y)) + half, 0, n - 1)
		var vals := PackedFloat32Array()
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				vals.append(img[y * n + x])
		vals.sort()
		var bg: float = vals[vals.size() / 2]
		var sw: float = 0.0
		var sx: float = 0.0
		var sy: float = 0.0
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var w: float = img[y * n + x] - bg
				if w > 0.0:
					sw += w
					sx += w * x
					sy += w * y
		if sw <= 0.0:
			return c
		c = Vector2(sx / sw, sy / sw)
	return c

## Aperture photometry at p. Returns electrons, error, sky, saturation.
static func measure(img: PackedFloat32Array, n: int, p: Vector2, r_ap: float, r_in: float, r_out: float,
		read_noise: float, full_well: float) -> Dictionary:
	var ap_sum: float = 0.0
	var n_ap: int = 0
	var sky := PackedFloat32Array()
	var sat: bool = false
	var R: int = int(ceil(r_out))
	for y in range(maxi(int(p.y) - R, 0), mini(int(p.y) + R + 1, n)):
		for x in range(maxi(int(p.x) - R, 0), mini(int(p.x) + R + 1, n)):
			var d: float = Vector2(x, y).distance_to(p)
			var v: float = img[y * n + x]
			if d <= r_ap:
				ap_sum += v
				n_ap += 1
				if v >= full_well * 0.999:
					sat = true
			elif d >= r_in and d <= r_out:
				sky.append(v)
	if sky.is_empty() or n_ap == 0:
		return {"ok": false}
	sky.sort()
	var sky_px: float = sky[sky.size() / 2]
	var flux: float = ap_sum - n_ap * sky_px
	var var_e: float = maxf(flux, 0.0) + n_ap * (1.0 + float(n_ap) / sky.size()) * (maxf(sky_px, 0.0) + read_noise * read_noise)
	return {"ok": true, "x": p.x, "y": p.y, "flux": flux, "err": sqrt(var_e), "sky": sky_px,
		"n_ap": n_ap, "n_sky": sky.size(), "saturated": sat,
		"r_ap": r_ap, "r_in": r_in, "r_out": r_out}

## Full measurement at a click: centroid, aperture sized from the FWHM,
## instrumental and calibrated magnitudes using the frame's zero point,
## exposure, aperture area and extinction × airmass.
static func measure_frame(frame: Dictionary, band: Dictionary, click: Vector2) -> Dictionary:
	var img: PackedFloat32Array = frame["image"]
	var n: int = frame["npix"]
	var fwhm: float = frame["fwhm_px"]
	var c: Vector2 = centroid(img, n, click, maxi(4, int(ceil(fwhm * 1.5))))
	var r_ap: float = maxf(2.0 * fwhm, 3.0)
	var m: Dictionary = measure(img, n, c, r_ap, r_ap + 3.0, r_ap + 3.0 + maxf(2.0 * fwhm, 4.0),
		frame["read_noise"], frame["full_well"])
	if not m.get("ok", false):
		return m
	var flux: float = m["flux"]
	m["snr"] = flux / maxf(m["err"], 1e-9)
	if flux <= 0.0:
		m["ok"] = false
		return m
	m["mag_err"] = 1.0857 * m["err"] / flux
	m["inst_mag"] = -2.5 * log(flux / frame["exptime"]) / log(10.0)
	m["mag"] = CCDSimulator.electrons_to_mag(flux, band, frame["airmass"], frame["area_m2"], frame["exptime"], frame["qe"])
	# Nearest synthesised star — for naming what was clicked.
	var best: float = 3.0
	m["name"] = ""
	m["star"] = -1
	for s in frame["truth"]:
		var d: float = Vector2(s["x"], s["y"]).distance_to(c)
		if d < best:
			best = d
			m["name"] = s["name"]
			m["star"] = s["star"]
			m["true_mag"] = s["mag"]
	return m

## Differential magnitude target − comparison, same frame (extinction,
## exposure and zero point cancel). Error adds in quadrature.
static func differential(t: Dictionary, c: Dictionary) -> Vector2:
	var dm: float = -2.5 * log(t["flux"] / c["flux"]) / log(10.0)
	return Vector2(dm, sqrt(pow(t["mag_err"], 2.0) + pow(c["mag_err"], 2.0)))
