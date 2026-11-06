extends "res://trees/TreeSpecies.gd"

const TreeSpecies = preload("res://trees/TreeSpecies.gd")

func _init() -> void:
	species_name = "cactus"
	biomes = ["DESERT"]
	elevation_min = 0.0
	elevation_max = 15.0

func build_tree() -> Node3D:
	var t := Node3D.new()
	t.name = "cactus"

	var body_color := Color(0.2, 0.4, 0.15)
	t.add_child(TreeSpecies.make_trunk(body_color, 0.4, 3.0))

	var arm1 := TreeSpecies.make_trunk(body_color, 0.3, 1.5)
	arm1.position = Vector3(0.4, 1.5, 0.0)
	arm1.rotation_degrees.z = -45.0
	t.add_child(arm1)

	var arm2 := TreeSpecies.make_trunk(body_color, 0.3, 1.5)
	arm2.position = Vector3(-0.4, 2.0, 0.0)
	arm2.rotation_degrees.z = 45.0
	t.add_child(arm2)

	t.add_child(TreeSpecies.make_collision(0.4, 3.5))
	return t
