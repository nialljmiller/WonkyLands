extends PanelContainer
## LogPanel — light curves from the observing log.
##
## Pick a target; band chips overlay bands in their own colours (one
## band: points coloured by night). Axes with ticks, magnitude inverted
## (brighter up), error bars, hover tooltip, wheel-zoom/drag on time.
## Fold on a period (field, ‹ › nudges and a fine slider), or let
## Find period (Lafler–Kinman, worker thread) draw the periodogram:
## click a dip or a candidate chip to fold on it.

signal closed

const ObservingLog = preload("res://telescope/ObservingLog.gd")
const UiStyle = preload("res://telescope/UiStyle.gd")

const BAND_COLORS: Dictionary = {"B": Color(0.45, 0.62, 1.0), "V": Color(0.45, 0.95, 0.55), "R": Color(1.0, 0.45, 0.4),
	"I": Color(0.85, 0.35, 0.6), "g": Color(0.3, 0.85, 0.8), "r": Color(1.0, 0.65, 0.3), "i": Color(0.8, 0.6, 0.45)}
const NIGHT_COLORS: Array = [Color(0.55, 0.85, 1.0), Color(1.0, 0.75, 0.4), Color(0.6, 1.0, 0.6),
	Color(1.0, 0.55, 0.75), Color(0.8, 0.7, 1.0), Color(1.0, 1.0, 0.55)]
const HOW_TO: String = "No observations yet. Here's how to make a light curve:\n\n1   Press T to place the telescope, walk up to it and press F.\n2   Pick a variable star (VAR), e.g. Algol, and press Expose.\n3   Press Monitor tonight, close the panel and press N to warp time.\n4   Come back here with L: the curve fills in night by night."

var _rows: Array = []
var _data: Dictionary = {}           # band -> {t, m, e, X} for the target
var _bands_on: Dictionary = {}       # band -> true
var _target_opt: OptionButton
var _band_row: HBoxContainer
var _count: Label
var _fold: Button
var _period: SpinBox
var _nudge: HSlider
var _p_base: float = 1.0
var _cands: HBoxContainer
var _controls: HBoxContainer
var _plot: Control
var _pgram: Control
var _result: Label
var _task: int = -1
var _search: Dictionary = {}
var _xr: Vector2 = Vector2.ZERO      # zoomed x range (ZERO = auto)
var _screen_pts: Array = []          # [pos, band, i] from the last draw
var _hover: Array = []
var _plot_rect: Rect2
var _x_auto: Vector2

func _ready() -> void:
	UiStyle.panel(self)
	var v := UiStyle.col(self, 8)
	var head := UiStyle.row(v, 8)
	head.add_child(UiStyle.label("LIGHT CURVES", 17, UiStyle.ACCENT))
	_target_opt = OptionButton.new()
	_target_opt.focus_mode = Control.FOCUS_NONE
	_target_opt.custom_minimum_size = Vector2(180, 0)
	_target_opt.item_selected.connect(func(_i): _select(true))
	head.add_child(_target_opt)
	_band_row = UiStyle.row(head, 3)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	_count = UiStyle.label("", 13, UiStyle.MUTED)
	head.add_child(_count)
	UiStyle.chip("✕", head, func(): closed.emit()).tooltip_text = "Close (Esc)"

	_controls = UiStyle.row(v, 6)
	var row := _controls
	_fold = UiStyle.chip("Fold", row, func(): _xr = Vector2.ZERO; _redraw(), true)
	_fold.tooltip_text = "Plot against phase = (JD mod P) / P, shown twice"
	row.add_child(UiStyle.label("P", 14, UiStyle.MUTED))
	_period = SpinBox.new()
	_period.min_value = 0.05
	_period.max_value = 100.0
	_period.step = 0.00001
	_period.value = 1.0
	_period.suffix = "d"
	_period.custom_minimum_size = Vector2(120, 0)
	_period.value_changed.connect(_on_period_typed)
	row.add_child(_period)
	UiStyle.chip("‹", row, func(): set_period(_period.value * 0.9995)).tooltip_text = "Nudge period shorter"
	UiStyle.chip("›", row, func(): set_period(_period.value * 1.0005)).tooltip_text = "Nudge period longer"
	_nudge = HSlider.new()
	_nudge.min_value = -0.02
	_nudge.max_value = 0.02
	_nudge.step = 0.0001
	_nudge.focus_mode = Control.FOCUS_NONE
	_nudge.custom_minimum_size = Vector2(110, 0)
	_nudge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_nudge.tooltip_text = "Fine-tune the period (±2 %)"
	_nudge.value_changed.connect(func(x): _set_period_value(_p_base * (1.0 + x)))
	row.add_child(_nudge)
	UiStyle.chip("Find period", row, find_period).tooltip_text = "Lafler–Kinman string-length search over the selected band"
	_cands = UiStyle.row(row, 4)

	_plot = Control.new()
	_plot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_plot.custom_minimum_size = Vector2(400, 220)
	_plot.clip_contents = true
	_plot.draw.connect(_draw_plot)
	_plot.gui_input.connect(_plot_input)
	_plot.mouse_exited.connect(func(): _hover = []; _plot.queue_redraw())
	v.add_child(_plot)
	_pgram = Control.new()
	_pgram.custom_minimum_size = Vector2(400, 120)
	_pgram.visible = false
	_pgram.draw.connect(_draw_pgram)
	_pgram.gui_input.connect(_pgram_input)
	_pgram.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_pgram.tooltip_text = "Click a dip to fold on that period"
	v.add_child(_pgram)
	var foot := UiStyle.row(v, 8)
	_result = UiStyle.label("", 13, UiStyle.TEXT)
	_result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(_result)
	foot.add_child(UiStyle.label("scroll zoom time · drag pan · double-click reset · Esc close", 11, Color(0.45, 0.5, 0.6)))

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
		_target_opt.add_item("%s  (%d)" % [names[k], targets[names[k]]])
		_target_opt.set_item_metadata(k, names[k])
		if names[k] == prev_t:
			_target_opt.select(k)
	_target_opt.visible = not names.is_empty()
	_controls.visible = not names.is_empty()
	_select(false)

## Show a target in a band (or "V,B"): the telescope's "Open light curve".
func focus(target: String, band: String) -> void:
	for k in _target_opt.item_count:
		if _target_opt.get_item_metadata(k) == target:
			_target_opt.select(k)
			_bands_on = {}
			for b in band.split(","):
				_bands_on[b] = true
			_fold.set_pressed_no_signal(false)
			_select(true)
			return

func set_fold(on: bool) -> void:
	_fold.button_pressed = on

func _target() -> String:
	return _target_opt.get_item_metadata(_target_opt.selected) if _target_opt.selected >= 0 else ""

func _select(new_target: bool) -> void:
	var tgt: String = _target()
	_data = {}
	for r in _rows:
		if r["target"] != tgt:
			continue
		if not _data.has(r["band"]):
			_data[r["band"]] = {"t": PackedFloat64Array(), "m": PackedFloat32Array(), "e": PackedFloat32Array(), "X": PackedFloat32Array()}
		var d: Dictionary = _data[r["band"]]
		d["t"].append(r["jd"]); d["m"].append(r["mag"]); d["e"].append(r["err"]); d["X"].append(r["airmass"])
	var keep: Dictionary = {}
	for b in _bands_on:
		if _data.has(b):
			keep[b] = true
	if keep.is_empty() and not _data.is_empty():
		keep[_data.keys()[0] if not _data.has("V") else "V"] = true
	_bands_on = keep
	for c in _band_row.get_children():
		c.queue_free()
	for b in _data:
		var chip: Button = UiStyle.chip(b, _band_row, _toggle_band.bind(b), true)
		chip.set_pressed_no_signal(_bands_on.has(b))
		chip.add_theme_color_override("font_color", BAND_COLORS.get(b, UiStyle.TEXT))
		for k in ["pressed", "hover_pressed"]:
			chip.add_theme_stylebox_override(k, UiStyle.box(BAND_COLORS.get(b, UiStyle.ACCENT).darkened(0.45), 12, 4))
		chip.add_theme_color_override("font_pressed_color", Color.WHITE)
		chip.tooltip_text = "%d points in %s" % [_data[b]["t"].size(), b]
	if new_target:
		_search = {}
		_pgram.visible = false
		for c in _cands.get_children():
			c.queue_free()
	_xr = Vector2.ZERO
	var n: int = 0
	for b in _bands_on:
		n += _data[b]["t"].size()
	_count.text = "%d points" % n if n > 0 else ""
	_result.text = "" if n >= 8 or _rows.is_empty() else "Only %d point%s so far: Monitor tonight builds a curve." % [n, "" if n == 1 else "s"]
	_redraw()

func _toggle_band(b: String) -> void:
	if _bands_on.has(b) and _bands_on.size() > 1:
		_bands_on.erase(b)
	else:
		_bands_on[b] = true
	_select(false)

func _redraw() -> void:
	_plot.queue_redraw()
	_pgram.queue_redraw()

# --- Period ---------------------------------------------------------
func set_period(p: float) -> void:
	_p_base = p
	_nudge.set_value_no_signal(0.0)
	_set_period_value(p)

func _set_period_value(p: float) -> void:
	_period.set_value_no_signal(p)
	_redraw()

func _on_period_typed(p: float) -> void:
	_p_base = p
	_nudge.set_value_no_signal(0.0)
	_redraw()

func _search_band() -> String:
	return "V" if _bands_on.has("V") else (_bands_on.keys()[0] if not _bands_on.is_empty() else "")

func find_period() -> void:
	var b: String = _search_band()
	if _task >= 0 or b == "" or _data[b]["t"].size() < 8:
		_result.text = "Need at least 8 points in one band for a period search."
		return
	var t: PackedFloat64Array = _data[b]["t"]
	var span: float = 0.0
	for x in t:
		span = maxf(span, x - t[0])
	var p_max: float = clampf(span * 0.7, 0.3, 30.0)
	_result.text = "Searching 0.2 – %.1f d in %s…" % [p_max, b]
	_task = WorkerThreadPool.add_task(_search_worker.bind(t.duplicate(), _data[b]["m"].duplicate(), p_max), false, "period search")

func _search_worker(t: PackedFloat64Array, m: PackedFloat32Array, p_max: float) -> void:
	var res: Dictionary = ObservingLog.period_search(t, m, 0.2, p_max)
	res["p_max"] = p_max
	call_deferred("_on_found", res)

func _on_found(res: Dictionary) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	for c in _cands.get_children():
		c.queue_free()
	if res["period"] <= 0.0:
		_result.text = "No convincing period yet: keep observing."
		return
	_search = res
	_pgram.visible = true
	for k in res["candidates"].size():
		var cnd: Array = res["candidates"][k]
		var chip: Button = UiStyle.chip("%.4f d" % cnd[0], _cands, func(): set_period(cnd[0]); _fold.button_pressed = true, false, 12)
		chip.tooltip_text = "θ = %.2f%s" % [cnd[1], "  (best)" if k == 0 else ""]
	set_period(res["period"])
	_fold.button_pressed = true
	_result.text = "Best period %.4f d (%.2f h), θ = %.3f: lower θ means a cleaner fold." % [res["period"], res["period"] * 24.0, res["theta"]]
	for c in res["candidates"]:
		if absf(c[0] / res["period"] - 2.0) < 0.02:
			_result.text += "  Eclipsing binaries often fold best at twice that: try %.4f d." % c[0]

func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)

# --- Light-curve plot -------------------------------------------------
func _draw_plot() -> void:
	var font: Font = get_theme_default_font()
	var r := Rect2(Vector2(62, 10), _plot.size - Vector2(76, 46))
	_plot_rect = r
	_plot.draw_style_box(UiStyle.box(Color(0.02, 0.03, 0.05, 0.9), 6, 0), r)
	_screen_pts = []
	if _rows.is_empty():
		var lines: PackedStringArray = HOW_TO.split("\n")
		for i in lines.size():
			_plot.draw_string(font, Vector2(r.position.x + r.size.x * 0.5 - 250, r.get_center().y + (i - lines.size() * 0.5) * 22.0 + 8),
				lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 15 if i == 0 else 14, UiStyle.ACCENT if i == 0 else UiStyle.TEXT)
		return
	if _bands_on.is_empty():
		return
	var folded: bool = _fold.button_pressed
	var p: float = _period.value
	var t_min: float = INF; var t_max: float = -INF; var y0: float = INF; var y1: float = -INF
	for b in _bands_on:
		var d: Dictionary = _data[b]
		for i in d["t"].size():
			t_min = minf(t_min, d["t"][i]); t_max = maxf(t_max, d["t"][i])
			y0 = minf(y0, d["m"][i] - d["e"][i]); y1 = maxf(y1, d["m"][i] + d["e"][i])
	var t_ref: float = floor(t_min)
	var pad_y: float = maxf((y1 - y0) * 0.08, 0.02)
	y0 -= pad_y; y1 += pad_y
	var span: float = maxf(t_max - t_min, 0.02)
	_x_auto = Vector2(0.0, 2.0) if folded else Vector2(t_min - t_ref - span * 0.03, t_max - t_ref + span * 0.03)
	var xr: Vector2 = _xr if _xr != Vector2.ZERO else _x_auto
	var to_px := func(x: float, y: float) -> Vector2:
		return Vector2(r.position.x + (x - xr.x) / (xr.y - xr.x) * r.size.x, r.position.y + (y - y0) / (y1 - y0) * r.size.y)
	# Grid + ticks
	var grid := Color(1, 1, 1, 0.07)
	var tc := Color(0.7, 0.75, 0.85)
	var yt: Array = UiStyle.ticks(y0, y1, 6)
	var yd: int = UiStyle.tick_decimals(yt)
	for y in yt:
		var py: float = to_px.call(xr.x, y).y
		_plot.draw_line(Vector2(r.position.x, py), Vector2(r.end.x, py), grid)
		_plot.draw_string(font, Vector2(4, py + 4), "%.*f" % [yd, y], HORIZONTAL_ALIGNMENT_RIGHT, r.position.x - 10, 11, tc)
	var xt: Array = UiStyle.ticks(xr.x, xr.y, 8)
	var xd: int = UiStyle.tick_decimals(xt)
	for x in xt:
		var px: float = to_px.call(x, y0).x
		_plot.draw_line(Vector2(px, r.position.y), Vector2(px, r.end.y), grid)
		_plot.draw_line(Vector2(px, r.end.y), Vector2(px, r.end.y + 4), tc)
		_plot.draw_string(font, Vector2(px - 40, r.end.y + 17), "%.*f" % [xd, x], HORIZONTAL_ALIGNMENT_CENTER, 80, 11, tc)
	var band_list: String = " ".join(PackedStringArray(_bands_on.keys()))
	var ylab := "%s mag  (brighter ↑)" % band_list
	_plot.draw_set_transform(Vector2(13, r.get_center().y + font.get_string_size(ylab, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x * 0.5), -PI * 0.5)
	_plot.draw_string(font, Vector2.ZERO, ylab, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, tc)
	_plot.draw_set_transform(Vector2.ZERO)
	var obs = load("res://telescope/Observatory.gd")
	var xl: String = "phase  (P = %.5f d)" % p if folded else "days since JD %.0f  (%s UT)" % [t_ref, obs.jd_to_string(t_ref)]
	_plot.draw_string(font, Vector2(r.position.x, r.end.y + 32), xl, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 12, tc)
	# Points
	var by_night: bool = _bands_on.size() == 1
	var nights: Dictionary = {}
	for b in _bands_on:
		var d: Dictionary = _data[b]
		for i in d["t"].size():
			var night: int = int(floor(d["t"][i])) - int(t_ref)
			nights[night] = true
			var col: Color = NIGHT_COLORS[night % NIGHT_COLORS.size()] if by_night else BAND_COLORS.get(b, UiStyle.ACCENT)
			var xs: Array = [d["t"][i] - t_ref]
			if folded:
				var ph: float = fposmod((d["t"][i] - t_ref) / p, 1.0)
				xs = [ph, ph + 1.0]
			for x in xs:
				if x < xr.x or x > xr.y:
					continue
				var c: Vector2 = to_px.call(x, d["m"][i])
				var lo: Vector2 = to_px.call(x, d["m"][i] - d["e"][i])
				var hi: Vector2 = to_px.call(x, d["m"][i] + d["e"][i])
				if hi.y - lo.y > 3.0:
					_plot.draw_line(lo, hi, col * Color(1, 1, 1, 0.45), 1.0)
					_plot.draw_line(lo - Vector2(2, 0), lo + Vector2(2, 0), col * Color(1, 1, 1, 0.45), 1.0)
					_plot.draw_line(hi - Vector2(2, 0), hi + Vector2(2, 0), col * Color(1, 1, 1, 0.45), 1.0)
				_plot.draw_circle(c, 2.6, col)
				_screen_pts.append([c, b, i, x])
	# Legend
	if by_night and nights.size() > 1:
		_plot.draw_string(font, Vector2(r.end.x - 208, r.position.y + 16), "colour = night (%d nights)" % nights.size(), HORIZONTAL_ALIGNMENT_RIGHT, 200, 11, tc)
	if not _hover.is_empty():
		_draw_tooltip(font, r, t_ref, folded, p)

func _draw_tooltip(font: Font, r: Rect2, t_ref: float, folded: bool, p: float) -> void:
	var pos: Vector2 = _hover[0]
	var d: Dictionary = _data[_hover[1]]
	var i: int = _hover[2]
	var obs = load("res://telescope/Observatory.gd")
	var lines: Array = ["%s UT" % obs.jd_to_string(d["t"][i]), "JD %.4f" % d["t"][i],
		"%s = %.3f ± %.3f" % [_hover[1], d["m"][i], d["e"][i]], "airmass %.2f" % d["X"][i]]
	if folded:
		lines.append("phase %.3f" % fposmod((d["t"][i] - t_ref) / p, 1.0))
	var w: float = 0.0
	for l in lines:
		w = maxf(w, font.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x)
	var box := Rect2(pos + Vector2(12, -12), Vector2(w + 20, lines.size() * 17 + 10))
	if box.end.x > r.end.x:
		box.position.x = pos.x - box.size.x - 12
	if box.end.y > r.end.y:
		box.position.y = r.end.y - box.size.y
	box.position.y = maxf(box.position.y, r.position.y)
	_plot.draw_circle(pos, 5.0, Color(1, 1, 1, 0.9), false, 1.5)
	var sb := UiStyle.box(Color(0.08, 0.1, 0.16, 0.96), 6, 0)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.4, 0.5, 0.7)
	_plot.draw_style_box(sb, box)
	for k in lines.size():
		_plot.draw_string(font, box.position + Vector2(10, 20 + k * 17), lines[k], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UiStyle.TEXT if k != 2 else Color.WHITE)

func _plot_input(e: InputEvent) -> void:
	var r: Rect2 = _plot_rect
	var xr: Vector2 = _xr if _xr != Vector2.ZERO else _x_auto
	if r.size.x <= 0.0 or xr == Vector2.ZERO:
		return
	if e is InputEventMouseButton and e.pressed:
		if e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var xm: float = xr.x + (e.position.x - r.position.x) / r.size.x * (xr.y - xr.x)
			var f: float = 0.8 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1.25
			_xr = Vector2(xm - (xm - xr.x) * f, xm + (xr.y - xm) * f)
			_plot.queue_redraw()
			_plot.accept_event()
		elif e.button_index == MOUSE_BUTTON_LEFT and e.double_click:
			_xr = Vector2.ZERO
			_plot.queue_redraw()
	elif e is InputEventMouseMotion:
		if e.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var dx: float = -e.relative.x / r.size.x * (xr.y - xr.x)
			_xr = xr + Vector2(dx, dx)
		var best: float = 10.0
		_hover = []
		for sp in _screen_pts:
			var dd: float = sp[0].distance_to(e.position)
			if dd < best:
				best = dd
				_hover = sp
		_plot.queue_redraw()

# --- Periodogram -------------------------------------------------------
func _pg_rect() -> Rect2:
	return Rect2(Vector2(62, 6), _pgram.size - Vector2(76, 30))

func _p_to_x(p: float, r: Rect2) -> float:
	var lo: float = log(0.2)
	var hi: float = log(float(_search["p_max"]))
	return r.position.x + (log(p) - lo) / (hi - lo) * r.size.x

func _x_to_p(x: float, r: Rect2) -> float:
	var lo: float = log(0.2)
	var hi: float = log(float(_search["p_max"]))
	return exp(lo + (x - r.position.x) / r.size.x * (hi - lo))

func _draw_pgram() -> void:
	if _search.is_empty():
		return
	var font: Font = get_theme_default_font()
	var r: Rect2 = _pg_rect()
	_pgram.draw_style_box(UiStyle.box(Color(0.02, 0.03, 0.05, 0.9), 6, 0), r)
	var th: PackedFloat32Array = _search["thetas"]
	var f0: float = _search["f0"]
	var df: float = _search["df"]
	var cols: int = int(r.size.x)
	var lowest := PackedFloat32Array()
	lowest.resize(cols)
	lowest.fill(INF)
	var tmax: float = 0.0
	for k in th.size():
		var c: int = clampi(int(_p_to_x(1.0 / (f0 + k * df), r) - r.position.x), 0, cols - 1)
		lowest[c] = minf(lowest[c], th[k])
		tmax = maxf(tmax, th[k])
	tmax = maxf(tmax, 1e-6)
	var pts := PackedVector2Array()
	for c in cols:
		if lowest[c] < INF:
			pts.append(Vector2(r.position.x + c, r.end.y - 4 - lowest[c] / tmax * (r.size.y - 8)))
	if pts.size() > 1:
		_pgram.draw_polyline(pts, UiStyle.ACCENT * Color(1, 1, 1, 0.85), 1.0)
	var tc := Color(0.7, 0.75, 0.85)
	for p in [0.2, 0.3, 0.5, 1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 30.0]:
		if p > float(_search["p_max"]) * 1.001:
			break
		var x: float = _p_to_x(p, r)
		_pgram.draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.06))
		_pgram.draw_string(font, Vector2(x - 20, r.end.y + 14), ("%.1f" % p).trim_suffix(".0"), HORIZONTAL_ALIGNMENT_CENTER, 40, 11, tc)
	_pgram.draw_string(font, Vector2(4, r.position.y + 12), "θ", HORIZONTAL_ALIGNMENT_RIGHT, r.position.x - 12, 12, tc)
	_pgram.draw_string(font, Vector2(4, r.end.y), "↓ better", HORIZONTAL_ALIGNMENT_RIGHT, r.position.x - 12, 10, Color(0.5, 0.55, 0.65))
	_pgram.draw_string(font, Vector2(r.end.x - 160, r.end.y + 14), "period (d, log)", HORIZONTAL_ALIGNMENT_RIGHT, 160, 11, tc)
	for c in _search["candidates"]:
		var x: float = _p_to_x(c[0], r)
		_pgram.draw_circle(Vector2(x, r.end.y - 4 - c[1] / tmax * (r.size.y - 8)), 3.5, UiStyle.WARN)
	var xp: float = _p_to_x(_period.value, r)
	if xp >= r.position.x and xp <= r.end.x:
		_pgram.draw_line(Vector2(xp, r.position.y), Vector2(xp, r.end.y), UiStyle.GOOD * Color(1, 1, 1, 0.8), 1.5)

func _pgram_input(e: InputEvent) -> void:
	if _search.is_empty() or not (e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT):
		return
	var r: Rect2 = _pg_rect()
	var th: PackedFloat32Array = _search["thetas"]
	var f0: float = _search["f0"]
	var df: float = _search["df"]
	# Deepest θ within ±6 px of the click.
	var fa: float = 1.0 / _x_to_p(e.position.x + 6.0, r)
	var fb: float = 1.0 / _x_to_p(e.position.x - 6.0, r)
	var best_k: int = -1
	for k in range(clampi(int((fa - f0) / df), 0, th.size() - 1), clampi(int((fb - f0) / df) + 1, 0, th.size())):
		if best_k < 0 or th[k] < th[best_k]:
			best_k = k
	if best_k >= 0:
		set_period(1.0 / (f0 + best_k * df))
		_fold.button_pressed = true
		_result.text = "Folded on %.4f d (θ = %.2f)." % [_period.value, th[best_k]]
