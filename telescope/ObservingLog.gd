extends RefCounted
## ObservingLog — measurements on disk, plus period finding.
##
## user://observations/log.csv, one row per measurement:
##   jd,target,band,mag,err,airmass,exptime

const DIR: String = "user://observations"
const LOG_PATH: String = "user://observations/log.csv"
const HEADER: String = "jd,target,band,mag,err,airmass,exptime"

static func ensure_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)

static func append(jd: float, target: String, band: String, mag: float, err: float, airmass: float, exptime: float) -> void:
	ensure_dir()
	var new_file: bool = not FileAccess.file_exists(LOG_PATH)
	var f := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE if not new_file else FileAccess.WRITE)
	if f == null:
		push_warning("ObservingLog: cannot open %s" % LOG_PATH)
		return
	f.seek_end()
	if new_file:
		f.store_line(HEADER)
	f.store_line("%.6f,%s,%s,%.4f,%.4f,%.3f,%.4f" % [jd, target.replace(",", " "), band, mag, err, airmass, exptime])
	f.close()

## All rows as dictionaries.
static func read_all() -> Array:
	var out: Array = []
	if not FileAccess.file_exists(LOG_PATH):
		return out
	var f := FileAccess.open(LOG_PATH, FileAccess.READ)
	while not f.eof_reached():
		var line: String = f.get_line().strip_edges()
		if line == "" or line == HEADER:
			continue
		var c: PackedStringArray = line.split(",")
		if c.size() < 7:
			continue
		out.append({"jd": c[0].to_float(), "target": c[1], "band": c[2], "mag": c[3].to_float(),
			"err": c[4].to_float(), "airmass": c[5].to_float(), "exptime": c[6].to_float()})
	return out

# ---------------------------------------------------------------------
# Period search — Lafler–Kinman string length (1965).
# Sort the points by phase and add up the squared jumps between
# neighbours: the right period gives a smooth curve, so a short string.
# Unbinned, so narrow eclipses caught by a handful of points still count
# (binned PDM smears them across bin edges).
# ---------------------------------------------------------------------
## θ(P) = Σ(m_{i+1} − m_i)² / Σ(m_i − m̄)² over phase order (lower = better).
static func string_length(t: PackedFloat64Array, m: PackedFloat32Array, period: float, var_sum: float) -> float:
	var n: int = t.size()
	# Sort by phase natively: phase in the high bits, index in the low 12.
	var keys := PackedInt64Array()
	keys.resize(n)
	for i in n:
		keys[i] = (int(fposmod(t[i] / period, 1.0) * 1e9) << 12) | i
	keys.sort()
	var s: float = 0.0
	var prev: float = m[keys[n - 1] & 4095]
	for k in n:
		var cur: float = m[keys[k] & 4095]
		s += (cur - prev) * (cur - prev)
		prev = cur
	return s / var_sum

## Scans frequency uniformly between 1/p_max and 1/p_min. Returns
## {period, theta} plus the periodogram (θ at f0 + k·df) and candidates. Prefers the shortest period whose θ is within 10 %
## of the best, so integer multiples of the true period don't win.
static func period_search(t_in: PackedFloat64Array, m_in: PackedFloat32Array, p_min: float, p_max: float) -> Dictionary:
	var t: PackedFloat64Array = t_in.slice(0, 4096)
	var m: PackedFloat32Array = m_in.slice(0, 4096)
	var n: int = t.size()
	if n < 8:
		return {"period": 0.0, "theta": 1.0}
	var mean: float = 0.0
	var t_lo: float = INF
	var t_hi: float = -INF
	for i in n:
		mean += m[i]
		t_lo = minf(t_lo, t[i])
		t_hi = maxf(t_hi, t[i])
	mean /= n
	var var_sum: float = 0.0
	for i in n:
		var_sum += (m[i] - mean) * (m[i] - mean)
	if var_sum <= 0.0:
		return {"period": 0.0, "theta": 1.0}
	var f0: float = 1.0 / p_max
	var f1: float = 1.0 / p_min
	# Phase drifts by span·df across the data: keep that ≲ 1/100 cycle so
	# narrow eclipses are not stepped over.
	var df: float = 0.01 / maxf(t_hi - t_lo, 1.0)
	var nsteps: int = clampi(int((f1 - f0) / df), 100, 30000)
	df = (f1 - f0) / nsteps
	var thetas := PackedFloat32Array()
	thetas.resize(nsteps + 1)
	var best: float = INF
	for k in nsteps + 1:
		thetas[k] = string_length(t, m, 1.0 / (f0 + k * df), var_sum)
		best = minf(best, thetas[k])
	for k in range(nsteps, -1, -1):
		var th: float = thetas[k]
		var lo: bool = (k == 0 or th <= thetas[k - 1]) and (k == nsteps or th <= thetas[k + 1])
		if lo and th <= best * 1.1:
			# Refine around the grid minimum.
			var best_f: float = f0 + k * df
			for j in range(-10, 11):
				var ff: float = f0 + (k + j * 0.1) * df
				var tj: float = string_length(t, m, 1.0 / ff, var_sum)
				if tj < th:
					th = tj
					best_f = ff
			var out: Dictionary = {"period": 1.0 / best_f, "theta": th, "f0": f0, "df": df, "thetas": thetas}
			out["candidates"] = _candidates(thetas, f0, df, out["period"], th)
			return out
	return {"period": 0.0, "theta": 1.0}

## Up to 3 distinct periods [[P, θ], …]: the chosen one first, then the
## deepest other local minima more than 3 % away from those already kept.
static func _candidates(thetas: PackedFloat32Array, f0: float, df: float, p_best: float, th_best: float) -> Array:
	var mins: Array = []
	for k in range(1, thetas.size() - 1):
		if thetas[k] <= thetas[k - 1] and thetas[k] <= thetas[k + 1]:
			mins.append([1.0 / (f0 + k * df), thetas[k]])
	mins.sort_custom(func(a, b): return a[1] < b[1])
	var out: Array = [[p_best, th_best]]
	for m in mins:
		if out.size() >= 3:
			break
		var far: bool = true
		for o in out:
			far = far and absf(m[0] / o[0] - 1.0) > 0.03
		if far:
			out.append(m)
	return out
