extends RefCounted
## Loaded by file path via preload — no class_name, so this works even
## when subfolder scripts parse after root-level ones.
## Base class for tree species. Each species is its own .gd file in
## res://trees/, extends this, and overrides build_tree(). TreeSystem
## auto-discovers every .gd in the directory on startup and uses each
## species' biomes + elevation range to decide where to place it.
##
## Drop a new TreeSpecies subclass in the folder and it starts spawning.

var species_name: String = "generic"
var biomes: Array[String] = []            # biome names from TerrainGenerator.BiomeType
var elevation_min: float = 0.0            # inclusive, in world units
var elevation_max: float = 100.0          # inclusive

# Static material cache — every tree that previously allocated its own
# StandardMaterial3D with (color, roughness) now shares one. With ~100
# trees per chunk × 2-3 materials each, this cuts thousands of material
# instances across the world down to a few dozen.
static var _MAT_CACHE: Dictionary = {}

static func _cached_mat(color: Color, roughness: float) -> StandardMaterial3D:
	var key: String = "%s|%.2f" % [color.to_html(), roughness]
	if _MAT_CACHE.has(key):
		return _MAT_CACHE[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	_MAT_CACHE[key] = mat
	return mat

func build_tree() -> Node3D:
	push_error("TreeSpecies.build_tree() must be overridden by %s" % species_name)
	return null

func accepts(biome_name: String, elevation: float) -> bool:
	if biomes.size() > 0 and not biomes.has(biome_name):
		return false
	return elevation >= elevation_min and elevation <= elevation_max

# ---------------------------------------------------------------------
# Distant representation. Beyond the near-detail ring we draw trees as
# a single batched impostor (one MultiMeshInstance3D per species per
# chunk, no sub-meshes, no collision). Each species declares the mesh
# and material for its impostor plus a Y offset so the mesh sits on
# the ground rather than through it.
#
# Default: a small green sphere. Override per species for better shape.
# ---------------------------------------------------------------------
func distant_mesh() -> Mesh:
	var m := SphereMesh.new()
	m.radius = 2.0
	m.height = 4.0
	m.radial_segments = 6
	m.rings = 3
	return m

func distant_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.5, 0.2)
	mat.roughness = 0.9
	return mat

func distant_y_offset() -> float:
	# Height to add to the ground point so the distant mesh's center
	# lands at roughly tree-canopy height.
	return 3.0

# ---------------------------------------------------------------------
# Static mesh helpers — shared across species so each species file stays
# short and declarative. Everything returns a bare Node ready to add as
# a child.
# ---------------------------------------------------------------------
static func make_trunk(color: Color, radius: float, height: float) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.top_radius = radius * 0.8
	m.bottom_radius = radius
	m.height = height
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = _cached_mat(color, 0.9)
	return mi

static func make_curved_trunk(color: Color, radius: float, height: float) -> MeshInstance3D:
	var mi := make_trunk(color, radius, height)
	mi.rotation_degrees.x = -15.0
	return mi

static func make_branch(color: Color, radius: float, length: float) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.top_radius = radius * 0.5
	m.bottom_radius = radius
	m.height = length
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = _cached_mat(color, 0.9)
	mi.rotation_degrees.x = 90.0
	mi.position.z = length * 0.5
	return mi

static func make_cone_foliage(color: Color, radius: float, height: float) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.top_radius = 0.0
	m.bottom_radius = radius
	m.height = height
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = _cached_mat(color, 0.7)
	return mi

static func make_sphere_foliage(color: Color, radius: float) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = _cached_mat(color, 0.7)
	return mi

static func make_palm_frond(color: Color) -> MeshInstance3D:
	var m := PrismMesh.new()
	m.size = Vector3(2.0, 0.1, 0.5)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = _cached_mat(color, 0.6)
	mi.position.z = 1.0
	return mi

static func make_collision(radius: float, height: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "TreeCollision"
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = radius
	cap.height = height
	cs.shape = cap
	cs.position.y = height * 0.5
	body.add_child(cs)
	return body
