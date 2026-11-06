extends Node3D
## OriginBase — the deterministic "home" at world origin.
##
## Builds a runway slab + centerline markings and a small cabin
## procedurally. Sits inside the flat zone that World defines and
## TerrainGenerator flattens the terrain to match.
##
## Everything else in the world (biomes, trees, fish, weather…) stays
## random; only this one footprint is reproducible.

# Materials
var _mat_concrete: StandardMaterial3D
var _mat_stripe: StandardMaterial3D
var _mat_wall: StandardMaterial3D
var _mat_roof: StandardMaterial3D
var _mat_wood: StandardMaterial3D
var _mat_door: StandardMaterial3D
var _mat_window: StandardMaterial3D

func _ready() -> void:
	_init_materials()
	_build_runway()
	_build_cabin()

static func _mat(c: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = roughness
	m.metallic = metallic
	return m

func _init_materials() -> void:
	_mat_concrete = _mat(Color(0.55, 0.55, 0.53), 0.85, 0.0)
	_mat_stripe   = _mat(Color(0.95, 0.9, 0.3), 0.6, 0.0)
	_mat_wall     = _mat(Color(0.82, 0.68, 0.5), 0.8, 0.0)
	_mat_roof     = _mat(Color(0.45, 0.2, 0.15), 0.7, 0.0)
	_mat_wood     = _mat(Color(0.35, 0.22, 0.14), 0.8, 0.0)
	_mat_door     = _mat(Color(0.25, 0.15, 0.1), 0.7, 0.0)
	_mat_window = StandardMaterial3D.new()
	_mat_window.albedo_color = Color(0.5, 0.65, 0.78, 0.6)
	_mat_window.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_window.metallic = 0.3
	_mat_window.roughness = 0.1
	_mat_window.emission_enabled = true
	_mat_window.emission = Color(0.9, 0.85, 0.55)
	_mat_window.emission_energy_multiplier = 0.4

static func _box(size: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	return mi

static func _prism(size: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := PrismMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	return mi

static func _cyl(radius: float, height: float, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 10
	mi.mesh = mesh
	mi.material_override = mat
	return mi

# ---------------------------------------------------------------------
# Runway — flat concrete slab + centerline stripes + end-markers.
# Dimensions match the flat footprint World defines.
# ---------------------------------------------------------------------
func _build_runway() -> void:
	var length: float = World.BASE_HALF_LENGTH * 2.0 - 10.0   # 130m usable
	var width: float = World.BASE_HALF_WIDTH * 2.0 - 4.0      # 16m wide
	var slab_y: float = World.BASE_HEIGHT + 0.02              # sit just above the flattened terrain

	# Main slab
	var slab := _box(Vector3(width, 0.1, length), _mat_concrete)
	slab.name = "RunwaySlab"
	slab.position = Vector3(0, slab_y, 0)
	add_child(slab)

	# Centerline: dashed yellow stripes every 8 m
	var dash_len: float = 4.0
	var gap: float = 4.0
	var start_z: float = -length * 0.5 + dash_len
	var z: float = start_z
	var i: int = 0
	while z < length * 0.5 - dash_len:
		var dash := _box(Vector3(0.3, 0.02, dash_len), _mat_stripe)
		dash.name = "CenterDash_%d" % i
		dash.position = Vector3(0, slab_y + 0.06, z)
		add_child(dash)
		z += dash_len + gap
		i += 1

	# Threshold bars at each end
	for end_sign in [-1.0, 1.0]:
		var bar := _box(Vector3(width - 1.0, 0.02, 0.5), _mat_stripe)
		bar.name = "Threshold_%s" % ("S" if end_sign < 0.0 else "N")
		bar.position = Vector3(0, slab_y + 0.06, end_sign * (length * 0.5 - 1.0))
		add_child(bar)

	# Four corner cones to make the runway read as human-built
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var cone := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0
		cm.bottom_radius = 0.3
		cm.height = 0.7
		cm.radial_segments = 8
		cone.mesh = cm
		cone.material_override = _mat_stripe
		cone.position = Vector3(corner.x * (width * 0.5 + 0.5), slab_y + 0.35, corner.y * (length * 0.5))
		add_child(cone)

# ---------------------------------------------------------------------
# Cabin — small 5×3×5 m wooden house offset to the side of the runway.
# Pitched roof, door facing the runway, a window on the side.
# ---------------------------------------------------------------------
func _build_cabin() -> void:
	var base_y: float = World.BASE_HEIGHT
	var cabin_x: float = 15.0        # offset east of the runway
	var cabin_z: float = -5.0        # slightly south of center
	var w: float = 5.0
	var h: float = 2.8
	var d: float = 4.0
	var wall_t: float = 0.15

	var cabin := Node3D.new()
	cabin.name = "Cabin"
	cabin.position = Vector3(cabin_x, base_y, cabin_z)
	add_child(cabin)

	# Floor
	var floor_mesh := _box(Vector3(w, 0.2, d), _mat_wood)
	floor_mesh.name = "Floor"
	floor_mesh.position = Vector3(0, 0.1, 0)
	cabin.add_child(floor_mesh)

	# Walls: left, right, back (far from runway), front with door cutout.
	var left_wall := _box(Vector3(wall_t, h, d), _mat_wall)
	left_wall.position = Vector3(-w * 0.5, h * 0.5 + 0.2, 0)
	cabin.add_child(left_wall)

	var right_wall := _box(Vector3(wall_t, h, d), _mat_wall)
	right_wall.position = Vector3(w * 0.5, h * 0.5 + 0.2, 0)
	cabin.add_child(right_wall)

	var back_wall := _box(Vector3(w, h, wall_t), _mat_wall)
	back_wall.position = Vector3(0, h * 0.5 + 0.2, d * 0.5)
	cabin.add_child(back_wall)

	# Front wall split around a 1.2×2.0 door opening (centered)
	var door_w: float = 1.2
	var door_h: float = 2.0
	var side_w: float = (w - door_w) * 0.5

	var front_left := _box(Vector3(side_w, h, wall_t), _mat_wall)
	front_left.position = Vector3(-(w * 0.5 - side_w * 0.5), h * 0.5 + 0.2, -d * 0.5)
	cabin.add_child(front_left)

	var front_right := _box(Vector3(side_w, h, wall_t), _mat_wall)
	front_right.position = Vector3(w * 0.5 - side_w * 0.5, h * 0.5 + 0.2, -d * 0.5)
	cabin.add_child(front_right)

	var front_top := _box(Vector3(door_w, h - door_h, wall_t), _mat_wall)
	front_top.position = Vector3(0, door_h + (h - door_h) * 0.5 + 0.2, -d * 0.5)
	cabin.add_child(front_top)

	# Door (slightly recessed so it reads)
	var door := _box(Vector3(door_w - 0.05, door_h, 0.05), _mat_door)
	door.position = Vector3(0, door_h * 0.5 + 0.2, -d * 0.5 - 0.02)
	cabin.add_child(door)

	# Window on left wall — emissive so a lit house stands out at night.
	var window := _box(Vector3(0.05, 0.8, 1.2), _mat_window)
	window.position = Vector3(-w * 0.5 - 0.02, 1.4, 0)
	cabin.add_child(window)

	# Pitched roof — two prism halves meeting at the ridge.
	var roof_overhang: float = 0.3
	var roof_w: float = w + roof_overhang * 2.0
	var roof_d: float = d + roof_overhang * 2.0
	var roof_h: float = 1.4

	# PrismMesh in Godot: size = (width, height, depth); apex sits at top.
	# One prism sliced in half would be ideal but two tilted boxes work too.
	# Use two rotated boxes forming the pitched roof slopes.
	var slope_len: float = sqrt(pow(roof_w * 0.5, 2) + pow(roof_h, 2))
	var slope_angle: float = atan2(roof_h, roof_w * 0.5)

	for side in [-1.0, 1.0]:
		var slope := _box(Vector3(slope_len, 0.15, roof_d), _mat_roof)
		slope.position = Vector3(side * (roof_w * 0.25), h + 0.2 + roof_h * 0.5, 0)
		slope.rotation.z = -side * slope_angle
		cabin.add_child(slope)

	# Gable triangles (front + back) to close the roof peak
	for z_side in [-1.0, 1.0]:
		var gable := _prism(Vector3(roof_w, roof_h, 0.1), _mat_wall)
		gable.position = Vector3(0, h + 0.2 + roof_h * 0.5, z_side * (d * 0.5 + 0.05))
		cabin.add_child(gable)

	# Little chimney for character
	var chimney := _box(Vector3(0.5, 1.2, 0.5), _mat_wall)
	chimney.position = Vector3(w * 0.25, h + 0.2 + roof_h + 0.3, d * 0.2)
	cabin.add_child(chimney)
