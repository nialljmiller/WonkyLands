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
# Impostor ring: chunks up to this Chebyshev distance beyond the
# "near" ring get batched one-draw-call MultiMesh trees (no collision,
# simpler mesh per species). Keeps the view full without exploding
# draw-call or physics-object counts when flying.
@export var tree_far_view_distance: int = 4

# ---------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------
const TreeSpecies = preload("res://trees/TreeSpecies.gd")

var species_list: Array = []  # of TreeSpecies instances
var tree_positions: Dictionary = {}            # Vector2 -> Array[Vector3] (near detail)
var far_tree_chunks: Dictionary = {}           # Vector2 -> Node3D (impostor root per chunk)
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
#
# Two concentric rings:
#   * near (Chebyshev ≤ view_distance): full procedural trees with
#     collision; each is its own Node3D tree.
#   * far  (view_distance < d ≤ tree_far_view_distance): a single
#     MultiMeshInstance3D per species per chunk, impostor meshes only,
#     no collision. This is what lets us see woods from the plane
#     without instancing thousands of detailed trees.
# ---------------------------------------------------------------------
func update_tree_chunks(player_pos: Vector3, view_distance: int, chunk_size: int) -> void:
	var center_x: int = int(floor(player_pos.x / chunk_size))
	var center_z: int = int(floor(player_pos.z / chunk_size))
	var far_vd: int = max(view_distance, tree_far_view_distance)

	var keep_near: Dictionary = {}
	var keep_far: Dictionary = {}

	for x in range(center_x - far_vd, center_x + far_vd + 1):
		for z in range(center_z - far_vd, center_z + far_vd + 1):
			var chunk_pos := Vector2(x, z)
			var cheb: int = int(max(abs(x - center_x), abs(z - center_z)))
			var biome: int = terrain_generator.determine_biome(
				Vector2(x * chunk_size + chunk_size * 0.5, z * chunk_size + chunk_size * 0.5)
			)
			if cheb <= view_distance:
				keep_near[chunk_pos] = true
				if terrain_generator.loaded_chunks.has(chunk_pos) and not tree_positions.has(chunk_pos):
					var chunk_node: Node3D = terrain_generator.loaded_chunks[chunk_pos].node
					place_trees_in_chunk(chunk_node, chunk_pos, biome)
				# Remove any far-ring impostor for this chunk — near-ring
				# detailed trees take over.
				if far_tree_chunks.has(chunk_pos):
					_remove_far_trees(chunk_pos)
			else:
				keep_far[chunk_pos] = true
				if not far_tree_chunks.has(chunk_pos):
					place_far_trees_in_chunk(chunk_pos, biome, chunk_size)

	# Unload near trees that rolled out of view.
	var to_remove_near: Array = []
	for chunk_pos in tree_positions.keys():
		if not keep_near.has(chunk_pos):
			to_remove_near.append(chunk_pos)
	for chunk_pos in to_remove_near:
		remove_trees_in_chunk(chunk_pos)

	# Unload far impostor chunks that rolled out.
	var to_remove_far: Array = []
	for chunk_pos in far_tree_chunks.keys():
		if not keep_far.has(chunk_pos):
			to_remove_far.append(chunk_pos)
	for chunk_pos in to_remove_far:
		_remove_far_trees(chunk_pos)

func remove_trees_in_chunk(chunk_pos: Vector2) -> void:
	tree_positions.erase(chunk_pos)

func _remove_far_trees(chunk_pos: Vector2) -> void:
	var node = far_tree_chunks.get(chunk_pos, null)
	if node and is_instance_valid(node):
		node.queue_free()
	far_tree_chunks.erase(chunk_pos)

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

		# Don't plant on the runway or inside the base footprint.
		if typeof(World) != TYPE_NIL and World.is_in_base_core(world_x, world_z):
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
# Far-ring placement — impostor trees via MultiMeshInstance3D.
# Density is lower than the near ring (impostors are visible but we
# don't need one per real tree) and we attach the impostor root to
# `self` rather than to a terrain chunk, so it survives terrain LOD
# swaps and isn't tied to any particular terrain chunk node.
# ---------------------------------------------------------------------
func place_far_trees_in_chunk(chunk_pos: Vector2, biome_type: int, chunk_size: int) -> void:
	var biome_name := _biome_to_string(biome_type)
	var world_pos_x: float = chunk_pos.x * chunk_size
	var world_pos_z: float = chunk_pos.y * chunk_size
	var water_level: float = terrain_generator.water_level

	# Deterministic layout per chunk (independent of near ring so as
	# chunks transition between near/far their layout is self-consistent).
	seed(int(chunk_pos.x * 7919 + chunk_pos.y * 7823))

	var density_mul: float = BIOME_DENSITY.get(biome_name, 1.0)
	# Far ring uses ~40% of near density to save GPU — these trees are
	# small on screen and the eye won't notice.
	var num_candidates: int = int(chunk_size * chunk_size * tree_density * density_mul * 0.4 / 100.0)

	# Collect instance transforms per species.
	var by_species: Dictionary = {}  # species_name -> {species, transforms: Array[Transform3D]}

	for i in range(num_candidates):
		var local_x := randf_range(0.0, chunk_size)
		var local_z := randf_range(0.0, chunk_size)
		var world_x := world_pos_x + local_x
		var world_z := world_pos_z + local_z

		var h: float = _calc_terrain_height(world_x, world_z)
		if h < water_level + 0.5:
			continue
		# Keep base footprint clear too, so the runway doesn't have
		# impostor trees phasing in.
		if typeof(World) != TYPE_NIL and World.is_in_base_core(world_x, world_z):
			continue

		var candidates: Array = []
		for species in species_list:
			if species.accepts(biome_name, h):
				candidates.append(species)
		if candidates.is_empty():
			continue

		var species = candidates[randi() % candidates.size()]
		var sname: String = species.species_name
		if not by_species.has(sname):
			by_species[sname] = {"species": species, "transforms": []}

		var scale := 1.0 + randf_range(-tree_scale_variation * 0.5, tree_scale_variation * 0.5)
		var yaw := randf_range(0.0, tree_rotation_variation)
		var y_offset: float = species.distant_y_offset() * scale
		var pos := Vector3(world_x, h + y_offset, world_z)
		var basis := Basis.from_euler(Vector3(0.0, deg_to_rad(yaw), 0.0)).scaled(Vector3.ONE * scale)
		by_species[sname].transforms.append(Transform3D(basis, pos))

	if by_species.is_empty():
		return

	# Build the chunk's impostor root with one MultiMeshInstance3D per species.
	var root := Node3D.new()
	root.name = "FarTrees_%d_%d" % [chunk_pos.x, chunk_pos.y]
	for sname in by_species.keys():
		var entry = by_species[sname]
		var species = entry.species
		var transforms: Array = entry.transforms
		if transforms.is_empty():
			continue

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = species.distant_mesh()
		mm.instance_count = transforms.size()
		for i in range(transforms.size()):
			mm.set_instance_transform(i, transforms[i])

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = species.distant_material()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)

	add_child(root)
	far_tree_chunks[chunk_pos] = root

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
