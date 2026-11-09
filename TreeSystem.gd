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
var near_tree_chunks: Dictionary = {}          # Vector2 -> Node3D (near-ring root per chunk)
var far_tree_chunks: Dictionary = {}           # Vector2 -> Node3D (impostor root per chunk)
var terrain_generator: Node = null

# Per-species template cache. First time a species is used we instantiate
# its full procedural tree, walk the children, and record:
#   _species_parts_cache[name] = Array of {mesh, material, xform}
#   _species_collisions_cache[name] = Array of {shape, xform}
# After that, individual tree placement just appends transforms to shared
# MultiMeshes and a shared StaticBody3D — no per-tree node tree.
var _species_parts_cache: Dictionary = {}
var _species_collisions_cache: Dictionary = {}

# Deferred near-ring placement — placing a chunk's trees is bursty
# (many MMIs + many CollisionShape3Ds in one frame). We queue missing
# chunks and process one per _process tick to spread the cost.
var _pending_near_placements: Array = []  # Array of {pos: Vector2, biome: int}
# Analogous queue for the far-ring impostor chunks.
var _pending_far_placements: Array = []   # Array of {pos: Vector2, biome: int, chunk_size: int}

# Which chunk the player is currently standing in. Only this chunk gets
# per-tree collision built; everyone else is render-only (fast). The
# plane flies above the canopy and the player on foot only touches
# trees in the chunk they're in.
var _collision_chunk: Vector2 = Vector2(999999, 999999)
# Per-chunk cache of tree data so we can add/drop collision lazily when
# the player crosses chunk boundaries, without rebuilding the MMIs.
var _chunk_trees: Dictionary = {}  # Vector2 -> {transforms_by_species: Dict, origin: Vector3}

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

func _process(_delta: float) -> void:
	# A couple of chunks per frame — MultiMesh build is cheap, the
	# CollisionShape3Ds were the heavy part, and only the collision
	# chunk builds those now.
	var budget: int = 2
	while budget > 0 and _pending_near_placements.size() > 0:
		var job: Dictionary = _pending_near_placements.pop_front()
		var cp: Vector2 = job.pos
		if not near_tree_chunks.has(cp):
			place_trees_in_chunk(cp, job.biome)
			budget -= 1
	if budget > 0 and _pending_far_placements.size() > 0:
		var job2: Dictionary = _pending_far_placements.pop_front()
		if not far_tree_chunks.has(job2.pos):
			place_far_trees_in_chunk(job2.pos, job2.biome, job2.chunk_size)

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
	var new_collision_chunk := Vector2(center_x, center_z)
	if new_collision_chunk != _collision_chunk:
		_migrate_collision(_collision_chunk, new_collision_chunk)
		_collision_chunk = new_collision_chunk

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
				# near_tree_chunks is our authoritative "is placed" marker.
				# tree_positions is just the per-chunk position list; both
				# are kept in lockstep so the lifetime bug (trees as
				# children of the terrain chunk node → die on LOD swap,
				# tree_positions stale forever) can't recur.
				if not near_tree_chunks.has(chunk_pos) and not _is_queued_near(chunk_pos):
					_pending_near_placements.append({"pos": chunk_pos, "biome": biome})
				if far_tree_chunks.has(chunk_pos):
					_remove_far_trees(chunk_pos)
			else:
				keep_far[chunk_pos] = true
				if not far_tree_chunks.has(chunk_pos) and not _is_queued_far(chunk_pos):
					_pending_far_placements.append({"pos": chunk_pos, "biome": biome, "chunk_size": chunk_size})

	# Unload near trees that rolled out of view.
	var to_remove_near: Array = []
	for chunk_pos in near_tree_chunks:
		if not keep_near.has(chunk_pos):
			to_remove_near.append(chunk_pos)
	for chunk_pos in to_remove_near:
		remove_trees_in_chunk(chunk_pos)

	# Drop pending placements that are no longer in view.
	_pending_near_placements = _pending_near_placements.filter(func(j): return keep_near.has(j.pos))
	_pending_far_placements = _pending_far_placements.filter(func(j): return keep_far.has(j.pos))

	# Unload far impostor chunks that rolled out.
	var to_remove_far: Array = []
	for chunk_pos in far_tree_chunks:
		if not keep_far.has(chunk_pos):
			to_remove_far.append(chunk_pos)
	for chunk_pos in to_remove_far:
		_remove_far_trees(chunk_pos)

func _is_queued_near(pos: Vector2) -> bool:
	for j in _pending_near_placements:
		if j.pos == pos:
			return true
	return false

func _is_queued_far(pos: Vector2) -> bool:
	for j in _pending_far_placements:
		if j.pos == pos:
			return true
	return false

func remove_trees_in_chunk(chunk_pos: Vector2) -> void:
	tree_positions.erase(chunk_pos)
	_chunk_trees.erase(chunk_pos)
	var root = near_tree_chunks.get(chunk_pos, null)
	if root != null and is_instance_valid(root):
		root.queue_free()
	near_tree_chunks.erase(chunk_pos)

func _remove_far_trees(chunk_pos: Vector2) -> void:
	var node = far_tree_chunks.get(chunk_pos, null)
	if node and is_instance_valid(node):
		node.queue_free()
	far_tree_chunks.erase(chunk_pos)

# ---------------------------------------------------------------------
# Placement — iterates species, filters by biome + elevation + slope,
# enforces min spacing.
# ---------------------------------------------------------------------
func place_trees_in_chunk(chunk_pos: Vector2, biome_type: int) -> void:
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
	# Per-species chunk-local transforms. Chunk-local here means relative
	# to the tree-chunk root node, which we anchor at the chunk's world
	# origin (world_pos_x, 0, world_pos_z).
	var by_species: Dictionary = {}
	var chunk_origin := Vector3(world_pos_x, 0.0, world_pos_z)
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
		var tree_scale: float = 1.0 + randf_range(-tree_scale_variation, tree_scale_variation)
		var yaw_rad: float = deg_to_rad(randf_range(0.0, tree_rotation_variation))
		var local_pos := Vector3(
			world_x - chunk_origin.x,
			terrain_height - chunk_origin.y + 0.01,
			world_z - chunk_origin.z,
		)
		var basis := Basis.from_euler(Vector3(0.0, yaw_rad, 0.0)).scaled(Vector3.ONE * tree_scale)
		var tree_xform := Transform3D(basis, local_pos)
		if not by_species.has(species):
			by_species[species] = []
		by_species[species].append(tree_xform)

	# Always create a root node, even for empty chunks — that way
	# near_tree_chunks.has(chunk_pos) stays authoritative. An empty root
	# is just an un-populated Node3D; cheap.
	var root := Node3D.new()
	root.name = "TreeChunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	root.position = chunk_origin
	if not by_species.is_empty():
		_build_render_batch(root, by_species)
	add_child(root)
	near_tree_chunks[chunk_pos] = root
	_chunk_trees[chunk_pos] = {"transforms_by_species": by_species, "origin": chunk_origin}
	# Only build collision for the chunk the player is actually in.
	# Flying overhead (the main use case) doesn't need it, and walking
	# never leaves the current chunk between steps.
	if chunk_pos == _collision_chunk and not by_species.is_empty():
		_build_collision_batch(root, by_species)

	if placed.size() > 0:
		print("Placed ", placed.size(), " ", biome_name, " trees in chunk ", chunk_pos)

# Build the render-only payload (MultiMeshInstance3Ds). Fast — no
# physics setup, no per-tree node overhead. Called for every placed
# chunk regardless of collision status.
func _build_render_batch(chunk_node: Node3D, by_species: Dictionary) -> void:
	for species in by_species:
		var transforms: Array = by_species[species]
		if transforms.is_empty():
			continue
		var tpl: Dictionary = _get_species_template(species)
		var parts: Array = tpl.parts
		for part in parts:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = part.mesh
			mm.instance_count = transforms.size()
			var part_xform: Transform3D = part.xform
			for i in range(transforms.size()):
				mm.set_instance_transform(i, transforms[i] * part_xform)
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			if part.material != null:
				mmi.material_override = part.material
			chunk_node.add_child(mmi)

# Build the per-tree CollisionShape3Ds — only for the chunk the player
# is in. If the chunk already has a TreeCollisions body, this is a
# no-op (we assume it's already built correctly).
func _build_collision_batch(chunk_node: Node3D, by_species: Dictionary) -> void:
	if chunk_node.get_node_or_null("TreeCollisions") != null:
		return
	var collision_body: StaticBody3D = null
	for species in by_species:
		var transforms: Array = by_species[species]
		if transforms.is_empty():
			continue
		var tpl: Dictionary = _get_species_template(species)
		var collisions: Array = tpl.collisions
		if collisions.is_empty():
			continue
		if collision_body == null:
			collision_body = StaticBody3D.new()
			collision_body.name = "TreeCollisions"
			chunk_node.add_child(collision_body)
		for xform in transforms:
			for c in collisions:
				var cs := CollisionShape3D.new()
				cs.shape = c.shape
				cs.transform = xform * c.xform
				collision_body.add_child(cs)

# Called when the player's current chunk changes. Removes collision from
# the previous chunk (if it was built) and adds collision to the new one.
func _migrate_collision(old_pos: Vector2, new_pos: Vector2) -> void:
	# Drop the old chunk's collision body, if present.
	var old_root = near_tree_chunks.get(old_pos, null)
	if old_root != null and is_instance_valid(old_root):
		var old_body = old_root.get_node_or_null("TreeCollisions")
		if old_body != null:
			old_body.queue_free()
	# Add collision for the new chunk, if it's placed already.
	var new_root = near_tree_chunks.get(new_pos, null)
	if new_root != null and is_instance_valid(new_root) and _chunk_trees.has(new_pos):
		var data: Dictionary = _chunk_trees[new_pos]
		_build_collision_batch(new_root, data.transforms_by_species)

# Instantiates a species' template ONCE and extracts its parts +
# collision shapes. Subsequent placements of the same species use the
# cached data — no further build_tree() calls.
func _get_species_template(species) -> Dictionary:
	var sname: String = species.species_name
	if _species_parts_cache.has(sname):
		return {"parts": _species_parts_cache[sname], "collisions": _species_collisions_cache[sname]}
	var parts: Array = []
	var collisions: Array = []
	var template: Node3D = species.build_tree()
	if template != null:
		_walk_template(template, Transform3D.IDENTITY, parts, collisions)
		template.free()
	_species_parts_cache[sname] = parts
	_species_collisions_cache[sname] = collisions
	return {"parts": parts, "collisions": collisions}

static func _walk_template(node: Node, accum: Transform3D, parts: Array, collisions: Array) -> void:
	var here: Transform3D = accum
	if node is Node3D:
		here = accum * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		parts.append({"mesh": mi.mesh, "material": mi.material_override, "xform": here})
	elif node is CollisionShape3D:
		var cs := node as CollisionShape3D
		collisions.append({"shape": cs.shape, "xform": here})
	for c in node.get_children():
		_walk_template(c, here, parts, collisions)

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
	for sname in by_species:
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
