extends PanelContainer
## LogPanel — light curves from the observing log.
##
## Pick a target and band from what's in user://observations/log.csv,
## see magnitude vs JD, fold on a trial period, or let "Find period"
## (Lafler–Kinman string length, on a worker thread) suggest one.

signal closed

const ObservingLog = preload("res://telescope/ObservingLog.gd")

var _rows: Array = []
var _t := PackedFloat64Array()
var _m := PackedFloat32Array()
var _e := PackedFloat32Array()
var _target_opt: OptionButton
var _band_opt: OptionButton
var _fold: CheckBox
var _period: SpinBox
var _result: Label
var _plot: Control
var _task: int = -1

func _ready() -> void:
	position = Vector2(16, 16)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.1, 0.88)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(12)
	add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	add_child(v)
	var title := Label.new()
	title.text = "OBSERVING LOG"
	title.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	v.add_child(title)
	var row := HBoxContainer.new()
	v.add_child(row)
	_target_opt = OptionButton.new()
	_target_opt.custom_minimum_size = Vector2(200, 0)
	_target_opt.item_selected.connect(func(_i): _select())
	row.add_child(_target_opt)
	_band_opt = OptionButton.new()
	_band_opt.item_selected.connect(func(_i): _select())
	row.add_child(_band_opt)
	_fold = CheckBox.new()
	_fold.text = "Fold"
	_fold.toggled.connect(func(_b): _plot.queue_redraw())
	row.add_child(_fold)
	var pl := Label.new()
	pl.text = "P (d)"
	row.add_child(pl)
	_period = SpinBox.new()
	_period.min_value = 0.05
	_period.max_value = 100.0
	_period.step = 0.0001
	_period.value = 1.0
	_period.custom_minimum_size = Vector2(110, 0)
	_period.value_changed.connect(func(_x): _plot.queue_redraw())
	row.add_child(_period)
	var find := Button.new()
	find.text = "Find period"
	find.pressed.connect(find_period)
	row.add_child(find)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func(): closed.emit())
	row.add_child(close)
	_plot = Control.new()
	_plot.custom_minimum_size = Vector2(760, 380)
	_plot.draw.connect(_draw_plot)
	v.add_child(_plot)
	_result = Label.new()
	_result.add_theme_font_size_override("font_size", 13)
	v.add_child(_result)

func refresh() -> void:
	_rows = ObservingLog.read_all()
	var prev_t: String = _target_opt.get_item_text(_target_opt.selected) if _target_opt.selected >= 0 else ""
	var targets: Dictionary = {}
	for r in _rows:
		targets[r["target"]] = targets.get(r["target"], 0) + 1
	_target_opt.clear()
	var names: Array = targets.keys()
	names.sort_custom(func(a, b): return targets[a] > targets[b])
	for k in names.size():
		_target_opt.add_item(names[k])
		if names[k] == prev_t:
			_target_opt.select(k)
	_select()

func _select() -> void:
	var tgt: String = _target_opt.get_item_text(_target_opt.selected) if _target_opt.selected >= 0 else ""
	var prev_b: String = _band_opt.get_item_text(_band_opt.selected) if _band_opt.selected >= 0 else "V"
	var bands: Array = []
	for r in _rows:
		if r["target"] == tgt and not bands.has(r["band"]):
			bands.append(r["band"])
	_band_opt.clear()
	for k in bands.size():
		_band_opt.add_item(bands[k])
		if bands[k] == prev_b:
			_band_opt.select(k)
	var band: String = _band_opt.get_item_text(_band_opt.selected) if _band_opt.selected >= 0 else ""
	_t = PackedFloat64Array(); _m = PackedFloat32Array(); _e = PackedFloat32Array()
	for r in _rows:
		if r["target"] == tgt and r["band"] == band:
			_t.append(r["jd"]); _m.append(r["mag"]); _e.append(r["err"])
	_result.text = "%d points" % _t.size() if _t.size() > 0 else "No measurements yet — take some with the telescope (Monitor helps)."
	_plot.queue_redraw()

func find_period() -> void:
	if _task >= 0 or _t.size() < 8:
		_result.text = "Need at least 8 points for a period search."
		return
	var span: float = _t[_t.size() - 1] - _t[0]
	for x in _t:
		span = maxf(span, x - _t[0])
	var p_max: float = clampf(span * 0.7, 0.3, 30.0)
	_result.text = "Searching 0.2 – %.1f d…" % p_max
	_task = WorkerThreadPool.add_task(_search.bind(_t.duplicate(), _m.duplicate(), p_max), false, "period search")

func _search(t: PackedFloat64Array, m: PackedFloat32Array, p_max: float) -> void:
	call_deferred("_on_found", ObservingLog.period_search(t, m, 0.2, p_max))

func _on_found(res: Dictionary) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if res["period"] <= 0.0:
		_result.text = "No convincing period."
		return
	_period.value = res["period"]
	_fold.button_pressed = true
	_result.text = "Best period %.4f d  (%.2f h)   string-length θ = %.2f  —  lower θ = cleaner fold" % [res["period"], res["period"] * 24.0, res["theta"]]

func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)

func _draw_plot() -> void:
	var r := Rect2(Vector2(48, 8), _plot.size - Vector2(56, 32))
	_plot.draw_rect(r, Color(0.02, 0.03, 0.05, 0.9))
	_plot.draw_rect(r, Color(0.3, 0.35, 0.45), false, 1.0)
	var font: Font = get_theme_default_font()
	if _t.is_empty():
		return
	var folded: bool = _fold.button_pressed
	var p: float = _period.value
	var x0: float = INF; var x1: float = -INF; var y0: float = INF; var y1: float = -INF
	for i in _t.size():
		x0 = minf(x0, _t[i]); x1 = maxf(x1, _t[i])
		y0 = minf(y0, _m[i] - _e[i]); y1 = maxf(y1, _m[i] + _e[i])
	var t_ref: float = floor(x0)
	if folded:
		x0 = 0.0; x1 = 2.0
	else:
		x0 -= t_ref; x1 -= t_ref
		if x1 - x0 < 1e-3:
			x1 = x0 + 0.01
	var pad: float = maxf((y1 - y0) * 0.08, 0.02)
	y0 -= pad; y1 += pad
	var to_px := func(x: float, y: float) -> Vector2:
		# Magnitudes: brighter (smaller) at the top.
		return Vector2(r.position.x + (x - x0) / (x1 - x0) * r.size.x, r.position.y + (y - y0) / (y1 - y0) * r.size.y)
	var col := Color(0.55, 0.85, 1.0)
	for i in _t.size():
		var xs: Array = []
		if folded:
			var ph: float = fposmod((_t[i] - t_ref) / p, 1.0)
			xs = [ph, ph + 1.0]
		else:
			xs = [_t[i] - t_ref]
		for x in xs:
			var c: Vector2 = to_px.call(x, _m[i])
			_plot.draw_line(to_px.call(x, _m[i] - _e[i]), to_px.call(x, _m[i] + _e[i]), col * Color(1, 1, 1, 0.5), 1.0)
			_plot.draw_circle(c, 2.5, col)
	var grey := Color(0.7, 0.75, 0.85)
	_plot.draw_string(font, Vector2(2, r.position.y + 10), "%.2f" % y0, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, grey)
	_plot.draw_string(font, Vector2(2, r.end.y), "%.2f" % y1, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, grey)
	var xl: String = "phase (P = %.4f d)" % p if folded else "JD − %.0f" % t_ref
	_plot.draw_string(font, Vector2(r.position.x, r.end.y + 16), "%.2f" % x0, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, grey)
	_plot.draw_string(font, Vector2(r.get_center().x - 60, r.end.y + 16), xl, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, grey)
	_plot.draw_string(font, Vector2(r.end.x - 40, r.end.y + 16), "%.2f" % x1, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, grey)
