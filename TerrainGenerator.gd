extends Node3D

# Terrain generation parameters
@export var map_width: int = 256
@export var map_depth: int = 256
@export var noise_scale: float = 0.05
@export var amplitude: float = 50.0

# Noise generation resource
var noise = FastNoiseLite.new()
var mesh_instance = MeshInstance3D.new()

func _ready():

	noise.seed = randi()
	noise.fractal_octaves = 4
	noise.frequency = 0.05

	# Generate terrain mesh
	generate_terrain()
	add_player_to_scene()
	# Apply height-based texturing
	apply_height_based_texturing()

	# Add celestial elements
	add_celestial_elements()

	# Add sky environment
	add_sky_environment()	
	
	
	
	
	
	
func generate_terrain():
	# Create mesh data structures
	var surface_tool = SurfaceTool.new()
	var mesh = ArrayMesh.new()
	
	# Begin mesh construction
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Generate vertices
	for z in range(map_depth):
		for x in range(map_width):
			# Calculate vertex position
			var y = noise.get_noise_2d(x * noise_scale, z * noise_scale) * amplitude
			surface_tool.add_vertex(Vector3(x - map_width/2, y, z - map_depth/2))
	
	# Generate indices (triangles)
	for z in range(map_depth - 1):
		for x in range(map_width - 1):
			var i = z * map_width + x
			
			# First triangle
			surface_tool.add_index(i)
			surface_tool.add_index(i + 1)
			surface_tool.add_index(i + map_width)
			
			# Second triangle
			surface_tool.add_index(i + 1)
			surface_tool.add_index(i + map_width + 1)
			surface_tool.add_index(i + map_width)
	
	# Finalize mesh
	surface_tool.generate_normals()
	mesh = surface_tool.commit()
	
	# Create mesh instance
	mesh_instance.mesh = mesh
	add_child(mesh_instance)
	
		# Replace the problematic collision shape code with:
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
	add_child(static_body)
	
		
# Add to TerrainGenerator script
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
	

# Enhanced collision implementation for terrain
func implement_terrain_collision():
	# Create static body for physics interactions
	var static_body = StaticBody3D.new()
	static_body.name = "TerrainCollider"

	# Configure collision properties
	static_body.collision_layer = 1  # Layer 1 for terrain
	static_body.collision_mask = 0   # Does not detect collisions itself

	# Extract mesh data for collision creation
	var mesh_arrays = mesh_instance.mesh.surface_get_arrays(0)
	var vertices = mesh_arrays[Mesh.ARRAY_VERTEX]
	var indices = mesh_arrays[Mesh.ARRAY_INDEX]

	# Create face array for collision shape
	var faces = PackedVector3Array()
	for i in range(0, indices.size(), 3):
		faces.append(vertices[indices[i]])
		faces.append(vertices[indices[i+1]])
		faces.append(vertices[indices[i+2]])

	# Create and configure collision shape
	var collision_shape = CollisionShape3D.new()
	var shape = ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	collision_shape.shape = shape

	# Add to static body
	static_body.add_child(collision_shape)
	add_child(static_body)

	# Return reference for further configuration
	return static_body
	
	
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
	var camera = get_node("Camera3D")
	if camera:
		remove_child(camera)
		player.add_child(camera)
		camera.position = Vector3(0, 0.7, 0)  # Position it at the player's head level

		# Disable the camera's own movement script
		camera.set_script(null)
		
		
		
# Modified apply_height_based_texturing function
func apply_height_based_texturing():
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

	# Set shader parameters with more diverse elevation thresholds
	terrain_material.set_shader_parameter("low_threshold", -10.0) # // Sand level
	terrain_material.set_shader_parameter("mid_threshold", 0.0)   # // Grass level
	terrain_material.set_shader_parameter("high_threshold", 20.0) # // Rock level
	terrain_material.set_shader_parameter("snow_threshold", 35.0) # // Snow level
	terrain_material.set_shader_parameter("blend_range", 3.0)     # // Blend zone

	#// Set colors
	terrain_material.set_shader_parameter("sand_color", Color(0.94, 0.83, 0.64))  #// Sand
	terrain_material.set_shader_parameter("grass_color", Color(0.33, 0.63, 0.22)) #// Grass
	terrain_material.set_shader_parameter("rock_color", Color(0.50, 0.45, 0.40))  #// Rock
	terrain_material.set_shader_parameter("snow_color", Color(0.95, 0.95, 0.97))  #// Snow

	#// Apply material to terrain mesh
	mesh_instance.material_override = terrain_material
		
	
# Modified texture loading function
func load_texture(path):
	var texture

	if ResourceLoader.exists(path):
		texture = load(path)
	else:
		# Create placeholder texture if file doesn't exist
		texture = create_placeholder_texture()

	# In Godot 4.x, texture repeating is configured differently
	# This is now handled through material parameters
	return texture

func create_placeholder_texture():
	# Create a new empty image
	var image = Image.create(64, 64, false, Image.FORMAT_RGB8)

	# Fill with a placeholder pattern
	image.fill(Color(0.5, 0.5, 0.5))

	# Create texture from image
	var texture = ImageTexture.create_from_image(image)
	return texture
	
	
	
	
