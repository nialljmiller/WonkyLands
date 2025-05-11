extends Node3D

class_name RippleSystem

# Ripple settings
@export var ripple_resolution = 256  # Size of the ripple texture (NxN)
@export var ripple_size = 20.0  # World size in meters that the ripple texture covers
@export var ripple_strength = 1.0  # Overall strength of ripples
@export var ripple_propagation_speed = 1.0  # How fast ripples move outward
@export var ripple_damping = 0.98  # How quickly ripples fade out (0-1)
@export var ripple_update_interval = 0.05  # Seconds between ripple updates
@export var max_ripples_per_frame = 5  # Maximum ripples to process per frame

# Interactive ripple settings
@export var player_ripple_interval = 0.2  # Time between player movement ripples
@export var player_ripple_speed_threshold = 3.0  # How fast player must move to create ripples
@export var player_ripple_strength = 0.5  # Strength of player movement ripples
@export var splash_ripple_strength = 1.0  # Strength of splash ripples
@export var rain_ripple_chance = 0.01  # Chance per frame of random rain ripples
@export var rain_ripple_strength = 0.3  # Strength of rain ripples

# References
var water_system = null  # Reference to parent water system
var ripple_texture: ImageTexture  # Texture for the ripples
var previous_buffer: Image  # Previous state buffer
var current_buffer: Image  # Current state buffer
var ripple_shader_param_name = "ripple_texture"  # Shader parameter to update

# Active ripples
var active_ripples = []  # List of ripples being processed
var player_ripple_timer = 0.0  # Timer for player ripples
var update_timer = 0.0  # Timer for updates
var debug_view = null  # Debug visualization

func _ready():
	# Find water system (parent)
	water_system = get_parent()
	if not water_system or not water_system.has_method("get_water_level"):
		push_error("RippleSystem requires a parent water system with get_water_level method")
	
	# Initialize ripple buffer and texture
	initialize_ripple_texture()
	
	# Create debug view if needed
	if OS.is_debug_build():
		create_debug_view()
	
	print("RippleSystem initialized with " + str(ripple_resolution) + "x" + str(ripple_resolution) + " resolution")

func _process(delta):
	# Update timer
	update_timer += delta
	if update_timer < ripple_update_interval:
		return
	
	# Reset timer
	update_timer = 0.0
	
	# Update ripples
	update_ripple_simulation()
	
	# Check for player movement ripples
	process_player_ripples(delta)
	
	# Process random environmental ripples (rain, etc.)
	process_environmental_ripples()
	
	# Update water shader with new ripple texture
	update_water_shaders()

# Initialize the ripple texture and buffers
func initialize_ripple_texture():
	# Create buffers
	previous_buffer = Image.create(ripple_resolution, ripple_resolution, false, Image.FORMAT_RF)
	current_buffer = Image.create(ripple_resolution, ripple_resolution, false, Image.FORMAT_RF)
	
	# Fill with neutral value (0.5 = no displacement)
	previous_buffer.fill(Color(0.5, 0, 0))
	current_buffer.fill(Color(0.5, 0, 0))
	
	# Create texture
	ripple_texture = ImageTexture.create_from_image(current_buffer)

# Create a debug visualization
func create_debug_view():
	debug_view = Sprite3D.new()
	debug_view.name = "RippleDebugView"
	debug_view.texture = ripple_texture
	debug_view.pixel_size = 0.1
	debug_view.modulate = Color(1, 1, 1, 0.5)
	debug_view.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	debug_view.position = Vector3(0, 2, 0)
	
	add_child(debug_view)

# Update the ripple simulation
func update_ripple_simulation():
	# Swap buffers
	var temp = previous_buffer
	previous_buffer = current_buffer
	current_buffer = temp
	
	# Water wave equation parameters
	var damping = ripple_damping
	var propagation_speed = ripple_propagation_speed
	
	# Simulate wave propagation using the wave equation
	for y in range(1, ripple_resolution - 1):
		for x in range(1, ripple_resolution - 1):
			# Sample neighboring pixels
			var top = previous_buffer.get_pixel(x, y - 1).r
			var bottom = previous_buffer.get_pixel(x, y + 1).r
			var left = previous_buffer.get_pixel(x - 1, y).r
			var right = previous_buffer.get_pixel(x + 1, y).r
			var center = previous_buffer.get_pixel(x, y).r
			var old_center = current_buffer.get_pixel(x, y).r
			
			# Wave equation: new value = (neighbors sum / 4 - center) * 2 - old_center
			var new_value = ((top + bottom + left + right) / 4.0 - center) * 2.0 * propagation_speed + center
			
			# Apply damping
			new_value = 0.5 + (new_value - 0.5) * damping
			
			# Set new pixel value
			current_buffer.set_pixel(x, y, Color(new_value, 0, 0))
	
	# Process active ripples
	var ripples_processed = 0
	var ripples_to_remove = []
	
	for ripple in active_ripples:
		# Skip if we've processed enough ripples this frame
		if ripples_processed >= max_ripples_per_frame:
			break
		
		# Update ripple
		ripple.age += ripple_update_interval
		ripple.radius += ripple.expansion_speed * ripple_update_interval
		
		# Check if ripple is too old
		if ripple.age > ripple.lifetime:
			ripples_to_remove.append(ripple)
			continue
		
		# Apply ripple to buffer
		apply_ripple_to_buffer(ripple)
		ripples_processed += 1
	
	# Remove old ripples
	for ripple in ripples_to_remove:
		active_ripples.erase(ripple)
	
	# Update texture
	ripple_texture.update(current_buffer)
	
	# Update debug view if needed
	if debug_view:
		debug_view.texture = ripple_texture

# Apply a ripple to the buffer
func apply_ripple_to_buffer(ripple):
	# Convert world position to texture coordinates
	var water_level = water_system.get_water_level()
	var tex_x = int((ripple.position.x / ripple_size + 0.5) * ripple_resolution)
	var tex_y = int((ripple.position.z / ripple_size + 0.5) * ripple_resolution)
	
	# Calculate inner and outer ripple radii in texture space
	var radius_pixels = ripple.radius / ripple_size * ripple_resolution
	var inner_radius = max(0, radius_pixels - 2)
	var outer_radius = radius_pixels
	
	# Calculate ripple strength with falloff based on age
	var intensity = ripple.strength * (1.0 - ripple.age / ripple.lifetime)
	
	# Draw ripple as a ring
	for y in range(max(0, tex_y - int(outer_radius)), min(ripple_resolution, tex_y + int(outer_radius) + 1)):
		for x in range(max(0, tex_x - int(outer_radius)), min(ripple_resolution, tex_x + int(outer_radius) + 1)):
			var dist = sqrt(pow(x - tex_x, 2) + pow(y - tex_y, 2))
			
			if dist <= outer_radius and dist >= inner_radius:
				# Calculate ripple value (wave shape)
				var ripple_value = 0.5 + intensity * sin((outer_radius - dist) / 2.0)
				
				# Get current value and blend
				var current = current_buffer.get_pixel(x, y).r
				var blended = current * 0.7 + ripple_value * 0.3
				
				# Set new value
				current_buffer.set_pixel(x, y, Color(blended, 0, 0))

# Add a ripple at a world position
func add_ripple(position: Vector3, strength: float = 1.0, radius: float = 0.2, lifetime: float = 2.0):
	# Make sure position is at water level
	var water_level = water_system.get_water_level()
	position.y = water_level
	
	# Create ripple
	var ripple = {
		"position": position,
		"strength": strength * ripple_strength,
		"radius": radius,
		"expansion_speed": 2.0,
		"age": 0.0,
		"lifetime": lifetime
	}
	
	active_ripples.append(ripple)

# Add splash ripple (stronger, bigger)
func add_splash_ripple(position: Vector3, size: float = 1.0):
	add_ripple(position, splash_ripple_strength * size, 0.5 * size, 2.0)

# Process player movement to create ripples
func process_player_ripples(delta):
	# Update player ripple timer
	player_ripple_timer -= delta
	if player_ripple_timer > 0:
		return
	
	# Get player
	var player = get_node_or_null("/root/TerrainGenerator/Player")
	if not player:
		return
	
	# Only create ripples if player is in water
	if not player.has_meta("is_swimming") or not player.get_meta("is_swimming"):
		return
	
	# Check player speed
	var velocity = Vector3.ZERO
	if player is CharacterBody3D:
		velocity = player.velocity
	
	var speed = velocity.length()
	if speed < player_ripple_speed_threshold:
		return
	
	# Create ripple at player position
	var player_pos = player.global_position
	player_pos.y = water_system.get_water_level()
	
	# Ripple strength based on speed
	var strength = min(player_ripple_strength * (speed / player_ripple_speed_threshold), 1.0)
	
	# Add ripple
	add_ripple(player_pos, strength, 0.3, 1.5)
	
	# Reset timer
	player_ripple_timer = player_ripple_interval

# Process environmental ripples (rain, wind, etc.)
func process_environmental_ripples():
	# Check for rain ripples
	var is_raining = false
	var rain_intensity = 0.0
	
	# Check for weather system
	var weather_system = get_node_or_null("/root/TerrainGenerator/WeatherSystem")
	if weather_system:
		if weather_system.has_method("is_raining") or weather_system.has("is_raining"):
			is_raining = weather_system.is_raining
		
		if weather_system.has_method("get_rain_intensity") or weather_system.has("rain_intensity"):
			rain_intensity = weather_system.rain_intensity
			if rain_intensity == null:
				rain_intensity = 0.5
	
	# Create random rain ripples
	if is_raining and randf() < rain_ripple_chance * rain_intensity:
		# Get a random position near the player
		var player = get_node_or_null("/root/TerrainGenerator/Player")
		if not player:
			return
		
		var random_offset = Vector3(
			randf_range(-10, 10),
			0,
			randf_range(-10, 10)
		)
		
		var ripple_pos = player.global_position + random_offset
		ripple_pos.y = water_system.get_water_level()
		
		# Add rain ripple
		add_ripple(ripple_pos, rain_ripple_strength * rain_intensity, 0.1, 1.0)

# Update water shaders with ripple texture
func update_water_shaders():
	# Check water system
	if not water_system or not water_system.has_method("apply_ripple_texture"):
		# Apply ripples to all water chunks
		var chunks = water_system.get("water_chunks", {})
		for chunk_pos in chunks:
			var water_mesh = chunks[chunk_pos]
			if water_mesh and is_instance_valid(water_mesh):
				var material = water_mesh.material_override
				if material and material is ShaderMaterial:
					material.set_shader_parameter(ripple_shader_param_name, ripple_texture)
	else:
		# Use water system's dedicated method
		water_system.apply_ripple_texture(ripple_texture)

# Add interaction ripple at position (for other objects)
func add_interaction_ripple(position: Vector3, strength: float = 1.0):
	# Make sure position is at water level
	var water_level = water_system.get_water_level()
	position.y = water_level
	
	# Add ripple
	add_ripple(position, strength, 0.2, 1.5)

# Clear all ripples
func clear_ripples():
	# Clear active ripples
	active_ripples.clear()
	
	# Reset buffers
	previous_buffer.fill(Color(0.5, 0, 0))
	current_buffer.fill(Color(0.5, 0, 0))
	
	# Update texture
	ripple_texture.update(current_buffer)
