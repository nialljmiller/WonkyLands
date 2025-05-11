extends Node

class_name BuoyancyComponent

# Buoyancy configuration
@export var density: float = 0.5  # Object density relative to water (< 1 floats, > 1 sinks)
@export var volume: float = 1.0  # Object volume in cubic meters
@export var water_drag: float = 0.05  # Water resistance
@export var water_angular_drag: float = 0.05  # Rotational resistance in water
@export var slosh_factor: float = 0.3  # How much water movements affect the object
@export var max_buoyancy_force: float = 20.0  # Maximum upward force

# Sampling configuration
@export var sample_points_count: int = 4  # Number of points to check for water
@export var auto_generate_sample_points: bool = true  # Automatically create sample points
@export var debug_draw: bool = false  # Visualize sample points

# Wave interaction
@export var respond_to_waves: bool = true  # Whether to respond to wave height
@export var wave_force_factor: float = 0.5  # How strongly waves push the object

# References
var parent_body  # The parent physics body (RigidBody3D or CharacterBody3D)
var water_system  # Reference to the water system
var sample_points = []  # Points to check for water level
var underwater_volume: float = 0.0  # Current percentage of volume underwater

# Debug variables
var debug_mesh: MeshInstance3D

func _ready():
	# Find parent body
	parent_body = get_parent()
	
	# Verify parent is a physics body
	if not (parent_body is RigidBody3D or parent_body is CharacterBody3D):
		push_error("BuoyancyComponent must be a child of RigidBody3D or CharacterBody3D")
		set_process(false)
		set_physics_process(false)
		return
	
	# Find water system
	water_system = get_node_or_null("/root/TerrainGenerator/WaterSystem")
	if not water_system:
		# Try to find water system in parent nodes
		var current = get_parent()
		while current and not water_system:
			water_system = current.get_node_or_null("WaterSystem")
			current = current.get_parent()
	
	if not water_system:
		push_warning("BuoyancyComponent could not find WaterSystem, will use default water level")
	
	# Generate sample points if needed
	if auto_generate_sample_points:
		generate_sample_points()
	
	# Create debug visualization if enabled
	if debug_draw:
		create_debug_visuals()

func _physics_process(delta):
	# Skip if no water system and no sample points
	if not water_system and sample_points.size() == 0:
		return
	
	# Get underwater percentage and apply buoyancy
	underwater_volume = calculate_underwater_volume()
	
	if underwater_volume > 0.0:
		# Apply buoyancy force
		apply_buoyancy_force(delta, underwater_volume)
		
		# Apply water resistance
		apply_water_resistance(delta, underwater_volume)
		
		# Apply wave forces if enabled
		if respond_to_waves:
			apply_wave_forces(delta, underwater_volume)
	
	# Update debug visualization
	if debug_draw:
		update_debug_visuals()

func generate_sample_points():
	# Clear existing points
	sample_points.clear()
	
	# Get mesh if available
	var mesh_instance = null
	for child in parent_body.get_children():
		if child is MeshInstance3D:
			mesh_instance = child
			break
	
	if mesh_instance and mesh_instance.mesh:
		# Use mesh bounds to create sample points
		var aabb = mesh_instance.mesh.get_aabb()
		var size = aabb.size
		var center = aabb.position + size / 2.0
		
		# Add center bottom point
		sample_points.append(center + Vector3(0, -size.y/2.0, 0))
		
		# Add corner points
		for x in [-1, 1]:
			for z in [-1, 1]:
				var point = center + Vector3(x * size.x * 0.4, -size.y * 0.4, z * size.z * 0.4)
				sample_points.append(point)
		
		# Add top center if we need more points
		if sample_points_count > 5:
			sample_points.append(center + Vector3(0, size.y/2.0, 0))
	else:
		# Create a default box sampling pattern
		var size = Vector3(1, 1, 1)  # Default size
		
		# Add bottom points
		for x in [-0.4, 0.4]:
			for z in [-0.4, 0.4]:
				var point = Vector3(x * size.x, -0.4 * size.y, z * size.z)
				sample_points.append(point)
	
	# Limit to requested count
	while sample_points.size() > sample_points_count:
		sample_points.pop_back()

func calculate_underwater_volume() -> float:
	if sample_points.size() == 0:
		return 0.0
	
	var water_level = -10.0  # Default water level
	if water_system and water_system.get("water_level") != null:
		water_level = water_system.water_level
	
	# Count how many sample points are underwater
	var points_underwater = 0
	
	for local_point in sample_points:
		# Transform to global coordinates
		var global_point = parent_body.global_transform * local_point
		
		# Get wave-adjusted water height at this position
		var water_height = water_level
		if water_system and water_system.has_method("get_wave_height_at_position"):
			water_height = water_system.get_wave_height_at_position(global_point)
		
		# Check if point is underwater
		if global_point.y < water_height:
			points_underwater += 1
	
	# Calculate percentage of volume underwater
	return float(points_underwater) / float(sample_points.size())

func apply_buoyancy_force(delta: float, submerged_fraction: float):
	# Calculate buoyancy force based on Archimedes' principle
	var water_density = 1.0  # Water density (1000 kg/m³ in real world)
	var displacement = volume * submerged_fraction
	var buoyancy_magnitude = displacement * water_density * 9.81 / density
	
	# Limit maximum force
	buoyancy_magnitude = min(buoyancy_magnitude, max_buoyancy_force)
	
	# Apply force
	var buoyancy_force = Vector3(0, buoyancy_magnitude, 0)
	
	if parent_body is RigidBody3D:
		# For rigid bodies, use physics forces
		parent_body.apply_central_force(buoyancy_force)
	elif parent_body is CharacterBody3D:
		# For character bodies, modify velocity directly
		parent_body.velocity.y += buoyancy_force.y * delta
		
		# Cap falling speed in water
		if parent_body.velocity.y < 0:
			parent_body.velocity.y = max(parent_body.velocity.y, -3.0)

func apply_water_resistance(delta: float, submerged_fraction: float):
	# Get current velocity
	var velocity = Vector3.ZERO
	
	if parent_body is RigidBody3D:
		velocity = parent_body.linear_velocity
	elif parent_body is CharacterBody3D:
		velocity = parent_body.velocity
	
	# Calculate drag force
	var speed = velocity.length()
	if speed < 0.01:
		return  # Object not moving significantly
	
	var drag_direction = -velocity.normalized()
	var drag_magnitude = speed * speed * water_drag * submerged_fraction
	var drag_force = drag_direction * drag_magnitude
	
	# Apply drag force
	if parent_body is RigidBody3D:
		parent_body.apply_central_force(drag_force)
		
		# Apply angular drag
		parent_body.apply_torque(-parent_body.angular_velocity * water_angular_drag * submerged_fraction)
	elif parent_body is CharacterBody3D:
		# Apply drag to velocity directly
		parent_body.velocity += drag_force * delta

func apply_wave_forces(delta: float, submerged_fraction: float):
	if not water_system or not water_system.has_method("get_wave_height_at_position"):
		return
	
	# Get object position
	var pos = parent_body.global_position
	
	# Sample wave heights around the object to find gradient
	var sample_dist = 1.0
	var heights = {
		"center": water_system.get_wave_height_at_position(pos),
		"right": water_system.get_wave_height_at_position(pos + Vector3(sample_dist, 0, 0)),
		"left": water_system.get_wave_height_at_position(pos + Vector3(-sample_dist, 0, 0)),
		"forward": water_system.get_wave_height_at_position(pos + Vector3(0, 0, sample_dist)),
		"back": water_system.get_wave_height_at_position(pos + Vector3(0, 0, -sample_dist))
	}
	
	# Calculate wave gradient (direction waves are pushing)
	var force_x = heights["left"] - heights["right"]
	var force_z = heights["back"] - heights["forward"]
	var wave_direction = Vector3(force_x, 0, force_z).normalized()
	
	# Calculate force magnitude based on wave height difference and object buoyancy
	var height_diff_magnitude = (abs(force_x) + abs(force_z)) / 2.0
	var force_magnitude = height_diff_magnitude * wave_force_factor * submerged_fraction * volume
	
	# Apply sideways force from waves
	var wave_force = wave_direction * force_magnitude
	
	# Add slight random variation for more natural movement
	wave_force += Vector3(
		(randf() - 0.5) * 0.1,
		0,
		(randf() - 0.5) * 0.1
	) * submerged_fraction * slosh_factor
	
	# Apply force
	if parent_body is RigidBody3D:
		parent_body.apply_central_force(wave_force)
	elif parent_body is CharacterBody3D:
		parent_body.velocity += wave_force * delta

func create_debug_visuals():
	# Create a small sphere for each sample point
	debug_mesh = MeshInstance3D.new()
	debug_mesh.name = "BuoyancyDebugMesh"
	add_child(debug_mesh)
	
	# Create an immediate geometry for drawing
	var immediate_mesh = ImmediateMesh.new()
	debug_mesh.mesh = immediate_mesh
	
	# Create material
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0, 1, 1, 0.7)
	material.flags_transparent = true
	material.flags_unshaded = true
	debug_mesh.material_override = material

func update_debug_visuals():
	if not debug_mesh:
		return
	
	# Get water level
	var water_level = -10.0  # Default water level
	if water_system and water_system.get("water_level") != null:
		water_level = water_system.water_level
	
	# Update visualization
	var immediate_mesh = debug_mesh.mesh as ImmediateMesh
	immediate_mesh.clear_surfaces()
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_POINTS, null)
	
	# Draw each sample point
	for i in range(sample_points.size()):
		var local_point = sample_points[i]
		var global_point = parent_body.global_transform * local_point
		
		# Get water height at this point
		var water_height = water_level
		if water_system and water_system.has_method("get_wave_height_at_position"):
			water_height = water_system.get_wave_height_at_position(global_point)
		
		# Set color based on whether point is underwater
		if global_point.y < water_height:
			immediate_mesh.surface_set_color(Color(0, 0, 1, 1))  # Blue for underwater
		else:
			immediate_mesh.surface_set_color(Color(1, 0, 0, 1))  # Red for above water
		
		# Set point size
		immediate_mesh.surface_set_normal(Vector3(0, 1, 0))
		immediate_mesh.surface_set_uv(Vector2(10.0, 10.0))  # Use UV to control point size
		
		# Add point
		immediate_mesh.surface_add_vertex(local_point)
	
	immediate_mesh.surface_end()

# Function to manually add a sample point
func add_sample_point(local_position: Vector3):
	sample_points.append(local_position)

# Function to clear all sample points
func clear_sample_points():
	sample_points.clear()

# Function to manually set the volume
func set_object_volume(new_volume: float):
	volume = max(0.01, new_volume)

# Function to adjust density
func set_object_density(new_density: float):
	density = max(0.01, new_density)

# Function to check if object is mostly underwater
func is_mostly_underwater() -> bool:
	return underwater_volume > 0.5

# Function to check if object is completely underwater
func is_fully_underwater() -> bool:
	return underwater_volume > 0.95
