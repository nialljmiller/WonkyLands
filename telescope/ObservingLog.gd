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
# Period search — phase-dispersion minimisation (Stellingwerf 1978).
# ---------------------------------------------------------------------
## θ(P) = pooled within-bin variance / total variance (lower = better).
static func pdm_theta(t: PackedFloat64Array, m: PackedFloat32Array, period: float, nbins: int = 20) -> float:
	var n: int = t.size()
	var sum := PackedFloat64Array(); sum.resize(nbins); sum.fill(0.0)
	var sum2 := PackedFloat64Array(); sum2.resize(nbins); sum2.fill(0.0)
	var cnt := PackedInt32Array(); cnt.resize(nbins); cnt.fill(0)
	var tot: float = 0.0
	var tot2: float = 0.0
	for i in n:
		var b: int = int(fposmod(t[i] / period, 1.0) * nbins) % nbins
		sum[b] += m[i]
		sum2[b] += m[i] * m[i]
		cnt[b] += 1
		tot += m[i]
		tot2 += m[i] * m[i]
	var var_tot: float = (tot2 - tot * tot / n) / maxf(n - 1, 1)
	if var_tot <= 0.0:
		return 1.0
	var s: float = 0.0
	var dof: int = 0
	for b in nbins:
		if cnt[b] > 1:
			s += sum2[b] - sum[b] * sum[b] / cnt[b]
			dof += cnt[b] - 1
	if dof <= 0:
		return 1.0
	return (s / dof) / var_tot

## Scans frequency uniformly between 1/p_max and 1/p_min. Returns
## {period, theta}. Prefers the shortest period whose θ is within 10 %
## of the best, so integer multiples of the true period don't win.
static func pdm_search(t: PackedFloat64Array, m: PackedFloat32Array, p_min: float, p_max: float) -> Dictionary:
	if t.size() < 8:
		return {"period": 0.0, "theta": 1.0}
	var span: float = t[t.size() - 1] - t[0]
	for i in t.size():
		span = maxf(span, absf(t[i] - t[0]))
	var f0: float = 1.0 / p_max
	var f1: float = 1.0 / p_min
	# Phase drifts by span·df across the data: keep that ≲ 1/50 cycle so
	# narrow eclipses are not stepped over.
	var df: float = 0.02 / maxf(span, 1.0)
	var nb: int = clampi(t.size() / 8, 10, 40)
	var nsteps: int = clampi(int((f1 - f0) / df), 100, 40000)
	df = (f1 - f0) / nsteps
	var thetas := PackedFloat32Array(); thetas.resize(nsteps + 1)
	var best_theta: float = INF
	for k in nsteps + 1:
		var th: float = pdm_theta(t, m, 1.0 / (f0 + k * df), nb)
		thetas[k] = th
		best_theta = minf(best_theta, th)
	# Highest-frequency (shortest-period) local minimum near the best.
	for k in range(nsteps, -1, -1):
		var th: float = thetas[k]
		var lo: bool = (k == 0 or th <= thetas[k - 1]) and (k == nsteps or th <= thetas[k + 1])
		if lo and th <= best_theta * 1.1:
			return {"period": _refine(t, m, f0 + k * df, df, nb), "theta": th}
	return {"period": 0.0, "theta": 1.0}

static func _refine(t: PackedFloat64Array, m: PackedFloat32Array, f: float, df: float, nb: int) -> float:
	var best_f: float = f
	var best_th: float = pdm_theta(t, m, 1.0 / f, nb)
	for k in range(-20, 21):
		var ff: float = f + k * df / 10.0
		var th: float = pdm_theta(t, m, 1.0 / ff, nb)
		if th < best_th:
			best_th = th
			best_f = ff
	return 1.0 / best_f
