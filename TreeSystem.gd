extends Node3D

class_name TreeSystem

# Tree placement settings
@export var tree_density: float = 0.5
@export var min_distance_between_trees: float = 3.0
@export var max_slope_angle: float = 35.0 # Maximum ground slope angle to place trees (degrees)

# Tree appearance settings
@export var tree_scale_variation: float = 0.2
@export var tree_rotation_variation: float = 180.0

# Tree placement boundaries
@export var min_height: float = 0.0 # Trees above water level only
@export var max_height: float = 100.0
@export var terrain_interaction_margin: float = 1.0 # Prevent tree trunks from clipping into terrain

# Tree prefab/scene storage
var tree_prefabs = {}
var tree_positions = {}
var active_trees = []


# Define elevation ranges for tree types
var tree_elevation_ranges = {
	"pine": {"min": 15.0, "max": 100.0},  # Pines at higher elevations
	"oak": {"min": 2.0, "max": 20.0},     # Oaks at medium elevations
	"palm": {"min": 0.0, "max": 10.0},    # Palms near water level
	"dead": {"min": 5.0, "max": 50.0},    # Dead trees range
	"cactus": {"min": 0.0, "max": 15.0}   # Cacti in lowlands
}


# Reference to parent terrain generator
var terrain_generator

func _ready():
	# Immediately setup tree prefabs
	setup_tree_prefabs()


# Make sure these registrations match your desired biome rules
func setup_tree_prefabs():
	# First, let's create our base tree resources
	create_pine_tree()
	create_oak_tree()
	create_palm_tree()
	create_dead_tree()
	create_cactus()

	# Clear any existing registrations
	tree_prefabs["TEMPERATE_FORESTs"] = ["oak", "pine"]  # Both in temperate forests
	tree_prefabs["SNOWY_MOUNTAINS"] = ["pine"]  # Only pine in snowy mountains
	tree_prefabs["DESERT"] = ["cactus"]  # Only cacti in desert
	tree_prefabs["TROPICAL_JUNGLE"] = ["palm"]  # Only palms in jungle
	tree_prefabs["VOLCANIC_WASTELAND"] = ["dead"]  # Only dead trees in wasteland


# Create a simple pine tree mesh
func create_pine_tree():
	var tree_node = Node3D.new()
	tree_node.name = "pine_tree"
	
	# Create trunk
	var trunk = create_trunk(Color(0.55, 0.35, 0.15), 0.4, 3.0)
	tree_node.add_child(trunk)
	
	# Create pine foliage (multiple cone shapes)
	var foliage_color = Color(0.2, 0.4, 0.15)
	
	var foliage1 = create_cone_foliage(foliage_color, 2.5, 3.0)
	foliage1.position.y = 2.0
	tree_node.add_child(foliage1)
	
	var foliage2 = create_cone_foliage(foliage_color, 2.0, 2.0)
	foliage2.position.y = 4.0
	tree_node.add_child(foliage2)
	
	var foliage3 = create_cone_foliage(foliage_color, 1.5, 1.5)
	foliage3.position.y = 5.5
	tree_node.add_child(foliage3)
	
	# Create collision shape
	var collision = create_tree_collision(0.4, 7.0)
	tree_node.add_child(collision)
	
	tree_prefabs["pine"] = tree_node

# Create a simple oak tree mesh
func create_oak_tree():
	var tree_node = Node3D.new()
	tree_node.name = "oak_tree"
	
	# Create trunk
	var trunk = create_trunk(Color(0.45, 0.3, 0.15), 0.5, 2.5)
	tree_node.add_child(trunk)
	
	# Create spherical foliage
	var foliage = create_sphere_foliage(Color(0.25, 0.4, 0.15), 3.0)
	foliage.position.y = 4.0
	tree_node.add_child(foliage)
	
	# Create collision shape
	var collision = create_tree_collision(0.5, 6.5)
	tree_node.add_child(collision)
	
	tree_prefabs["oak"] = tree_node

# Create a simple palm tree mesh
func create_palm_tree():
	var tree_node = Node3D.new()
	tree_node.name = "palm_tree"
	
	# Create curved trunk
	var trunk = create_curved_trunk(Color(0.6, 0.45, 0.25), 0.3, 5.0)
	tree_node.add_child(trunk)
	
	# Create palm fronds
	for i in range(6):
		var frond = create_palm_frond(Color(0.3, 0.5, 0.15))
		frond.position.y = 5.0
		frond.rotation_degrees.y = i * 60
		frond.rotation_degrees.x = -30
		tree_node.add_child(frond)
	
	# Create collision shape
	var collision = create_tree_collision(0.3, 6.0)
	tree_node.add_child(collision)
	
	tree_prefabs["palm"] = tree_node

# Create a simple dead tree mesh
func create_dead_tree():
	var tree_node = Node3D.new()
	tree_node.name = "dead_tree"
	
	# Create trunk
	var trunk = create_trunk(Color(0.3, 0.25, 0.2), 0.4, 4.0)
	tree_node.add_child(trunk)
	
	# Create bare branches
	var branch1 = create_branch(Color(0.35, 0.3, 0.25), 0.2, 2.0)
	branch1.position.y = 3.0
	branch1.rotation_degrees.z = 45
	tree_node.add_child(branch1)
	
	var branch2 = create_branch(Color(0.35, 0.3, 0.25), 0.2, 1.5)
	branch2.position.y = 3.5
	branch2.rotation_degrees.z = -30
	branch2.rotation_degrees.y = 90
	tree_node.add_child(branch2)
	
	var branch3 = create_branch(Color(0.35, 0.3, 0.25), 0.15, 1.0)
	branch3.position.y = 4.0
	branch3.rotation_degrees.z = 20
	branch3.rotation_degrees.y = 180
	tree_node.add_child(branch3)
	
	# Create collision shape
	var collision = create_tree_collision(0.4, 5.0)
	tree_node.add_child(collision)
	
	tree_prefabs["dead"] = tree_node

# Create a simple cactus mesh
func create_cactus():
	var cactus_node = Node3D.new()
	cactus_node.name = "cactus"
	
	# Create main body
	var main_body = create_trunk(Color(0.2, 0.4, 0.15), 0.4, 3.0)
	cactus_node.add_child(main_body)
	
	# Create arms
	var arm1 = create_trunk(Color(0.2, 0.4, 0.15), 0.3, 1.5)
	arm1.position.y = 1.5
	arm1.position.x = 0.4
	arm1.rotation_degrees.z = -45
	cactus_node.add_child(arm1)
	
	var arm2 = create_trunk(Color(0.2, 0.4, 0.15), 0.3, 1.5)
	arm2.position.y = 2.0
	arm2.position.x = -0.4
	arm2.rotation_degrees.z = 45
	cactus_node.add_child(arm2)
	
	# Create collision shape
	var collision = create_tree_collision(0.4, 3.5)
	cactus_node.add_child(collision)
	
	tree_prefabs["cactus"] = cactus_node

# Helper function to create a tree trunk
func create_trunk(color: Color, radius: float, height: float) -> MeshInstance3D:
	var trunk_mesh = CylinderMesh.new()
	trunk_mesh.top_radius = radius * 0.8
	trunk_mesh.bottom_radius = radius
	trunk_mesh.height = height
	
	var trunk_instance = MeshInstance3D.new()
	trunk_instance.mesh = trunk_mesh
	
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	trunk_instance.material_override = material
	
	return trunk_instance

# Helper function to create a curved trunk (for palm trees)
func create_curved_trunk(color: Color, radius: float, height: float) -> MeshInstance3D:
	var trunk_mesh = CylinderMesh.new()
	trunk_mesh.top_radius = radius * 0.7
	trunk_mesh.bottom_radius = radius
	trunk_mesh.height = height
	
	var trunk_instance = MeshInstance3D.new()
	trunk_instance.mesh = trunk_mesh
	
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	trunk_instance.material_override = material
	
	# Add a slight curve to the trunk
	trunk_instance.rotation_degrees.x = -15
	
	return trunk_instance

# Helper function to create a branch
func create_branch(color: Color, radius: float, length: float) -> MeshInstance3D:
	var branch_mesh = CylinderMesh.new()
	branch_mesh.top_radius = radius * 0.5
	branch_mesh.bottom_radius = radius
	branch_mesh.height = length
	
	var branch_instance = MeshInstance3D.new()
	branch_instance.mesh = branch_mesh
	
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	branch_instance.material_override = material
	
	# Rotate cylinder to extend horizontally
	branch_instance.rotation_degrees.x = 90
	# Move pivot point to one end
	branch_instance.position.z = length / 2
	
	return branch_instance

# Helper function to create cone-shaped foliage (for pine trees)
func create_cone_foliage(color: Color, radius: float, height: float) -> MeshInstance3D:
	var foliage_mesh = CylinderMesh.new()
	foliage_mesh.top_radius = 0.0
	foliage_mesh.bottom_radius = radius
	foliage_mesh.height = height
	
	var foliage_instance = MeshInstance3D.new()
	foliage_instance.mesh = foliage_mesh
	
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.7
	foliage_instance.material_override = material
	
	return foliage_instance

# Helper function to create spherical foliage (for deciduous trees)
func create_sphere_foliage(color: Color, radius: float) -> MeshInstance3D:
	var foliage_mesh = SphereMesh.new()
	foliage_mesh.radius = radius
	foliage_mesh.height = radius * 2
	
	var foliage_instance = MeshInstance3D.new()
	foliage_instance.mesh = foliage_mesh
	
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.7
	foliage_instance.material_override = material
	
	return foliage_instance

# Helper function to create palm frond
func create_palm_frond(color: Color) -> MeshInstance3D:
	var frond_mesh = PrismMesh.new()
	frond_mesh.size = Vector3(2.0, 0.1, 0.5)
	
	var frond_instance = MeshInstance3D.new()
	frond_instance.mesh = frond_mesh
	
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.6
	frond_instance.material_override = material
	
	# Position so one end is at origin
	frond_instance.position.z = 1.0
	
	return frond_instance

# Helper function to create tree collision
func create_tree_collision(radius: float, height: float) -> StaticBody3D:
	var collision_body = StaticBody3D.new()
	collision_body.name = "TreeCollision"
	
	var collision_shape = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = radius
	capsule.height = height
	
	collision_shape.shape = capsule
	collision_shape.position.y = height / 2
	
	collision_body.add_child(collision_shape)
	
	return collision_body

# Register a type of tree for a specific biome
func register_tree_for_biome(tree_type: String, biome_name: String):
	# Store trees by biome for easy lookup
	if not tree_type in tree_prefabs:
		push_error("Tree type '", tree_type, "' not found in tree_prefabs")
		return
		
	if not biome_name in tree_prefabs:
		tree_prefabs[biome_name] = []
	
	if tree_prefabs[biome_name] is Array:
		tree_prefabs[biome_name].append(tree_type)
	else:
		tree_prefabs[biome_name] = [tree_type]

# Get a random tree type for a specific biome
func get_random_tree_for_biome(biome_type) -> String:
	var biome_name = biome_type_to_string(biome_type)
	
	if biome_name in tree_prefabs and tree_prefabs[biome_name] is Array and tree_prefabs[biome_name].size() > 0:
		var trees_for_biome = tree_prefabs[biome_name]
		return trees_for_biome[randi() % trees_for_biome.size()]
	else:
		# Fallback to a generic tree if no specific trees for this biome
		return "oak"

# Convert biome enum to string name
func biome_type_to_string(biome_type) -> String:
	# This must match the enum in TerrainGenerator.gd
	match biome_type:
		0: return "TEMPERATE_FOREST"
		1: return "DESERT"
		2: return "SNOWY_MOUNTAINS"
		3: return "TROPICAL_JUNGLE"
		4: return "VOLCANIC_WASTELAND"
		_: return "TEMPERATE_FOREST"  # Default


# Place trees for a specific chunk with improved elevation handling
func place_trees_in_chunk(chunk_node: Node3D, chunk_pos: Vector2, biome_type, terrain_heightmap = null):
	# Get world position for this chunk
	var chunk_size = terrain_generator.chunk_size
	var world_pos_x = chunk_pos.x * chunk_size
	var world_pos_z = chunk_pos.y * chunk_size

	# Get water level from terrain generator
	var water_level = terrain_generator.water_level

	# Seed random number generator based on chunk position for consistency
	seed((chunk_pos.x * 1000 + chunk_pos.y) as int)

	# Calculate number of trees based on density and biome
	var base_num_trees = int(chunk_size * chunk_size * tree_density / 100.0)

	# Adjust tree density based on biome
	var biome_density_multiplier = 1.0
	var biome_name = biome_type_to_string(biome_type)

	match biome_type:
		0:  # TEMPERATE_FOREST
			biome_density_multiplier = 1.5
		1:  # DESERT
			biome_density_multiplier = 0.2
		2:  # SNOWY_MOUNTAINS
			biome_density_multiplier = 0.8
			if randf() < 0.9:  # 90% chance for pines in snowy areas
				tree_prefabs[biome_name] = ["pine"]
		3:  # TROPICAL_JUNGLE
			biome_density_multiplier = 2.0
		4:  # VOLCANIC_WASTELAND
			biome_density_multiplier = 0.3

	var num_trees = int(base_num_trees * biome_density_multiplier)
	var placed_positions = []

	# Track this chunk's trees
	tree_positions[chunk_pos] = []

	# Try to place trees
	var attempts = 0
	var max_attempts = num_trees * 5  # Allow multiple attempts per tree

	while placed_positions.size() < num_trees and attempts < max_attempts:
		attempts += 1

		# Generate random position within chunk
		var local_x = randf_range(0, chunk_size)
		var local_z = randf_range(0, chunk_size)

		var world_x = world_pos_x + local_x
		var world_z = world_pos_z + local_z

		# Get terrain height at this position
		var terrain_height = calculate_terrain_height(world_x, world_z)

		# Skip if underwater - add extra margin to ensure trees aren't partially submerged
		if terrain_height < water_level + 0.5:
			continue
			
		# Determine appropriate tree type based on biome and elevation
		var valid_tree_types = []
		var all_biome_trees = tree_prefabs[biome_name] if biome_name in tree_prefabs else ["oak"] # Default

		# Filter tree types based on elevation
		for tree_type in all_biome_trees:
			if tree_type in tree_elevation_ranges:
				var range_data = tree_elevation_ranges[tree_type]
				if terrain_height >= range_data["min"] and terrain_height <= range_data["max"]:
					valid_tree_types.append(tree_type)

		# If no valid tree type for this elevation, skip
		if valid_tree_types.size() == 0:
			continue
			
		# Calculate slope at this position
		var slope = calculate_terrain_slope(world_x, world_z)
		if slope > max_slope_angle:
			continue

		# Check minimum distance to other trees
		var too_close = false
		for pos in placed_positions:
			var dist = Vector2(world_x, world_z).distance_to(Vector2(pos.x, pos.z))
			if dist < min_distance_between_trees:
				too_close = true
				break

		if too_close:
			continue

		# All checks passed, place a tree
		var pos = Vector3(world_x, terrain_height, world_z)
		placed_positions.append(pos)
		tree_positions[chunk_pos].append(pos)

		# Create the tree with a specific type from valid types
		var selected_tree_type = valid_tree_types[randi() % valid_tree_types.size()]
		create_tree_at_position(pos, selected_tree_type, chunk_node)

	# Debug output
	if placed_positions.size() > 0:
		print("Placed ", placed_positions.size(), " trees in chunk ", chunk_pos)
		
		
# Calculate terrain height at given world position
func calculate_terrain_height(world_x: float, world_z: float) -> float:
	# Use same noise and settings as terrain generator
	var noise = terrain_generator.noise
	var noise_scale = terrain_generator.noise_scale
	var amplitude = terrain_generator.amplitude
	
	# Calculate base height using noise
	var base_height = noise.get_noise_2d(world_x * noise_scale, world_z * noise_scale) * amplitude
	
	# Get biome at this position
	var biome_type = terrain_generator.determine_biome(Vector2(world_x, world_z))
	
	# Apply biome-specific height adjustments
	return terrain_generator.apply_biome_height_adjustments(base_height, biome_type, Vector2(world_x, world_z))

# Calculate terrain slope at given world position
func calculate_terrain_slope(world_x: float, world_z: float) -> float:
	var sample_distance = 1.0
	
	# Sample heights at neighboring points
	var height_center = calculate_terrain_height(world_x, world_z)
	var height_north = calculate_terrain_height(world_x, world_z - sample_distance)
	var height_south = calculate_terrain_height(world_x, world_z + sample_distance)
	var height_east = calculate_terrain_height(world_x + sample_distance, world_z)
	var height_west = calculate_terrain_height(world_x - sample_distance, world_z)
	
	# Calculate partial derivatives for x and z directions
	var slope_x = (height_east - height_west) / (2 * sample_distance)
	var slope_z = (height_south - height_north) / (2 * sample_distance)
	
	# Calculate slope angle in degrees
	var normal = Vector3(-slope_x, 1.0, -slope_z).normalized()
	var angle = rad_to_deg(acos(normal.dot(Vector3.UP)))
	
	return angle



func create_tree_at_position(position: Vector3, tree_type: String, parent_node: Node3D):
	if not tree_type in tree_prefabs:
		push_error("Tree type '", tree_type, "' not found!")
		return

	# Instance the tree prefab
	var tree_node = tree_prefabs[tree_type].duplicate()

	# Apply random variations
	var scale_factor = 1.0 + randf_range(-tree_scale_variation, tree_scale_variation)
	tree_node.scale = Vector3(scale_factor, scale_factor, scale_factor)

	# Apply random rotation around Y axis
	tree_node.rotation_degrees.y = randf_range(0, tree_rotation_variation)

	# In TreeSystem.gd - create_tree_at_position function
	# Replace the current position setting with:
	var terrain_height = calculate_terrain_height(position.x, position.z)

	# Remove or reduce the terrain_interaction_margin
	# Set to 0 or a very small value like 0.01
	position.y = terrain_height + 0.01  # Just enough to avoid z-fighting
	# Apply the corrected position
	tree_node.position = position

	# Add to parent
	parent_node.add_child(tree_node)
	active_trees.append(tree_node)

	return tree_node

# Update tree chunks when terrain chunks change
func update_tree_chunks(player_pos: Vector3, view_distance: int, chunk_size: int):
	var center_chunk_x = floor(player_pos.x / chunk_size)
	var center_chunk_z = floor(player_pos.z / chunk_size)
	
	# Track which chunks should remain loaded
	var chunks_to_keep = {}
	
	# Go through visible terrain chunks to add trees
	for x in range(center_chunk_x - view_distance, center_chunk_x + view_distance + 1):
		for z in range(center_chunk_z - view_distance, center_chunk_z + view_distance + 1):
			var chunk_pos = Vector2(x, z)
			chunks_to_keep[chunk_pos] = true
			
			# If terrain chunk exists but no trees yet, add them
			if terrain_generator.loaded_chunks.has(chunk_pos) and not tree_positions.has(chunk_pos):
				var chunk_node = terrain_generator.loaded_chunks[chunk_pos]
				var biome_type = terrain_generator.determine_biome(
					Vector2(x * chunk_size + chunk_size/2, z * chunk_size + chunk_size/2)
				)
				place_trees_in_chunk(chunk_node, chunk_pos, biome_type)
	
	# Remove trees in chunks outside view distance
	var chunks_to_remove = []
	for chunk_pos in tree_positions.keys():
		if not chunks_to_keep.has(chunk_pos):
			chunks_to_remove.append(chunk_pos)
	
	for chunk_pos in chunks_to_remove:
		remove_trees_in_chunk(chunk_pos)

# Remove trees in a specific chunk
func remove_trees_in_chunk(chunk_pos: Vector2):
	if not tree_positions.has(chunk_pos):
		return
		
	# Find all tree nodes in this chunk and remove them
	for tree_pos in tree_positions[chunk_pos]:
		for tree in active_trees:
			if is_instance_valid(tree) and tree.position.is_equal_approx(tree_pos):
				tree.queue_free()
				active_trees.erase(tree)
				break
	
	# Remove chunk from tracking
	tree_positions.erase(chunk_pos)




# Add this function to TreeSystem.gd
func get_exact_ground_height(world_x: float, world_z: float) -> float:
	var space_state = get_world_3d().direct_space_state
	var from = Vector3(world_x, 1000, world_z)  # Start high above
	var to = Vector3(world_x, -1000, world_z)   # End deep below

	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space_state.intersect_ray(query)

	if result:
		return result.position.y
	else:
		# Fallback to noise-based height if raycast fails
		return calculate_terrain_height(world_x, world_z)
