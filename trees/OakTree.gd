extends "res://trees/TreeSpecies.gd"

const TreeSpecies = preload("res://trees/TreeSpecies.gd")

func _init() -> void:
	species_name = "oak"
	biomes = ["TEMPERATE_FOREST"]
	elevation_min = 2.0
	elevation_max = 20.0

func build_tree() -> Node3D:
	var t := Node3D.new()
	t.name = "oak_tree"

	t.add_child(TreeSpecies.make_trunk(Color(0.45, 0.3, 0.15), 0.5, 2.5))

	var foliage := TreeSpecies.make_sphere_foliage(Color(0.25, 0.4, 0.15), 3.0)
	foliage.position.y = 4.0
	t.add_child(foliage)

	t.add_child(TreeSpecies.make_collision(0.5, 6.5))
	return t
