extends "res://trees/TreeSpecies.gd"

const TreeSpecies = preload("res://trees/TreeSpecies.gd")

func _init() -> void:
	species_name = "pine"
	biomes = ["TEMPERATE_FOREST", "SNOWY_MOUNTAINS"]
	elevation_min = 15.0
	elevation_max = 100.0

func build_tree() -> Node3D:
	var t := Node3D.new()
	t.name = "pine_tree"

	t.add_child(TreeSpecies.make_trunk(Color(0.55, 0.35, 0.15), 0.4, 3.0))

	var foliage_color := Color(0.2, 0.4, 0.15)
	var tiers := [
		[2.5, 3.0, 2.0],
		[2.0, 2.0, 4.0],
		[1.5, 1.5, 5.5],
	]
	for tier in tiers:
		var f := TreeSpecies.make_cone_foliage(foliage_color, tier[0], tier[1])
		f.position.y = tier[2]
		t.add_child(f)

	t.add_child(TreeSpecies.make_collision(0.4, 7.0))
	return t
