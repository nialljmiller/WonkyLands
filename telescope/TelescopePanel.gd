extends PanelContainer
## TelescopePanel — the telescope's control screen.
##
## The frame is the hero; two slim columns walk through the steps:
##   ① Point  — searchable list of stars up now, variables tagged
##   ② Expose — filter, exposure (presets, slider, Auto), Expose
##   ③ Measure — click a star: card with mag ± err, comparison, log,
##               FITS, Monitor tonight (with sparkline) and colours.
## Keys: Space expose · 1–7 filter · N time warp · Esc close.
## Frames are synthesised on a worker thread (CCDSimulator); the stretch
## runs in a shader (FrameView), so nothing heavy runs per frame.

signal closed
signal open_light_curve(target: String, band: String)
signal warp

const SkyModel = preload("res://telescope/SkyModel.gd")
const CCDSimulator = preload("res://telescope/CCDSimulator.gd")
const FrameDisplay = preload("res://telescope/FrameDisplay.gd")
const Photometry = preload("res://telescope/Photometry.gd")
const FitsWriter = preload("res://telescope/FitsWriter.gd")
const ObservingLog = preload("res://telescope/ObservingLog.gd")
const UiStyle = preload("res://telescope/UiStyle.gd")
const FrameView = preload("res://telescope/FrameView.gd")
const TargetPicker = preload("res://telescope/TargetPicker.gd")

const PRESETS: Array = [0.001, 0.01, 0.1, 1.0, 10.0, 60.0]
const COLOURS: Array = [["B", "V"], ["V", "R"], ["V", "I"], ["g", "r"], ["r", "i"]]

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
## Monitor mode: re-expose the target every this many GAME minutes
## while it's dark and the target is up, logging each good measurement.
@export var monitor_interval_min: float = 10.0
@export var monitor_min_alt_deg: float = 8.0
@export var monitor_max_sun_alt_deg: float = -6.0
## Auto exposure aims the target's peak pixel at this fraction of full well.
@export var auto_peak_frac: float = 0.5

var engine = null
var catalog = null
var telescope: Node3D = null        # prop to slew
var look_dir_provider: Callable      # returns the camera's forward dir

var frame: Dictionary = {}           # last synthesised frame
var _task: int = -1
var _pending_req: Dictionary = {}
var _meas: Dictionary = {}           # last clicked / auto measurement
var _comp: Dictionary = {}           # comparison star (same frame)
var _logged: Dictionary = {}         # "jd|star" already in the log
var _series: Dictionary = {}         # "target|band" -> [[jd, mag, err]]
var _series_loaded: bool = false
var _band: int = 0
var _colour_seq: Array = []          # bands still to take
var _colour_res: Dictionary = {}     # band -> measurement
var monitoring: bool = false
var monitor_status: String = ""
var monitor_points: int = 0
var _monitor_target: Dictionary = {}
var _monitor_next_jd: float = 0.0
var _monitor_wait: String = ""
var _clock: float = 0.0

# Widgets
var _picker: TargetPicker
var _teaser: Label
var _band_btns: Array = []
var _exp_slider: HSlider
var _exp_label: Label
var _auto: Button
var _exp_hint: Label
var _expose_btn: Button
var _view: FrameView
var _readout: Label
var _stretch_btns: Array = []
var _gain: HSlider
var _labels_btn: Button
var _meas_hint: Label
var _card: RichTextLabel
var _comp_chip: Button
var _comp_btn: Button
var _log_btn: Button
var _autolog: Button
var _fits_btn: Button
var _monitor_btn: Button
var _monitor_lbl: Label
var _spark: Control
var _colour_opt: OptionButton
var _colour_lbl: Label
var _clock_lbl: Label

func _ready() -> void:
	UiStyle.panel(self)
	add_child(UiStyle.label("Loading the star catalog…", 15, UiStyle.MUTED))

## Built on first open: the catalog (and so the filter list) loads async.
func _build() -> void:
	get_child(0).queue_free()
	var root := UiStyle.col(self, 8)
	# Header
	var head := UiStyle.row(root, 10)
	head.add_child(UiStyle.label("TELESCOPE", 17, UiStyle.ACCENT))
	head.add_child(UiStyle.label("%d mm refractor · %.0f′ field" % [int(aperture_m * 1000.0), fov_deg * 60.0], 13, UiStyle.MUTED))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	_clock_lbl = UiStyle.label("", 13, UiStyle.MUTED)
	head.add_child(_clock_lbl)
	UiStyle.chip("✕", head, func(): closed.emit()).tooltip_text = "Close (Esc)"

	var body := UiStyle.row(root, 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left := _column(body, 290)
	var center := UiStyle.col(body, 6)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var right := _column(body, 260)

	# ① Point
	left.add_child(UiStyle.step("①", "POINT"))
	_picker = TargetPicker.new()
	_picker.catalog = catalog
	_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_picker.picked.connect(_on_target_changed)
	left.add_child(_picker)
	_teaser = UiStyle.hint()
	left.add_child(_teaser)

	# ② Expose
	left.add_child(UiStyle.step("②", "EXPOSE"))
	var bands := UiStyle.row(left, 3)
	var group := ButtonGroup.new()
	for b in catalog.band_names:
		var c: Button = UiStyle.chip(b, bands, Callable(), true)
		c.toggled.connect(func(on): if on: _on_band_chip(_band_btns.find(c)))
		c.button_group = group
		c.custom_minimum_size = Vector2(32, 0)
		c.tooltip_text = "%s  (%.0f nm) · key %d" % [catalog.bands[b].get("filter", b), catalog.bands[b].get("lambda_eff_nm", 0.0), _band_btns.size() + 1]
		_band_btns.append(c)
	var pres := HFlowContainer.new()
	pres.add_theme_constant_override("h_separation", 4)
	pres.add_theme_constant_override("v_separation", 4)
	left.add_child(pres)
	for t in PRESETS:
		UiStyle.chip(fmt_exp(t).replace(" ", ""), pres, func(): _auto.set_pressed_no_signal(false); set_exptime(t), false, 12)
	var er := UiStyle.row(left, 6)
	_exp_slider = HSlider.new()
	_exp_slider.min_value = -3.0      # log10 seconds: 1 ms ..
	_exp_slider.max_value = 2.5       # .. ~5 min
	_exp_slider.step = 0.05
	_exp_slider.value = 1.0
	_exp_slider.focus_mode = Control.FOCUS_NONE
	_exp_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_exp_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_exp_slider.drag_started.connect(func(): _auto.set_pressed_no_signal(false))
	_exp_slider.value_changed.connect(func(_x): _update_hints())
	er.add_child(_exp_slider)
	_exp_label = UiStyle.label("", 14)
	_exp_label.custom_minimum_size = Vector2(62, 0)
	_exp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	er.add_child(_exp_label)
	_auto = UiStyle.chip("Auto", er, _apply_auto, true)
	_auto.tooltip_text = "Pick an exposure that puts the target's brightest pixel at ~%d%% of full well" % int(auto_peak_frac * 100.0)
	_auto.set_pressed_no_signal(true)
	_exp_hint = UiStyle.hint()
	left.add_child(_exp_hint)
	_expose_btn = UiStyle.primary("Expose", left, expose)
	var cr := UiStyle.row(left, 4)
	cr.add_child(UiStyle.label("Colour", 13, UiStyle.MUTED))
	_colour_opt = OptionButton.new()
	_colour_opt.focus_mode = Control.FOCUS_NONE
	for pair in COLOURS:
		if catalog.band_names.has(pair[0]) and catalog.band_names.has(pair[1]):
			_colour_opt.add_item("%s − %s" % pair)
			_colour_opt.set_item_metadata(_colour_opt.item_count - 1, pair)
	cr.add_child(_colour_opt)
	UiStyle.chip("Take both", cr, take_colour).tooltip_text = "Expose in both filters (Auto exposure) and compare the colour index with the catalog's SED_Tools synthetic photometry"
	_colour_lbl = UiStyle.hint()
	_colour_lbl.visible = false
	left.add_child(_colour_lbl)


	# Frame (centre)
	var tools := UiStyle.row(center, 4)
	tools.add_child(UiStyle.label("Stretch", 12, UiStyle.MUTED))
	var sg := ButtonGroup.new()
	for s in ["asinh", "linear", "log"]:
		var b: Button = UiStyle.chip(s, tools, _apply_stretch, true, 12)
		b.button_group = sg
		_stretch_btns.append(b)
	_stretch_btns[0].set_pressed_no_signal(true)
	tools.add_child(UiStyle.label("  ☀", 13, UiStyle.MUTED))
	_gain = HSlider.new()
	_gain.min_value = -1.0
	_gain.max_value = 2.0
	_gain.step = 0.02
	_gain.focus_mode = Control.FOCUS_NONE
	_gain.custom_minimum_size = Vector2(90, 0)
	_gain.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_gain.value_changed.connect(func(_x): _apply_stretch())
	_gain.tooltip_text = "Brightness"
	tools.add_child(_gain)
	var sp2 := Control.new()
	sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tools.add_child(sp2)
	_labels_btn = UiStyle.chip("Labels", tools, func(): _view.show_labels = _labels_btn.button_pressed; _view.redraw(), true, 12)
	_labels_btn.set_pressed_no_signal(true)
	_labels_btn.tooltip_text = "Name catalog stars (zoom in for faint field-star magnitudes)"
	UiStyle.chip("Fit", tools, func(): _view.reset_view(), false, 12).tooltip_text = "Reset zoom (double-click the frame)"
	_view = FrameView.new()
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.custom_minimum_size = Vector2(300, 300)
	_view.clicked.connect(_on_frame_click)
	_view.hovered.connect(func(t): _readout.text = t if t != "" else _summary())
	center.add_child(_view)
	_readout = UiStyle.label("", 12, UiStyle.MUTED)
	_readout.clip_text = true
	_readout.custom_minimum_size = Vector2(10, 0)
	center.add_child(_readout)

	# ③ Measure
	right.add_child(UiStyle.step("③", "MEASURE"))
	_meas_hint = UiStyle.hint()
	right.add_child(_meas_hint)
	var card := UiStyle.card(10)
	right.add_child(card)
	_card = RichTextLabel.new()
	_card.bbcode_enabled = true
	_card.fit_content = true
	_card.scroll_active = false
	_card.add_theme_font_size_override("normal_font_size", 13)
	_card.add_theme_font_size_override("bold_font_size", 15)
	card.add_child(_card)
	_comp_chip = UiStyle.chip("", right, clear_comparison, false, 12)
	_comp_chip.tooltip_text = "Comparison star — click to clear"
	_comp_chip.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0))
	var mr := UiStyle.row(right, 4)
	_comp_btn = UiStyle.chip("Set as comparison", mr, _set_comparison)
	_log_btn = UiStyle.chip("Log", mr, _log_measurement)
	var mr2 := UiStyle.row(right, 4)
	_autolog = UiStyle.chip("Auto-log ✓", mr2, func(): _autolog.text = "Auto-log ✓" if _autolog.button_pressed else "Auto-log", true)
	_autolog.set_pressed_no_signal(true)
	_autolog.tooltip_text = "Good measurements of the target go straight into the observing log"
	_fits_btn = UiStyle.chip("Save FITS", mr2, save_fits)

	right.add_child(_spacer(6))
	right.add_child(UiStyle.label("TIME SERIES", 13, UiStyle.ACCENT))
	_monitor_btn = UiStyle.chip("◉  Monitor tonight", right, func(): set_monitoring(_monitor_btn.button_pressed), true)
	_monitor_btn.tooltip_text = "Re-observe this target every %d game-minutes while it's dark and up, logging each measurement. Keeps going when you walk away; press N to warp time." % int(monitor_interval_min)
	_monitor_lbl = UiStyle.hint()
	right.add_child(_monitor_lbl)
	_spark = Control.new()
	_spark.custom_minimum_size = Vector2(0, 52)
	_spark.draw.connect(_draw_spark)
	right.add_child(_spark)
	UiStyle.chip("Open light curve  ›", right, func(): open_light_curve.emit(_series_target(), _band_name()))

	root.add_child(UiStyle.label("Space expose  ·  1–%d filter  ·  scroll zoom · drag pan · double-click fit  ·  N warp time  ·  Esc close" % _band_btns.size(), 11, Color(0.45, 0.5, 0.6)))
	var vi: int = catalog.band_names.find("V")
	_band = maxi(vi, 0)
	_band_btns[_band].button_pressed = true
	_apply_stretch()
	_show_measurement()

func _column(parent: Control, w: float) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(w, 0)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(sc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.add_child(v)
	return v

func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func exptime() -> float:
	return pow(10.0, _exp_slider.value)

static func fmt_exp(t: float) -> String:
	if t < 0.0995:
		return "%.0f ms" % (t * 1000.0)
	return ("%.1f s" % t).replace(".0 s", " s") if t < 9.95 else "%.0f s" % t

func _band_name() -> String:
	return catalog.band_names[_band]

# ---------------------------------------------------------------------
# Opening: refresh targets
# ---------------------------------------------------------------------
func refresh() -> void:
	if catalog == null or not catalog.is_loaded:
		return
	if _view == null:
		_build()
	_picker.refresh(engine)
	if not _series_loaded:
		_series_loaded = true
		for r in ObservingLog.read_all():
			_series_append(r["target"], r["band"], r["jd"], r["mag"], r["err"])
	_on_target_changed()

func select_target_by_name(target_name: String) -> bool:
	var i: int = catalog.find_star(target_name)
	if i < 0 or _picker.altitude_of(i).is_empty():
		return false
	_picker.select_star(i)
	_on_target_changed()
	return true

func set_band(b: String) -> void:
	var k: int = catalog.band_names.find(b)
	if k >= 0:
		_band_btns[k].button_pressed = true

func _on_band_chip(k: int) -> void:
	_band = k
	_on_target_changed()

func set_exptime(t: float) -> void:
	_exp_slider.value = log(clampf(t, 0.001, 316.0)) / log(10.0)

func _on_target_changed() -> void:
	if telescope != null and engine != null and catalog != null:   # turn the dome
		var tgt: Dictionary = current_target()
		var snap: Dictionary = SkyModel.snapshot(engine)
		telescope.point_at(SkyModel.radec_to_dir(tgt["ra"], tgt["dec"], snap["lst"], snap["lat"]))
	if _auto.button_pressed:
		_apply_auto()
	_update_hints()
	_spark.queue_redraw()

func current_target() -> Dictionary:
	var i: int = _picker.selected_star
	if i >= 0:
		return {"name": catalog.star_name(i), "star": i, "ra": catalog.ra_rad[i], "dec": catalog.dec_rad[i]}
	var snap: Dictionary = SkyModel.snapshot(engine)
	var dir: Vector3 = look_dir_provider.call() if look_dir_provider.is_valid() else Vector3(0, 1, 0)
	var rd: Vector2 = SkyModel.dir_to_radec(dir, snap["lst"], snap["lat"])
	return {"name": "RA %.2fh Dec %+.1f°" % [rad_to_deg(rd.x) / 15.0, rad_to_deg(rd.y)], "star": -1, "ra": rd.x, "dec": rd.y}

# ---------------------------------------------------------------------
# Auto exposure: the same zero point, extinction, PSF and sky the
# CCDSimulator uses, so peak = star·(central pixel fraction) + sky.
# ---------------------------------------------------------------------
## Peak-pixel and sky electrons per second for a target (x = star, y = sky).
func peak_rates(tgt: Dictionary, band_name: String) -> Vector2:
	var band: Dictionary = catalog.bands[band_name]
	var snap: Dictionary = SkyModel.snapshot(engine)
	var dir: Vector3 = SkyModel.radec_to_dir(tgt["ra"], tgt["dec"], snap["lst"], snap["lat"])
	var X: float = SkyModel.airmass(asin(clampf(dir.y, -1.0, 1.0)))
	var scale_as: float = fov_deg * 3600.0 / npix
	var area: float = PI * pow(aperture_m * 0.5, 2.0)
	var seeing_px: float = seeing_arcsec * pow(X, 0.6) / scale_as
	var sigma: float = sqrt(seeing_px * seeing_px + defocus_px * defocus_px) / 2.3548
	var sky_mag: float = SkyModel.sky_mag_arcsec2(float(band["sky_dark_mag_arcsec2"]), snap)
	var sky1: float = CCDSimulator.star_electrons(sky_mag, band, 0.0, area, 1.0, qe) * scale_as * scale_as
	if tgt["star"] < 0:
		return Vector2(0.0, sky1)
	var frac: float = CCDSimulator._erf(0.5 / (sigma * sqrt(2.0)))
	var m: float = catalog.star_mag_at(tgt["star"], band_name, snap["jd"])
	return Vector2(CCDSimulator.star_electrons(m, band, X, area, 1.0, qe) * frac * frac, sky1)

func auto_exptime(tgt: Dictionary, band_name: String) -> float:
	var r: Vector2 = peak_rates(tgt, band_name)
	if tgt["star"] < 0:      # blank sky: sky at 5 % of full well, ≤ 30 s
		return clampf(0.05 * full_well_e / maxf(r.y, 1e-9), 0.001, 30.0)
	return clampf(auto_peak_frac * full_well_e / maxf(r.x + r.y, 1e-9), 0.001, 300.0)

func _apply_auto() -> void:
	if _auto.button_pressed and catalog != null and engine != null:
		set_exptime(auto_exptime(current_target(), _band_name()))
	_update_hints()

# ---------------------------------------------------------------------
# Exposure
# ---------------------------------------------------------------------
func is_busy() -> bool:
	return _task >= 0

func expose(from_monitor: bool = false) -> void:
	if _task >= 0 or catalog == null or not catalog.is_loaded:
		return
	var tgt: Dictionary = current_target()
	var snap: Dictionary = SkyModel.snapshot(engine)
	var dir: Vector3 = SkyModel.radec_to_dir(tgt["ra"], tgt["dec"], snap["lst"], snap["lat"])
	if telescope != null:
		telescope.point_at(dir)
	if dir.y < 0.0:
		_exp_hint.text = "%s is below the horizon." % tgt["name"]
		return
	if _auto.button_pressed:
		set_exptime(auto_exptime(tgt, _band_name()))
	_pending_req = {
		"catalog": catalog, "ra": tgt["ra"], "dec": tgt["dec"],
		"band": _band_name(),
		"exptime": exptime(), "snap": snap, "npix": npix, "fov_deg": fov_deg,
		"aperture_m": aperture_m, "qe": qe, "seeing_arcsec": seeing_arcsec,
		"defocus_px": defocus_px, "read_noise": read_noise_e, "full_well": full_well_e,
		"seed": hash([snap["jd"], tgt["ra"], tgt["dec"]]),
		"target": tgt,
		"monitor": from_monitor,
	}
	_expose_btn.disabled = true
	_expose_btn.text = "Exposing…"
	_view.busy_text = "Exposing %s in %s…" % [fmt_exp(exptime()), _band_name()]
	_view.redraw()
	_task = WorkerThreadPool.add_task(_worker.bind(_pending_req), false, "CCD exposure")

func _worker(req: Dictionary) -> void:
	var f: Dictionary = CCDSimulator.synthesize(req)
	f["float_image"] = FrameDisplay.float_image(f["image"], f["npix"])
	f["levels"] = FrameDisplay.levels(f["image"], f["full_well"])
	call_deferred("_on_frame", f)

func _on_frame(f: Dictionary) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_expose_btn.disabled = false
	_expose_btn.text = "Expose"
	f["target"] = _pending_req["target"]
	f["monitor"] = _pending_req["monitor"]
	var same: bool = not frame.is_empty() and frame["target"]["name"] == f["target"]["name"]
	frame = f
	_view.busy_text = ""
	_view.set_frame(f, same)
	frame_ready(f)

## After every exposure: measure the target at the chip centre.
func frame_ready(f: Dictionary) -> void:
	_comp = {}
	_meas = {}
	if f["target"]["star"] >= 0 and f["saturated_frac"] < 0.5:
		var c: float = (f["npix"] - 1) * 0.5
		measure_at(Vector2(c, c))
		if _autolog.button_pressed and not f.get("monitor", false) and _status(_meas) == "good" and _meas.get("star", -1) == f["target"]["star"]:
			log_measurement(_meas)
	_show_measurement()
	if monitoring and f.get("monitor", false):
		_monitor_record()
	if not _colour_seq.is_empty():
		_colour_step()

# ---------------------------------------------------------------------
# Monitor mode — automated time series for light curves
# ---------------------------------------------------------------------
func set_monitoring(on: bool) -> void:
	if on:
		var tgt: Dictionary = current_target()
		if tgt["star"] < 0:
			_monitor_lbl.text = "Pick a named star to monitor."
			_monitor_btn.set_pressed_no_signal(false)
			return
		_monitor_target = tgt
		_monitor_next_jd = 0.0
		monitor_points = 0
	monitoring = on
	_monitor_btn.set_pressed_no_signal(on)
	_monitor_btn.text = ("◉  Monitoring %s" % _monitor_target["name"]) if on else "◉  Monitor tonight"
	monitor_status = ("monitoring %s" % _monitor_target["name"]) if on else ""
	_update_monitor_label()
	_spark.queue_redraw()

func _process(delta: float) -> void:
	if _view == null:
		return
	_clock += delta
	if visible and _clock >= 0.25:
		_clock = 0.0
		if engine:
			_clock_lbl.text = "%s UT  ×%d" % [load("res://telescope/Observatory.gd").jd_to_string(engine.current_jd), int(engine.time_scale)]
		_update_monitor_label()
	if not monitoring or _task >= 0 or engine == null:
		return
	var jd: float = engine.current_jd
	if jd < _monitor_next_jd:
		return
	_monitor_next_jd = jd + monitor_interval_min / 1440.0
	var snap: Dictionary = SkyModel.snapshot(engine)
	var dir: Vector3 = SkyModel.radec_to_dir(_monitor_target["ra"], _monitor_target["dec"], snap["lst"], snap["lat"])
	var alt: float = rad_to_deg(asin(clampf(dir.y, -1.0, 1.0)))
	_monitor_wait = "Waiting for dark" if snap["sun_alt_deg"] > monitor_max_sun_alt_deg else ("Waiting for it to rise" if alt < monitor_min_alt_deg else "")
	if snap["sun_alt_deg"] > monitor_max_sun_alt_deg:
		monitor_status = "%s: waiting for dark · %d pts" % [_monitor_target["name"], monitor_points]
		return
	if alt < monitor_min_alt_deg:
		monitor_status = "%s: waiting to rise · %d pts" % [_monitor_target["name"], monitor_points]
		return
	if _picker.selected_star != _monitor_target["star"]:
		_picker.refresh(engine)
		_picker.select_star(_monitor_target["star"])
	expose(true)

func _monitor_record() -> void:
	if _meas.is_empty() or _meas.get("star", -1) != _monitor_target["star"]:
		return
	if _meas["saturated"]:
		# Friendly auto-exposure: halve and try again next time.
		set_exptime(exptime() * 0.5)
		monitor_status = "%s: saturated, shortening to %s" % [_monitor_target["name"], fmt_exp(exptime())]
		return
	if _meas["snr"] < 20.0 and exptime() < 60.0 and not _auto.button_pressed:
		set_exptime(exptime() * 2.0)
	if _meas["snr"] < 5.0:
		return
	log_measurement(_meas)
	monitor_points += 1
	monitor_status = "monitoring %s · %d pts · last %s %.3f" % [_monitor_target["name"], monitor_points, frame["band"], _meas["mag"]]

func _update_monitor_label() -> void:
	if not monitoring:
		_monitor_lbl.text = "Builds a light curve while you explore."
		return
	var tonight: int = 0
	for p in _series.get(_monitor_target["name"] + "|" + _band_name(), []):
		if p[0] > engine.current_jd - 0.6 and p[0] <= engine.current_jd:
			tonight += 1
	var state: String = _monitor_wait if _monitor_wait != "" else "Next exposure in %.0f min" % (maxf(_monitor_next_jd - engine.current_jd, 0.0) * 1440.0)
	_monitor_lbl.text = "%s · %d points tonight" % [state, tonight]

# ---------------------------------------------------------------------
# Photometry
# ---------------------------------------------------------------------
func _to_screen(p: Vector2) -> Vector2:
	return _view.to_screen(p)

func _on_frame_click(p: Vector2) -> void:
	if frame.is_empty() or _task >= 0:
		return
	measure_at(p)
	_show_measurement()

func measure_at(p: Vector2) -> Dictionary:
	var m: Dictionary = Photometry.measure_frame(frame, catalog.bands[frame["band"]], p)
	if not m.get("ok", false):
		_meas_hint.text = "Nothing measurable there: click right on a star."
		return m
	if m["name"] == "" and m["star"] < 0:
		m["name"] = "field star"
	_meas = m
	return m

## good / low S/N / saturated
static func _status(m: Dictionary) -> String:
	if m.is_empty():
		return ""
	if m["saturated"]:
		return "saturated"
	return "good" if m["snr"] >= 20.0 else "low S/N"

func _show_measurement() -> void:
	_view.meas = _meas
	_view.comp = _comp
	var sat_frame: bool = not frame.is_empty() and frame["saturated_frac"] > 0.5
	_view.banner = ""
	if sat_frame:
		_view.banner = "Daylight: the sky floods the chip. Press N to warp to night."
	elif _status(_meas) == "saturated":
		_view.banner = "%s is saturated: use Auto or a shorter exposure" % _meas["name"]
	_view.banner_color = UiStyle.BAD
	_view.redraw()
	_card.text = _card_text(_meas)
	_comp_chip.visible = not _comp.is_empty()
	if not _comp.is_empty():
		_comp_chip.text = "Comparison: %s  (%s %.3f)   ✕" % [_comp["name"], frame["band"], _comp["mag"]]
	_comp_btn.disabled = _meas.is_empty() or _meas == _comp
	_log_btn.disabled = _meas.is_empty() or _meas["saturated"] or _logged.has(_log_key(_meas))
	_fits_btn.disabled = frame.is_empty()
	_readout.text = _summary()
	_update_hints()

func _card_text(m: Dictionary) -> String:
	if m.is_empty():
		return "[color=#8c9ab0]No measurement yet.[/color]"
	var b: String = frame["band"]
	var st: String = _status(m)
	var col: String = {"good": "#66e68c", "low S/N": "#ffb84d", "saturated": "#ff6b61"}[st]
	var s: String = "[b]%s[/b]" % m["name"]
	var vi: int = catalog.variable_of_star(m["star"]) if m["star"] >= 0 else -1
	if vi >= 0:
		s += "  [color=#ff8cd9]VAR[/color]"
	s += "   [color=%s]● %s[/color]\n" % [col, st]
	if st == "saturated":
		s += "[font_size=20][color=#ff6b61]%s ≈ ?[/color][/font_size]\n[color=#8c9ab0]Peak pixel hit full well; the counts are clipped, so the magnitude can't be trusted.[/color]" % b
	else:
		s += "[font_size=22]%s = %.3f[/font_size] [color=#8c9ab0]± %.3f[/color]\n" % [b, m["mag"], m["mag_err"]]
		if m.has("true_mag"):
			s += "catalog %.3f   [color=#8c9ab0]Δ %+.3f[/color]\n" % [m["true_mag"], m["mag"] - m["true_mag"]]
		s += "[color=#8c9ab0]S/N %.0f · %s e⁻ · airmass %.2f[/color]" % [m["snr"], FrameView._thousands(m["flux"]), frame["airmass"]]
	if not _comp.is_empty() and _comp != m and not m["saturated"]:
		var d: Vector2 = Photometry.differential(m, _comp)
		s += "\n[color=#8cd9ff]Δ%s vs comparison = [b]%+.3f ± %.3f[/b][/color]" % [b, d.x, d.y]
	if _logged.has(_log_key(m)):
		s += "\n[color=#66e68c]✓ in the observing log[/color]"
	return s

func _summary() -> String:
	if frame.is_empty():
		return "Hover the frame for pixel values, coordinates and star names."
	return "%s · %s · %s · airmass %.2f · sky %.1f mag/″² · seeing %.0f″ · %d stars on chip" % [
		frame["target"]["name"], frame["band"], fmt_exp(frame["exptime"]), frame["airmass"],
		frame["sky_mag"], frame["fwhm_px"] * frame["scale_arcsec"], frame["truth"].size()]

func _set_comparison() -> void:
	if _meas.is_empty():
		return
	_comp = _meas
	_show_measurement()

func clear_comparison() -> void:
	_comp = {}
	_show_measurement()

func _log_key(m: Dictionary) -> String:
	var who: String = str(m["star"]) if m.get("star", -1) >= 0 else "%.0f,%.0f" % [m.get("x", 0.0), m.get("y", 0.0)]
	return "%.6f|%s" % [frame.get("jd", 0.0), who]

func _log_measurement() -> void:
	if _meas.is_empty() or _meas["saturated"]:
		return
	log_measurement(_meas)
	_show_measurement()

func log_measurement(m: Dictionary) -> void:
	var key: String = _log_key(m)
	if _logged.has(key):
		return
	_logged[key] = true
	ObservingLog.append(frame["jd"], m["name"], frame["band"], m["mag"], m["mag_err"], frame["airmass"], frame["exptime"])
	_series_append(m["name"], frame["band"], frame["jd"], m["mag"], m["mag_err"])
	_spark.queue_redraw()

func _series_append(target: String, band: String, jd: float, mag: float, err: float) -> void:
	var k: String = target + "|" + band
	if not _series.has(k):
		_series[k] = []
	_series[k].append([jd, mag, err])

func _series_target() -> String:
	return _monitor_target["name"] if monitoring else current_target()["name"]

func _draw_spark() -> void:
	var r := Rect2(Vector2.ZERO, _spark.size)
	_spark.draw_style_box(UiStyle.box(UiStyle.CARD, 6, 0), r)
	var font: Font = get_theme_default_font()
	# The latest night's points, in time order.
	var all: Array = _series.get(_series_target() + "|" + _band_name(), [])
	var latest: float = -INF
	for p in all:
		latest = maxf(latest, p[0])
	var pts: Array = all.filter(func(p): return p[0] > latest - 0.6)
	pts.sort_custom(func(a, b): return a[0] < b[0])
	if pts.size() < 2:
		_spark.draw_string(font, Vector2(0, r.size.y * 0.5 + 5), "%s %s: %d point%s so far" % [_series_target(), _band_name(), pts.size(), "" if pts.size() == 1 else "s"], HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 12, UiStyle.MUTED)
		return
	var t0: float = pts[0][0]
	var t1: float = maxf(pts[-1][0], t0 + 1e-4)
	var m0: float = INF
	var m1: float = -INF
	for p in pts:
		m0 = minf(m0, p[1]); m1 = maxf(m1, p[1])
	m1 = maxf(m1, m0 + 0.02)
	var inner: Rect2 = r.grow_individual(-8, -8, -60, -8)
	var prev := Vector2.INF
	for p in pts:
		var q := Vector2(inner.position.x + (p[0] - t0) / (t1 - t0) * inner.size.x, inner.position.y + (p[1] - m0) / (m1 - m0) * inner.size.y)
		if prev != Vector2.INF:
			_spark.draw_line(prev, q, UiStyle.ACCENT * Color(1, 1, 1, 0.4), 1.0)
		_spark.draw_circle(q, 1.8, UiStyle.ACCENT)
		prev = q
	_spark.draw_string(font, Vector2(inner.end.x + 6, inner.position.y + 8), "%.2f" % m0, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiStyle.MUTED)
	_spark.draw_string(font, Vector2(inner.end.x + 6, inner.end.y + 2), "%.2f" % m1, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiStyle.MUTED)
	_spark.draw_string(font, Vector2(inner.end.x + 6, inner.get_center().y + 5), "latest night" if latest < engine.current_jd - 0.6 else "tonight", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiStyle.TEXT)

# ---------------------------------------------------------------------
# Colour: two filters back to back, colour index vs catalog
# ---------------------------------------------------------------------
func take_colour() -> void:
	var tgt: Dictionary = current_target()
	if tgt["star"] < 0 or _task >= 0 or _colour_opt.selected < 0:
		_colour_lbl.text = "Pick a named star first."
		_colour_lbl.visible = true
		return
	_colour_seq = _colour_opt.get_item_metadata(_colour_opt.selected).duplicate()
	_colour_res = {}
	_colour_lbl.visible = true
	_colour_lbl.text = "Taking %s, then %s…" % _colour_seq
	_auto.button_pressed = true
	set_band(_colour_seq[0])
	expose()

func _colour_step() -> void:
	var b: String = _colour_seq.pop_front()
	if _status(_meas) == "saturated" or _meas.is_empty() or _meas["star"] != frame["target"]["star"]:
		_colour_lbl.text = "Couldn't measure the target in %s." % b
		_colour_seq = []
		return
	_colour_res[b] = _meas
	if not _colour_seq.is_empty():
		set_band(_colour_seq[0])
		expose.call_deferred()
		return
	var bs: Array = _colour_res.keys()
	var a: Dictionary = _colour_res[bs[0]]
	var c: Dictionary = _colour_res[bs[1]]
	var jd: float = frame["jd"]
	var i: int = frame["target"]["star"]
	var cat_ci: float = catalog.star_mag_at(i, bs[0], jd) - catalog.star_mag_at(i, bs[1], jd)
	_colour_lbl.text = "%s − %s = %.3f ± %.3f   (catalog %.3f)" % [bs[0], bs[1], a["mag"] - c["mag"], sqrt(a["mag_err"] ** 2 + c["mag_err"] ** 2), cat_ci]
	_colour_lbl.add_theme_color_override("font_color", UiStyle.TEXT)

# ---------------------------------------------------------------------
# Hints, stretch, keys
# ---------------------------------------------------------------------
func _update_hints() -> void:
	if catalog == null or _exp_label == null:
		return
	_exp_label.text = fmt_exp(exptime())
	var tgt: Dictionary = current_target()
	var i: int = tgt["star"]
	if i < 0:
		_teaser.text = "Blank-sky frame wherever you're looking. Pick a star to measure one."
	else:
		var vi: int = catalog.variable_of_star(i)
		var t: Dictionary = _picker.altitude_of(i)
		if vi >= 0:
			var v: Dictionary = catalog.variables[vi]
			var tbl: Array = v["dmag"].get("V", [0.0])
			var amp: float = tbl.max() - tbl.min()
			var p: float = v["period_days"]
			var next_d: float = fposmod(float(v["epoch_jd"]) - engine.current_jd, p)
			var when: String = "%.0f h" % (next_d * 24.0) if next_d < 2.0 else "%.1f d" % next_d
			var verb: String = "watch it dim" if String(v["type"]).begins_with("E") else "watch it pulse"
			_teaser.text = "%s, P ≈ %.2f d: %s by %.1f mag. Next %s in %s." % [TargetPicker.type_name(v["type"]).get_slice(" (", 0), p, verb, amp, String(v.get("epoch_is", "minimum")), when]
			_teaser.add_theme_color_override("font_color", UiStyle.VAR)
		else:
			_teaser.text = "%s · V %.2f · %.0f K · %s, alt %.0f°" % [tgt["name"], catalog.vmag[i], float(catalog.stars[i].get("teff", 0)), "rising" if t.get("rising", false) else "setting", t.get("alt", 0.0)]
			_teaser.add_theme_color_override("font_color", UiStyle.MUTED)
	var r: Vector2 = peak_rates(tgt, _band_name()) if engine else Vector2.ZERO
	var fill: float = (r.x + r.y) * exptime() / full_well_e
	if _auto.button_pressed:
		_exp_hint.text = "Auto: %s peaks near %d%% of full well." % [tgt["name"] if i >= 0 else "the sky", int(minf(fill, 9.99) * 100.0)] if i >= 0 else "Auto: blank-sky exposure."
		_exp_hint.add_theme_color_override("font_color", UiStyle.MUTED)
	elif fill >= 1.0:
		_exp_hint.text = "⚠ %s will saturate at %s. Try Auto." % [tgt["name"] if i >= 0 else "The sky", fmt_exp(exptime())]
		_exp_hint.add_theme_color_override("font_color", UiStyle.WARN)
	else:
		_exp_hint.text = "Peak ≈ %d%% of full well." % int(fill * 100.0) if i >= 0 else ""
		_exp_hint.add_theme_color_override("font_color", UiStyle.MUTED)
	if frame.is_empty():
		_meas_hint.text = "Take an exposure first: Expose or Space."
	elif frame["saturated_frac"] > 0.5:
		_meas_hint.text = "Too bright to measure. Wait for night."
	elif _comp.is_empty():
		_meas_hint.text = "Click any star to measure it. Set one as comparison for differential photometry."
	else:
		_meas_hint.text = "Click another star: Δmag is relative to the comparison."
	_card.text = _card_text(_meas) if _card else ""

func _apply_stretch() -> void:
	var mode: int = 0
	for k in _stretch_btns.size():
		if _stretch_btns[k].button_pressed:
			mode = k
	_view.set_stretch(mode, pow(10.0, _gain.value))

func _input(e: InputEvent) -> void:
	if _view == null or not visible or not (e is InputEventKey) or not e.pressed or e.echo:
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	if e.keycode == KEY_SPACE:
		expose()
	elif e.keycode >= KEY_1 and e.keycode < KEY_1 + _band_btns.size():
		_band_btns[e.keycode - KEY_1].button_pressed = true
	elif e.keycode == KEY_N:
		warp.emit()
	else:
		return
	get_viewport().set_input_as_handled()

# ---------------------------------------------------------------------
# FITS export (+ a truth sidecar so the synthesis can be checked)
# ---------------------------------------------------------------------
func save_fits() -> String:
	if frame.is_empty():
		return ""
	var path: String = write_frame_fits(frame, catalog)
	if path == "":
		UiStyle.toast(_view, "FITS write failed")
	else:
		UiStyle.toast(_view, "Saved %s" % path.get_file(), "Open folder", func(): OS.shell_open(ProjectSettings.globalize_path(ObservingLog.DIR)))
	return path

## Writes <target>_<band>_<jd>.fits and a .truth.json sidecar into
## user://observations; returns the FITS path ("" on failure).
static func write_frame_fits(frame: Dictionary, catalog, dir: String = ObservingLog.DIR) -> String:
	DirAccess.make_dir_recursive_absolute(dir)
	var stem: String = "%s_%s_%.5f" % [String(frame["target"]["name"]).validate_filename().replace(" ", "_"), frame["band"], frame["jd"]]
	var path: String = dir + "/" + stem + ".fits"
	var c: float = (frame["npix"] - 1) * 0.5
	var cards: Array = [
		["DATE-OBS", _jd_to_isot(frame["jd"]), "UT, mid-exposure"],
		["JD", frame["jd"], "Julian Date"],
		["EXPTIME", frame["exptime"], "s"],
		["FILTER", frame["band"], String(catalog.bands[frame["band"]].get("filter", ""))],
		["OBJECT", frame["target"]["name"]],
		["RA", rad_to_deg(frame["ra"]), "deg, J2000, pointing"],
		["DEC", rad_to_deg(frame["dec"]), "deg, J2000, pointing"],
		["AIRMASS", frame["airmass"]],
		["SITELAT", frame["lat"], "deg"],
		["SITELONG", frame["lon"], "deg, east positive"],
		["BUNIT", "electron"],
		["GAIN", 1.0, "e-/ADU"],
		["RDNOISE", frame["read_noise"], "e-"],
		["SATURATE", frame["full_well"], "e-"],
		["APERTURE", frame["area_m2"], "m^2 collecting area"],
		["FWHM", frame["fwhm_px"], "px"],
		["SKYMAG", frame["sky_mag"], "mag/arcsec^2"],
		["CTYPE1", "RA---TAN"], ["CTYPE2", "DEC--TAN"],
		["CRPIX1", c + 1.0], ["CRPIX2", c + 1.0],
		["CRVAL1", rad_to_deg(frame["ra"])], ["CRVAL2", rad_to_deg(frame["dec"])],
		["CDELT1", -frame["scale_arcsec"] / 3600.0], ["CDELT2", frame["scale_arcsec"] / 3600.0],
		["ORIGIN", "WonkyLands"],
	]
	var err: Error = FitsWriter.write(path, frame["image"], frame["npix"], cards)
	if err != OK:
		return ""
	var truth: Array = []
	for s in frame["truth"]:
		truth.append({"x": s["x"], "y": s["y"], "mag": s["mag"], "e": s["e"], "name": s["name"]})
	var tf := FileAccess.open(dir + "/" + stem + ".truth.json", FileAccess.WRITE)
	tf.store_string(JSON.stringify({"note": "x,y 0-based, row 0 = FITS row 1", "sky_e": frame["sky_e"], "stars": truth}))
	tf.close()
	return path

static func _jd_to_isot(jd: float) -> String:
	var s: String = load("res://telescope/Observatory.gd").jd_to_string(jd)
	var secs: float = fposmod((jd + 0.5) * 86400.0, 60.0)
	return s.replace(" ", "T") + ":%06.3f" % secs

func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
