extends Node
## World — the single source of cross-system truth.
##
## Subsystems register themselves on ready. Other subsystems query World
## instead of reaching across the scene tree with hardcoded paths or
## duck-typed has_method() checks. Cross-cutting events are broadcast here.

# ---------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------
signal player_registered(player)
signal player_entered_water(player)
signal player_exited_water(player)
signal time_changed(hours: float, day: int)
signal sun_direction_changed(direction: Vector3)
signal terrain_chunk_loaded(chunk_pos: Vector2, chunk_node: Node)
signal terrain_chunk_unloaded(chunk_pos: Vector2)

# ---------------------------------------------------------------------
# Registered systems. Nullable; always check validity before using.
# ---------------------------------------------------------------------
var _player: CharacterBody3D = null
var _water: Node = null
var _astro: Node = null
var _terrain: Node = null

# ---------------------------------------------------------------------
# Registration API — called by each system in its _ready().
# ---------------------------------------------------------------------
func register_player(p: CharacterBody3D) -> void:
	_player = p
	player_registered.emit(p)

func register_water_system(w: Node) -> void:
	_water = w

func register_astronomical_system(a: Node) -> void:
	_astro = a

func register_terrain(t: Node) -> void:
	_terrain = t

# ---------------------------------------------------------------------
# Query API — subsystems call these instead of walking the scene tree.
# Each returns a safe default when the backing system isn't up yet.
# ---------------------------------------------------------------------
func get_player() -> CharacterBody3D:
	return _player if is_instance_valid(_player) else null

func get_water_system() -> Node:
	return _water if is_instance_valid(_water) else null

func get_astronomical_system() -> Node:
	return _astro if is_instance_valid(_astro) else null

func get_terrain() -> Node:
	return _terrain if is_instance_valid(_terrain) else null

func get_water_level() -> float:
	var w := get_water_system()
	return w.water_level if w else -1e9

func get_wave_height_at_position(pos: Vector3) -> float:
	var w := get_water_system()
	if w and w.has_method("get_wave_height_at_position"):
		return w.get_wave_height_at_position(pos)
	return 0.0

func get_flow_direction() -> Vector3:
	var w := get_water_system()
	return w.flow_direction if w else Vector3.ZERO

func get_flow_strength() -> float:
	var w := get_water_system()
	return w.flow_strength if w else 0.0

func get_sun_direction() -> Vector3:
	var a := get_astronomical_system()
	if a and a.has_method("get_sun_direction"):
		return a.get_sun_direction()
	return Vector3.DOWN

func get_terrain_height(x: float, z: float) -> float:
	var t := get_terrain()
	if t and t.has_method("get_terrain_height"):
		return t.get_terrain_height(x, z)
	return 0.0

# ---------------------------------------------------------------------
# Base footprint — the deterministic "home" area at the world origin.
# Terrain is flattened and biome is forced inside this footprint so the
# runway + cabin always sit on cozy flat forest regardless of seed. The
# constants are the single source of truth; TerrainGenerator queries
# them to flatten, TreeSystem queries them to skip placement, and
# OriginBase uses them for layout.
# ---------------------------------------------------------------------
const BASE_HALF_WIDTH: float = 10.0        # X half-extent of flat area
const BASE_HALF_LENGTH: float = 70.0       # Z half-extent (runway runs along Z)
const BASE_HEIGHT: float = 2.0             # terrain elevation inside the footprint
const BASE_BLEND_MARGIN: float = 15.0      # smooth fade from BASE_HEIGHT to natural
const BASE_BIOME_RADIUS: float = 100.0     # forest-biome override radius (squared check)

func is_in_base_core(x: float, z: float) -> bool:
	return abs(x) <= BASE_HALF_WIDTH and abs(z) <= BASE_HALF_LENGTH

func base_flatten_blend(x: float, z: float) -> float:
	# Returns 0..1: 1 inside the core, 0 beyond the blend margin, smooth
	# in between. Callers lerp(natural_height, BASE_HEIGHT, blend).
	var dx: float = max(abs(x) - BASE_HALF_WIDTH, 0.0)
	var dz: float = max(abs(z) - BASE_HALF_LENGTH, 0.0)
	if dx > BASE_BLEND_MARGIN or dz > BASE_BLEND_MARGIN:
		return 0.0
	var fx: float = dx / BASE_BLEND_MARGIN
	var fz: float = dz / BASE_BLEND_MARGIN
	return 1.0 - smoothstep(0.0, 1.0, max(fx, fz))

func is_in_base_biome(x: float, z: float) -> bool:
	# Slightly larger than the flatten area so biome texturing doesn't
	# show a seam right at the edge of the runway.
	return (x * x + z * z) <= (BASE_BIOME_RADIUS * BASE_BIOME_RADIUS)

# ---------------------------------------------------------------------
# Event broadcasting — subsystems emit through World so everyone sees
# the same event stream (no peer-to-peer signal wiring needed).
# ---------------------------------------------------------------------
func notify_player_entered_water(player) -> void:
	player_entered_water.emit(player)

func notify_player_exited_water(player) -> void:
	player_exited_water.emit(player)

func notify_time_changed(hours: float, day: int) -> void:
	time_changed.emit(hours, day)

func notify_sun_direction(direction: Vector3) -> void:
	sun_direction_changed.emit(direction)

func notify_chunk_loaded(chunk_pos: Vector2, chunk_node: Node) -> void:
	terrain_chunk_loaded.emit(chunk_pos, chunk_node)

func notify_chunk_unloaded(chunk_pos: Vector2) -> void:
	terrain_chunk_unloaded.emit(chunk_pos)
