extends "res://Fish.gd"

class_name StripedFish

func _ready():
	# Call parent ready function
	super._ready()
	
	# Striped fish specific settings
	fish_color = Color(0.7, 0.7, 0.9)
	fish_size = Vector3(0.5, 0.18, 0.09)
	swim_speed = 1.3
	wander_radius = 5.5
	turn_speed = 2.5
	
	# Create custom mesh with stripes
	create_striped_fish_mesh()

func create_striped_fish_mesh():
	# Create basic fish shape using primitives
	var fish_body = MeshInstance3D.new()
	fish_body.name = "FishBody"
	
	# Create fish body (flattened cube)
	var body_mesh = PrismMesh.new()
	body_mesh.size = fish_size
	fish_body.mesh = body_mesh
	
	# Create material for fish
	var fish_material = StandardMaterial3D.new()
	fish_material.albedo_color = fish_color
	fish_material.metallic = 0.7
	fish_material.roughness = 0.2
	
	fish_body.material_override = fish_material
	
	# Add tail fin
	var tail_fin = MeshInstance3D.new()
	tail_fin.name = "TailFin"
	
	var tail_mesh = PrismMesh.new()
	tail_mesh.size = Vector3(fish_size.x * 0.5, fish_size.y * 0.8, fish_size.z * 0.5)
	tail_fin.mesh = tail_mesh
	
	# Position tail
	tail_fin.position = Vector3(-fish_size.x * 0.7, 0, 0)
	
	# Create stripe material (darker color)
	var stripe_material = StandardMaterial3D.new()
	stripe_material.albedo_color = fish_color.darkened(0.4)
	stripe_material.metallic = 0.7
	stripe_material.roughness = 0.2
	
	tail_fin.material_override = stripe_material
	
	# Add stripes (simple version - just additional meshes)
	add_stripe(fish_body, 0.15, stripe_material)
	add_stripe(fish_body, -0.15, stripe_material)
	
	# Add to fish body
	fish_body.add_child(tail_fin)
	
	# Add to main node (with rotation to face forward direction)
	fish_body.rotation_degrees.y = 90
	add_child(fish_body)

func add_stripe(parent, position_y, material):
	var stripe = MeshInstance3D.new()
	stripe.name = "Stripe"
	
	var stripe_mesh = BoxMesh.new()
	stripe_mesh.size = Vector3(fish_size.x * 0.8, fish_size.y * 0.2, fish_size.z * 1.01)
	stripe.mesh = stripe_mesh
	
	stripe.position.y = position_y
	stripe.material_override = material
	
	parent.add_child(stripe)
