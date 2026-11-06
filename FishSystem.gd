extends Node3D
class_name FishSystem
## Fish spawner + chunk manager. Doesn't know about individual species —
## discovers any *Fish.tscn in the species directory on ready, picks one
## at random when spawning. Drop in a new Fish variant and it just works.
## Per-fish behavior (wander, flee, school, jump) lives in Fish.gd / its
## subclasses.

@export var max_fish_per_chunk: int = 8
@export var fish_spawn_chance: float = 0.8
@export var min_fish_depth: float = 0.5
@export var max_fish_depth: float = 10.0

# Spawn throttling — avoids a frame spike when a new chunk loads.
@export var max_spawns_per_frame: int = 4

# Where to look for species scenes. Anything named *Fish.tscn in here is
# treated as a species. "Fish.tscn" itself (if it existed) would be
# excluded — only variant scenes qualify.
@export var species_dir: String = "res://"

# ---------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------
var water_system: Node = null
var fish_parent: Node3D
var active_fish: Array[CharacterBody3D] = []
var fish_chunks: Dictionary = {}                      # Vector2 -> Array[fish]
var _pending_fish_spawns: Array[Dictionary] = []

var _species_scenes: Array[PackedScene] = []

var debug_fish_count_timer: float = 0.0
var total_fish_created: int = 0

# ---------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------
func _ready() -> void:
	if typeof(World) != TYPE_NIL:
		water_system = World.get_water_system()
	if water_system == null:
		water_system = get_parent()  # legacy fallback

	fish_parent = Node3D.new()
	fish_parent.name = "FishParent"
	add_child(fish_parent)

	_discover_species()

func _process(delta: float) -> void:
	if _pending_fish_spawns.size() > 0:
		_process_pending_spawns()

	debug_fish_count_timer += delta
	if debug_fish_count_timer >= 3.0:
		debug_fish_count_timer = 0.0
		print("Active fish: ", active_fish.size(), " / created ", total_fish_created, " / species ", _species_scenes.size())

# ---------------------------------------------------------------------
# Species discovery — anything named *Fish.tscn under species_dir counts
# as a species. Drop a new file in and it shows up on next launch.
# ---------------------------------------------------------------------
func _discover_species() -> void:
	_species_scenes.clear()
	var dir := DirAccess.open(species_dir)
	if dir == null:
		push_warning("FishSystem: cannot open species_dir %s" % species_dir)
		return
	for file_name in dir.get_files():
		if not file_name.ends_with("Fish.tscn"):
			continue
		var path := species_dir.path_join(file_name)
		var scene := load(path) as PackedScene
		if scene != null:
			_species_scenes.append(scene)
	if _species_scenes.is_empty():
		push_warning("FishSystem: no *Fish.tscn species found in %s" % species_dir)

# ---------------------------------------------------------------------
# Chunk-based spawning
# ---------------------------------------------------------------------
func spawn_fish_in_chunk(chunk_pos: Vector2, _water_chunk_node: Node3D) -> int:
	if fish_chunks.has(chunk_pos):
		return 0
	if water_system == null or _species_scenes.is_empty():
		fish_chunks[chunk_pos] = []
		return 0

	var water_level: float = water_system.get_water_level()
	var chunk_size: float = water_system.get_chunk_size()
	var world_pos_x: float = chunk_pos.x * chunk_size
	var world_pos_z: float = chunk_pos.y * chunk_size

	if randf() > fish_spawn_chance:
		fish_chunks[chunk_pos] = []  # processed-but-empty
		return 0

	fish_chunks[chunk_pos] = []

	var num_fish: int = (randi() % max_fish_per_chunk) + 1
	for i in range(num_fish):
		var spawn_x: float = randf_range(world_pos_x, world_pos_x + chunk_size)
		var spawn_z: float = randf_range(world_pos_z, world_pos_z + chunk_size)
		var spawn_y: float = water_level - randf_range(min_fish_depth, max_fish_depth)
		_pending_fish_spawns.append({
			"chunk_pos": chunk_pos,
			"position": Vector3(spawn_x, spawn_y, spawn_z),
		})

	return num_fish

func _process_pending_spawns() -> void:
	var spawned_this_frame: int = 0
	var limit: int = max(1, max_spawns_per_frame)

	while spawned_this_frame < limit and _pending_fish_spawns.size() > 0:
		var request: Dictionary = _pending_fish_spawns.pop_front()
		var chunk_pos: Vector2 = request.get("chunk_pos", Vector2.ZERO)
		var pos: Vector3 = request.get("position", Vector3.ZERO)

		var fish := _instantiate_random_species()
		if fish == null:
			continue

		fish.position = pos
		fish_parent.add_child(fish)

		if fish_chunks.has(chunk_pos):
			fish_chunks[chunk_pos].append(fish)
		else:
			fish_chunks[chunk_pos] = [fish]

		active_fish.append(fish)
		total_fish_created += 1
		spawned_this_frame += 1

func _instantiate_random_species() -> CharacterBody3D:
	if _species_scenes.is_empty():
		return null
	var scene: PackedScene = _species_scenes[randi() % _species_scenes.size()]
	return scene.instantiate() as CharacterBody3D

# ---------------------------------------------------------------------
# Chunk teardown — called by WaterSystem.remove_water_chunk
# ---------------------------------------------------------------------
func clear_fish_chunk(chunk_pos: Vector2) -> void:
	if not fish_chunks.has(chunk_pos):
		return

	for fish in fish_chunks[chunk_pos]:
		if is_instance_valid(fish):
			active_fish.erase(fish)
			fish.queue_free()

	fish_chunks.erase(chunk_pos)

	# Drop queued-but-unspawned fish for this chunk.
	for i in range(_pending_fish_spawns.size() - 1, -1, -1):
		if _pending_fish_spawns[i].get("chunk_pos", Vector2.ZERO) == chunk_pos:
			_pending_fish_spawns.remove_at(i)
