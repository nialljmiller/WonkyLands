extends Control
## FrameView — the CCD frame as the hero of the telescope panel.
##
## Wheel zooms about the cursor, drag pans, double-click resets, a
## click (no drag) emits `clicked(pixel)`. The stretch runs in a shader
## (FrameDisplay). Draws apertures, catalog labels, the compass, a
## banner (saturation / daylight) and the hover readout via `hovered`.

signal clicked(pixel: Vector2)
signal hovered(text: String)

const FrameDisplay = preload("res://telescope/FrameDisplay.gd")
const CCDSimulator = preload("res://telescope/CCDSimulator.gd")
const UiStyle = preload("res://telescope/UiStyle.gd")

var frame: Dictionary = {}
var meas: Dictionary = {}
var comp: Dictionary = {}
var show_labels: bool = true
var banner: String = ""
var banner_color: Color = UiStyle.WARN
var busy_text: String = ""
var empty_text: String = "No frame yet.\nPick a target, then press Expose (Space)."

var zoom: float = 1.0
var _c: Vector2 = Vector2(128, 128)    # display coords at the view centre
var _tex: ImageTexture = null
var _mat := ShaderMaterial.new()
var _img: Control
var _ov: Control
var _press: Vector2 = Vector2.INF
var _dragged: bool = false
var _hover_star: Dictionary = {}

func _ready() -> void:
	clip_contents = true
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	var sh := Shader.new()
	sh.code = FrameDisplay.SHADER
	_mat.shader = sh
	_img = Control.new()
	_img.material = _mat
	_img.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_ov = Control.new()
	for c in [_img, _ov]:
		c.set_anchors_preset(Control.PRESET_FULL_RECT)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(c)
	_img.draw.connect(func(): if _tex: _img.draw_texture_rect(_tex, Rect2(_screen_of(Vector2.ZERO), Vector2.ONE * _n() * _k()), false))
	_ov.draw.connect(_draw_overlay)
	resized.connect(redraw)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.01, 0.012, 0.02))

func set_frame(f: Dictionary, keep_view: bool) -> void:
	frame = f
	_tex = ImageTexture.create_from_image(f["float_image"])
	var lv: Dictionary = f["levels"]
	for k in ["black", "white", "soft", "blown"]:
		_mat.set_shader_parameter(k, lv[k])
	_mat.set_shader_parameter("full_well", f["full_well"])
	if not keep_view:
		reset_view()
	redraw()

func set_stretch(mode: int, gain: float) -> void:
	_mat.set_shader_parameter("mode", mode)
	_mat.set_shader_parameter("gain", gain)

func reset_view() -> void:
	zoom = 1.0
	_c = Vector2.ONE * _n() * 0.5
	redraw()

func redraw() -> void:
	queue_redraw()
	if _img:
		_img.queue_redraw()
		_ov.queue_redraw()

# --- Coordinates: frame pixel (0-based, row 0 = bottom) ↔ screen ----
func _n() -> int:
	return int(frame.get("npix", 256))

func _k() -> float:
	return minf(size.x, size.y) / _n() * zoom

func _screen_of(d: Vector2) -> Vector2:
	return size * 0.5 + (d - _c) * _k()

func to_screen(p: Vector2) -> Vector2:
	return _screen_of(Vector2(p.x + 0.5, _n() - 0.5 - p.y))

func to_pixel(s: Vector2) -> Vector2:
	var d: Vector2 = _c + (s - size * 0.5) / _k()
	return Vector2(d.x - 0.5, _n() - 0.5 - d.y)

func _clamp_view() -> void:
	zoom = clampf(zoom, 1.0, 24.0)
	var half: Vector2 = size * 0.5 / _k()
	var n: float = _n()
	for a in 2:
		_c[a] = n * 0.5 if half[a] * 2.0 >= n else clampf(_c[a], half[a], n - half[a])

# --- Input -----------------------------------------------------------
func _gui_input(e: InputEvent) -> void:
	if frame.is_empty():
		return
	if e is InputEventMouseButton:
		if e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var d: Vector2 = _c + (e.position - size * 0.5) / _k()
			zoom *= 1.25 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8
			zoom = clampf(zoom, 1.0, 24.0)
			_c = d - (e.position - size * 0.5) / _k()
			_clamp_view()
			redraw()
		elif e.button_index == MOUSE_BUTTON_LEFT and e.double_click:
			reset_view()
		elif e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
			_press = e.position
			_dragged = false
		elif e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
			if not _dragged and _press != Vector2.INF:
				clicked.emit(to_pixel(e.position))
			_press = Vector2.INF
		accept_event()
	elif e is InputEventMouseMotion:
		if e.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE):
			if _press == Vector2.INF or _press.distance_to(e.position) > 4.0:
				_dragged = true
			if _dragged:
				_c -= e.relative / _k()
				_clamp_view()
				redraw()
		_hover(e.position)

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and not _hover_star.is_empty():
		_hover_star = {}
		_ov.queue_redraw()
		hovered.emit("")

func _hover(s: Vector2) -> void:
	var p: Vector2 = to_pixel(s)
	var n: int = _n()
	var ix: int = roundi(p.x)
	var iy: int = roundi(p.y)
	if ix < 0 or iy < 0 or ix >= n or iy >= n:
		hovered.emit("")
		return
	var e: float = frame["image"][iy * n + ix]
	var rd: Vector2 = CCDSimulator.unproject(p, frame["ra"], frame["dec"], frame["scale_arcsec"] / CCDSimulator.ARCSEC_PER_RAD, (n - 1) * 0.5)
	var txt: String = "x %d  y %d   %s e⁻%s   RA %s  Dec %s" % [ix + 1, iy + 1, _thousands(e), " (sat)" if e >= frame["full_well"] * 0.999 else "", ra_str(rd.x), dec_str(rd.y)]
	var best: float = 6.0 / maxf(zoom, 1.0) + 2.0
	var star: Dictionary = {}
	for t in frame["truth"]:
		var d: float = Vector2(t["x"], t["y"]).distance_to(p)
		if d < best:
			best = d
			star = t
	if not star.is_empty():
		txt += "   ★ %s %s %.2f" % [star["name"] if star["name"] != "" else "field star", frame["band"], star["mag"]]
	if star != _hover_star:
		_hover_star = star
		_ov.queue_redraw()
	hovered.emit(txt)

static func ra_str(ra: float) -> String:
	var h: float = rad_to_deg(ra) / 15.0
	return "%02dh%02dm%02ds" % [int(h), int(fmod(h * 60.0, 60.0)), int(fmod(h * 3600.0, 60.0))]

static func dec_str(dec: float) -> String:
	var d: float = absf(rad_to_deg(dec))
	return "%s%02d°%02d′%02d″" % ["−" if dec < 0.0 else "+", int(d), int(fmod(d * 60.0, 60.0)), int(fmod(d * 3600.0, 60.0))]

static func _thousands(v: float) -> String:
	var s: String = str(int(round(v)))
	var out: String = ""
	while s.length() > 3:
		out = " " + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out

# --- Overlay ---------------------------------------------------------
func _draw_overlay() -> void:
	var font: Font = get_theme_default_font()
	if _tex == null:
		_center_text(font, empty_text if busy_text == "" else busy_text, UiStyle.MUTED)
		return
	var k: float = _k()
	var faint: float = 5.0 * sqrt(frame["sky_e"] + pow(frame["read_noise"], 2.0)) * 2.0 * PI * pow(frame["fwhm_px"] / 2.3548, 2.0)
	if show_labels:
		for t in frame["truth"]:
			var bright: bool = t["star"] >= 0
			# Field stars only when zoomed in and actually detectable (≳ 5σ peak over sky).
			if not bright and (zoom < 3.0 or t["e"] < faint):
				continue
			var s: Vector2 = to_screen(Vector2(t["x"], t["y"]))
			if not Rect2(Vector2.ZERO, size).grow(-4).has_point(s):
				continue
			var txt: String = ("%s %.2f" % [t["name"], t["mag"]]) if bright else "%.1f" % t["mag"]
			var off := Vector2(maxf(frame["fwhm_px"] * k, 6.0) + 3.0, -4.0)
			if bright:
				_ov.draw_line(s + off * Vector2(0.5, 0) + Vector2(0, -2), s + off + Vector2(-2, 0), Color(0.6, 0.85, 1.0, 0.5), 1.0)
			_ov.draw_string_outline(font, s + off, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color(0, 0, 0, 0.8))
			_ov.draw_string(font, s + off, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.65, 0.88, 1.0) if bright else Color(0.75, 0.75, 0.8, 0.8))
	for item in [[comp, Color(0.4, 0.8, 1.0)], [meas, UiStyle.BAD if meas.get("saturated", false) else UiStyle.GOOD]]:
		var m: Dictionary = item[0]
		if m.is_empty():
			continue
		var c: Vector2 = to_screen(Vector2(m["x"], m["y"]))
		_ov.draw_arc(c, m["r_ap"] * k, 0, TAU, 48, item[1], 1.5)
		_ov.draw_arc(c, m["r_in"] * k, 0, TAU, 48, item[1] * Color(1, 1, 1, 0.45), 1.0)
		_ov.draw_arc(c, m["r_out"] * k, 0, TAU, 48, item[1] * Color(1, 1, 1, 0.45), 1.0)
	if not _hover_star.is_empty():
		_ov.draw_arc(to_screen(Vector2(_hover_star["x"], _hover_star["y"])), maxf(frame["fwhm_px"] * k * 1.2, 7.0), 0, TAU, 32, Color(1, 1, 0.6, 0.6), 1.0)
	# Compass: N up, E left.
	var o := Vector2(size.x - 26, size.y - 26)
	var cc := Color(1, 1, 0.6, 0.75)
	_ov.draw_line(o, o + Vector2(0, -18), cc, 1.5)
	_ov.draw_line(o, o + Vector2(-18, 0), cc, 1.5)
	_ov.draw_string(font, o + Vector2(-4, -21), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, cc)
	_ov.draw_string(font, o + Vector2(-31, 4), "E", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, cc)
	if zoom > 1.01:
		_ov.draw_string(font, Vector2(8, size.y - 10), "×%.1f" % zoom, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, cc)
	if banner != "":
		_pill(font, banner, Vector2(size.x * 0.5, 22), banner_color)
	if busy_text != "":
		_pill(font, busy_text, size * 0.5, UiStyle.ACCENT)

func _pill(font: Font, txt: String, at: Vector2, col: Color) -> void:
	var w: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	var r := Rect2(at - Vector2(w * 0.5 + 12, 14), Vector2(w + 24, 28))
	var sb := UiStyle.box(Color(0.04, 0.05, 0.08, 0.85), 14, 0)
	sb.set_border_width_all(1)
	sb.border_color = col * Color(1, 1, 1, 0.6)
	_ov.draw_style_box(sb, r)
	_ov.draw_string(font, r.position + Vector2(12, 19), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)

func _center_text(font: Font, txt: String, col: Color) -> void:
	var lines: PackedStringArray = txt.split("\n")
	for i in lines.size():
		var y: float = size.y * 0.5 + (i - lines.size() * 0.5) * 22.0
		_ov.draw_string(font, Vector2(0, y), lines[i], HORIZONTAL_ALIGNMENT_CENTER, size.x, 15, col)
