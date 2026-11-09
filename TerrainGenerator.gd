extends Node3D

# Terrain generation parameters
@export var chunk_size: int = 128  # Size of each chunk
# Chunks in a square of radius `permanent_chunk_radius` around origin are
# built at LOD 0 at startup and never unloaded. Merl (the opossum agent)
# roams inside this zone and relies on it always being fully loaded.
@export var permanent_chunk_radius: int = 1    # 3x3 = ~384m x 384m at chunk_size 128
@export var view_distance: int = 1  # Legacy — used only for trees (kept close)
@export var terrain_view_distance: int = 16  # Terrain mesh ring. Covered by LOD.
@export var water_view_distance: int = 8     # Water plane ring.
@export var tree_view_distance: int = 1      # Near-detail tree ring (expensive).
@export var chunk_update_interval: float = 0.25  # Re-check chunk loading this often (seconds)

# Bias chunks in the direction of motion when queueing worker builds.
# Higher = more aggressive forward streaming.
@export var motion_priority_bias: float = 4.0

# LOD config. lod_rings[i] = maximum Chebyshev-distance (in chunks) for LOD i.
# Anything beyond the last entry uses the final LOD. subdivisions[i] is the
# grid density for that LOD — a chunk at LOD 0 has subdivisions^2 quads.
# Five levels now so very-far horizon chunks are nearly free.
@export var lod_rings: PackedInt32Array = PackedInt32Array([1, 2, 4, 7, 11])
@export var lod_subdivisions: PackedInt32Array = PackedInt32Array([128, 64, 24, 8, 4, 2])

@export var noise_scale: float = 0.05
@export var amplitude: float = 50.0

# Biome parameters
@export var enable_biomes: bool = true
@export var biome_scale: float = 0.005  # Scale of biome transitions
# Add tree system to export variables (add near the top with other export variables)
@export var enable_trees: bool = true
@export var tree_density: float = 0.5  # Trees per 100 square units

# Water settings
@export var enable_water: bool = true
@export var water_level: float = -5.0  # Global water level
var water_system = null

# Astronomical system settings
@export var enable_astronomical_system: bool = true
@export var day_length: float = 360000.0  # Seconds per full day cycle
@export var start_time: float = 8.0  # Starting hour (24-hour format)
var astronomical_system = null

# Vehicle settings
@export var enable_plane: bool = true
@export var plane_spawn_offset: Vector3 = Vector3(40, 6, -25)

# Origin base settings
@export var enable_origin_base: bool = true

# Noise generation resource
var noise = FastNoiseLite.new()
var biome_noise = FastNoiseLite.new()  # For biome selection
var loaded_chunks = {}  # Dictionary to store active chunks
var current_chunk = Vector2.ZERO  # Current chunk the player is in
var tree_system = null

# _pending_chunks maps chunk_pos → lod being built. We don't double-queue
# the same chunk+lod pair. loaded_chunks now maps chunk_pos → {node, lod}
# so we can detect when a chunk needs to be rebuilt at a different LOD.
var _pending_chunks: Dictionary = {}
var _chunk_update_timer: float = 0.0

# Worker threads finish out-of-sync; multiple can land in the same
# frame. _pending_finalize is the main-thread queue of ready chunks;
# we drain at most max_finalize_per_frame per tick so GPU mesh upload
# cost is spread. The visible cost of waiting an extra frame or two
# is far smaller than a 1-frame spike.
@export var max_finalize_per_frame: int = 3
var _pending_finalize: Array = []

# Terrain shader + per-biome materials are built once and shared across
# all chunks. Creating a new Shader/ShaderMaterial per chunk was the
# main source of per-frame hitches when chunks finalised.
var _terrain_shader: Shader = null
var _biome_materials: Dictionary = {}   # BiomeType enum int → ShaderMaterial

# Biome types
enum BiomeType {
	TEMPERATE_FOREST,
	DESERT,
	SNOWY_MOUNTAINS,
	TROPICAL_JUNGLE,
	VOLCANIC_WASTELAND
}

func _ready():
	if typeof(World) != TYPE_NIL:
		World.register_terrain(self)

	# Setup noise generators (deterministic per run via random seed)
	noise.seed = randi()
	noise.fractal_octaves = 4
	noise.frequency = 0.05

	biome_noise.seed = randi() + 100
	biome_noise.fractal_octaves = 3
	biome_noise.frequency = 0.01

	# Astro owns the WorldEnvironment now (no fallback add_sky_environment).
	if enable_astronomical_system:
		initialize_astronomical_system()

	if enable_water:
		initialize_water_system()

	add_player_to_scene()

	# Generate initial terrain around the player before anything downstream
	# tries to spawn on it (trees, plane).
	var initial_position: Vector3 = Vector3.ZERO
	if has_node("Player"):
		initial_position = $Player.global_position
	update_terrain_chunks(initial_position)

	if enable_origin_base:
		_spawn_origin_base()

	if enable_plane:
		# Defer so the terrain collision exists when the plane raycasts for
		# its spawn height.
		var plane_timer := Timer.new()
		plane_timer.one_shot = true
		plane_timer.wait_time = 0.2
		plane_timer.autostart = true
		add_child(plane_timer)
		plane_timer.timeout.connect(func(): add_plane_to_scene())

	if enable_trees:
		var tree_timer := Timer.new()
		tree_timer.one_shot = true
		tree_timer.wait_time = 0.5
		tree_timer.autostart = true
		add_child(tree_timer)
		tree_timer.timeout.connect(func(): initialize_tree_system())

	# Spawn Merl (the opossum agent) after terrain + base are in place.
	var merl_timer := Timer.new()
	merl_timer.one_shot = true
	merl_timer.wait_time = 0.8
	merl_timer.autostart = true
	add_child(merl_timer)
	merl_timer.timeout.connect(func(): _spawn_merl())

func _process(delta):
	# Drain the finalize queue first — priority-sort by distance to the
	# tracked body so the chunks the player is actually flying into land
	# before chunks that are already behind them.
	if _pending_finalize.size() > 1:
		var tracked: Node3D = _tracked_body()
		if tracked != null:
			var pcx: float = floor(tracked.global_position.x / chunk_size)
			var pcz: float = floor(tracked.global_position.z / chunk_size)
			_pending_finalize.sort_custom(func(a, b):
				var da = (a.chunk_pos.x - pcx) * (a.chunk_pos.x - pcx) + (a.chunk_pos.y - pcz) * (a.chunk_pos.y - pcz)
				var db = (b.chunk_pos.x - pcx) * (b.chunk_pos.x - pcx) + (b.chunk_pos.y - pcz) * (b.chunk_pos.y - pcz)
				return da < db)
	var left: int = max_finalize_per_frame
	while left > 0 and _pending_finalize.size() > 0:
		var job: Dictionary = _pending_finalize.pop_front()
		_finalize_chunk(job.chunk_pos, job.lod, job.world_pos_x, job.world_pos_z,
			job.biome, job.vertices, job.indices, job.normals, job.collision_shape)
		left -= 1

	var player = get_node_or_null("Player")
	if not player:
		return
	# Follow whichever body the player is driving (plane cockpit when
	# seated) — that's where new chunks are needed.
	var reference_pos: Vector3 = player.global_position
	if typeof(World) != TYPE_NIL:
		var plane = get_node_or_null("BushPlane")
		if plane and plane.has_method("get") and plane.get("controlling_player") == player:
			reference_pos = plane.global_position

	var player_chunk = Vector2(
		floor(reference_pos.x / chunk_size),
		floor(reference_pos.z / chunk_size)
	)
	var crossed_boundary: bool = player_chunk != current_chunk
	_chunk_update_timer += delta
	if not crossed_boundary and _chunk_update_timer < chunk_update_interval:
		return
	_chunk_update_timer = 0.0
	current_chunk = player_chunk

	# Terrain first so downstream systems can query the right heights.
	update_terrain_chunks(reference_pos)
	if enable_water and water_system:
		water_system.update_water_chunks(reference_pos, water_view_distance, chunk_size)
	if enable_trees and tree_system:
		tree_system.update_tree_chunks(reference_pos, tree_view_distance, chunk_size)

# Initialize tree system
func initialize_tree_system():
	if enable_trees:
		# Create tree system node
		tree_system = load("res://TreeSystem.gd").new()
		tree_system.name = "TreeSystem"
		tree_system.tree_density = tree_density
		tree_system.terrain_generator = self  # Pass reference to self

		# Add to scene
		add_child(tree_system)
		
		# Update tree chunks only after system is initialized and terrain exists
		var player_pos = Vector3.ZERO
		if has_node("Player"):
			player_pos = $Player.global_position
			tree_system.update_tree_chunks(player_pos, view_distance, chunk_size)

func add_plane_to_scene():
	if not enable_plane:
		return

	if has_node("BushPlane"):
		return

	var plane_packed = load("res://Plane.tscn")
	if not plane_packed:
		return

	var plane = plane_packed.instantiate()
	plane.name = "BushPlane"

	var spawn_origin: Vector3
	if enable_origin_base:
		# Park at the south end of the runway, pointed down it. The plane's
		# forward axis is −Z, so no rotation is needed.
		spawn_origin = Vector3(0.0, World.BASE_HEIGHT + 1.5, World.BASE_HALF_LENGTH - 10.0)
	else:
		# Fallback: offset from player with a terrain probe.
		var base_origin: Vector3 = plane_spawn_offset
		if has_node("Player"):
			base_origin = $Player.global_position + plane_spawn_offset
		var ground = get_ground_height(base_origin)
		base_origin.y = (ground + 1.5) if ground != null else max(water_level + 2.0, 5.0)
		spawn_origin = base_origin

	plane.global_transform = Transform3D(Basis.IDENTITY, spawn_origin)
	add_child(plane)

func _spawn_merl() -> void:
	# Food first — Merl's perception needs the spawner to exist when
	# he does his first scan.
	var spawner_script := load("res://agents/FoodSpawner.gd") as GDScript
	if spawner_script != null:
		var spawner = spawner_script.new()
		spawner.name = "FoodSpawner"
		spawner.home_center = Vector3.ZERO
		spawner.home_radius = float(permanent_chunk_radius) * float(chunk_size) * 0.85
		add_child(spawner)

	var merl_packed := load("res://agents/Merl.tscn") as PackedScene
	if merl_packed == null:
		push_warning("TerrainGenerator: Merl.tscn failed to load")
		return
	var merl := merl_packed.instantiate()
	merl.name = "Merl"
	merl.home_center = Vector3.ZERO
	merl.home_radius = float(permanent_chunk_radius) * float(chunk_size) * 0.9
	var spawn_x: float = 25.0
	var spawn_z: float = 15.0
	var ground: float = get_terrain_height(spawn_x, spawn_z)
	merl.position = Vector3(spawn_x, ground + 0.5, spawn_z)
	add_child(merl)

func _spawn_origin_base() -> void:
	var base_packed := load("res://OriginBase.tscn") as PackedScene
	if base_packed == null:
		push_warning("TerrainGenerator: OriginBase.tscn failed to load")
		return
	var base := base_packed.instantiate()
	base.name = "OriginBase"
	add_child(base)

func get_ground_height(position: Vector3):
	if not is_inside_tree():
		return null

	var space_state = get_world_3d().direct_space_state
	if not space_state:
		return null

	var from = position + Vector3.UP * 500.0
	var to = position - Vector3.UP * 500.0
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space_state.intersect_ray(query)
	if result.is_empty():
		return null
	return result.position.y

# Initialize astronomical system
func initialize_astronomical_system():
	if not enable_astronomical_system:
		return
	# Physics engine — accurate sun + moon positions, Keplerian orbits,
	# observer on an Earth-like planet. Never renders anything.
	astronomical_system = load("res://astronomy/AstronomyEngine.gd").new()
	astronomical_system.name = "AstronomyEngine"
	# Start-hour from the legacy TerrainGenerator export, for compat.
	astronomical_system.start_hour_ut = start_time
	add_child(astronomical_system)

	# Sky renderer — the visual half. Reads engine state each frame
	# and anchors a sky dome to the player with properly positioned
	# sun and moons at correct apparent angular sizes.
	var sky = load("res://sky/SkyRenderer.gd").new()
	sky.name = "SkyRenderer"
	sky.engine = astronomical_system
	add_child(sky)

func initialize_water_system():
	# Create water system node
	water_system = load("res://WaterSystem.gd").new()
	water_system.name = "WaterSystem"
	water_system.water_level = water_level
	water_system.water_chunk_size = chunk_size

	# Add to scene
	add_child(water_system)

	# Initialize water chunks immediately
	var player_pos = Vector3.ZERO
	if has_node("Player"):
		player_pos = $Player.global_position
	water_system.update_water_chunks(player_pos, view_distance, chunk_size)

# ---------------------------------------------------------------------
# LOD helpers
# ---------------------------------------------------------------------
func _subdivisions_for_lod(lod: int) -> int:
	var i: int = clamp(lod, 0, lod_subdivisions.size() - 1)
	return int(lod_subdivisions[i])

func _lod_for_chunk(chunk_pos: Vector2, player_chunk: Vector2) -> int:
	# Permanent chunks always at full detail.
	if _is_permanent_chunk(chunk_pos):
		return 0
	var dist: int = int(max(abs(chunk_pos.x - player_chunk.x), abs(chunk_pos.y - player_chunk.y)))
	for i in range(lod_rings.size()):
		if dist <= int(lod_rings[i]):
			return i
	return lod_rings.size()

func _is_permanent_chunk(chunk_pos: Vector2) -> bool:
	return abs(chunk_pos.x) <= permanent_chunk_radius and abs(chunk_pos.y) <= permanent_chunk_radius

# ---------------------------------------------------------------------
# update_terrain_chunks — called whenever the player crosses a chunk
# boundary OR the periodic timer fires. Figures out the ideal LOD for
# every chunk in view, queues builds in near-first order, and frees
# chunks that have rolled out of range. Chunks already loaded at the
# correct LOD are left alone; chunks loaded at the wrong LOD are
# rebuilt via a swap-on-finalize (the old node stays rendered until
# the new one is ready, so there's no visible gap).
# ---------------------------------------------------------------------
func update_terrain_chunks(player_pos: Vector3):
	var pcx: int = int(floor(player_pos.x / chunk_size))
	var pcz: int = int(floor(player_pos.z / chunk_size))
	var player_chunk := Vector2(pcx, pcz)
	var vd: int = terrain_view_distance
	var chunks_to_keep: Dictionary = {}
	var to_queue: Array = []

	# Motion direction in XZ (used to prioritise chunks ahead of the
	# player so the horizon they're flying toward loads first).
	var motion_xz: Vector2 = Vector2.ZERO
	var tracked: Node3D = _tracked_body()
	if tracked != null and tracked.has_method("get") and tracked.get("velocity") != null:
		var v: Vector3 = tracked.velocity
		motion_xz = Vector2(v.x, v.z)
		var m: float = motion_xz.length()
		if m > 1.0:
			motion_xz /= m
		else:
			motion_xz = Vector2.ZERO

	# Mark permanent chunks as kept regardless of player distance.
	for px in range(-permanent_chunk_radius, permanent_chunk_radius + 1):
		for pz in range(-permanent_chunk_radius, permanent_chunk_radius + 1):
			chunks_to_keep[Vector2(px, pz)] = true

	for x in range(pcx - vd, pcx + vd + 1):
		for z in range(pcz - vd, pcz + vd + 1):
			var cp := Vector2(x, z)
			chunks_to_keep[cp] = true
			var desired_lod: int = _lod_for_chunk(cp, player_chunk)

			var existing = loaded_chunks.get(cp, null)
			if existing != null and existing.lod == desired_lod:
				continue  # already correct

			# Skip if a build for this exact LOD is already in flight.
			var pending_lod = _pending_chunks.get(cp, -1)
			if pending_lod == desired_lod:
				continue

			var dx: int = x - pcx
			var dz: int = z - pcz
			var chunk_offset := Vector2(float(dx), float(dz))
			# Base priority: Chebyshev distance² (closer first).
			var priority: float = dx * dx + dz * dz
			# Motion bias: chunks whose offset aligns with velocity get a
			# lower priority value → queued first.
			if motion_xz != Vector2.ZERO and chunk_offset.length() > 0.01:
				priority -= motion_priority_bias * chunk_offset.normalized().dot(motion_xz)
			to_queue.append({
				"pos": cp,
				"lod": desired_lod,
				"pr": priority,
			})

	to_queue.sort_custom(func(a, b): return a.pr < b.pr)
	for req in to_queue:
		generate_terrain_chunk(req.pos, req.lod)

	# Unload chunks that rolled out of view — but never unload permanent ones.
	var to_remove: Array = []
	for cp in loaded_chunks:
		if not chunks_to_keep.has(cp) and not _is_permanent_chunk(cp):
			to_remove.append(cp)
	for cp in to_remove:
		remove_terrain_chunk(cp)

# ---------------------------------------------------------------------
# generate_terrain_chunk — enqueues a worker task for one chunk at the
# given LOD. Does nothing if that exact LOD is already pending or
# already loaded.
# ---------------------------------------------------------------------
func generate_terrain_chunk(chunk_pos: Vector2, lod: int) -> void:
	if _pending_chunks.has(chunk_pos) and int(_pending_chunks[chunk_pos]) == lod:
		return
	var existing = loaded_chunks.get(chunk_pos, null)
	if existing != null and existing.lod == lod:
		return
	_pending_chunks[chunk_pos] = lod
	WorkerThreadPool.add_task(
		Callable(self, "_build_chunk_on_worker").bind(chunk_pos, lod),
		false,
		"wonkylands.chunk.%d.%d.lod%d" % [chunk_pos.x, chunk_pos.y, lod]
	)

# ---------------------------------------------------------------------
# Worker-thread build. `sub` is grid subdivisions; vertex count scales
# as (sub+1)². Collision is only built for LOD 0 chunks (the ring
# around the player where anything can walk / drive / crash).
# ---------------------------------------------------------------------
func _build_chunk_on_worker(chunk_pos: Vector2, lod: int) -> void:
	var sub: int = _subdivisions_for_lod(lod)
	var step: float = float(chunk_size) / float(sub)
	var world_pos_x: float = chunk_pos.x * chunk_size
	var world_pos_z: float = chunk_pos.y * chunk_size
	var chunk_center := Vector2(world_pos_x + chunk_size / 2.0, world_pos_z + chunk_size / 2.0)
	var dominant_biome: int = determine_biome(chunk_center)

	var vertex_count: int = (sub + 1) * (sub + 1)
	var vertices := PackedVector3Array()
	vertices.resize(vertex_count)
	var offset: int = 0
	for z in range(sub + 1):
		for x in range(sub + 1):
			var local_x: float = x * step
			var local_z: float = z * step
			var gx: float = world_pos_x + local_x
			var gz: float = world_pos_z + local_z
			var y: float = get_terrain_height(gx, gz)
			vertices[offset] = Vector3(local_x, y, local_z)
			offset += 1

	var indices := PackedInt32Array()
	for z in range(sub):
		for x in range(sub):
			var i: int = z * (sub + 1) + x
			var right: int = i + 1
			var below: int = i + (sub + 1)
			var below_right: int = below + 1
			indices.append(i)
			indices.append(right)
			indices.append(below)
			indices.append(right)
			indices.append(below_right)
			indices.append(below)

	var normals := PackedVector3Array()
	normals.resize(vertex_count)
	for n in range(vertex_count):
		normals[n] = Vector3.ZERO
	for t in range(0, indices.size(), 3):
		var i0: int = indices[t]
		var i1: int = indices[t + 1]
		var i2: int = indices[t + 2]
		var face_n: Vector3 = (vertices[i1] - vertices[i0]).cross(vertices[i2] - vertices[i0])
		if face_n.length_squared() == 0.0:
			continue
		normals[i0] += face_n
		normals[i1] += face_n
		normals[i2] += face_n
	for n in range(vertex_count):
		var acc: Vector3 = normals[n]
		normals[n] = acc.normalized() if acc.length_squared() > 0.0 else Vector3.UP

	# ArrayMesh construction uses RenderingServer RIDs and is not safe on
	# worker threads (hits "Attempting to initialize the wrong RID").
	# We pass the raw arrays to the main thread and build ArrayMesh there.
	# ConcavePolygonShape3D is pure CPU though — safe to build its BVH
	# here.
	var collision_shape: ConcavePolygonShape3D = null
	if lod == 0:
		var faces := PackedVector3Array()
		faces.resize(indices.size())
		for i in range(0, indices.size(), 3):
			faces[i]     = vertices[indices[i]]
			faces[i + 1] = vertices[indices[i + 1]]
			faces[i + 2] = vertices[indices[i + 2]]
		collision_shape = ConcavePolygonShape3D.new()
		collision_shape.set_faces(faces)

	call_deferred("_enqueue_finalize", {
		"chunk_pos": chunk_pos,
		"lod": lod,
		"world_pos_x": world_pos_x,
		"world_pos_z": world_pos_z,
		"biome": dominant_biome,
		"vertices": vertices,
		"indices": indices,
		"normals": normals,
		"collision_shape": collision_shape,
	})

func _enqueue_finalize(job: Dictionary) -> void:
	# Permanent chunks should appear ASAP at startup (before the player
	# can see empty ground); skip the queue for them.
	if _is_permanent_chunk(job.chunk_pos):
		_finalize_chunk(job.chunk_pos, job.lod, job.world_pos_x, job.world_pos_z,
			job.biome, job.vertices, job.indices, job.normals, job.collision_shape)
	else:
		_pending_finalize.append(job)

func _finalize_chunk(chunk_pos: Vector2, lod: int, world_pos_x: float, world_pos_z: float, biome: int,
		vertices: PackedVector3Array, indices: PackedInt32Array, normals: PackedVector3Array,
		collision_shape: ConcavePolygonShape3D) -> void:
	# Main-thread: build ArrayMesh (not safe on worker), attach cached
	# shader material, create collision from the pre-built shape, and
	# add to scene.
	_pending_chunks.erase(chunk_pos)
	if not _chunk_is_still_wanted(chunk_pos):
		return
	var existing = loaded_chunks.get(chunk_pos, null)
	if existing != null and existing.lod == lod:
		return  # became redundant while we were building

	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_%d_%d_L%d" % [chunk_pos.x, chunk_pos.y, lod]
	chunk_node.position = Vector3(world_pos_x, 0, world_pos_z)

	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _get_biome_material(biome)
	chunk_node.add_child(mesh_instance)

	if collision_shape != null:
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = collision_shape
		body.add_child(cs)
		chunk_node.add_child(body)

	add_child(chunk_node)

	# Swap: free any previous node at this chunk (different LOD) AFTER
	# the new one is in-tree so there's no visible gap.
	if existing != null and is_instance_valid(existing.node):
		existing.node.queue_free()

	loaded_chunks[chunk_pos] = {"node": chunk_node, "lod": lod}
	if typeof(World) != TYPE_NIL:
		World.notify_chunk_loaded(chunk_pos, chunk_node)

func _chunk_is_still_wanted(chunk_pos: Vector2) -> bool:
	if _is_permanent_chunk(chunk_pos):
		return true
	var ref_pos: Vector3 = Vector3.ZERO
	var tracked: Node3D = _tracked_body()
	if tracked != null:
		ref_pos = tracked.global_position
	var pcx: float = floor(ref_pos.x / chunk_size)
	var pcz: float = floor(ref_pos.z / chunk_size)
	return abs(chunk_pos.x - pcx) <= terrain_view_distance and abs(chunk_pos.y - pcz) <= terrain_view_distance

# Returns the body whose position + velocity should drive chunk streaming:
# the plane when the player is piloting it, otherwise the player.
func _tracked_body() -> Node3D:
	var player: Node3D = null
	if typeof(World) != TYPE_NIL:
		player = World.get_player()
	var plane = get_node_or_null("BushPlane")
	if plane and plane.get("controlling_player") == player and is_instance_valid(plane):
		return plane
	return player

# Removes a chunk that's outside the view distance
func remove_terrain_chunk(chunk_pos: Vector2):
	var entry = loaded_chunks[chunk_pos]
	if is_instance_valid(entry.node):
		entry.node.queue_free()
	loaded_chunks.erase(chunk_pos)
	if typeof(World) != TYPE_NIL:
		World.notify_chunk_unloaded(chunk_pos)

# Analytical terrain height at a world XZ point. Matches the noise logic
# used during chunk generation so subsystems can query without raycasting.
# Inside the base footprint we blend toward BASE_HEIGHT so the runway
# and cabin always have flat ground to sit on, regardless of seed.
func get_terrain_height(x: float, z: float) -> float:
	var base := noise.get_noise_2d(x * noise_scale, z * noise_scale) * amplitude
	var biome := determine_biome(Vector2(x, z))
	var natural: float = apply_biome_height_adjustments(base, biome, Vector2(x, z))
	if typeof(World) != TYPE_NIL:
		var blend: float = World.base_flatten_blend(x, z)
		if blend > 0.0:
			return lerp(natural, World.BASE_HEIGHT, blend)
	return natural


# Determine biome based on position
func determine_biome(world_position: Vector2) -> int:
	# Force forest around the origin so the base always sits in a cozy
	# green patch, regardless of what the biome noise rolled.
	if typeof(World) != TYPE_NIL and World.is_in_base_biome(world_position.x, world_position.y):
		return BiomeType.TEMPERATE_FOREST
	if not enable_biomes:
		return BiomeType.TEMPERATE_FOREST
	
	# Use noise to determine biome (value between -1 and 1)
	var biome_value = biome_noise.get_noise_2d(world_position.x * biome_scale, world_position.y * biome_scale)
	
	# Temperature noise (North-South gradient)
	var temp_noise = (world_position.y * 0.001) + biome_noise.get_noise_2d(world_position.x * biome_scale * 0.5, world_position.y * biome_scale * 0.5) * 0.5
	
	# Elevation noise for mountain ranges
	var elevation_noise = noise.get_noise_2d(world_position.x * biome_scale * 2, world_position.y * biome_scale * 2)
	
	# Moisture noise for jungles/deserts
	var moisture_noise = biome_noise.get_noise_2d(world_position.x * biome_scale * 1.5, world_position.y * biome_scale * 1.5)
	
	# Determine biome based on combined factors
	
	# Volcanic areas (rare)
	if biome_value > 0.7 and elevation_noise > 0.4:
		return BiomeType.VOLCANIC_WASTELAND
	
	# Snowy mountains (cold and high elevation)
	if temp_noise < -0.3 and elevation_noise > 0.2:
		return BiomeType.SNOWY_MOUNTAINS
	
	# Desert (hot and dry)
	if temp_noise > 0.3 and moisture_noise < -0.2:
		return BiomeType.DESERT
	
	# Tropical Jungle (hot and wet)
	if temp_noise > 0.2 and moisture_noise > 0.2:
		return BiomeType.TROPICAL_JUNGLE
	
	# Default to temperate forest
	return BiomeType.TEMPERATE_FOREST

# Apply height adjustments based on biome
func apply_biome_height_adjustments(base_height: float, biome_type: int, world_position: Vector2) -> float:
	var adjusted_height = base_height
	
	match biome_type:
		BiomeType.DESERT:
			# Deserts have sand dunes
			var dune_noise = noise.get_noise_2d(world_position.x * 0.1, world_position.y * 0.1)
			adjusted_height = base_height * 0.6 + dune_noise * 5
			
		BiomeType.SNOWY_MOUNTAINS:
			# Amplify mountains
			adjusted_height = base_height * 1.5
			
			# Add extra peaks
			if base_height > 10:
				var peak_noise = noise.get_noise_2d(world_position.x * 0.2, world_position.y * 0.2)
				adjusted_height += peak_noise * 10
				
		BiomeType.TROPICAL_JUNGLE:
			# Jungle has rolling hills
			adjusted_height = base_height * 0.8
			
			# Add erosion patterns
			var erosion = noise.get_noise_2d(world_position.x * 0.3, world_position.y * 0.3)
			adjusted_height += erosion * 3
			
		BiomeType.VOLCANIC_WASTELAND:
			# Volcanic areas have steep mountains and craters
			adjusted_height = base_height * 1.2
			
			# Add volcanic cones
			var volcano_noise = noise.get_noise_2d(world_position.x * 0.05, world_position.y * 0.05)
			if volcano_noise > 0.6:
				var distance = volcano_noise - 0.6
				adjusted_height += 30 * distance
			
			# Add craters
			var crater_noise = noise.get_noise_2d(world_position.x * 0.15, world_position.y * 0.15)
			if crater_noise > 0.7:
				adjusted_height -= 10
	
	return adjusted_height

# Apply biome-based texturing — cheap cached path. The Shader resource
# is compiled once, and one ShaderMaterial is built per biome and
# reused across every chunk of that biome. Prior code allocated both
# per-chunk, which was the main source of main-thread hitches during
# chunk streaming.
func apply_biome_texturing(mesh_instance: MeshInstance3D, biome_type: int):
	mesh_instance.material_override = _get_biome_material(biome_type)

func _get_biome_material(biome_type: int) -> ShaderMaterial:
	if _biome_materials.has(biome_type):
		return _biome_materials[biome_type]
	if _terrain_shader == null:
		_terrain_shader = Shader.new()
		_terrain_shader.code = _TERRAIN_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = _terrain_shader
	_apply_biome_params(mat, biome_type)
	_biome_materials[biome_type] = mat
	return mat

const _TERRAIN_SHADER_CODE: String = """
shader_type spatial;

uniform float low_threshold = -10.0;
uniform float mid_threshold = 0.0;
uniform float high_threshold = 20.0;
uniform float blend_range = 3.0;

uniform vec3 low_color;
uniform vec3 mid_color;
uniform vec3 high_color;
uniform vec3 top_color;

varying vec3 vertex_pos;

void vertex() {
	vertex_pos = VERTEX;
}

void fragment() {
	float height = vertex_pos.y;
	float low_factor = 1.0 - smoothstep(low_threshold, low_threshold + blend_range, height);
	float mid_factor = smoothstep(low_threshold, low_threshold + blend_range, height)
					 - smoothstep(mid_threshold + blend_range, high_threshold, height);
	float high_factor = smoothstep(mid_threshold + blend_range, high_threshold, height)
					  - smoothstep(high_threshold, high_threshold + blend_range, height);
	float top_factor = smoothstep(high_threshold, high_threshold + blend_range, height);
	vec3 final_color = low_color * low_factor
					 + mid_color * mid_factor
					 + high_color * high_factor
					 + top_color * top_factor;
	ALBEDO = final_color;
	ROUGHNESS = 0.9 - (top_factor * 0.8);
}
"""

func _apply_biome_params(terrain_material: ShaderMaterial, biome_type: int) -> void:
	match biome_type:
		BiomeType.TEMPERATE_FOREST:
			# Temperate forest has water, grass, dirt, and stone
			terrain_material.set_shader_parameter("low_threshold", water_level)
			terrain_material.set_shader_parameter("mid_threshold", 5.0)
			terrain_material.set_shader_parameter("high_threshold", 20.0)
			terrain_material.set_shader_parameter("low_color", Color(0.8, 0.7, 0.5))  # Sandy beach
			terrain_material.set_shader_parameter("mid_color", Color(0.3, 0.5, 0.2))  # Grass
			terrain_material.set_shader_parameter("high_color", Color(0.6, 0.5, 0.4))  # Dirt/forest
			terrain_material.set_shader_parameter("top_color", Color(0.7, 0.7, 0.7))  # Stone
			
		BiomeType.DESERT:
			# Desert has sand and rock formations
			terrain_material.set_shader_parameter("low_threshold", water_level)
			terrain_material.set_shader_parameter("mid_threshold", 0.0)
			terrain_material.set_shader_parameter("high_threshold", 15.0)
			terrain_material.set_shader_parameter("low_color", Color(0.9, 0.8, 0.6))  # Wet sand
			terrain_material.set_shader_parameter("mid_color", Color(0.95, 0.85, 0.6))  # Desert sand
			terrain_material.set_shader_parameter("high_color", Color(0.9, 0.75, 0.5))  # Dry sand
			terrain_material.set_shader_parameter("top_color", Color(0.8, 0.6, 0.4))  # Sandstone
			
		BiomeType.SNOWY_MOUNTAINS:
			# Snowy mountains have frozen lakes, snow, stone, and snow caps
			terrain_material.set_shader_parameter("low_threshold", water_level)
			terrain_material.set_shader_parameter("mid_threshold", 15.0)
			terrain_material.set_shader_parameter("high_threshold", 30.0)
			terrain_material.set_shader_parameter("low_color", Color(0.8, 0.9, 0.95))  # Ice
			terrain_material.set_shader_parameter("mid_color", Color(0.9, 0.9, 0.9))  # Snow
			terrain_material.set_shader_parameter("high_color", Color(0.7, 0.7, 0.8))  # Stone
			terrain_material.set_shader_parameter("top_color", Color(0.95, 0.95, 0.95))  # Snow caps
			
		BiomeType.TROPICAL_JUNGLE:
			# Jungle has sandy beaches, dense vegetation, and mountains
			terrain_material.set_shader_parameter("low_threshold", water_level)
			terrain_material.set_shader_parameter("mid_threshold", 2.0)
			terrain_material.set_shader_parameter("high_threshold", 25.0)
			terrain_material.set_shader_parameter("low_color", Color(0.9, 0.85, 0.7))  # Sand
			terrain_material.set_shader_parameter("mid_color", Color(0.15, 0.4, 0.1))  # Dense jungle
			terrain_material.set_shader_parameter("high_color", Color(0.3, 0.45, 0.2))  # Jungle mountains
			terrain_material.set_shader_parameter("top_color", Color(0.6, 0.6, 0.5))  # Stone peaks
			
		BiomeType.VOLCANIC_WASTELAND:
			# Volcanic areas have ash beaches, volcanic soil, basalt, and magma
			terrain_material.set_shader_parameter("low_threshold", water_level)
			terrain_material.set_shader_parameter("mid_threshold", 5.0)
			terrain_material.set_shader_parameter("high_threshold", 30.0)
			terrain_material.set_shader_parameter("low_color", Color(0.3, 0.3, 0.3))  # Ash
			terrain_material.set_shader_parameter("mid_color", Color(0.25, 0.2, 0.15))  # Volcanic soil
			terrain_material.set_shader_parameter("high_color", Color(0.15, 0.15, 0.15))  # Basalt
			terrain_material.set_shader_parameter("top_color", Color(0.7, 0.2, 0.1))  # Magma-tinged rock
	terrain_material.set_shader_parameter("blend_range", 3.0)

func add_player_to_scene():
	# Instance the declarative Player.tscn so controller, collision, mesh
	# and camera all come from one place instead of being assembled here.
	var player_packed := load("res://Player.tscn") as PackedScene
	if player_packed == null:
		push_error("TerrainGenerator: Player.tscn failed to load")
		return
	var player := player_packed.instantiate()
	player.name = "Player"

	# Spawn next to the cabin door (cabin is at +15 X, -5 Z from origin;
	# door faces −Z). If the base is disabled, fall back to origin.
	var spawn_x: float = 15.0 if enable_origin_base else 0.0
	var spawn_z: float = -10.0 if enable_origin_base else 0.0
	var ground_h: float = get_terrain_height(spawn_x, spawn_z)
	# Extra clearance so collision has time to arrive from the worker-
	# thread chunk build before gravity closes the gap.
	var spawn_y: float = max(ground_h, water_level) + 12.0
	player.position = Vector3(spawn_x, spawn_y, spawn_z)
	add_child(player)

	var stray_cam := get_node_or_null("Camera3D")
	if stray_cam:
		stray_cam.queue_free()
