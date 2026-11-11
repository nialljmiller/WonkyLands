extends Node3D
## Static ground dressing — rocks, bushes, flowers and grass scattered per
## chunk. Densities and colours depend on the chunk's biome, so the desert
## gets sandstone and dry tufts, the jungle gets lush undergrowth, and the
## snowy peaks get bare grey rock.
##
## Each chunk is a handful of MultiMeshes, one per prop kind, so a chunk is
## a few draw calls no matter how many blades of grass it holds. Placement
## is seeded from the chunk coordinates, so a chunk looks the same every
## time it reloads. Props are visual only: no collision.

var terrain_generator: Node = null
var scatter_view_distance: int = 2        # chunks around the player that get dressing
var chunks_per_frame: int = 1             # spread the cost of placement over frames
var grass_visible_range: float = 90.0     # grass is the densest thing, so cull it early
var prop_visible_range: float = 260.0
var water_clearance: float = 0.3          # keep props this far above the waterline
var max_slope: float = 0.9                # rise per metre above which flowers and grass won't grow

# Densities are props per 100 square metres. A chunk is chunk_size² m², so
# the counts scale with chunk size without retuning.
const DENSITY_PER_100M2 := {
	"TEMPERATE_FOREST":   {"grass": 12.0, "flower": 1.5, "bush": 1.2, "rock": 0.3},
	"DESERT":             {"grass": 0.8,  "flower": 0.05, "bush": 0.2, "rock": 2.0},
	"SNOWY_MOUNTAINS":    {"grass": 0.0,  "flower": 0.0,  "bush": 0.1, "rock": 3.0},
	"TROPICAL_JUNGLE":    {"grass": 14.0, "flower": 4.0,  "bush": 3.0, "rock": 0.5},
	"VOLCANIC_WASTELAND": {"grass": 0.0,  "flower": 0.0,  "bush": 0.0, "rock": 4.0},
}

const PALETTE := {
	"TEMPERATE_FOREST": {
		"grass":  [Color(0.28, 0.5, 0.2), Color(0.34, 0.56, 0.24), Color(0.22, 0.42, 0.18)],
		"flower": [Color(0.95, 0.95, 0.9), Color(0.98, 0.85, 0.25), Color(0.6, 0.45, 0.85)],
		"bush":   [Color(0.18, 0.36, 0.16), Color(0.22, 0.42, 0.2)],
		"rock":   [Color(0.5, 0.48, 0.45), Color(0.42, 0.4, 0.38)],
	},
	"DESERT": {
		"grass":  [Color(0.7, 0.6, 0.35), Color(0.65, 0.55, 0.3)],
		"flower": [Color(0.9, 0.6, 0.3)],
		"bush":   [Color(0.5, 0.5, 0.3), Color(0.45, 0.42, 0.25)],
		"rock":   [Color(0.78, 0.62, 0.45), Color(0.7, 0.55, 0.4)],
	},
	"SNOWY_MOUNTAINS": {
		"rock":   [Color(0.55, 0.56, 0.6), Color(0.7, 0.72, 0.75), Color(0.4, 0.42, 0.45)],
	},
	"TROPICAL_JUNGLE": {
		"grass":  [Color(0.15, 0.55, 0.18), Color(0.2, 0.62, 0.22)],
		"flower": [Color(0.9, 0.2, 0.5), Color(0.98, 0.5, 0.15), Color(0.95, 0.85, 0.2)],
		"bush":   [Color(0.1, 0.42, 0.14), Color(0.16, 0.48, 0.18)],
		"rock":   [Color(0.42, 0.44, 0.38)],
	},
	"VOLCANIC_WASTELAND": {
		"rock":   [Color(0.12, 0.11, 0.11), Color(0.22, 0.14, 0.12), Color(0.3, 0.12, 0.08)],
	},
}

# Vertical offset from the terrain to the prop's origin, scaled by the prop
# size for rocks and bushes so they sink into the ground a little.
const Y_OFFSET := {"rock": -0.1, "bush": 0.25, "flower": 0.09, "grass": 0.0}
const SCALE_RANGE := {
	"rock":   Vector2(0.5, 1.8),
	"bush":   Vector2(0.6, 1.3),
	"flower": Vector2(0.8, 1.2),
	"grass":  Vector2(0.7, 1.4),
}
const KINDS := ["rock", "bush", "flower", "grass"]

var _meshes: Dictionary = {}      # kind -> Mesh
var _materials: Dictionary = {}   # kind -> StandardMaterial3D
var _chunks: Dictionary = {}      # Vector2 chunk -> Node3D holding its MultiMeshes
var _queue: Array[Vector2] = []
var _queued: Dictionary = {}
var _last_centre: Vector2 = Vector2(INF, INF)

func _ready() -> void:
	_build_meshes()
	_build_materials()

func _process(_delta: float) -> void:
	if terrain_generator == null or typeof(World) == TYPE_NIL:
		return
	var centre: Vector2 = _centre_chunk()
	if centre.x == INF:
		return
	if centre != _last_centre:
		_last_centre = centre
		_rebuild_queue(centre)
		_unload_far(centre)
	for _i in range(chunks_per_frame):
		if _queue.is_empty():
			break
		var chunk_pos: Vector2 = _queue.pop_front()
		_queued.erase(chunk_pos)
		if not _chunks.has(chunk_pos):
			_dress_chunk(chunk_pos)

# The chunk the player is in, following the plane when they're flying it.
func _centre_chunk() -> Vector2:
	var body: Node3D = World.get_player()
	var plane = terrain_generator.get_node_or_null("BushPlane")
	if plane != null and plane.get("controlling_player") == body:
		body = plane
	if body == null:
		return Vector2(INF, INF)
	var size: float = float(terrain_generator.chunk_size)
	return Vector2(floor(body.global_position.x / size), floor(body.global_position.z / size))

# Nearest rings first, so the chunks under the player get dressed before the
# edges of the view distance.
func _rebuild_queue(centre: Vector2) -> void:
	_queue.clear()
	_queued.clear()
	for ring in range(scatter_view_distance + 1):
		for x in range(int(centre.x) - ring, int(centre.x) + ring + 1):
			for z in range(int(centre.y) - ring, int(centre.y) + ring + 1):
				if maxi(absi(x - int(centre.x)), absi(z - int(centre.y))) != ring:
					continue
				var chunk_pos := Vector2(x, z)
				if not _chunks.has(chunk_pos):
					_queue.append(chunk_pos)
					_queued[chunk_pos] = true

# Free chunks that have fallen out of range. One chunk of slack stops edge
# chunks from being built and freed back and forth as the player moves.
func _unload_far(centre: Vector2) -> void:
	var limit: int = scatter_view_distance + 1
	var to_free: Array = []
	for chunk_pos in _chunks:
		if maxf(absf(chunk_pos.x - centre.x), absf(chunk_pos.y - centre.y)) > limit:
			to_free.append(chunk_pos)
	for chunk_pos in to_free:
		_chunks[chunk_pos].queue_free()
		_chunks.erase(chunk_pos)

# ---------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------
func _dress_chunk(chunk_pos: Vector2) -> void:
	var size: float = float(terrain_generator.chunk_size)
	var origin := Vector2(chunk_pos.x * size, chunk_pos.y * size)
	var biome_name: String = _biome_to_string(terrain_generator.determine_biome(origin + Vector2(size, size) * 0.5))
	var densities: Dictionary = DENSITY_PER_100M2.get(biome_name, {})
	var palette: Dictionary = PALETTE.get(biome_name, {})
	var water_level: float = World.get_water_level()

	var node := Node3D.new()
	node.name = "Dress_%d_%d" % [int(chunk_pos.x), int(chunk_pos.y)]
	add_child(node)
	_chunks[chunk_pos] = node

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(chunk_pos)
	var area_units: float = size * size / 100.0

	for kind in KINDS:
		var colours: Array = palette.get(kind, [])
		var count: int = int(round(float(densities.get(kind, 0.0)) * area_units))
		if count <= 0 or colours.is_empty():
			continue
		var transforms: Array[Transform3D] = []
		var tints: Array[Color] = []
		for _i in range(count):
			var x: float = origin.x + rng.randf() * size
			var z: float = origin.y + rng.randf() * size
			if _is_excluded(x, z):
				continue
			var h: float = terrain_generator.get_terrain_height(x, z)
			if h < water_level + water_clearance:
				continue
			if kind == "flower" or kind == "grass":
				var rise: float = maxf(absf(terrain_generator.get_terrain_height(x + 1.0, z) - h),
					absf(terrain_generator.get_terrain_height(x, z + 1.0) - h))
				if rise > max_slope:
					continue
			var s: float = rng.randf_range(SCALE_RANGE[kind].x, SCALE_RANGE[kind].y)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.75, 1.2), s))
			var y: float = h + Y_OFFSET[kind] * (s if kind == "rock" or kind == "bush" else 1.0)
			transforms.append(Transform3D(basis, Vector3(x, y, z)))
			tints.append(colours[rng.randi() % colours.size()])
		if not transforms.is_empty():
			node.add_child(_make_multimesh(kind, transforms, tints))

func _make_multimesh(kind: String, transforms: Array[Transform3D], tints: Array[Color]) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _meshes[kind]
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, tints[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = kind.capitalize()
	mmi.multimesh = mm
	mmi.material_override = _materials[kind]
	mmi.visibility_range_end = grass_visible_range if kind == "grass" else prop_visible_range
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	if kind == "grass" or kind == "flower":
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi

# Base footprint (runway, cabin, flattened airfield) stays clear of
# undergrowth; OriginBase builds its own ground there.
func _is_excluded(x: float, z: float) -> bool:
	return World.is_reserved(x, z)

# ---------------------------------------------------------------------
# Meshes + materials (built once, shared by every chunk)
# ---------------------------------------------------------------------
func _build_meshes() -> void:
	var rock := SphereMesh.new()
	rock.radius = 0.5
	rock.height = 0.6
	rock.rings = 4
	rock.radial_segments = 6
	_meshes["rock"] = rock

	var bush := SphereMesh.new()
	bush.radius = 0.55
	bush.height = 0.7
	bush.rings = 4
	bush.radial_segments = 7
	_meshes["bush"] = bush

	var flower := SphereMesh.new()
	flower.radius = 0.045
	flower.height = 0.07
	flower.rings = 3
	flower.radial_segments = 5
	_meshes["flower"] = flower

	_meshes["grass"] = _grass_mesh()

# Two crossed quads, so a single tuft reads as a clump from any angle.
static func _grass_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ang in [0.0, PI * 0.5]:
		var r := Vector3(cos(ang), 0.0, sin(ang)) * 0.12
		var up := Vector3(0.0, 0.35, 0.0)
		var a := -r
		var b := r
		var c := r + up
		var d := -r + up
		for v in [a, b, c, a, c, d]:
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
	return st.commit()

func _build_materials() -> void:
	for kind in KINDS:
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.9
		if kind == "grass":
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_materials[kind] = mat

# Must match TerrainGenerator.BiomeType enum order (same mapping TreeSystem uses).
static func _biome_to_string(biome_type: int) -> String:
	match biome_type:
		0: return "TEMPERATE_FOREST"
		1: return "DESERT"
		2: return "SNOWY_MOUNTAINS"
		3: return "TROPICAL_JUNGLE"
		4: return "VOLCANIC_WASTELAND"
		_: return "TEMPERATE_FOREST"
