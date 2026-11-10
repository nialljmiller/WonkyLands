extends RefCounted
## UiStyle — shared look for the astronomy panels: dark rounded
## panels, pill chips, numbered step headers, toasts.

const BG := Color(0.05, 0.06, 0.1, 0.92)
const CARD := Color(0.09, 0.11, 0.17, 0.95)
const ACCENT := Color(0.45, 0.75, 1.0)
const TEXT := Color(0.86, 0.9, 1.0)
const MUTED := Color(0.55, 0.62, 0.74)
const GOOD := Color(0.4, 0.9, 0.55)
const WARN := Color(1.0, 0.72, 0.3)
const BAD := Color(1.0, 0.42, 0.38)
const VAR := Color(1.0, 0.55, 0.85)

static func box(bg: Color, radius: int = 10, margin: float = 12.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	return sb

static func panel(c: PanelContainer) -> void:
	c.add_theme_stylebox_override("panel", box(BG))
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 16)

static func card(margin: float = 8.0) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(CARD, 8, margin))
	return p

static func label(t: String, size: int = 14, col: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l

## Small helper text that wraps inside a column.
static func hint(t: String = "") -> Label:
	var l := label(t, 12, MUTED)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

## "① POINT" style header.
static func step(n: String, title: String) -> Label:
	var l := label("%s  %s" % [n, title], 15, ACCENT)
	return l

## Pill button. Toggle chips get an accent fill when pressed. Buttons
## never take focus, so Space stays the expose key.
static func chip(t: String, parent: Control = null, cb: Callable = Callable(), toggle: bool = false, size: int = 13) -> Button:
	var b := Button.new()
	b.text = t
	b.toggle_mode = toggle
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", size)
	var pad := 4.0 if size <= 13 else 6.0
	for s in [["normal", Color(0.14, 0.17, 0.25)], ["hover", Color(0.2, 0.24, 0.34)],
			["pressed", Color(0.22, 0.42, 0.66)], ["hover_pressed", Color(0.26, 0.48, 0.74)],
			["disabled", Color(0.1, 0.11, 0.15)]]:
		var sb := box(s[1], 12, pad)
		sb.content_margin_left = pad + 5.0
		sb.content_margin_right = pad + 5.0
		b.add_theme_stylebox_override(s[0], sb)
	b.add_theme_color_override("font_disabled_color", Color(0.4, 0.43, 0.5))
	if cb.is_valid():
		if toggle:
			b.toggled.connect(func(_on): cb.call())
		else:
			b.pressed.connect(cb)
	if parent:
		parent.add_child(b)
	return b

## Big primary action (Expose).
static func primary(t: String, parent: Control, cb: Callable) -> Button:
	var b := chip(t, parent, cb, false, 17)
	for s in [["normal", Color(0.2, 0.5, 0.85)], ["hover", Color(0.28, 0.58, 0.95)], ["pressed", Color(0.16, 0.4, 0.7)]]:
		var sb := box(s[1], 12, 8)
		b.add_theme_stylebox_override(s[0], sb)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b

static func row(parent: Control, sep: int = 6) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	parent.add_child(h)
	return h

static func col(parent: Control, sep: int = 6) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	parent.add_child(v)
	return v

## Short-lived message with an optional action button, faded out.
static func toast(host: Control, text: String, action: String = "", cb: Callable = Callable()) -> void:
	for c in host.get_children():
		if c.has_meta("toast"):
			c.queue_free()
	var p := PanelContainer.new()
	p.set_meta("toast", true)
	p.add_theme_stylebox_override("panel", box(Color(0.12, 0.16, 0.24, 0.96), 10, 8))
	var h := row(p, 10)
	var l := label(text, 13)
	h.add_child(l)
	if action != "":
		chip(action, h, cb)
	host.add_child(p)
	p.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 14)
	p.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var tw := p.create_tween()
	tw.tween_interval(4.0)
	tw.tween_property(p, "modulate:a", 0.0, 0.6)
	tw.tween_callback(p.queue_free)

## Axis ticks: ~n "nice" values covering [a, b].
static func ticks(a: float, b: float, n: int = 6) -> Array:
	var span: float = absf(b - a)
	if span <= 0.0:
		return [a]
	var raw: float = span / n
	var mag: float = pow(10.0, floor(log(raw) / log(10.0)))
	var step_v: float = mag
	for m in [1.0, 2.0, 2.5, 5.0, 10.0]:
		step_v = m * mag
		if step_v >= raw:
			break
	var out: Array = []
	var v: float = ceil(minf(a, b) / step_v) * step_v
	while v <= maxf(a, b) + step_v * 1e-6:
		out.append(v)
		v += step_v
	return out

## Decimals needed to print ticks of this spacing.
static func tick_decimals(ts: Array) -> int:
	if ts.size() < 2:
		return 2
	var step_v: float = absf(ts[1] - ts[0])
	for d in 5:
		var x: float = step_v * pow(10.0, d)
		if absf(x - round(x)) < 1e-4 * maxf(x, 1.0):
			return d
	return 4
