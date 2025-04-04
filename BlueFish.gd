extends "res://Fish.gd"

func _ready():
	# Call parent ready function
	super._ready()
	
	# Blue fish specific settings
	fish_color = Color(0.3, 0.6, 0.9)
	fish_size = Vector3(0.4, 0.15, 0.08)
	swim_speed = 1.2
	wander_radius = 6.0
	school_distance = 3.0
	
	# Create mesh with these settings
	create_fish_mesh()
