extends Node
## Dev harness: boots the main scene with optional overrides from user
## args (after `--`), measures FPS and can drive the telescope for
## screenshots. Not used by the game.
##   --hour=H        start hour UT (default: scene's own)
##   --fps=S0,S1     average FPS between seconds S0 and S1, print, quit
##   --look=ALT,AZ   point the player camera at alt/az (deg)
##   --nostars       disable the star field (A/B perf runs)
##   --seed=N        fix the world seed (same terrain and observatory site)
##   --at=SPOT       stand by the hilltop observatory looking at it:
##                   spawn (stay put), far, out, side, back, foot, door, in
##   --noobs         hide the observatory (A/B perf runs)
##   --walkin[=S]    walk forward S s (default 6) from --at (door, or foot
##                   of the path); print whether the player ended up inside
##   --expose=NAME   step into the observatory, expose NAME, show the panel
##   --exp=S --band=B --monitor --warp=X   exposure, filter, monitor, time warp
##   --varsonly --search=TEXT --noexpose    target-picker states
##   --click [--zoom=Z --nocomp --fits --colour]   measure / comparison /
##                   hover / FITS toast / colour-index sequence
##   --log [--target=NAME --band=B --find --fold]  light-curve panel

var _args: Dictionary = {}
var _t: float = 0.0
var _frames: int = 0
var _fps_t0: float = -1.0
var _done: bool = false
var _done_at: bool = false
var _proc_ms: float = 0.0
var _draws: float = 0.0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if _args.has("seed"):
		seed(int(_args["seed"]))
	var tg: Node = load("res://terrain_generator.tscn").instantiate()
	if _args.has("hour"):
		tg.start_time = float(_args["hour"])
	if _args.has("nostars") and "enable_star_field" in tg:
		tg.enable_star_field = false
	add_child(tg)

func _process(delta: float) -> void:
	_t += delta
	if _args.has("look"):
		var p = World.get_player()
		if p != null:
			var la: PackedStringArray = String(_args["look"]).split(",")
			var cam: Camera3D = p.get_node_or_null("Camera3D")
			p.rotation.y = -deg_to_rad(float(la[1]))  # az from north, clockwise
			p.set("_yaw", p.rotation.y)
			if cam:
				cam.rotation.x = deg_to_rad(float(la[0]))
	if _args.has("at") and (_t > 3.0 and not _args.has("walkin") or _t < 3.1):
		_stand_at(String(_args["at"]))
	if _args.has("walkin") and _t > 3.1 and not _done:
		Input.action_press("player_forward")
		if _t > 3.1 + float(_args["walkin"] if _args["walkin"] != "" else "6"):
			_done = true
			Input.action_release("player_forward")
			var obs = get_tree().root.find_child("HillObservatory", true, false)
			print("PROBE_WALKIN inside=", obs.can_use(World.get_player()), " at ", obs.to_local(World.get_player().global_position))
			get_tree().quit()
	if _args.has("debugstars") and Engine.get_process_frames() % 60 == 0:
		var sf = get_tree().root.find_child("StarField", true, false)
		if sf:
			print("StarField mmi=", sf._mmi, " vis=", sf._mmi.visible if sf._mmi else null,
				" lim=", sf.limiting_mag, " basis=", sf.global_transform.basis, " pos=", sf.global_position)
	if (_args.has("expose") or _args.has("log") or _args.has("warp") or _args.has("click")) and _t > 2.0 and not _done:
		_done = true
		var obs = get_tree().root.find_child("Observatory", true, false)
		if obs and obs.has_method("debug_drive"):
			obs.debug_drive(_args)
	if _args.has("fps"):
		var r: PackedStringArray = String(_args["fps"]).split(",")
		if _t >= float(r[0]):
			if _fps_t0 < 0.0:
				_fps_t0 = _t
				_frames = 0
			_frames += 1
			_proc_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			_draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			if _t >= float(r[1]):
				print("PROBE_FPS %.1f over %.1fs  process %.2f ms  draws %.0f" % [_frames / (_t - _fps_t0), _t - _fps_t0, _proc_ms / _frames, _draws / _frames])
				get_tree().quit()

## Put the player at a named spot relative to the observatory (local −Z
## is its door side) and aim the camera at the dome or the barrel.
func _stand_at(spot: String) -> void:
	var obs = get_tree().root.find_child("HillObservatory", true, false)
	var p = World.get_player()
	if obs == null or p == null:
		return
	if not _done_at:
		_done_at = true
		obs.visible = not _args.has("noobs")
		print("PROBE_OBS alt %.0f az %.0f yaw %.0f " % [rad_to_deg(obs._alt), rad_to_deg(obs._az), rad_to_deg(obs.rotation.y)], "site ", obs.global_position, "  %.0f m from spawn" % Vector2(obs.global_position.x - 15.0, obs.global_position.z + 10.0).length())
	var spots: Dictionary = {"far": Vector3(-25, 9, -80), "out": Vector3(13, 4, -20), "side": Vector3(22, 6, 4), "back": Vector3(-8, 6, 22), "door": Vector3(0, 0, -11), "foot": Vector3(0, 0, -42), "in": Vector3(-1.2, 0, 3.2)}
	var look: Vector3 = obs.to_global(Vector3(0, 6.0, 0))
	if spots.has(spot):
		var at: Vector3 = obs.to_global(spots[spot])
		at.y = (obs.global_position.y + 1.3) if spot == "in" else World.get_terrain_height(at.x, at.z) + 1.0 + spots[spot].y
		p.global_position = at
		p.velocity = Vector3.ZERO
		if spot == "in":
			look = obs.to_global(Vector3(0, 2.6, -0.5))
		elif spot == "door":
			look = obs.to_global(Vector3(0, 2.4, 0))
	var d: Vector3 = look - p.global_position - Vector3(0, 0.7, 0)
	p.rotation.y = atan2(-d.x, -d.z)
	p.set("_yaw", p.rotation.y)
	var cam: Camera3D = p.get_node_or_null("Camera3D")
	if cam:
		cam.rotation.x = atan2(d.y, Vector2(d.x, d.z).length())
