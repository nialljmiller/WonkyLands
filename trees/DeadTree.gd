extends "res://trees/TreeSpecies.gd"

const TreeSpecies = preload("res://trees/TreeSpecies.gd")

func _init() -> void:
	species_name = "dead"
	biomes = ["VOLCANIC_WASTELAND"]
	elevation_min = 5.0
	elevation_max = 50.0

func distant_mesh() -> Mesh:
	# Dead trees from far = a thin vertical dash.
	var m := CylinderMesh.new()
	m.top_radius = 0.4
	m.bottom_radius = 0.5
	m.height = 4.5
	m.radial_segments = 5
	m.rings = 1
	return m

func distant_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.25, 0.2)
	mat.roughness = 0.9
	return mat

func distant_y_offset() -> float:
	return 2.3

func build_tree() -> Node3D:
	var t := Node3D.new()
	t.name = "dead_tree"

	t.add_child(TreeSpecies.make_trunk(Color(0.3, 0.25, 0.2), 0.4, 4.0))

	var branch_color := Color(0.35, 0.3, 0.25)
	var branches := [
		{"r": 0.2,  "l": 2.0, "y": 3.0, "rz": 45.0,  "ry": 0.0},
		{"r": 0.2,  "l": 1.5, "y": 3.5, "rz": -30.0, "ry": 90.0},
		{"r": 0.15, "l": 1.0, "y": 4.0, "rz": 20.0,  "ry": 180.0},
	]
	for b in branches:
		var branch := TreeSpecies.make_branch(branch_color, b.r, b.l)
		branch.position.y = b.y
		branch.rotation_degrees.z = b.rz
		branch.rotation_degrees.y = b.ry
		t.add_child(branch)

	t.add_child(TreeSpecies.make_collision(0.4, 5.0))
	return t
