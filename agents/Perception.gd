extends RefCounted
## Perception — what an agent can see and hear right now.
##
## scan() is called by the agent periodically (not every frame) and
## returns an Array of Percept dictionaries. Memory.gd folds these
## into a decaying short-term map.
##
## Each percept:
##   {
##     kind:       int (PerceptKind.* enum)
##     position:   Vector3 world-space
##     salience:   float 0..1 (how interesting; decays with distance)
##     id:         String stable identifier (used for memory merge)
##     sense:      int (Sense.SIGHT or Sense.HEARING)
##   }

enum PerceptKind { PLAYER, PLANE, CABIN, TREE, FISH, FOOD }
enum Sense { SIGHT, HEARING }

var sight_radius: float = 30.0
var sight_fov_deg: float = 220.0        # opossums have wide FOV
var hearing_radius: float = 70.0

# Cached references so we don't walk the tree every tick.
var _cached_plane: Node3D = null
var _cached_cabin_pos: Vector3 = Vector3(15.0, 2.0, -5.0)   # from OriginBase.gd

func scan(owner_pos: Vector3, owner_fwd_xz: Vector3, scene_root: Node) -> Array:
	var out: Array = []
	var fwd: Vector3 = owner_fwd_xz
	fwd.y = 0.0
	if fwd.length_squared() < 1e-4:
		fwd = Vector3(0, 0, -1)
	else:
		fwd = fwd.normalized()
	var sight_cos_half: float = cos(deg_to_rad(sight_fov_deg * 0.5))
	var sight_sq: float = sight_radius * sight_radius
	var hearing_sq: float = hearing_radius * hearing_radius
	var footsteps_sq: float = (hearing_radius * 0.3) * (hearing_radius * 0.3)
	var cabin_vis_sq: float = (sight_radius * 1.5) * (sight_radius * 1.5)

	# -----------------------------------------------------------------
	# Player — sight (requires in FOV + range) AND hearing (always if close)
	# -----------------------------------------------------------------
	if typeof(World) != TYPE_NIL:
		var player: Node3D = World.get_player()
		if player != null:
			var p: Vector3 = player.global_position
			var dsq: float = _horizontal_distance_sq(owner_pos, p)
			if dsq < sight_sq and _in_fov(owner_pos, p, fwd, sight_cos_half):
				out.append(_make_percept(PerceptKind.PLAYER, p, _salience_sq(dsq, sight_sq, 0.95), "player", Sense.SIGHT))
			elif dsq < footsteps_sq:
				out.append(_make_percept(PerceptKind.PLAYER, p, _salience_sq(dsq, footsteps_sq, 0.6), "player", Sense.HEARING))

	# -----------------------------------------------------------------
	# Plane — hearing dominates (noisy engine), sight if in range + FOV
	# -----------------------------------------------------------------
	if _cached_plane == null or not is_instance_valid(_cached_plane):
		_cached_plane = scene_root.get_node_or_null("BushPlane") as Node3D
	if _cached_plane != null:
		var pp: Vector3 = _cached_plane.global_position
		var pdsq: float = owner_pos.distance_squared_to(pp)
		if pdsq < hearing_sq:
			out.append(_make_percept(PerceptKind.PLANE, pp, _salience_sq(pdsq, hearing_sq, 1.0), "plane", Sense.HEARING))

	# -----------------------------------------------------------------
	# Cabin — static landmark, always visible
	# -----------------------------------------------------------------
	if _horizontal_distance_sq(owner_pos, _cached_cabin_pos) < cabin_vis_sq:
		out.append(_make_percept(PerceptKind.CABIN, _cached_cabin_pos, 0.25, "cabin", Sense.SIGHT))

	# -----------------------------------------------------------------
	# Food — read from FoodSpawner if present. Small list (≤6) so we
	# don't bother with chunk-locality.
	# -----------------------------------------------------------------
	var food_sys = scene_root.get_node_or_null("FoodSpawner")
	if food_sys != null and "active_food" in food_sys:
		for berry in food_sys.active_food:
			if berry == null or not is_instance_valid(berry):
				continue
			var fp: Vector3 = berry.global_position
			var fdsq: float = _horizontal_distance_sq(owner_pos, fp)
			if fdsq < sight_sq and _in_fov(owner_pos, fp, fwd, sight_cos_half):
				var perc: Dictionary = _make_percept(PerceptKind.FOOD, fp,
					_salience_sq(fdsq, sight_sq, 0.85),
					"food_%d" % berry.get_instance_id(),
					Sense.SIGHT)
				perc["object_ref"] = berry
				out.append(perc)

	# -----------------------------------------------------------------
	# Trees — chunk-locality filter: skip any chunk whose center is
	# beyond sight_radius + half_chunk of the agent before iterating
	# its positions. With a chunk-size of 128 and sight_radius 30, that
	# means we visit at most the 4 chunks around the agent instead of
	# every loaded tree chunk in the world.
	# -----------------------------------------------------------------
	var tree_sys = scene_root.get_node_or_null("TreeSystem")
	if tree_sys != null and "tree_positions" in tree_sys:
		var chunk_size: float = 128.0
		if tree_sys.terrain_generator != null:
			chunk_size = float(tree_sys.terrain_generator.chunk_size)
		var half_chunk: float = chunk_size * 0.5
		# Precompute chunk-level cutoff² (sight + chunk half-diagonal).
		var chunk_diag: float = half_chunk * sqrt(2.0)
		var chunk_cutoff_sq: float = (sight_radius + chunk_diag) * (sight_radius + chunk_diag)
		for chunk_pos in tree_sys.tree_positions:
			var cx: float = chunk_pos.x * chunk_size + half_chunk
			var cz: float = chunk_pos.y * chunk_size + half_chunk
			var cdsq: float = (owner_pos.x - cx) * (owner_pos.x - cx) + (owner_pos.z - cz) * (owner_pos.z - cz)
			if cdsq > chunk_cutoff_sq:
				continue
			for tp in tree_sys.tree_positions[chunk_pos]:
				var tdsq: float = _horizontal_distance_sq(owner_pos, tp)
				if tdsq < sight_sq and _in_fov(owner_pos, tp, fwd, sight_cos_half):
					out.append(_make_percept(PerceptKind.TREE, tp,
						_salience_sq(tdsq, sight_sq, 0.4),
						"tree_%d_%d" % [int(tp.x), int(tp.z)],
						Sense.SIGHT))

	return out

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
static func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

static func _horizontal_distance_sq(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return dx * dx + dz * dz

static func _in_fov(owner_pos: Vector3, target: Vector3, fwd: Vector3, cos_half_fov: float) -> bool:
	var to_target: Vector3 = target - owner_pos
	to_target.y = 0.0
	var d: float = to_target.length()
	if d < 0.01:
		return true
	return to_target.normalized().dot(fwd) >= cos_half_fov

static func _salience(distance: float, max_distance: float, base: float) -> float:
	var t: float = clampf(1.0 - distance / max(max_distance, 0.01), 0.0, 1.0)
	return base * t

static func _salience_sq(distance_sq: float, max_distance_sq: float, base: float) -> float:
	# distance²-driven falloff; preserves the linear distance-based shape
	# of _salience() by taking a sqrt of the ratio (still cheaper than
	# a sqrt on both inputs independently).
	var t: float = clampf(1.0 - sqrt(distance_sq / max(max_distance_sq, 0.01)), 0.0, 1.0)
	return base * t

static func _make_percept(kind: int, pos: Vector3, salience: float, id: String, sense: int) -> Dictionary:
	return {
		"kind": kind,
		"position": pos,
		"salience": salience,
		"id": id,
		"sense": sense,
	}
