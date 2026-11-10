extends Node
## Dev harness: boots the main scene with optional overrides from user
## args (after `--`), measures FPS and can drive the telescope for
## screenshots. Not used by the game.
##   --hour=H        start hour UT (default: scene's own)
##   --fps=S0,S1     average FPS between seconds S0 and S1, print, quit
##   --look=ALT,AZ   point the player camera at alt/az (deg)
##   --nostars       disable the star field (A/B perf runs)
##   --expose=NAME   place a telescope, expose NAME, show the panel
##   --log           open the observing-log panel

var _args: Dictionary = {}
var _t: float = 0.0
var _frames: int = 0
var _fps_t0: float = -1.0
var _done: bool = false
var _proc_ms: float = 0.0
var _draws: float = 0.0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else ""
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
	if _args.has("debugstars") and Engine.get_process_frames() % 60 == 0:
		var sf = get_tree().root.find_child("StarField", true, false)
		if sf:
			print("StarField mmi=", sf._mmi, " vis=", sf._mmi.visible if sf._mmi else null,
				" lim=", sf.limiting_mag, " basis=", sf.global_transform.basis, " pos=", sf.global_position)
	if (_args.has("expose") or _args.has("log")) and _t > 2.0 and not _done:
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
