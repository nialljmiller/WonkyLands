extends Node3D

# Terrain generation parameters
@export var chunk_size: int = 128  # Size of each chunk
@export var view_distance: int = 1  # How many chunks to render around player
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

# Chunk coords that have a worker task in flight — we don't double-queue
# them, and the main-thread finalize checks this before adding the node.
var _pending_chunks: Dictionary = {}

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

func _process(delta):
	# Check if player exists
	var player = get_node_or_null("Player")
	if player:
		# Get player position and calculate current chunk
		var player_pos = player.global_position
		var player_chunk = Vector2(
			floor(player_pos.x / chunk_size),
			floor(player_pos.z / chunk_size)
		)
		
		# If player moved to a new chunk, update visible chunks
		if player_chunk != current_chunk:
			current_chunk = player_chunk
			
			# Update terrain chunks FIRST
			update_terrain_chunks(player_pos)
			
			# Update water chunks AFTER terrain
			if enable_water and water_system:
				water_system.update_water_chunks(player_pos, view_distance, chunk_size)
				
			# Update tree chunks LAST, after terrain is updated
			if enable_trees and tree_system:
				tree_system.update_tree_chunks(player_pos, view_distance, chunk_size)

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

	# TEMP: dev autopilot for headless flight-test.
	if OS.has_environment("WONKY_PLANE_AUTOPILOT"):
		plane.dev_auto_pilot = true
		print("[spawn] plane autopilot enabled, position=", spawn_origin)
	plane.global_transform = Transform3D(Basis.IDENTITY, spawn_origin)
	add_child(plane)

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
	if enable_astronomical_system:
		# Create astronomical system node
		astronomical_system = load("res://AstronomicalSystem.gd").new()
		astronomical_system.name = "AstronomicalSystem"
		astronomical_system.day_length = day_length
		astronomical_system.start_time = start_time
		
		# Add to scene
		add_child(astronomical_system)

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

# Updates which terrain chunks are visible based on player position
func update_terrain_chunks(player_pos: Vector3):
	var center_chunk_x = floor(player_pos.x / chunk_size)
	var center_chunk_z = floor(player_pos.z / chunk_size)
	
	# Track which chunks should remain loaded
	var chunks_to_keep = {}
	
	# Generate all chunks within view distance
	for x in range(center_chunk_x - view_distance, center_chunk_x + view_distance + 1):
		for z in range(center_chunk_z - view_distance, center_chunk_z + view_distance + 1):
			var chunk_pos = Vector2(x, z)
			chunks_to_keep[chunk_pos] = true
			
			# If chunk doesn't exist, generate it
			if not loaded_chunks.has(chunk_pos):
				generate_terrain_chunk(chunk_pos)
	
	# Remove chunks outside view distance
	var chunks_to_remove = []
	for chunk_pos in loaded_chunks.keys():
		if not chunks_to_keep.has(chunk_pos):
			chunks_to_remove.append(chunk_pos)
	
	for chunk_pos in chunks_to_remove:
		remove_terrain_chunk(chunk_pos)

# Generates a single terrain chunk. The heavy math (vertex grid,
# normals, triangle list) runs on a worker thread via WorkerThreadPool;
# scene-tree ops happen in _finalize_chunk on the main thread. This
# eliminates the frame spike on chunk boundary crossings.
func generate_terrain_chunk(chunk_pos: Vector2):
	if _pending_chunks.has(chunk_pos) or loaded_chunks.has(chunk_pos):
		return
	_pending_chunks[chunk_pos] = true
	WorkerThreadPool.add_task(
		Callable(self, "_build_chunk_on_worker").bind(chunk_pos),
		false,
		"wonkylands.chunk.%d.%d" % [chunk_pos.x, chunk_pos.y]
	)

# Runs on a worker thread. FastNoiseLite and the local math here are
# safe for concurrent reads; we never touch the scene tree from here.
func _build_chunk_on_worker(chunk_pos: Vector2) -> void:
	var world_pos_x: float = chunk_pos.x * chunk_size
	var world_pos_z: float = chunk_pos.y * chunk_size
	var chunk_center := Vector2(world_pos_x + chunk_size / 2.0, world_pos_z + chunk_size / 2.0)
	var dominant_biome: int = determine_biome(chunk_center)

	var vertex_count: int = (chunk_size + 1) * (chunk_size + 1)
	var vertices := PackedVector3Array()
	vertices.resize(vertex_count)
	var offset: int = 0
	for z in range(chunk_size + 1):
		for x in range(chunk_size + 1):
			var gx: float = world_pos_x + x
			var gz: float = world_pos_z + z
			# get_terrain_height handles base flattening in one place so
			# player spawn / tree placement / chunk mesh all agree on
			# ground elevation.
			var y: float = get_terrain_height(gx, gz)
			vertices[offset] = Vector3(x, y, z)
			offset += 1

	var indices := PackedInt32Array()
	for z in range(chunk_size):
		for x in range(chunk_size):
			var i: int = z * (chunk_size + 1) + x
			var right: int = i + 1
			var below: int = i + (chunk_size + 1)
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

	# Pre-expand collision faces (indexed triangles → triangle list) on
	# the worker so the main thread just hands them to the shape.
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for i in range(0, indices.size(), 3):
		faces[i]     = vertices[indices[i]]
		faces[i + 1] = vertices[indices[i + 1]]
		faces[i + 2] = vertices[indices[i + 2]]

	call_deferred("_finalize_chunk", chunk_pos, world_pos_x, world_pos_z, dominant_biome,
		vertices, indices, normals, faces)

func _finalize_chunk(chunk_pos: Vector2, world_pos_x: float, world_pos_z: float, biome: int,
		vertices: PackedVector3Array, indices: PackedInt32Array,
		normals: PackedVector3Array, faces: PackedVector3Array) -> void:
	# Player may have moved out of range while this chunk was building.
	# If so, drop the result instead of adding geometry that'll be freed
	# next tick anyway.
	_pending_chunks.erase(chunk_pos)
	if not _chunk_is_still_wanted(chunk_pos):
		return
	if loaded_chunks.has(chunk_pos):
		return

	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	chunk_node.position = Vector3(world_pos_x, 0, world_pos_z)
	add_child(chunk_node)

	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	chunk_node.add_child(mesh_instance)

	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	cs.shape = shape
	body.add_child(cs)
	chunk_node.add_child(body)

	apply_biome_texturing(mesh_instance, biome)

	loaded_chunks[chunk_pos] = chunk_node
	if typeof(World) != TYPE_NIL:
		World.notify_chunk_loaded(chunk_pos, chunk_node)

func _chunk_is_still_wanted(chunk_pos: Vector2) -> bool:
	var player: Node3D = null
	if typeof(World) != TYPE_NIL:
		player = World.get_player()
	var player_pos: Vector3 = player.global_position if player else Vector3.ZERO
	var pcx: float = floor(player_pos.x / chunk_size)
	var pcz: float = floor(player_pos.z / chunk_size)
	return abs(chunk_pos.x - pcx) <= view_distance and abs(chunk_pos.y - pcz) <= view_distance

# Removes a chunk that's outside the view distance
func remove_terrain_chunk(chunk_pos: Vector2):
	var chunk = loaded_chunks[chunk_pos]
	chunk.queue_free()
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

# Apply biome-based texturing to a mesh instance
func apply_biome_texturing(mesh_instance: MeshInstance3D, biome_type: int):
	# Create shader material for terrain
	var terrain_material = ShaderMaterial.new()

	# Create shader
	var shader = Shader.new()
	
	# Start with common shader code
	var shader_code = """
	shader_type spatial;

	uniform float low_threshold = -10.0;
	uniform float mid_threshold = 0.0;
	uniform float high_threshold = 20.0;
	uniform float blend_range = 3.0;

	// Base colors (will be overridden by biome-specific colors)
	uniform vec3 low_color;
	uniform vec3 mid_color;
	uniform vec3 high_color;
	uniform vec3 top_color;

	varying vec3 vertex_pos;

	void vertex() {
		vertex_pos = VERTEX;
	}

	void fragment() {
		// Height-based coloring
		float height = vertex_pos.y;
		
		// Calculate blend factors based on height
		float low_factor = 1.0 - smoothstep(low_threshold, low_threshold + blend_range, height);
		float mid_factor = smoothstep(low_threshold, low_threshold + blend_range, height) - 
						smoothstep(mid_threshold + blend_range, high_threshold, height);
		float high_factor = smoothstep(mid_threshold + blend_range, high_threshold, height) - 
						smoothstep(high_threshold, high_threshold + blend_range, height);
		float top_factor = smoothstep(high_threshold, high_threshold + blend_range, height);
		
		// Combine colors based on height
		vec3 final_color = low_color * low_factor + 
						mid_color * mid_factor + 
						high_color * high_factor + 
						top_color * top_factor;
		
		// Apply lighting
		ALBEDO = final_color;
		
		// Add roughness variation based on elevation
		ROUGHNESS = 0.9 - (top_factor * 0.8); // Higher areas smoother
		
		// Add metallic variation for certain biomes (set in biome config)
	}
	"""
	
	shader.code = shader_code
	terrain_material.shader = shader

	# Set biome-specific shader parameters
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
			
	# Apply biome blend range
	terrain_material.set_shader_parameter("blend_range", 3.0)

	# Apply material to terrain mesh
	mesh_instance.material_override = terrain_material

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
