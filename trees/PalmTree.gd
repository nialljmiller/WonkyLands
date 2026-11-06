extends "res://trees/TreeSpecies.gd"

const TreeSpecies = preload("res://trees/TreeSpecies.gd")

func _init() -> void:
	species_name = "palm"
	biomes = ["TROPICAL_JUNGLE"]
	elevation_min = 0.0
	elevation_max = 10.0

func build_tree() -> Node3D:
	var t := Node3D.new()
	t.name = "palm_tree"

	t.add_child(TreeSpecies.make_curved_trunk(Color(0.6, 0.45, 0.25), 0.3, 5.0))

	var frond_color := Color(0.3, 0.5, 0.15)
	for i in range(6):
		var frond := TreeSpecies.make_palm_frond(frond_color)
		frond.position.y = 5.0
		frond.rotation_degrees.y = i * 60.0
		frond.rotation_degrees.x = -30.0
		t.add_child(frond)

	t.add_child(TreeSpecies.make_collision(0.3, 6.0))
	return t
