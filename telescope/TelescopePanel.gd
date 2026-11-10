extends PanelContainer
## TelescopePanel — the telescope's control screen.
##
## Pick a target (named stars above the horizon, variables marked, or
## "where I'm looking"), a filter from the catalog's bands and an
## exposure time, then Expose. The frame is synthesised on a worker
## thread (CCDSimulator) and shown with an asinh stretch.

signal closed

const SkyModel = preload("res://telescope/SkyModel.gd")
const CCDSimulator = preload("res://telescope/CCDSimulator.gd")
const FrameDisplay = preload("res://telescope/FrameDisplay.gd")

# The instrument. Not catalog physics — the kit the player owns.
@export var aperture_m: float = 0.08          # 80 mm refractor
@export var qe: float = 0.8
@export var seeing_arcsec: float = 2.5
## Deliberate defocus (px FWHM) so stars spread over a few of the
## 14″ pixels — what photometrists do with bright stars anyway.
@export var defocus_px: float = 2.5
@export var read_noise_e: float = 8.0
@export var full_well_e: float = 100000.0
@export var npix: int = 256
@export var fov_deg: float = 1.0

var engine = null
var catalog = null
var telescope: Node3D = null        # prop to slew
var look_dir_provider: Callable      # returns the camera's forward dir

var frame: Dictionary = {}           # last synthesised frame
var _targets: Array = []             # [{label, star(-1 = look), ra, dec}]
var _task: int = -1
var _pending_req: Dictionary = {}

var _target_opt: OptionButton
var _band_opt: OptionButton
var _exp_slider: HSlider
var _exp_label: Label
var _expose_btn: Button
var _status: Label
var _view: Control
var _tex_rect: TextureRect
var _info: RichTextLabel

func _ready() -> void:
	position = Vector2(16, 16)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.1, 0.88)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(12)
	add_theme_stylebox_override("panel", sb)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	add_child(h)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.custom_minimum_size = Vector2(330, 0)
	h.add_child(v)
	var title := Label.new()
	title.text = "TELESCOPE  ·  %d mm refractor  ·  %.0f′ field" % [int(aperture_m * 1000.0), fov_deg * 60.0]
	title.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	v.add_child(title)

	var row1 := HBoxContainer.new()
	v.add_child(row1)
	row1.add_child(_label("Target"))
	_target_opt = OptionButton.new()
	_target_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_opt.fit_to_longest_item = false
	row1.add_child(_target_opt)
	_target_opt.clip_text = true
	_target_opt.custom_minimum_size = Vector2(250, 0)
	var row1b := HBoxContainer.new()
	v.add_child(row1b)
	row1b.add_child(_label("Filter"))
	_band_opt = OptionButton.new()
	row1b.add_child(_band_opt)

	var row2 := HBoxContainer.new()
	v.add_child(row2)
	row2.add_child(_label("Exposure"))
	_exp_slider = HSlider.new()
	_exp_slider.min_value = -3.0      # log10 seconds: 1 ms ..
	_exp_slider.max_value = 2.5       # .. ~5 min
	_exp_slider.step = 0.05
	_exp_slider.value = 1.0
	_exp_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_exp_slider.value_changed.connect(func(_x): _exp_label.text = _fmt_exp(exptime()))
	row2.add_child(_exp_slider)
	_exp_label = _label(_fmt_exp(exptime()))
	_exp_label.custom_minimum_size = Vector2(70, 0)
	row2.add_child(_exp_label)

	var row3 := HBoxContainer.new()
	v.add_child(row3)
	_expose_btn = _button("Expose", row3, expose)
	_button("Close", row3, func(): closed.emit())
	_status = _label("")
	_status.add_theme_font_size_override("font_size", 13)
	_status.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status)

	_view = Control.new()
	_view.custom_minimum_size = Vector2(512, 512)
	h.add_child(_view)
	_tex_rect = TextureRect.new()
	_tex_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_tex_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.add_child(_tex_rect)

	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.custom_minimum_size = Vector2(330, 0)
	_info.add_theme_font_size_override("normal_font_size", 13)
	v.add_child(_info)
	_info.text = "[color=#8899aa]Pick a target and press Expose. Daylight frames will be… bright.[/color]"

func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l

func _button(t: String, parent: Control, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

func exptime() -> float:
	return pow(10.0, _exp_slider.value)

static func _fmt_exp(t: float) -> String:
	return "%.0f ms" % (t * 1000.0) if t < 1.0 else "%.1f s" % t

# ---------------------------------------------------------------------
# Opening: refresh targets and filters
# ---------------------------------------------------------------------
func refresh() -> void:
	if catalog == null or not catalog.is_loaded:
		_status.text = "star catalog not loaded"
		return
	if _band_opt.item_count == 0:
		for b in catalog.band_names:
			_band_opt.add_item(b)
		var vi: int = catalog.band_names.find("V")
		_band_opt.select(maxi(vi, 0))
	var prev: String = _target_opt.get_item_text(_target_opt.selected) if _target_opt.selected >= 0 else ""
	_targets.clear()
	_target_opt.clear()
	_targets.append({"label": "Where I'm looking", "star": -1})
	var snap: Dictionary = SkyModel.snapshot(engine)
	var basis: Basis = SkyModel.equatorial_basis(snap["lst"], snap["lat"])
	var vars: Array = []
	var named: Array = []
	for i in catalog.named_indices:
		var alt: float = rad_to_deg(asin(clampf((basis * catalog.unit_eq[i]).y, -1.0, 1.0)))
		if alt < 5.0:
			continue
		var is_var: bool = catalog.variable_of_star(i) >= 0
		var lbl: String = "%s%s  (V %.1f, alt %.0f°)" % ["VARIABLE · " if is_var else "", catalog.star_name(i), catalog.vmag[i], alt]
		(vars if is_var else named).append({"label": lbl, "star": i})
	for t in vars + named:
		_targets.append(t)
	var sel: int = 0
	for k in _targets.size():
		_target_opt.add_item(_targets[k]["label"])
		if _targets[k]["label"].get_slice("  (", 0) == prev.get_slice("  (", 0):
			sel = k
	_target_opt.select(sel)
	_status.text = "%d targets up" % (_targets.size() - 1)

func select_target_by_name(target_name: String) -> bool:
	for k in _targets.size():
		var s: int = _targets[k]["star"]
		if s >= 0 and catalog.star_name(s).to_lower() == target_name.to_lower():
			_target_opt.select(k)
			return true
	return false

func set_band(b: String) -> void:
	var k: int = catalog.band_names.find(b)
	if k >= 0:
		_band_opt.select(k)

func set_exptime(t: float) -> void:
	_exp_slider.value = log(t) / log(10.0)

# ---------------------------------------------------------------------
# Exposure
# ---------------------------------------------------------------------
func current_target() -> Dictionary:
	var k: int = maxi(_target_opt.selected, 0)
	var t: Dictionary = _targets[k] if k < _targets.size() else {"label": "Where I'm looking", "star": -1}
	var snap: Dictionary = SkyModel.snapshot(engine)
	if t["star"] >= 0:
		return {"name": catalog.star_name(t["star"]), "star": t["star"],
			"ra": catalog.ra_rad[t["star"]], "dec": catalog.dec_rad[t["star"]]}
	var dir: Vector3 = look_dir_provider.call() if look_dir_provider.is_valid() else Vector3(0, 1, 0)
	var rd: Vector2 = SkyModel.dir_to_radec(dir, snap["lst"], snap["lat"])
	return {"name": "RA %.2fh Dec %+.1f°" % [rad_to_deg(rd.x) / 15.0, rad_to_deg(rd.y)], "star": -1, "ra": rd.x, "dec": rd.y}

func is_busy() -> bool:
	return _task >= 0

func expose() -> void:
	if _task >= 0 or catalog == null or not catalog.is_loaded:
		return
	var tgt: Dictionary = current_target()
	var snap: Dictionary = SkyModel.snapshot(engine)
	var dir: Vector3 = SkyModel.radec_to_dir(tgt["ra"], tgt["dec"], snap["lst"], snap["lat"])
	if telescope != null:
		telescope.point_at(dir)
	if dir.y < 0.0:
		_status.text = "%s is below the horizon" % tgt["name"]
		return
	_pending_req = {
		"catalog": catalog, "ra": tgt["ra"], "dec": tgt["dec"],
		"band": catalog.band_names[maxi(_band_opt.selected, 0)],
		"exptime": exptime(), "snap": snap, "npix": npix, "fov_deg": fov_deg,
		"aperture_m": aperture_m, "qe": qe, "seeing_arcsec": seeing_arcsec,
		"defocus_px": defocus_px, "read_noise": read_noise_e, "full_well": full_well_e,
		"seed": hash([snap["jd"], tgt["ra"], tgt["dec"]]),
		"target": tgt,
	}
	_expose_btn.disabled = true
	_status.text = "exposing %s…" % _fmt_exp(exptime())
	_task = WorkerThreadPool.add_task(_worker.bind(_pending_req), false, "CCD exposure")

func _worker(req: Dictionary) -> void:
	var f: Dictionary = CCDSimulator.synthesize(req)
	f["display"] = FrameDisplay.to_image(f["image"], f["npix"], f["full_well"])
	call_deferred("_on_frame", f)

func _on_frame(f: Dictionary) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_expose_btn.disabled = false
	f["target"] = _pending_req["target"]
	frame = f
	_tex_rect.texture = ImageTexture.create_from_image(f["display"])
	_status.text = "%s  %s  %s  X=%.2f" % [f["target"]["name"], f["band"], _fmt_exp(f["exptime"]), f["airmass"]]
	_info.text = _frame_summary(f)
	frame_ready(f)

## Hook for photometry (overridden in later phases).
func frame_ready(_f: Dictionary) -> void:
	pass

func _frame_summary(f: Dictionary) -> String:
	var s: String = "sky %.1f mag/″²  ·  FWHM %.1f px (%.0f″)  ·  %d stars on chip" % [
		f["sky_mag"], f["fwhm_px"], f["fwhm_px"] * f["scale_arcsec"], f["truth"].size()]
	if f["saturated_frac"] > 0.5:
		s += "\n[color=#ffaa55]Blown out — the sky is brighter than the chip can take. Wait for night![/color]"
	return s

func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
