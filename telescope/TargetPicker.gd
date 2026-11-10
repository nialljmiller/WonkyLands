extends VBoxContainer
## TargetPicker — search box + list of named stars sorted by altitude.
##
## Rows: name (variables get a pink VAR chip), V, altitude with a
## rising ▲ / setting ▼ arrow. "Where I'm looking" is always first.
## Emits `picked` when the selection changes.

signal picked

const SkyModel = preload("res://telescope/SkyModel.gd")
const UiStyle = preload("res://telescope/UiStyle.gd")
const MAX_ROWS: int = 200

var catalog = null
var targets: Array = []          # [{star, alt, rising}] sorted by altitude
var selected_star: int = -1      # -1 = where I'm looking
var _search: LineEdit
var _vars_only: Button
var _tree: Tree

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	var r := UiStyle.row(self, 4)
	_search = LineEdit.new()
	_search.placeholder_text = "Search stars…"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t): _fill())
	_search.text_submitted.connect(func(_t): _pick_first())
	r.add_child(_search)
	_vars_only = UiStyle.chip("VAR only", r, _fill, true)
	_vars_only.tooltip_text = "Show only variable stars"
	_tree = Tree.new()
	_tree.columns = 3
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.focus_mode = Control.FOCUS_NONE
	_tree.custom_minimum_size = Vector2(0, 128)
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.set_column_expand(0, true)
	for c in [1, 2]:
		_tree.set_column_expand(c, false)
		_tree.set_column_custom_minimum_width(c, 54)
	_tree.add_theme_font_size_override("font_size", 13)
	_tree.add_theme_constant_override("v_separation", 2)
	_tree.add_theme_stylebox_override("panel", UiStyle.box(UiStyle.CARD, 8, 4))
	_tree.item_selected.connect(_on_select)
	add_child(_tree)

## Recompute altitudes and rising/setting (cheap: a few thousand dots).
func refresh(engine) -> void:
	var snap: Dictionary = SkyModel.snapshot(engine)
	var b0: Basis = SkyModel.equatorial_basis(snap["lst"], snap["lat"])
	var b1: Basis = SkyModel.equatorial_basis(snap["lst"] + 0.05, snap["lat"])
	targets.clear()
	for i in catalog.named_indices:
		var y: float = (b0 * catalog.unit_eq[i]).y
		if y > 0.087:     # 5°
			targets.append({"star": i, "alt": rad_to_deg(asin(clampf(y, -1.0, 1.0))), "rising": (b1 * catalog.unit_eq[i]).y > y})
	targets.sort_custom(func(a, b): return a["alt"] > b["alt"])
	_fill()

func _fill() -> void:
	_tree.clear()
	var root: TreeItem = _tree.create_item()
	var look: TreeItem = _tree.create_item(root)
	look.set_text(0, "◎  Where I'm looking")
	look.set_custom_color(0, UiStyle.ACCENT)
	look.set_metadata(0, -1)
	if selected_star < 0:
		look.select(0)
	var q: String = _search.text.strip_edges().to_lower()
	var shown: int = 0
	var hidden: int = 0
	for t in targets:
		var i: int = t["star"]
		var vi: int = catalog.variable_of_star(i)
		if (_vars_only.button_pressed and vi < 0) or (q != "" and catalog.star_name(i).to_lower().find(q) < 0):
			continue
		if shown >= MAX_ROWS:
			hidden += 1
			continue
		shown += 1
		var it: TreeItem = _tree.create_item(root)
		it.set_metadata(0, i)
		it.set_text(0, catalog.star_name(i))
		it.set_text(1, "%.1f" % catalog.vmag[i])
		it.set_text(2, "%s %d°" % ["▲" if t["rising"] else "▼", int(t["alt"])])
		it.set_custom_color(2, UiStyle.GOOD if t["rising"] else UiStyle.MUTED)
		it.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
		it.set_text_alignment(2, HORIZONTAL_ALIGNMENT_RIGHT)
		it.set_tooltip_text(0, "%s · V %.2f · %s" % [catalog.star_name(i), catalog.vmag[i], "rising" if t["rising"] else "setting"])
		if vi >= 0:
			var v: Dictionary = catalog.variables[vi]
			it.set_cell_mode(0, TreeItem.CELL_MODE_CUSTOM)
			it.set_custom_draw_callback(0, _draw_var_chip)
			it.set_custom_color(0, UiStyle.VAR)
			it.set_tooltip_text(0, "%s · %s, P = %.3f d" % [catalog.star_name(i), type_name(v["type"]), v["period_days"]])
		if i == selected_star:
			it.select(0)
			_tree.scroll_to_item(it)
	if hidden > 0:
		var more: TreeItem = _tree.create_item(root)
		more.set_text(0, "… %d more, type to search" % hidden)
		more.set_custom_color(0, UiStyle.MUTED)
		more.set_selectable(0, false)
		more.set_selectable(1, false)
		more.set_selectable(2, false)

## Custom cells don't draw their text: name in pink, then the chip.
func _draw_var_chip(it: TreeItem, r: Rect2) -> void:
	var font: Font = _tree.get_theme_default_font()
	_tree.draw_string(font, Vector2(r.position.x + 4, r.get_center().y + 5), catalog.star_name(it.get_metadata(0)), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 46, 13, UiStyle.VAR)
	var cr := Rect2(r.end.x - 38, r.position.y + r.size.y * 0.5 - 8, 34, 16)
	_tree.draw_style_box(UiStyle.box(UiStyle.VAR * Color(1, 1, 1, 0.85), 8, 0), cr)
	_tree.draw_string(font, cr.position + Vector2(0, 12), "VAR", HORIZONTAL_ALIGNMENT_CENTER, cr.size.x, 10, Color(0.1, 0.03, 0.1))

func _on_select() -> void:
	var it: TreeItem = _tree.get_selected()
	if it == null or it.get_metadata(0) == null:
		return
	selected_star = it.get_metadata(0)
	picked.emit()

func _pick_first() -> void:
	var first: TreeItem = _tree.get_root().get_child(1) if _tree.get_root().get_child_count() > 1 else null
	if first and first.get_metadata(0) != null:
		first.select(0)
	_search.release_focus()

func select_star(i: int) -> void:
	selected_star = i
	_fill()

func altitude_of(i: int) -> Dictionary:
	for t in targets:
		if t["star"] == i:
			return t
	return {}

static func type_name(code: String) -> String:
	if code.begins_with("EA"):
		return "Eclipsing binary (Algol type)"
	if code.begins_with("EB"):
		return "Eclipsing binary (β Lyrae type)"
	if code.begins_with("E"):
		return "Eclipsing binary"
	if code.contains("CEP"):
		return "Cepheid"
	if code.begins_with("RR"):
		return "RR Lyrae star"
	if code == "M":
		return "Mira"
	return "Variable star (%s)" % code
