extends RefCounted
## SkyCatalog — the star catalog baked by SED_Tools (data/sky_catalog.json).
##
## Loaded once per run, on a WorkerThreadPool task, so the ~3 MB JSON
## parse never lands on a frame. Everyone (StarField, telescope) shares
## the same instance via SkyCatalog.shared() and waits on `loaded`.
##
## All photometric numbers (zero points, sky brightness, extinction,
## colours, light curves) come from the file; this script only reshapes
## them into packed arrays for fast lookups.

signal loaded

const DEFAULT_PATH: String = "res://data/sky_catalog.json"

static var _shared = null
# Optional override (tests, or `-- --sky-catalog=/path.json` on the CLI).
static var path_override: String = ""

var is_loaded: bool = false
var error: String = ""
var path: String = ""

var meta: Dictionary = {}
var stars: Array = []            # raw star dicts, sorted by V
var variables: Array = []
var field_templates: Array = []
var band_names: PackedStringArray = PackedStringArray()
var bands: Dictionary = {}       # band name -> meta band dict

# Packed per-star arrays (same order as `stars`).
var ra_rad: PackedFloat64Array = PackedFloat64Array()
var dec_rad: PackedFloat64Array = PackedFloat64Array()
var vmag: PackedFloat32Array = PackedFloat32Array()
var unit_eq: PackedVector3Array = PackedVector3Array()   # equatorial unit vectors
var named_indices: PackedInt32Array = PackedInt32Array()
var variable_star_index: PackedInt32Array = PackedInt32Array()  # variable i -> star index
# Field-star support: the catalog's faint limit (field stars start
# there), how deep the telescope's synthetic field goes (a cost knob,
# not physics), and for every catalog star the nearest field template,
# so field colours follow the catalog's own Teff/logg mix.
var faintest_v: float = 6.5
var field_v_max: float = 16.0
var template_for_star: PackedInt32Array = PackedInt32Array()

var _task_id: int = -1

static func shared():
	if _shared == null:
		_shared = load("res://telescope/SkyCatalog.gd").new()
		_shared.start_async()
	return _shared

static func resolve_path() -> String:
	if path_override != "":
		return path_override
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sky-catalog="):
			return a.trim_prefix("--sky-catalog=")
	return DEFAULT_PATH

func start_async() -> void:
	path = resolve_path()
	if not FileAccess.file_exists(path):
		error = "sky catalog not found at %s — sky runs without stars" % path
		push_warning("SkyCatalog: " + error)
		return
	_task_id = WorkerThreadPool.add_task(_load_worker, false, "SkyCatalog load")

## Synchronous load for tests and tools.
func load_now(p: String = "") -> bool:
	path = p if p != "" else resolve_path()
	_parse(path)
	is_loaded = error == ""
	return is_loaded

func _load_worker() -> void:
	_parse(path)
	call_deferred("_finish")

func _finish() -> void:
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	if error != "":
		push_warning("SkyCatalog: " + error)
		return
	is_loaded = true
	loaded.emit()

func _parse(p: String) -> void:
	var text: String = FileAccess.get_file_as_string(p)
	if text == "":
		error = "could not read %s" % p
		return
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or not data.has("stars"):
		error = "malformed catalog %s" % p
		return
	meta = data.get("meta", {})
	stars = data.get("stars", [])
	variables = data.get("variables", [])
	field_templates = data.get("field_templates", [])
	for b in meta.get("bands", []):
		band_names.append(String(b["name"]))
		bands[String(b["name"])] = b
	var n: int = stars.size()
	ra_rad.resize(n)
	dec_rad.resize(n)
	vmag.resize(n)
	unit_eq.resize(n)
	for i in n:
		var s: Dictionary = stars[i]
		var ra: float = deg_to_rad(float(s["ra_deg"]))
		var dec: float = deg_to_rad(float(s["dec_deg"]))
		ra_rad[i] = ra
		dec_rad[i] = dec
		vmag[i] = float(s["mags"].get("V", 99.0))
		unit_eq[i] = Vector3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
		if String(s.get("name", "")) != "":
			named_indices.append(i)
	faintest_v = vmag[n - 1] if n > 0 else 6.5
	for i in n:
		if vmag[i] < 50.0:
			faintest_v = maxf(faintest_v, vmag[i])
	_match_templates()
	variable_star_index.resize(variables.size())
	variable_star_index.fill(-1)
	for i in n:
		var v = stars[i].get("var")
		if v != null and int(v) >= 0 and int(v) < variables.size():
			variable_star_index[int(v)] = i

func _match_templates() -> void:
	template_for_star.resize(stars.size())
	template_for_star.fill(0)
	if field_templates.is_empty():
		return
	for i in stars.size():
		var lt: float = log(maxf(float(stars[i].get("teff", 5800.0)), 1000.0))
		var lg: float = float(stars[i].get("logg", 4.0))
		var best: int = 0
		var best_d: float = INF
		for k in field_templates.size():
			var tp: Dictionary = field_templates[k]
			var d: float = pow((lt - log(float(tp["teff"]))) / 0.05, 2.0) + pow(lg - float(tp["logg"]), 2.0)
			if d < best_d:
				best_d = d
				best = k
		template_for_star[i] = best

# ---------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------
func star_name(i: int) -> String:
	var s: Dictionary = stars[i]
	var nm: String = String(s.get("name", ""))
	return nm if nm != "" else "HR %d" % int(s.get("hr", 0))

func star_mag(i: int, band: String) -> float:
	return float(stars[i]["mags"].get(band, 99.0))

## Star colour as a 0..1 Color (accepts either 0..1 or 0..255 rgb).
func star_color(i: int) -> Color:
	return rgb_to_color(stars[i].get("rgb", [1, 1, 1]))

static func rgb_to_color(rgb: Array) -> Color:
	if rgb.size() < 3:
		return Color.WHITE
	var r: float = float(rgb[0]); var g: float = float(rgb[1]); var b: float = float(rgb[2])
	if maxf(r, maxf(g, b)) > 1.0:
		r /= 255.0; g /= 255.0; b /= 255.0
	return Color(r, g, b)

func variable_of_star(i: int) -> int:
	var v = stars[i].get("var")
	return -1 if v == null else int(v)

## Magnitude offset of variable `vi` in `band` at Julian Date `jd`
## (+ = fainter), linearly interpolated in the catalog's phase table.
func variable_dmag(vi: int, band: String, jd: float) -> float:
	if vi < 0 or vi >= variables.size():
		return 0.0
	var v: Dictionary = variables[vi]
	var table: Array = v.get("dmag", {}).get(band, [])
	var n: int = table.size()
	if n == 0:
		return 0.0
	var phase: float = fposmod((jd - float(v["epoch_jd"])) / float(v["period_days"]), 1.0)
	var x: float = phase * n
	var i0: int = int(floor(x)) % n
	var f: float = x - floor(x)
	return lerpf(float(table[i0]), float(table[(i0 + 1) % n]), f)

## Current magnitude of star i in band (variables included).
func star_mag_at(i: int, band: String, jd: float) -> float:
	return star_mag(i, band) + variable_dmag(variable_of_star(i), band, jd)

func find_star(name_or_hr: String) -> int:
	var key: String = name_or_hr.strip_edges().to_lower()
	for i in named_indices:
		if String(stars[i]["name"]).to_lower() == key:
			return i
	if key.begins_with("hr "):
		var hr: int = int(key.substr(3))
		for i in stars.size():
			if int(stars[i].get("hr", -1)) == hr:
				return i
	return -1
