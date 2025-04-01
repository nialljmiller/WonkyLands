extends StaticBody3D

class_name Tree

# Tree properties
@export var tree_type: String = "oak"
@export var tree_health: float = 100.0
@export var can_be_cut: bool = true
@export var regrowth_time: float = 300.0  # Seconds for tree to regrow

# Visual state
@export var wind_strength: float = 0.05
@export var wind_speed: float = 1.0
@export var sway_amount: float = 0.02
var initial_scale
var initial_rotation
var is_cut: bool = false

# Interaction
var player_in_range: bool = false
var cut_progress: float = 0.0
var time_since_cut: float = 0.0

# References to components
var trunk_mesh
var foliage_meshes = []
var collision_shape
var interaction_area

func _ready():
	# Store initial transform for animating
	initial_scale = scale
	initial_rotation = rotation
	
	# Find trunk and foliage meshes
	for child in get_children():
		if child is MeshInstance3D:
			if "trunk" in child.name.to_lower():
				trunk_mesh = child
			elif "foliage" in child.name.to_lower() or "leaf" in child.name.to_lower():
				foliage_meshes.append(child)
	
	# Create interaction area if not already there
	setup_interaction_area()

func _process(delta):
	# Wind animation for foliage
	if not is_cut:
		animate_wind(delta)
	
	# Handle regrowth if cut
	if is_cut and can_be_cut:
		time_since_cut += delta
		if time_since_cut >= regrowth_time:
			regrow_tree()

# Creates an area around the tree for interaction
func setup_interaction_area():
	interaction_area = Area3D.new()
	interaction_area.name = "InteractionArea"
	
	var area_shape = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = 3.0  # Interaction distance
	area_shape.shape = sphere
	
	# Position area halfway up the tree for better interaction
	area_shape.position.y = 2.0
	
	interaction_area.add_child(area_shape)
	add_child(interaction_area)
	
	# Connect interaction signals
	interaction_area.body_entered.connect(_on_body_entered_interaction)
	interaction_area.body_exited.connect(_on_body_exited_interaction)

# Apply gentle wind animation to tree foliage
func animate_wind(delta):
	if foliage_meshes.size() == 0:
		return
		
	var time = Time.get_ticks_msec() / 1000.0
	
	for foliage in foliage_meshes:
		if is_instance_valid(foliage):
			# Calculate sway based on wind and time
			var sway_x = sin(time * wind_speed + position.x * 0.1) * sway_amount
			var sway_z = cos(time * wind_speed * 0.7 + position.z * 0.1) * sway_amount
			
			# Apply subtle rotation to foliage
			foliage.rotation.x = initial_rotation.x + sway_x * wind_strength
			foliage.rotation.z = initial_rotation.z + sway_z * wind_strength

# Player interaction handlers
func _on_body_entered_interaction(body):
	if body.name == "Player":
		player_in_range = true
		# Show interaction prompt - implementation would depend on your UI system
		print("Press E to interact with tree")

func _on_body_exited_interaction(body):
	if body.name == "Player":
		player_in_range = false
		# Hide interaction prompt
		print("Player left tree interaction zone")

# Handle cutting down the tree
func cut_tree():
	if is_cut or not can_be_cut:
		return
		
	is_cut = true
	time_since_cut = 0.0
	
	# Hide foliage
	for foliage in foliage_meshes:
		if is_instance_valid(foliage):
			foliage.visible = false
	
	# Shorten trunk
	if trunk_mesh:
		# Just shorten the trunk to simulate a stump
		trunk_mesh.scale.y = 0.2
		trunk_mesh.position.y = -trunk_mesh.scale.y * trunk_mesh.mesh.height / 2
	
	# Disable collision
	var tree_collision = get_node_or_null("TreeCollision")
	if tree_collision:
		tree_collision.disabled = true
	
	# Spawn dropped items (wood, etc.)
	spawn_wood()

# Regrow the tree after being cut
func regrow_tree():
	is_cut = false
	
	# Restore foliage
	for foliage in foliage_meshes:
		if is_instance_valid(foliage):
			foliage.visible = true
	
	# Restore trunk
	if trunk_mesh:
		trunk_mesh.scale = Vector3(1, 1, 1)
		trunk_mesh.position.y = 0
	
	# Re-enable collision
	var tree_collision = get_node_or_null("TreeCollision")
	if tree_collision:
		tree_collision.disabled = false

# Spawn wood items when tree is cut
func spawn_wood():
	# This is where you'd instantiate your wood item pickup
	# The implementation depends on your inventory/item system
	print("Wood dropped from ", tree_type, " tree")
	
	# Example of what this might look like:
	# var wood_item = load("res://items/WoodItem.tscn").instantiate()
	# wood_item.position = global_position + Vector3(0, 1, 0)
	# wood_item.item_count = randi_range(2, 5)  # Random amount of wood
	# get_parent().add_child(wood_item)

# Apply damage to the tree (for chopping)
func damage_tree(amount: float) -> bool:
	if is_cut or not can_be_cut:
		return false
		
	tree_health -= amount
	
	# Visual feedback
	if trunk_mesh:
		trunk_mesh.rotation_degrees.z = lerp(0.0, 5.0, (100.0 - tree_health) / 100.0)
	
	# Check if tree should fall
	if tree_health <= 0:
		cut_tree()
		return true
	
	return false
	
# Take damage from player tools
func _on_interaction_input():
	if player_in_range and Input.is_action_just_pressed("interact"):  # Define this action in your input map
		# If player has axe equipped, damage tree
		var player = get_node("/root/TerrainGenerator/Player")
		if player and player.has_method("get_equipped_tool"):
			var tool_type = player.get_equipped_tool()
			
			if tool_type == "axe":
				var damage = 20.0  # Base damage value
				damage_tree(damage)
			else:
				print("Need an axe to cut down trees!")
		else:
			# Simple version, just cut the tree
			cut_tree()
