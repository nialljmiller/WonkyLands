extends Node3D

# Terrain generation parameters
@export var chunk_size: int = 128  # Size of each chunk
@export var view_distance: int = 2  # How many chunks to render around player
@export var noise_scale: float = 0.05
@export var amplitude: float = 50.0

# Noise generation resource
var noise = FastNoiseLite.new()
var loaded_chunks = {}  # Dictionary to store active chunks
var current_chunk = Vector2.ZERO  # Current chunk the player is in

func _ready():
	# Setup noise generator
	noise.seed = randi()
	noise.fractal_octaves = 4
	noise.frequency = 0.05

	# Add celestial elements
	add_celestial_elements()

	# Add sky environment
	add_sky_environment()

	# Add player to scene
	add_player_to_scene()
	
	# Generate initial chunks
	var initial_position = Vector3.ZERO
	if has_node("Player"):
		initial_position = $Player.global_position
	update_terrain_chunks(initial_position)

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
			update_terrain_chunks(player_pos)

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

# Generates a single terrain chunk
func generate_terrain_chunk(chunk_pos: Vector2):
	# Calculate world position for this chunk
	var world_pos_x = chunk_pos.x * chunk_size
	var world_pos_z = chunk_pos.y * chunk_size
	
	# Create container node for the chunk
	var chunk_node = Node3D.new()
	chunk_node.name = "Chunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	add_child(chunk_node)
	
	# Create mesh data structures
	var surface_tool = SurfaceTool.new()
	var mesh = ArrayMesh.new()
	
	# Begin mesh construction
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Generate vertices for this chunk
	for z in range(chunk_size + 1):  # +1 to avoid seams between chunks
		for x in range(chunk_size + 1):
			# Calculate global position
			var global_x = world_pos_x + x
			var global_z = world_pos_z + z
			
			# Calculate height using noise
			var y = noise.get_noise_2d(global_x * noise_scale, global_z * noise_scale) * amplitude
			
			# Add vertex (in local chunk coordinates)
			surface_tool.add_vertex(Vector3(x, y, z))
	
	# Generate triangles
	for z in range(chunk_size):
		for x in range(chunk_size):
			var i = z * (chunk_size + 1) + x
			
			# First triangle
			surface_tool.add_index(i)
			surface_tool.add_index(i + 1)
			surface_tool.add_index(i + (chunk_size + 1))
			
			# Second triangle
			surface_tool.add_index(i + 1)
			surface_tool.add_index(i + (chunk_size + 1) + 1)
			surface_tool.add_index(i + (chunk_size + 1))
	
	# Finalize mesh
	surface_tool.generate_normals()
	mesh = surface_tool.commit()
	
	# Create mesh instance
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = mesh
	
	# Position the chunk
	chunk_node.position = Vector3(world_pos_x, 0, world_pos_z)
	
	# Add mesh to chunk
	chunk_node.add_child(mesh_instance)
	
	# Add collision
	add_chunk_collision(chunk_node, mesh)
	
	# Apply height-based texturing
	apply_height_based_texturing(mesh_instance)
	
	# Store chunk in dictionary
	loaded_chunks[chunk_pos] = chunk_node

# Removes a chunk that's outside the view distance
func remove_terrain_chunk(chunk_pos: Vector2):
	var chunk = loaded_chunks[chunk_pos]
	chunk.queue_free()
	loaded_chunks.erase(chunk_pos)

# Adds collision to a chunk
func add_chunk_collision(chunk_node: Node3D, mesh: ArrayMesh):
	var static_body = StaticBody3D.new()
	var collision_shape = CollisionShape3D.new()
	var shape = ConcavePolygonShape3D.new()

	# Extract mesh data
	var mesh_arrays = mesh.surface_get_arrays(0)
	var vertices = mesh_arrays[Mesh.ARRAY_VERTEX]
	var indices = mesh_arrays[Mesh.ARRAY_INDEX]

	# Create face array (array of Vector3 points forming triangles)
	var faces = PackedVector3Array()
	for i in range(0, indices.size(), 3):
		faces.append(vertices[indices[i]])
		faces.append(vertices[indices[i+1]])
		faces.append(vertices[indices[i+2]])

	shape.set_faces(faces)

	collision_shape.shape = shape
	static_body.add_child(collision_shape)
	chunk_node.add_child(static_body)

# Apply height-based texturing to a mesh instance
func apply_height_based_texturing(mesh_instance: MeshInstance3D):
	# Create shader material for terrain
	var terrain_material = ShaderMaterial.new()

	# Create shader
	var shader = Shader.new()
	shader.code = """
	shader_type spatial;

	uniform float low_threshold = -10.0;    // Sand level
	uniform float mid_threshold = 0.0;      // Grass level
	uniform float high_threshold = 20.0;    // Rock level
	uniform float snow_threshold = 35.0;    // Snow level
	uniform float blend_range = 3.0;        // Blend zone between terrains

	// Colors for each elevation
	uniform vec3 sand_color = vec3(0.94, 0.83, 0.64);    // Light sand
	uniform vec3 grass_color = vec3(0.33, 0.63, 0.22);   // Green grass
	uniform vec3 rock_color = vec3(0.50, 0.45, 0.40);    // Gray rock
	uniform vec3 snow_color = vec3(0.95, 0.95, 0.97);    // White snow

	varying vec3 vertex_pos;

	void vertex() {
		vertex_pos = VERTEX;
	}

	void fragment() {
		// Height-based coloring
		float height = vertex_pos.y;
		
		// Calculate blend factors based on height
		float sand_factor = 1.0 - smoothstep(low_threshold, low_threshold + blend_range, height);
		float grass_factor = smoothstep(low_threshold, low_threshold + blend_range, height) - 
							smoothstep(mid_threshold + blend_range, high_threshold, height);
		float rock_factor = smoothstep(mid_threshold + blend_range, high_threshold, height) - 
							smoothstep(high_threshold, snow_threshold, height);
		float snow_factor = smoothstep(high_threshold, snow_threshold, height);
		
		// Combine colors based on height
		vec3 final_color = sand_color * sand_factor + 
						  grass_color * grass_factor + 
						  rock_color * rock_factor + 
						  snow_color * snow_factor;
		
		// Apply lighting
		ALBEDO = final_color;
		
		// Add some roughness variation based on elevation
		ROUGHNESS = mix(0.9, 0.1, snow_factor); // Snow is smoother than rock
		
		// Make the rock more specular
		METALLIC = rock_factor * 0.2;
	}
	"""

	terrain_material.shader = shader

	# Set shader parameters with diverse elevation thresholds
	terrain_material.set_shader_parameter("low_threshold", -10.0)
	terrain_material.set_shader_parameter("mid_threshold", 0.0)
	terrain_material.set_shader_parameter("high_threshold", 20.0)
	terrain_material.set_shader_parameter("snow_threshold", 35.0)
	terrain_material.set_shader_parameter("blend_range", 3.0)

	# Set colors
	terrain_material.set_shader_parameter("sand_color", Color(0.94, 0.83, 0.64))
	terrain_material.set_shader_parameter("grass_color", Color(0.33, 0.63, 0.22))
	terrain_material.set_shader_parameter("rock_color", Color(0.50, 0.45, 0.40))
	terrain_material.set_shader_parameter("snow_color", Color(0.95, 0.95, 0.97))

	# Apply material to terrain mesh
	mesh_instance.material_override = terrain_material

# Add sky environment
func add_sky_environment():
	# Create world environment node
	var world_environment = WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"

	# Create environment resource
	var environment = Environment.new()

	# Configure sky
	environment.background_mode = Environment.BG_SKY

	# Create procedural sky
	var sky = Sky.new()
	var sky_material = ProceduralSkyMaterial.new()

	# Configure sky parameters
	sky_material.sky_top_color = Color(0.2, 0.4, 0.8)
	sky_material.sky_horizon_color = Color(0.6, 0.7, 0.9)
	sky_material.sky_curve = 0.15

	sky_material.ground_bottom_color = Color(0.1, 0.1, 0.1)
	sky_material.ground_horizon_color = Color(0.6, 0.7, 0.9)
	sky_material.ground_curve = 0.15

	sky_material.sun_angle_max = 30.0
	sky_material.sun_curve = 0.15

	# Assign material to sky
	sky.sky_material = sky_material
	environment.sky = sky

	# Configure ambient light
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_color = Color(0.5, 0.5, 0.5)
	environment.ambient_light_energy = 1.0

	# Configure tone mapping
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.0
	environment.tonemap_white = 1.0

	# Assign environment to world environment
	world_environment.environment = environment

	# Add to scene hierarchy
	add_child(world_environment)
		
func add_celestial_elements():
	# Create directional light for sun
	var sun_light = DirectionalLight3D.new()
	sun_light.name = "SunLight"
	sun_light.light_color = Color(1.0, 0.98, 0.88)  # Slightly warm sunlight
	sun_light.light_energy = 1.2
	sun_light.shadow_enabled = true

	# Configure shadow parameters for optimal terrain visualization
	sun_light.shadow_bias = 0.05
	sun_light.directional_shadow_max_distance = 500.0
	sun_light.directional_shadow_split_1 = 0.1
	sun_light.directional_shadow_split_2 = 0.2
	sun_light.directional_shadow_split_3 = 0.5

	# Position light to suggest mid-morning/afternoon illumination
	sun_light.rotation_degrees = Vector3(-45, -30, 0)

	# Add visual representation of sun (optional)
	var sun_mesh = SphereMesh.new()
	var sun_instance = MeshInstance3D.new()
	sun_instance.name = "SunMesh"
	sun_instance.mesh = sun_mesh

	# Create emissive material for sun visualization
	var sun_material = StandardMaterial3D.new()
	sun_material.emission_enabled = true
	sun_material.emission = Color(1.0, 0.9, 0.5)
	sun_material.emission_energy = 5.0
	sun_instance.material_override = sun_material

	# Position sun visual representation
	sun_instance.position = Vector3(-1000, 800, -1000)
	sun_instance.scale = Vector3(50, 50, 50)

	# Add to scene hierarchy
	add_child(sun_light)
	add_child(sun_instance)

func add_player_to_scene():
	# Create player character
	var player = CharacterBody3D.new()
	player.name = "Player"

	# Add collision shape
	var collision = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = 0.5
	capsule.height = 1.5
	collision.shape = capsule
	player.add_child(collision)

	# Add visual mesh
	var mesh = MeshInstance3D.new()
	var capsule_mesh = CapsuleMesh.new()
	capsule_mesh.radius = 0.5
	capsule_mesh.height = 1.5
	mesh.mesh = capsule_mesh
	player.add_child(mesh)

	# Set starting position (high above terrain)
	player.position = Vector3(0, 50, 0)

	# Attach controller script
	player.set_script(load("res://PlayerController.gd"))

	# Add to scene
	add_child(player)

	# Move the existing camera to be a child of the player
	var camera = get_node_or_null("Camera3D")
	if camera:
		remove_child(camera)
		player.add_child(camera)
		camera.position = Vector3(0, 0.7, 0)  # Position it at the player's head level
		camera.set_script(null)
	else:
		# Create a new camera if none exists
		camera = Camera3D.new()
		camera.position = Vector3(0, 0.7, 0)
		player.add_child(camera)

# Future enhancement: Add biome variation system
# This could be expanded to generate different terrain types
# based on position, temperature, humidity, etc.
func determine_biome(world_position: Vector2):
	# This is a placeholder for future biome implementation
	# You could add different biome types based on position
	return "default"
