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

const WARP_STEPS: Array = [60.0, 600.0, 3600.0]
const USE_RANGE_M: float = 3.0

var engine = null    # AstronomyEngine, set by TerrainGenerator

var catalog = null
var telescope: Node3D = null
var panel = null
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
	_hud.position = Vector2(-300, 8)
	_hud.size = Vector2(290, 20)
	_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hud.add_theme_font_size_override("font_size", 13)
	_hud.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0, 0.85))
	_hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_layer.add_child(_hud)
	_hint = Label.new()
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.position = Vector2(-150, -60)
	_hint.size = Vector2(300, 24)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_layer.add_child(_hint)

	panel = TelescopePanelScript.new()
	panel.engine = engine
	panel.catalog = catalog
	panel.look_dir_provider = _look_dir
	panel.visible = false
	panel.closed.connect(close_panels)
	_layer.add_child(panel)

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
		if Input.is_action_just_pressed("interact") and _near_telescope(p):
			open_panel(panel)
	_hud_accum += delta
	if _hud_accum >= 0.25:
		_hud_accum = 0.0
		_update_hud(p)

func _input(event: InputEvent) -> void:
	if _open_panel != null and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_panels()
		get_viewport().set_input_as_handled()

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
	_hud.text = "%s UT   ×%d" % [jd_to_string(engine.current_jd), int(engine.time_scale)]
	if _open_panel != null:
		_hint.text = ""
	elif _near_telescope(p) and _player_free(p):
		_hint.text = "F  use telescope"
	else:
		_hint.text = ""

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
	if args.has("expose"):
		place_telescope()
		open_panel(panel)
		if not panel.select_target_by_name(String(args["expose"])):
			push_warning("probe: target %s not up" % args["expose"])
		if args.has("band"):
			panel.set_band(String(args["band"]))
		if args.has("exp"):
			panel.set_exptime(float(args["exp"]))
		panel.expose()
