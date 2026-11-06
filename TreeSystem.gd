extends Node3D
class_name TreeSystem
## Scatters trees across terrain chunks. Species are auto-discovered from
## trees/*.gd — each file is a TreeSpecies subclass that declares its own
## biomes and elevation range and builds its own mesh. Adding a new
## species = drop a .gd into the folder.

# ---------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------
@export var species_dir: String = "res://trees"
@export var tree_density: float = 0.2          # trees per 100 square units
@export var min_distance_between_trees: float = 5.0
@export var max_slope_angle: float = 35.0      # degrees
@export var tree_scale_variation: float = 0.5
@export var tree_rotation_variation: float = 180.0
@export var terrain_interaction_margin: float = 1.0

# ---------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------
const TreeSpecies = preload("res://trees/TreeSpecies.gd")

var species_list: Array = []  # of TreeSpecies instances
var tree_positions: Dictionary = {}            # Vector2 -> Array[Vector3]
var active_trees: Array = []
var terrain_generator: Node = null

const BIOME_DENSITY := {
	"TEMPERATE_FOREST":   1.5,
	"DESERT":             0.2,
	"SNOWY_MOUNTAINS":    0.8,
	"TROPICAL_JUNGLE":    2.0,
	"VOLCANIC_WASTELAND": 0.3,
}

# ---------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------
func _ready() -> void:
	_discover_species()

# ---------------------------------------------------------------------
# Species discovery — scan species_dir for TreeSpecies subclasses.
# ---------------------------------------------------------------------
func _discover_species() -> void:
	species_list.clear()
	var dir := DirAccess.open(species_dir)
	if dir == null:
		push_warning("TreeSystem: cannot open species_dir %s" % species_dir)
		return
	for file_name in dir.get_files():
		if not file_name.ends_with(".gd"):
			continue
		if file_name == "TreeSpecies.gd":
			continue
		var script := load(species_dir.path_join(file_name))
		if script == null:
			continue
		var instance = script.new()
		# Accept anything that implements the TreeSpecies interface
		# (has build_tree + accepts). preload-loaded classes don't play
		# nice with `is`, so duck-check the interface instead.
		if instance.has_method("build_tree") and instance.has_method("accepts"):
			species_list.append(instance)
	if species_list.is_empty():
		push_warning("TreeSystem: no species found in %s" % species_dir)

# ---------------------------------------------------------------------
# Chunk management — called by TerrainGenerator when the loaded-chunk
# set changes.
# ---------------------------------------------------------------------
func update_tree_chunks(player_pos: Vector3, view_distance: int, chunk_size: int) -> void:
	var center_x: int = int(floor(player_pos.x / chunk_size))
	var center_z: int = int(floor(player_pos.z / chunk_size))

	var keep: Dictionary = {}
	for x in range(center_x - view_distance, center_x + view_distance + 1):
		for z in range(center_z - view_distance, center_z + view_distance + 1):
			var chunk_pos := Vector2(x, z)
			keep[chunk_pos] = true
			if terrain_generator.loaded_chunks.has(chunk_pos) and not tree_positions.has(chunk_pos):
				var chunk_node: Node3D = terrain_generator.loaded_chunks[chunk_pos]
				var biome: int = terrain_generator.determine_biome(
					Vector2(x * chunk_size + chunk_size * 0.5, z * chunk_size + chunk_size * 0.5)
				)
				place_trees_in_chunk(chunk_node, chunk_pos, biome)

	# Unload trees in chunks that rolled out of view.
	var to_remove: Array = []
	for chunk_pos in tree_positions.keys():
		if not keep.has(chunk_pos):
			to_remove.append(chunk_pos)
	for chunk_pos in to_remove:
		remove_trees_in_chunk(chunk_pos)

func remove_trees_in_chunk(chunk_pos: Vector2) -> void:
	# The chunk Node3D itself is freed by TerrainGenerator and its children
	# go with it; we just forget the bookkeeping.
	tree_positions.erase(chunk_pos)

# ---------------------------------------------------------------------
# Placement — iterates species, filters by biome + elevation + slope,
# enforces min spacing.
# ---------------------------------------------------------------------
func place_trees_in_chunk(chunk_node: Node3D, chunk_pos: Vector2, biome_type: int) -> void:
	var chunk_size: int = terrain_generator.chunk_size
	var water_level: float = terrain_generator.water_level
	var world_pos_x: float = chunk_pos.x * chunk_size
	var world_pos_z: float = chunk_pos.y * chunk_size
	var biome_name := _biome_to_string(biome_type)

	# Deterministic per-chunk — same chunk gets the same trees across runs.
	seed(int(chunk_pos.x * 1000.0 + chunk_pos.y))

	var base_num_trees := int(chunk_size * chunk_size * tree_density / 100.0)
	var density_mul: float = BIOME_DENSITY.get(biome_name, 1.0)
	var num_trees := int(base_num_trees * density_mul)

	tree_positions[chunk_pos] = []
	var placed: Array[Vector3] = []
	var attempts: int = 0
	var max_attempts: int = num_trees * 5

	while placed.size() < num_trees and attempts < max_attempts:
		attempts += 1
		var local_x := randf_range(0.0, chunk_size)
		var local_z := randf_range(0.0, chunk_size)
		var world_x := world_pos_x + local_x
		var world_z := world_pos_z + local_z

		var terrain_height := _calc_terrain_height(world_x, world_z)
		if terrain_height < water_level + 0.5:
			continue

		var candidates: Array = []
		for species in species_list:
			if species.accepts(biome_name, terrain_height):
				candidates.append(species)
		if candidates.is_empty():
			continue

		if _calc_terrain_slope(world_x, world_z) > max_slope_angle:
			continue

		var too_close := false
		for p in placed:
			if Vector2(world_x, world_z).distance_to(Vector2(p.x, p.z)) < min_distance_between_trees:
				too_close = true
				break
		if too_close:
			continue

		var world_pos := Vector3(world_x, terrain_height, world_z)
		placed.append(world_pos)
		tree_positions[chunk_pos].append(world_pos)

		var species = candidates[randi() % candidates.size()]
		_spawn_tree(species, world_pos, chunk_node)

	if placed.size() > 0:
		print("Placed ", placed.size(), " ", biome_name, " trees in chunk ", chunk_pos)

func _spawn_tree(species, world_position: Vector3, chunk_node: Node3D) -> void:
	var tree: Node3D = species.build_tree()
	if tree == null:
		return
	var tree_scale: float = 1.0 + randf_range(-tree_scale_variation, tree_scale_variation)
	tree.scale = Vector3.ONE * tree_scale
	tree.rotation_degrees.y = randf_range(0.0, tree_rotation_variation)

	var chunk_origin := chunk_node.position
	tree.position = Vector3(
		world_position.x - chunk_origin.x,
		world_position.y - chunk_origin.y + 0.01,
		world_position.z - chunk_origin.z,
	)
	chunk_node.add_child(tree)
	active_trees.append(tree)

# ---------------------------------------------------------------------
# Terrain sampling — proxies to TerrainGenerator so species don't need
# to know about noise/biome internals.
# ---------------------------------------------------------------------
func _calc_terrain_height(world_x: float, world_z: float) -> float:
	return terrain_generator.get_terrain_height(world_x, world_z)

func _calc_terrain_slope(world_x: float, world_z: float) -> float:
	var d := 1.0
	var hc := _calc_terrain_height(world_x, world_z)
	var hn := _calc_terrain_height(world_x, world_z - d)
	var hs := _calc_terrain_height(world_x, world_z + d)
	var he := _calc_terrain_height(world_x + d, world_z)
	var hw := _calc_terrain_height(world_x - d, world_z)
	var sx := (he - hw) / (2.0 * d)
	var sz := (hs - hn) / (2.0 * d)
	var normal := Vector3(-sx, 1.0, -sz).normalized()
	return rad_to_deg(acos(normal.dot(Vector3.UP)))

func _biome_to_string(biome_type: int) -> String:
	# Must match TerrainGenerator.BiomeType enum order.
	match biome_type:
		0: return "TEMPERATE_FOREST"
		1: return "DESERT"
		2: return "SNOWY_MOUNTAINS"
		3: return "TROPICAL_JUNGLE"
		4: return "VOLCANIC_WASTELAND"
		_: return "TEMPERATE_FOREST"
