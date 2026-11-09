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

const Perception = preload("res://agents/Perception.gd")

enum State { WANDER, INVESTIGATE_PLAYER, FLEEING, RESTING, OBSESSED, HIDING_FROM_PLANE, EATING, NAPPING }

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
var _obsession_id: String = ""           # memory id of the thing he's obsessed with
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
# Optional memory handle — the controller injects this after init so
# the brain can query what Merl has perceived rather than inventing
# random positions. If null, we fall back to random wander targets.
var memory = null
# Optional needs handle — injected by controller. If null we skip the
# needs-driven state transitions.
var needs = null

# Thresholds for how close Merl needs to be before he "arrives" and
# consumes / naps.
var eat_distance: float = 0.6
var nap_arrive_distance: float = 1.0

# Target references for current goal-directed state.
var _food_target: Node3D = null       # berry the controller will consume
var _nap_target: Vector3 = Vector3.ZERO

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
	# 1) Nearby loud plane → hide. Memory tells us if the plane is
	#    perceived + how salient (distance-based).
	if memory != null:
		var plane_percept: Dictionary = memory.most_salient(Perception.PerceptKind.PLANE)
		if plane_percept.size() > 0 and plane_percept.salience > 0.4 and _state != State.HIDING_FROM_PLANE:
			_enter_hiding_from_plane(self_pos, plane_percept.position)

	if player_dist < flee_distance:
		_enter_fleeing(self_pos, player_pos)
	elif _state != State.FLEEING and _state != State.OBSESSED and _state != State.HIDING_FROM_PLANE and _state != State.EATING and _state != State.NAPPING and player_dist < investigate_approach_distance:
		if _state != State.INVESTIGATE_PLAYER:
			_enter_investigate(player_pos)

	# --- Needs-driven transitions ---
	# Only override the "base layer" states; if he's actively hiding or
	# fleeing, deal with that first.
	if _state == State.WANDER or _state == State.RESTING:
		if needs != null:
			if needs.is_hungry():
				var food_mem: Dictionary = memory.most_salient(Perception.PerceptKind.FOOD) if memory != null else {}
				if food_mem.size() > 0:
					_enter_eating(food_mem)
			elif needs.is_tired():
				_enter_napping(self_pos, ground_y_at)

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
				_obsession_id = ""
				_pick_wander_target(ground_y_at)
				_state_timer = _rng.randf_range(wander_min_dwell, wander_max_dwell)
			State.HIDING_FROM_PLANE:
				# Plane presumably gone — emerge cautiously
				_state = State.WANDER
				_pick_wander_target(ground_y_at)
				_state_timer = _rng.randf_range(wander_min_dwell, wander_max_dwell)
			State.EATING:
				# Gave up / finished (actual consumption handled by
				# controller when close enough, which also returns to
				# WANDER via a callback).
				_state = State.WANDER
				_pick_wander_target(ground_y_at)
				_state_timer = _rng.randf_range(wander_min_dwell, wander_max_dwell)
			State.NAPPING:
				# Woken up
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
			# If the target is remembered via memory, keep its position
			# updated in case it moves (e.g. the plane).
			if memory != null and _obsession_id != "":
				var items: Dictionary = memory.all_items()
				if items.has(_obsession_id):
					_obsession_point = items[_obsession_id].position
			var ang: float = Time.get_ticks_msec() * 0.0005
			var circle_offset: Vector3 = Vector3(sin(ang), 0.0, cos(ang)) * 2.5
			return _intent(_obsession_point + circle_offset, 0.55, "obsessed", true)
		State.HIDING_FROM_PLANE:
			# Freeze in place, low. Don't move. Watch the sky.
			return _intent(self_pos, 0.0, "hiding_from_plane", true)
		State.EATING:
			# Head to the food target. The controller is responsible for
			# "arriving" + consuming via on_eat() below.
			if _food_target != null and is_instance_valid(_food_target):
				return _intent(_food_target.global_position, 0.75, "eating", true)
			else:
				# Food vanished (other agent? expired?) — bail out next tick
				_state_timer = 0.0
				return _intent(self_pos, 0.0, "eating", false)
		State.NAPPING:
			# Travel to the nap spot, then stay still. Speed drops off
			# as he approaches — he's winding down.
			var d: float = Vector2(self_pos.x - _nap_target.x, self_pos.z - _nap_target.z).length()
			if d < nap_arrive_distance:
				# Satisfy sleep need while stationary — controller does
				# the actual needs.sleep(delta) call.
				return _intent(_nap_target, 0.0, "napping", false)
			var frac: float = clampf(d / 6.0, 0.0, 1.0)
			return _intent(_nap_target, 0.35 + 0.3 * frac, "napping", false)
	return _intent(self_pos, 0.0, "idle", false)

# Called by the controller when Merl arrives at food (brain state =
# EATING and he's within eat_distance). Controller passes the berry
# node so we can clear our reference; the controller handles the
# actual consume + needs.eat() + spawner notification.
func on_eat_consumed() -> void:
	_food_target = null
	# Return to wandering next tick; state_timer <= 0 forces a
	# transition. The actual needs.eat() happens in the controller.
	_state_timer = 0.0
	_state = State.WANDER

# Called each tick by the controller while NAPPING — returns true if
# Merl has arrived at his nap spot (so the controller can call
# needs.sleep()).
func is_napping_at_spot(self_pos: Vector3) -> bool:
	if _state != State.NAPPING:
		return false
	var d: float = Vector2(self_pos.x - _nap_target.x, self_pos.z - _nap_target.z).length()
	return d < nap_arrive_distance

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
	_obsession_id = ""
	# If memory is wired up, obsess over a REAL perceived object
	# (not the player — that's handled by INVESTIGATE_PLAYER). Pick
	# from trees / cabin / plane by salience.
	if memory != null:
		# Build a pool of non-player memories
		var candidates: Array = []
		var items_ref: Dictionary = memory.all_items()
		for id in items_ref:
			var item: Dictionary = items_ref[id]
			if item.kind == Perception.PerceptKind.PLAYER:
				continue
			candidates.append({"id": id, "item": item})
		if candidates.size() > 0:
			var pick: Dictionary = candidates[_rng.randi() % candidates.size()]
			_obsession_point = pick.item.position
			_obsession_id = pick.id
			if ground_y_at.is_valid():
				_obsession_point.y = ground_y_at.call(_obsession_point.x, _obsession_point.z)
			return
	# Fallback — random spot in roam area.
	var r: float = _rng.randf() * home_radius * 0.9
	var a: float = _rng.randf() * TAU
	var p: Vector3 = home_center + Vector3(cos(a) * r, 0.0, sin(a) * r)
	if ground_y_at.is_valid():
		p.y = ground_y_at.call(p.x, p.z)
	_obsession_point = p

func _enter_hiding_from_plane(self_pos: Vector3, plane_pos: Vector3) -> void:
	_state = State.HIDING_FROM_PLANE
	_state_timer = _rng.randf_range(5.0, 12.0)
	# No target movement — he just freezes in place.
	_current_target = self_pos

func _enter_eating(food_mem: Dictionary) -> void:
	_state = State.EATING
	_state_timer = 30.0  # fail-safe timeout if food becomes unreachable
	# Memory entries for FOOD carry the object_ref (controller side).
	# But memory.all_items() doesn't retain it — we re-query via the
	# nearest FOOD percept held by memory. Controller will walk to the
	# position and handle consumption when close.
	_food_target = null   # controller will match by proximity

func _enter_napping(self_pos: Vector3, ground_y_at: Callable) -> void:
	_state = State.NAPPING
	_state_timer = _rng.randf_range(25.0, 50.0)
	# Nap under the nearest remembered tree if we know one; otherwise
	# nap right where we are.
	var pick: Dictionary = {}
	if memory != null:
		pick = memory.most_salient(Perception.PerceptKind.TREE)
	if pick.size() > 0:
		# Offset slightly from tree centre so he's "beside" it, not in it.
		var off: Vector3 = Vector3(sin(_rng.randf() * TAU), 0.0, cos(_rng.randf() * TAU)) * 1.5
		_nap_target = pick.position + off
	else:
		_nap_target = self_pos
	if ground_y_at.is_valid():
		_nap_target.y = ground_y_at.call(_nap_target.x, _nap_target.z)

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
