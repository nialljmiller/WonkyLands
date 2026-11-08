extends Node3D
## Tiny world-state holder for Merl's food (berries). Spawns a handful
## of berry nodes inside Merl's home area at startup; when Merl eats
## one it respawns after a cooldown at a new random spot.
##
## Berries are StaticBody3D so Perception can pick them up as part of
## future object queries (or by tree walk). For now MerlController's
## perception reaches into this node's `active_food` array directly,
## which is the simplest coupling.

@export var count: int = 6
@export var home_center: Vector3 = Vector3.ZERO
@export var home_radius: float = 150.0
@export var respawn_seconds: float = 45.0

# Public: list of currently-spawned food nodes.
var active_food: Array[Node3D] = []

var _respawn_queue: Array = []   # Array of {timer: float}
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _terrain: Node = null

func _ready() -> void:
	_rng.randomize()
	_terrain = _find_terrain()
	for i in range(count):
		_spawn_berry_at(_pick_position())

func _process(delta: float) -> void:
	for i in range(_respawn_queue.size() - 1, -1, -1):
		_respawn_queue[i].timer -= delta
		if _respawn_queue[i].timer <= 0.0:
			_respawn_queue.remove_at(i)
			_spawn_berry_at(_pick_position())

# Called by Merl when he eats a berry. Removes from world and schedules
# a respawn.
func consume(berry: Node3D) -> void:
	if berry == null or not is_instance_valid(berry):
		return
	active_food.erase(berry)
	berry.queue_free()
	_respawn_queue.append({"timer": respawn_seconds})

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
func _pick_position() -> Vector3:
	# Uniform in disc, with a mild bias away from the centre (base) so
	# berries don't all land on the runway.
	var r: float = home_radius * (0.25 + 0.7 * _rng.randf())
	var a: float = _rng.randf() * TAU
	var p: Vector3 = home_center + Vector3(cos(a) * r, 0.0, sin(a) * r)
	if _terrain != null:
		p.y = _terrain.get_terrain_height(p.x, p.z) + 0.08
	return p

func _spawn_berry_at(pos: Vector3) -> void:
	var berry := _build_berry_mesh()
	berry.position = pos
	add_child(berry)
	active_food.append(berry)

static func _build_berry_mesh() -> Node3D:
	var root := Node3D.new()
	root.name = "Berry"
	# Stem
	var stem := MeshInstance3D.new()
	var stem_mesh := CylinderMesh.new()
	stem_mesh.top_radius = 0.006
	stem_mesh.bottom_radius = 0.01
	stem_mesh.height = 0.08
	stem_mesh.radial_segments = 5
	stem.mesh = stem_mesh
	var stem_mat := StandardMaterial3D.new()
	stem_mat.albedo_color = Color(0.25, 0.4, 0.15)
	stem_mat.roughness = 0.9
	stem.material_override = stem_mat
	stem.position.y = 0.04
	root.add_child(stem)
	# Berry
	var berry := MeshInstance3D.new()
	var berry_mesh := SphereMesh.new()
	berry_mesh.radius = 0.035
	berry_mesh.height = 0.07
	berry_mesh.radial_segments = 8
	berry_mesh.rings = 4
	berry.mesh = berry_mesh
	var berry_mat := StandardMaterial3D.new()
	berry_mat.albedo_color = Color(0.75, 0.15, 0.2)
	berry_mat.roughness = 0.3
	berry_mat.metallic = 0.2
	berry.material_override = berry_mat
	berry.position.y = 0.11
	root.add_child(berry)
	return root

func _find_terrain() -> Node:
	var n: Node = get_parent()
	while n != null:
		if n.has_method("get_terrain_height"):
			return n
		n = n.get_parent()
	return null
