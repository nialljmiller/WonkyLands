extends "res://Fish.gd"

class_name DeepSeaFish

# Deep sea fish settings
@export var min_depth: float = 10.0  # Minimum depth below water
@export var preferred_depth: float = 20.0  # Preferred swimming depth
@export var has_lure: bool = true  # Whether this fish has a bioluminescent lure
@export var lure_color: Color = Color(0.0, 0.9, 1.0, 1.0)  # Color of the lure

var depth_weight: float = 0.7
var lure_mesh: MeshInstance3D

func _ready():
	# Call parent ready function
	super._ready()
	
	# Deep sea fish specific settings
	fish_color = Color(0.05, 0.05, 0.1)
	fish_size = Vector3(0.8, 0.3, 0.15)
	swim_speed = 0.8
	wander_radius = 4.0
	
	# Create mesh with these settings
	create_deep_sea_fish_mesh()

func _physics_process(delta):
	# Normal fish behavior
	super._physics_process(delta)
	
	# Deep sea fish stay deep underwater
	if is_instance_valid(water_system):
		var current_depth = water_system.water_level - global_position.y
		
		# If too shallow, dive deeper
		if current_depth < min_depth:
			velocity.y = -swim_speed * 2  # Dive faster
		
		# Try to maintain preferred depth
		elif abs(current_depth - preferred_depth) > 2.0:
			var depth_adjustment = sign(preferred_depth - current_depth) * swim_speed * 0.5
			velocity.y = lerp(velocity.y, depth_adjustment, depth_weight * delta)
	
	# Pulsate the lure light if present
	if has_lure and is_instance_valid(lure_mesh):
		var pulse = (1.0 + sin(Time.get_ticks_msec() / 500.0)) / 2.0
		var lure_material = lure_mesh.material_override
		if lure_material:
			lure_material.emission_energy = 2.0 + pulse * 3.0

func create_deep_sea_fish_mesh():
	# Create basic fish shape using primitives
	var fish_body = MeshInstance3D.new()
	fish_body.name = "FishBody"
	
	# Create fish body (elongated shape)
	var body_mesh = PrismMesh.new()
	body_mesh.size = fish_size
	fish_body.mesh = body_mesh
	
	# Create material for fish
	var fish_material = StandardMaterial3D.new()
	fish_material.albedo_color = fish_color
	fish_material.metallic = 0.5
	fish_material.roughness = 0.3
	
	fish_body.material_override = fish_material
	
	# Add tail fin
	var tail_fin = MeshInstance3D.new()
	tail_fin.name = "TailFin"
	
	var tail_mesh = PrismMesh.new()
	tail_mesh.size = Vector3(fish_size.x * 0.5, fish_size.y * 0.8, fish_size.z * 0.5)
	tail_fin.mesh = tail_mesh
	
	# Position tail
	tail_fin.position = Vector3(-fish_size.x * 0.7, 0, 0)
	tail_fin.material_override = fish_material
	
	# Add to fish body
	fish_body.add_child(tail_fin)
	
	# Add light lure if enabled
	if has_lure:
		lure_mesh = MeshInstance3D.new()
		lure_mesh.name = "Lure"
		
		var lure_sphere = SphereMesh.new()
		lure_sphere.radius = fish_size.x * 0.1
		lure_sphere.height = fish_size.x * 0.2
		lure_mesh.mesh = lure_sphere
		
		# Create emissive material for lure
		var lure_material = StandardMaterial3D.new()
		lure_material.emission_enabled = true
		lure_material.emission = lure_color
		lure_material.emission_energy = 3.0
		
		lure_mesh.material_override = lure_material
		
		# Position lure in front of fish head
		lure_mesh.position = Vector3(fish_size.x * 0.6, fish_size.y * 0.3, 0)
		
		# Add to fish body
		fish_body.add_child(lure_mesh)
	
	# Add to main node (with rotation to face forward direction)
	fish_body.rotation_degrees.y = 90
	add_child(fish_body)

func get_random_target() -> Vector3:
	# Override to prefer deeper water targets
	var random_offset = Vector3(
		randf_range(-wander_radius, wander_radius),
		randf_range(-wander_radius/4, wander_radius/4),  # Smaller vertical movement
		randf_range(-wander_radius, wander_radius)
	)
	
	var target = initial_position + random_offset
	
	# Make sure target is deep enough below water level
	if water_system:
		var min_y = water_system.water_level - preferred_depth - 5.0
		var max_y = water_system.water_level - min_depth + 2.0
		target.y = clamp(target.y, min_y, max_y)
	
	return target
