extends Node3D
## OriginBase — the deterministic "home" at world origin.
##
## Builds a runway slab + centerline markings and Uiop's cabin procedurally.
## Sits inside the flat zone that World defines and TerrainGenerator flattens
## the terrain to match.
##
## Everything else in the world (biomes, trees, fish, weather…) stays
## random; only this one footprint is reproducible.

# Cabin dimensions, shared with anything that needs to know where the floor
# is (TerrainGenerator spawns Uiop inside).
const CABIN_X: float = 15.0          # offset east of the runway
const CABIN_Z: float = -5.0          # slightly south of centre
const CABIN_W: float = 5.0
const CABIN_D: float = 4.0
const CABIN_H: float = 2.8           # wall height above the floor
const FLOOR_T: float = 0.2
const WALL_T: float = 0.15
const DOOR_W: float = 1.2
const DOOR_H: float = 2.0
const ROOF_H: float = 1.4
const ROOF_OVERHANG: float = 0.3

# Materials
var _mat_concrete: StandardMaterial3D
var _mat_stripe: StandardMaterial3D
var _mat_wall: StandardMaterial3D
var _mat_roof: StandardMaterial3D
var _mat_wood: StandardMaterial3D
var _mat_window: StandardMaterial3D

func _ready() -> void:
	_init_materials()
	_build_runway()
	_build_cabin()

# Height of the cabin floor's top surface. Uiop spawns on this.
static func cabin_floor_top() -> float:
	return World.BASE_HEIGHT + FLOOR_T

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

# A visible box with a matching box collider. Walls, floor and roof all go
# through this so they can't drift apart from their collision.
static func _solid_box(size: Vector3, pos: Vector3, mat: StandardMaterial3D, rot: Vector3 = Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation = rot
	body.add_child(_box(size, mat))
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	return body

# A gable triangle with a matching convex collider (a box would leave the
# peak floating in air).
static func _solid_gable(width: float, height: float, pos: Vector3, mat: StandardMaterial3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.add_child(_prism(Vector3(width, height, WALL_T), mat))
	var hw: float = width * 0.5
	var hh: float = height * 0.5
	var ht: float = WALL_T * 0.5
	var shape := ConvexPolygonShape3D.new()
	shape.points = PackedVector3Array([
		Vector3(-hw, -hh, -ht), Vector3(hw, -hh, -ht), Vector3(0.0, hh, -ht),
		Vector3(-hw, -hh, ht), Vector3(hw, -hh, ht), Vector3(0.0, hh, ht),
	])
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	return body

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
	var width: float = 16.0                                   # runway width; the flat footprint is wider, so the cabin sits clear of it
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
# Cabin — Uiop's house. Sits on the flattened ground at base height with a
# foundation sunk below it, so it can't float or show gaps. Every wall, the
# floor and the roof have collision. The only opening is the doorway in the
# front wall, which faces -Z (toward the player's spawn).
# ---------------------------------------------------------------------
func _build_cabin() -> void:
	var w: float = CABIN_W
	var h: float = CABIN_H
	var d: float = CABIN_D
	var f: float = FLOOR_T

	var cabin := Node3D.new()
	cabin.name = "Cabin"
	cabin.position = Vector3(CABIN_X, World.BASE_HEIGHT, CABIN_Z)
	add_child(cabin)

	# Foundation: sunk well below the floor so the house never hovers.
	var foundation := _solid_box(Vector3(w, 1.5, d), Vector3(0, -0.75, 0), _mat_concrete)
	foundation.name = "Foundation"
	cabin.add_child(foundation)

	# Floor — top surface at FLOOR_T above the cabin origin.
	var floor_body := _solid_box(Vector3(w, f, d), Vector3(0, f * 0.5, 0), _mat_wood)
	floor_body.name = "Floor"
	cabin.add_child(floor_body)

	var wall_mid: float = h * 0.5 + f

	# Left, right and back walls: solid.
	var left_wall := _solid_box(Vector3(WALL_T, h, d), Vector3(-w * 0.5, wall_mid, 0), _mat_wall)
	left_wall.name = "LeftWall"
	cabin.add_child(left_wall)

	var right_wall := _solid_box(Vector3(WALL_T, h, d), Vector3(w * 0.5, wall_mid, 0), _mat_wall)
	right_wall.name = "RightWall"
	cabin.add_child(right_wall)

	var back_wall := _solid_box(Vector3(w, h, WALL_T), Vector3(0, wall_mid, d * 0.5), _mat_wall)
	back_wall.name = "BackWall"
	cabin.add_child(back_wall)

	# Front wall: two side pieces and a lintel over the doorway. Nothing
	# between them, so the doorway is open.
	var side_w: float = (w - DOOR_W) * 0.5

	var front_left := _solid_box(Vector3(side_w, h, WALL_T), Vector3(-(w * 0.5 - side_w * 0.5), wall_mid, -d * 0.5), _mat_wall)
	front_left.name = "FrontLeft"
	cabin.add_child(front_left)

	var front_right := _solid_box(Vector3(side_w, h, WALL_T), Vector3(w * 0.5 - side_w * 0.5, wall_mid, -d * 0.5), _mat_wall)
	front_right.name = "FrontRight"
	cabin.add_child(front_right)

	var lintel_h: float = h - DOOR_H
	var front_top := _solid_box(Vector3(DOOR_W, lintel_h, WALL_T), Vector3(0, DOOR_H + lintel_h * 0.5 + f, -d * 0.5), _mat_wall)
	front_top.name = "Lintel"
	cabin.add_child(front_top)

	# Window on the left wall. Emissive so a lit house stands out at night.
	# It sits inside the wall's thickness, so the wall keeps its collision.
	var window := _box(Vector3(0.05, 0.8, 1.2), _mat_window)
	window.position = Vector3(-w * 0.5 - 0.02, 1.4, 0)
	cabin.add_child(window)

	# Pitched roof — two solid slopes meeting at the ridge.
	var roof_w: float = w + ROOF_OVERHANG * 2.0
	var roof_d: float = d + ROOF_OVERHANG * 2.0
	var slope_len: float = sqrt(pow(roof_w * 0.5, 2) + pow(ROOF_H, 2))
	var slope_angle: float = atan2(ROOF_H, roof_w * 0.5)
	var roof_y: float = h + f + ROOF_H * 0.5

	for side in [-1.0, 1.0]:
		var slope := _solid_box(Vector3(slope_len, 0.15, roof_d),
			Vector3(side * (roof_w * 0.25), roof_y, 0),
			_mat_roof,
			Vector3(0, 0, -side * slope_angle))
		slope.name = "RoofSlope_%s" % ("L" if side < 0.0 else "R")
		cabin.add_child(slope)

	# Gable triangles close the roof at the front and back.
	for z_side in [-1.0, 1.0]:
		var gable := _solid_gable(roof_w, ROOF_H, Vector3(0, roof_y, z_side * (d * 0.5 + 0.05)), _mat_wall)
		gable.name = "Gable_%s" % ("Front" if z_side < 0.0 else "Back")
		cabin.add_child(gable)

	# Chimney.
	var chimney := _solid_box(Vector3(0.5, 1.2, 0.5), Vector3(w * 0.25, h + f + ROOF_H + 0.3, d * 0.2), _mat_wall)
	chimney.name = "Chimney"
	cabin.add_child(chimney)
