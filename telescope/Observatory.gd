extends Node3D
## Observatory — the player's astronomy kit.
##
##   T  place the telescope in front of you (again to move it)
##   F  (interact) use the telescope when standing next to it
##   N  time warp: ×60 → ×600 → ×3600 → ×60
##   L  observing log / light curves
##   Esc closes any open panel
##
## Owns a small HUD line (game date/time UT and warp) and the panels.
## Nothing here runs per frame beyond a few cheap checks; the HUD text
## refreshes at 4 Hz.

const SkyCatalog = preload("res://telescope/SkyCatalog.gd")
const SkyModel = preload("res://telescope/SkyModel.gd")
const TelescopeScript = preload("res://telescope/Telescope.gd")
const TelescopePanelScript = preload("res://telescope/TelescopePanel.gd")
const LogPanelScript = preload("res://telescope/LogPanel.gd")
const UiStyle = preload("res://telescope/UiStyle.gd")

const WARP_STEPS: Array = [60.0, 600.0, 3600.0]
const USE_RANGE_M: float = 3.0

var engine = null    # AstronomyEngine, set by TerrainGenerator

var catalog = null
var telescope: Node3D = null
var panel = null
var log_panel = null
var _layer: CanvasLayer = null
var _hud: Label = null
var _hint: Label = null
var _hud_accum: float = 0.0
var _open_panel: Control = null

func _ready() -> void:
	catalog = SkyCatalog.shared()
	_layer = CanvasLayer.new()
	_layer.layer = 5
	add_child(_layer)
	_hud = Label.new()
	_hud.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hud.position = Vector2(-420, 8)
	_hud.size = Vector2(410, 40)
	_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hud.add_theme_font_size_override("font_size", 13)
	_hud.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0, 0.85))
	_hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_layer.add_child(_hud)
	_hint = UiStyle.label("", 15)
	_hint.add_theme_stylebox_override("normal", UiStyle.box(Color(0.05, 0.06, 0.1, 0.75), 14, 8))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.visible = false
	_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 70)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_layer.add_child(_hint)

	panel = TelescopePanelScript.new()
	panel.engine = engine
	panel.catalog = catalog
	panel.look_dir_provider = _look_dir
	panel.visible = false
	panel.closed.connect(close_panels)
	panel.warp.connect(cycle_warp)
	panel.open_light_curve.connect(func(t, b): open_panel(log_panel); log_panel.focus(t, b))
	_layer.add_child(panel)
	log_panel = LogPanelScript.new()
	log_panel.visible = false
	log_panel.closed.connect(close_panels)
	_layer.add_child(log_panel)

func _player() -> Node3D:
	if typeof(World) == TYPE_NIL:
		return null
	return World.get_player()

## Player on foot and in control (not flying, not in a panel).
func _player_free(p: Node3D) -> bool:
	return p != null and p.is_physics_processing() and _open_panel == null

func _look_dir() -> Vector3:
	var p := _player()
	if p == null:
		return Vector3.UP
	var cam: Camera3D = get_viewport().get_camera_3d()
	return -cam.global_transform.basis.z if cam else -p.global_transform.basis.z

func _process(delta: float) -> void:
	var p := _player()
	if _player_free(p):
		if Input.is_action_just_pressed("telescope_place"):
			place_telescope()
		if Input.is_action_just_pressed("time_warp"):
			cycle_warp()
		if Input.is_action_just_pressed("interact") and _near_telescope(p) and not _vehicle_claims(p):
			open_panel(panel)
		if Input.is_action_just_pressed("observing_log"):
			open_panel(log_panel)
	_hud_accum += delta
	if _hud_accum >= 0.25:
		_hud_accum = 0.0
		_update_hud(p)

func _input(event: InputEvent) -> void:
	if _open_panel != null and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_panels()
		get_viewport().set_input_as_handled()

## True if a vehicle (anything tracking a `nearby_player`, e.g. the
## plane) will also take this F press — let it have it.
func _vehicle_claims(p: Node3D) -> bool:
	for n in get_parent().get_children():
		if n != p and "nearby_player" in n and n.nearby_player == p:
			return true
	return false

func _near_telescope(p: Node3D) -> bool:
	return telescope != null and p != null and p.global_position.distance_to(telescope.global_position) < USE_RANGE_M

func cycle_warp() -> void:
	if engine == null:
		return
	var k: int = WARP_STEPS.find(engine.time_scale)
	engine.time_scale = WARP_STEPS[(k + 1) % WARP_STEPS.size()]
	_update_hud(_player())

func place_telescope() -> void:
	var p := _player()
	if p == null:
		return
	if telescope == null:
		telescope = TelescopeScript.new()
		telescope.name = "Telescope"
		get_parent().add_child(telescope)
		panel.telescope = telescope
	var fwd: Vector3 = -p.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var spot: Vector3 = p.global_position + fwd * 1.8
	var space := get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(spot + Vector3.UP * 20.0, spot + Vector3.DOWN * 50.0, 0xFFFFFFFF, [p.get_rid()]))
	if not hit.is_empty():
		spot.y = hit.position.y
	else:
		spot.y = p.global_position.y - 0.9
	telescope.global_position = spot

func open_panel(c: Control) -> void:
	close_panels()
	var p := _player()
	if p and p.has_method("set_control_enabled"):
		p.set_control_enabled(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	c.visible = true
	_open_panel = c
	if c.has_method("refresh"):
		c.refresh()

func close_panels() -> void:
	if _open_panel == null:
		return
	_open_panel.visible = false
	_open_panel = null
	var p := _player()
	if p and p.has_method("set_control_enabled"):
		p.set_control_enabled(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _update_hud(p: Node3D) -> void:
	if engine == null:
		return
	_hud.visible = _open_panel == null
	_hud.text = "%s UT   ×%d" % [jd_to_string(engine.current_jd), int(engine.time_scale)]
	if panel.monitoring:
		_hud.text += "\n" + panel.monitor_status
	_hint.visible = _open_panel == null and _near_telescope(p) and _player_free(p)
	_hint.text = "F  ·  Use telescope"

## "YYYY-MM-DD HH:MM" from a Julian Date (Meeus, Gregorian).
static func jd_to_string(jd: float) -> String:
	var z: int = int(floor(jd + 0.5))
	var f: float = jd + 0.5 - z
	var alpha: int = int(floor((z - 1867216.25) / 36524.25))
	var a: int = z + 1 + alpha - alpha / 4
	var b: int = a + 1524
	var c: int = int(floor((b - 122.1) / 365.25))
	var d: int = int(floor(365.25 * c))
	var e: int = int(floor((b - d) / 30.6001))
	var day: int = b - d - int(floor(30.6001 * e))
	var month: int = e - 1 if e < 14 else e - 13
	var year: int = c - 4716 if month > 2 else c - 4715
	var mins: int = int(floor(f * 1440.0 + 1e-6))
	return "%04d-%02d-%02d %02d:%02d" % [year, month, day, mins / 60, mins % 60]

# ---------------------------------------------------------------------
# Dev hook for tests/probe.gd: place, aim and expose without input.
# ---------------------------------------------------------------------
func debug_drive(args: Dictionary) -> void:
	if args.has("click"):
		await _debug_click(args)
		return
	if args.has("expose"):
		place_telescope()
		open_panel(panel)
		if not panel.select_target_by_name(String(args["expose"])):
			push_warning("probe: target %s not up" % args["expose"])
		if args.has("band"):
			panel.set_band(String(args["band"]))
		if args.has("exp"):
			panel._auto.button_pressed = false
			panel.set_exptime(float(args["exp"]))
		if args.has("varsonly"):
			panel._picker._vars_only.button_pressed = true
		if args.has("search"):
			panel._picker._search.text = String(args["search"])
			panel._picker._fill()
		if not args.has("noexpose"):
			panel.expose()
		if args.has("monitor"):
			panel.set_monitoring(true)
			if not args.has("stay"):
				close_panels()
	if args.has("warp"):
		engine.time_scale = float(args["warp"])
	if args.has("log"):
		open_panel(log_panel)
		if args.has("target"):
			log_panel.focus(String(args["target"]), String(args.get("band", "V")))
		if args.has("find"):
			log_panel.find_period()
		if args.has("fold"):
			log_panel.set_fold(true)
		if args.has("pick"):     # click a candidate-period chip
			while log_panel._search.is_empty():
				await get_tree().process_frame
			log_panel.set_period(log_panel._search["candidates"][int(args["pick"])][0])
		if args.has("hover"):
			await get_tree().create_timer(float(args["hover"])).timeout
			var pts: Array = log_panel._screen_pts
			if not pts.is_empty():
				var mv := InputEventMouseMotion.new()
				mv.position = pts[pts.size() / 3][0] + Vector2(1, 1)
				log_panel._plot_input(mv)

## Exercise the click → comparison → differential → log → FITS path.
func _debug_click(args: Dictionary) -> void:
	args.erase("click")
	debug_drive(args)
	while panel.frame.is_empty():
		await get_tree().create_timer(0.2).timeout
	await get_tree().process_frame
	var f: Dictionary = panel.frame
	var c: float = (f["npix"] - 1) * 0.5
	var comp: Dictionary = {}
	for s in f["truth"]:
		var off: float = Vector2(s["x"], s["y"]).distance_to(Vector2(c, c))
		if off > 20.0 and s["x"] > 20 and s["y"] > 20 and s["x"] < f["npix"] - 20 and s["y"] < f["npix"] - 20 \
				and (comp.is_empty() or s["e"] > comp["e"]):
			comp = s
	if args.has("zoom"):
		var z: float = float(args["zoom"])
		panel._view.zoom = z
		panel._view._c = Vector2(c + 0.5, f["npix"] - 0.5 - c)
		panel._view._clamp_view()
		panel._view.redraw()
	if not args.has("nocomp"):
		for target in [Vector2(comp["x"], comp["y"]), Vector2(c, c)]:
			for pressed in [true, false]:
				var ev := InputEventMouseButton.new()
				ev.pressed = pressed
				ev.button_index = MOUSE_BUTTON_LEFT
				ev.position = panel._to_screen(target + Vector2(0.7, -0.6))
				panel._view._gui_input(ev)
			if panel._comp.is_empty():
				panel._set_comparison()
		panel._log_measurement()
	var mv := InputEventMouseMotion.new()
	mv.position = panel._to_screen(Vector2(comp["x"], comp["y"]) + Vector2(0.3, 0.2))
	panel._view._gui_input(mv)
	if args.has("fits"):
		print("DEBUG_FITS ", ProjectSettings.globalize_path(panel.save_fits()))
	if args.has("colour"):
		panel.take_colour()
	await get_tree().create_timer(1.0).timeout
	print("DEBUG_CLICK ", panel._card.get_parsed_text().replace("\n", " | "), " || ", panel._readout.text, " || ", panel._colour_lbl.text)
	if args.has("paths"):
		await _debug_paths()

## Input paths the flags above skip: wheel zoom, Open light curve,
## plot zoom/pan and a periodogram click.
func _debug_paths() -> void:
	var wheel := InputEventMouseButton.new()
	wheel.pressed = true
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.position = panel._view.size * 0.5
	panel._view._gui_input(wheel)
	print("DEBUG_PATHS view zoom ", panel._view.zoom)
	panel.open_light_curve.emit("Algol", "V")
	await get_tree().create_timer(0.3).timeout
	wheel.position = log_panel._plot_rect.get_center()
	log_panel._plot_input(wheel)
	var drag := InputEventMouseMotion.new()
	drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	drag.relative = Vector2(40, 0)
	drag.position = wheel.position
	log_panel._plot_input(drag)
	print("DEBUG_PATHS log target ", log_panel._target(), " bands ", log_panel._bands_on.keys(), " xr ", log_panel._xr)
	log_panel.find_period()
	while log_panel._search.is_empty():
		await get_tree().process_frame
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = Vector2(log_panel._p_to_x(log_panel._search["candidates"][0][0] * 2.0, log_panel._pg_rect()), 40)
	log_panel._pgram_input(click)
	print("DEBUG_PATHS pgram click -> P ", log_panel._period.value)
