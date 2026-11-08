extends RefCounted
## Merl's decision-making layer — pure logic, no scene-tree access.
##
## The controller (MerlController.gd) calls tick() each physics frame.
## The brain returns an intent Dictionary:
##   {
##     "target": Vector3 (world-space destination),
##     "speed_mul": float (0..1 multiplier on walk speed),
##     "state_name": String (for debug / UI),
##     "sniff": bool (true if he should pause and look around)
##   }
##
## Keeping brain and controller separate so a future LLM-driven brain
## (MerlLLMBrain.gd) can be swapped in: same tick() signature, different
## internals. The controller doesn't care how decisions get made.

enum State { WANDER, INVESTIGATE_PLAYER, FLEEING, RESTING, OBSESSED }

# Where the opossum is allowed to roam (soft centre + hard radius).
var home_center: Vector3 = Vector3.ZERO
var home_radius: float = 180.0

# Behaviour tunables — tweak to taste.
var investigate_approach_distance: float = 6.0   # Player within this radius → he gets curious
var flee_distance: float = 2.5                    # Within this → he scurries off
var rest_min_seconds: float = 6.0
var rest_max_seconds: float = 14.0
var wander_min_dwell: float = 2.0                 # min pause at a wander target
var wander_max_dwell: float = 5.0
var obsession_min_seconds: float = 20.0
var obsession_max_seconds: float = 50.0

var _state: int = State.WANDER
var _state_timer: float = 0.0
var _current_target: Vector3 = Vector3.ZERO
var _obsession_point: Vector3 = Vector3.ZERO
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

func _init() -> void:
	_rng.randomize()
	_pick_wander_target()

# ---------------------------------------------------------------------
# Public: returns the current intent given the world state.
#   self_pos    = Merl's current position
#   player_pos  = player's position (Vector3.INF if no player)
#   ground_y_at = Callable to query terrain height at (x, z) — used
#                 to keep targets grounded
# ---------------------------------------------------------------------
func tick(self_pos: Vector3, player_pos: Vector3, delta: float, ground_y_at: Callable) -> Dictionary:
	_state_timer -= delta
	var player_dist: float = INF
	if player_pos.x != INF:
		player_dist = Vector2(self_pos.x - player_pos.x, self_pos.z - player_pos.z).length()

	# --- Reactive transitions (highest priority) ---
	if player_dist < flee_distance:
		_enter_fleeing(self_pos, player_pos)
	elif _state != State.FLEEING and _state != State.OBSESSED and player_dist < investigate_approach_distance:
		if _state != State.INVESTIGATE_PLAYER:
			_enter_investigate(player_pos)

	# --- Timed transitions (state has run its course) ---
	if _state_timer <= 0.0:
		match _state:
			State.WANDER:
				# Occasionally obsess over something random instead of
				# just wandering onward.
				if _rng.randf() < 0.18:
					_enter_obsessed(self_pos, ground_y_at)
				elif _rng.randf() < 0.1:
					_enter_resting()
				else:
					_pick_wander_target(ground_y_at)
					_state_timer = _rng.randf_range(wander_min_dwell, wander_max_dwell)
			State.INVESTIGATE_PLAYER:
				# Lost interest — resume wandering
				_state = State.WANDER
				_pick_wander_target(ground_y_at)
				_state_timer = _rng.randf_range(wander_min_dwell, wander_max_dwell)
			State.FLEEING:
				# Caught his breath — back to wandering
				_state = State.WANDER
				_pick_wander_target(ground_y_at)
				_state_timer = _rng.randf_range(wander_min_dwell, wander_max_dwell)
			State.RESTING:
				_state = State.WANDER
				_pick_wander_target(ground_y_at)
				_state_timer = _rng.randf_range(wander_min_dwell, wander_max_dwell)
			State.OBSESSED:
				# Done obsessing — back to wandering.
				_state = State.WANDER
				_pick_wander_target(ground_y_at)
				_state_timer = _rng.randf_range(wander_min_dwell, wander_max_dwell)

	# --- Compute per-tick intent for current state ---
	match _state:
		State.WANDER:
			return _intent(_current_target, 0.65, "wander", false)
		State.INVESTIGATE_PLAYER:
			# Walk slowly toward a point a bit offset from the player
			# (he's curious but not confrontational).
			var dir: Vector3 = (self_pos - player_pos)
			dir.y = 0.0
			dir = dir.normalized()
			var t: Vector3 = player_pos + dir * (investigate_approach_distance * 0.6)
			return _intent(t, 0.4, "investigate_player", true)
		State.FLEEING:
			# Full speed away from player, aimed back toward home.
			var away: Vector3 = (self_pos - player_pos)
			away.y = 0.0
			if away.length_squared() < 0.01:
				away = Vector3(_rng.randf_range(-1, 1), 0.0, _rng.randf_range(-1, 1))
			away = away.normalized()
			var flee_target: Vector3 = self_pos + away * 8.0
			return _intent(flee_target, 1.0, "fleeing", false)
		State.RESTING:
			return _intent(self_pos, 0.0, "resting", false)
		State.OBSESSED:
			# Hang around the obsession point, circling with some drift.
			var ang: float = Time.get_ticks_msec() * 0.0005
			var circle_offset: Vector3 = Vector3(sin(ang), 0.0, cos(ang)) * 2.5
			return _intent(_obsession_point + circle_offset, 0.55, "obsessed", true)
	return _intent(self_pos, 0.0, "idle", false)

# ---------------------------------------------------------------------
# State entry helpers
# ---------------------------------------------------------------------
func _enter_fleeing(self_pos: Vector3, player_pos: Vector3) -> void:
	_state = State.FLEEING
	_state_timer = _rng.randf_range(2.5, 5.0)

func _enter_investigate(_player_pos: Vector3) -> void:
	_state = State.INVESTIGATE_PLAYER
	_state_timer = _rng.randf_range(5.0, 11.0)

func _enter_resting() -> void:
	_state = State.RESTING
	_state_timer = _rng.randf_range(rest_min_seconds, rest_max_seconds)

func _enter_obsessed(self_pos: Vector3, ground_y_at: Callable) -> void:
	_state = State.OBSESSED
	_state_timer = _rng.randf_range(obsession_min_seconds, obsession_max_seconds)
	# Pick a random point in home area to obsess over — could be a tree,
	# a rock, a water puddle, or just an interesting patch of dirt. For
	# now any random spot in the roam zone qualifies; a future hook can
	# query TreeSystem / World for actual nearby objects.
	var r: float = _rng.randf() * home_radius * 0.9
	var a: float = _rng.randf() * TAU
	var p: Vector3 = home_center + Vector3(cos(a) * r, 0.0, sin(a) * r)
	if ground_y_at.is_valid():
		p.y = ground_y_at.call(p.x, p.z)
	_obsession_point = p

func _pick_wander_target(ground_y_at: Callable = Callable()) -> void:
	# Random point in home area, biased slightly toward centre so he
	# doesn't just hug the boundary.
	var r: float = sqrt(_rng.randf()) * home_radius
	var a: float = _rng.randf() * TAU
	var p: Vector3 = home_center + Vector3(cos(a) * r, 0.0, sin(a) * r)
	if ground_y_at.is_valid():
		p.y = ground_y_at.call(p.x, p.z)
	_current_target = p

static func _intent(target: Vector3, speed_mul: float, state_name: String, sniff: bool) -> Dictionary:
	return {
		"target": target,
		"speed_mul": speed_mul,
		"state_name": state_name,
		"sniff": sniff,
	}
