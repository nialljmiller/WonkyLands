extends CharacterBody3D
## Uiop — a low-poly procedural opossum that roams the permanent chunks
## around the base. Brain is pluggable (see UiopBrain.gd); this file
## just does physics, animation, and visual construction.

const UiopBrain = preload("res://agents/UiopBrain.gd")
const Perception = preload("res://agents/Perception.gd")
const Memory = preload("res://agents/Memory.gd")
const Needs = preload("res://agents/Needs.gd")

@export var home_center: Vector3 = Vector3.ZERO
@export var home_radius: float = 180.0
@export var walk_speed: float = 2.4
@export var turn_rate_deg_per_s: float = 180.0
@export var gravity: float = 24.0
@export var perception_scan_interval: float = 0.4   # seconds between full sense scans
@export var body_scale: float = 1.6                # how big he is; scales the visuals and collider
@export var snap_to_ground_on_ready: bool = true    # off when the spawner places him somewhere specific (his house)
@export var catch_reach: float = 2.5                # horizontal reach from the shore to snag a fish
@export var hunt_sight: float = 30.0                # how far he can pick out a fish to chase
@export var catch_chance: float = 0.5               # chance each attempt lands
@export var catch_attempt_interval: float = 1.0     # seconds between attempts

# Internal
var _brain: Variant = null
var _perception: Variant = null
var _memory: Variant = null
var _needs: Variant = null
var _perception_timer: float = 0.0
var _target_pos: Vector3 = Vector3.ZERO
var _speed_mul: float = 0.0
var _sniffing: bool = false
var _state_name: String = "spawning"
var _wiggle_phase: float = 0.0
var _catch_cooldown: float = 0.0

# Visual node refs
var _tail_pivot: Node3D = null
var _head_pivot: Node3D = null

@onready var _terrain = _find_terrain()

func _ready() -> void:
	_perception = Perception.new()
	_memory = Memory.new()
	_needs = Needs.new()
	_brain = UiopBrain.new()
	_brain.home_center = home_center
	_brain.home_radius = home_radius
	_brain.memory = _memory
	_brain.needs = _needs
	if typeof(World) != TYPE_NIL:
		World.time_changed.connect(func(_hours: float, day: int): _brain.set_day(day))
	add_to_group("uiop")
	_init_materials()
	_build_visuals()
	# Ground the spawn position via terrain query if available
	if snap_to_ground_on_ready:
		global_position = _snap_to_ground(global_position)

func _physics_process(delta: float) -> void:
	var player_pos: Vector3 = Vector3.INF * Vector3.ONE
	if typeof(World) != TYPE_NIL:
		var p: Node3D = World.get_player()
		if p != null:
			player_pos = p.global_position

	# Perception: scan at a fixed cadence (expensive); memory decays
	# continuously so the brain sees staleness properly.
	_perception_timer -= delta
	var new_percepts: Array = []
	if _perception_timer <= 0.0:
		_perception_timer = perception_scan_interval
		new_percepts = _perception.scan(global_position, -transform.basis.z, _scene_root())
	_memory.update(delta, new_percepts)

	# Needs decay — movement factor from previous tick's speed
	var movement_factor: float = clamp(Vector2(velocity.x, velocity.z).length() / walk_speed, 0.0, 1.0)
	_needs.tick(delta, movement_factor)

	_brain.water_level = World.get_water_level() if typeof(World) != TYPE_NIL else -1e9
	_update_hunt_target()
	var intent: Dictionary = _brain.tick(global_position, player_pos, delta,
		Callable(self, "_ground_y_at"))

	# Cross-boundary interactions: eating, sleeping and fishing need world/needs
	# access that the brain itself can't do.
	_handle_eating(delta)
	_handle_napping(delta)
	_handle_fishing(delta)
	_target_pos = intent.target
	_speed_mul = intent.speed_mul
	_sniffing = intent.sniff
	_state_name = intent.state_name

	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = -0.5  # keeps is_on_floor() stable on slopes

	# Horizontal movement toward target
	var horizontal_target := Vector3(_target_pos.x, global_position.y, _target_pos.z)
	var to_target := horizontal_target - global_position
	to_target.y = 0.0
	var dist := to_target.length()

	if _speed_mul > 0.0 and dist > 0.2:
		# Face the target smoothly
		var desired_yaw := atan2(-to_target.x, -to_target.z)
		var current_yaw := rotation.y
		var yaw_diff := wrapf(desired_yaw - current_yaw, -PI, PI)
		var max_step := deg_to_rad(turn_rate_deg_per_s) * delta
		var yaw_step: float = clamp(yaw_diff, -max_step, max_step)
		rotation.y = current_yaw + yaw_step

		# Only move if roughly facing the target
		if absf(yaw_diff) < deg_to_rad(40.0):
			var fwd := -transform.basis.z
			var h := fwd * (walk_speed * _speed_mul)
			velocity.x = h.x
			velocity.z = h.z
		else:
			velocity.x = 0.0
			velocity.z = 0.0
	else:
		velocity.x *= 0.5
		velocity.z *= 0.5

	move_and_slide()
	_animate(delta)

# ---------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------
func _animate(delta: float) -> void:
	# Tail sway, scaled by movement speed. When sniffing, head bobs
	# instead.
	var moving: float = clamp(Vector2(velocity.x, velocity.z).length() / walk_speed, 0.0, 1.0)
	_wiggle_phase += delta * (3.0 + 6.0 * moving) * TAU
	if _tail_pivot != null:
		_tail_pivot.rotation.y = sin(_wiggle_phase) * deg_to_rad(18.0 + 20.0 * moving)
	if _head_pivot != null:
		var head_target := 0.0
		if _sniffing:
			head_target = sin(_wiggle_phase * 1.5) * deg_to_rad(12.0)
		_head_pivot.rotation.x = lerp(_head_pivot.rotation.x, head_target, delta * 4.0)

# ---------------------------------------------------------------------
# Terrain helpers
# ---------------------------------------------------------------------
func _find_terrain() -> Node:
	# Walk up the tree looking for TerrainGenerator.
	var n: Node = get_parent()
	while n != null:
		if n.has_method("get_terrain_height"):
			return n
		n = n.get_parent()
	return null

func _scene_root() -> Node:
	# Perception needs access to peer scene nodes (BushPlane, TreeSystem,
	# OriginBase). They all live under TerrainGenerator — use that as
	# the "root" for lookups.
	return _terrain if _terrain != null else get_tree().current_scene

# ---------------------------------------------------------------------
# Needs-driven interactions
# ---------------------------------------------------------------------
func _handle_eating(_delta: float) -> void:
	# If brain says EATING, find the closest active berry we remember
	# and, if we're close enough, consume it.
	if _brain._state != UiopBrain.State.EATING:
		return
	var spawner = _scene_root().get_node_or_null("FoodSpawner")
	if spawner == null or not "active_food" in spawner:
		return
	# Nearest berry within sight
	var nearest: Node3D = null
	var best_dist: float = 1e9
	for b in spawner.active_food:
		if b == null or not is_instance_valid(b):
			continue
		var d: float = global_position.distance_to(b.global_position)
		if d < best_dist:
			best_dist = d
			nearest = b
	if nearest == null:
		return
	# Steer the brain's target to this berry
	_brain._food_target = nearest
	if best_dist < _brain.eat_distance:
		spawner.consume(nearest)
		_needs.eat()
		_brain.on_eat_consumed()

func _handle_napping(delta: float) -> void:
	if _brain._state != UiopBrain.State.NAPPING:
		return
	if _brain.is_napping_at_spot(global_position):
		_needs.sleep(delta)

func _handle_fishing(delta: float) -> void:
	# The brain steers him to the shore. Here we check whether a fish is
	# within reach of where he's standing and, if so, try to catch it.
	_catch_cooldown = maxf(_catch_cooldown - delta, 0.0)
	if not _brain.is_hunting_fish() or _catch_cooldown > 0.0:
		return
	var fish_system = _fish_system()
	if fish_system == null:
		return
	var nearest: CharacterBody3D = null
	var best_dist: float = catch_reach
	for fish in fish_system.active_fish:
		if fish == null or not is_instance_valid(fish):
			continue
		# Only fish under the surface are catchable.
		if fish.global_position.y > _brain.water_level:
			continue
		var d: float = Vector2(fish.global_position.x - global_position.x, fish.global_position.z - global_position.z).length()
		if d < best_dist:
			best_dist = d
			nearest = fish
	if nearest == null:
		return
	_catch_cooldown = catch_attempt_interval
	if randf() < catch_chance:
		_memory.forget("fish_%d" % nearest.get_instance_id())
		fish_system.catch_fish(nearest)
		_brain.on_fish_caught()

func _update_hunt_target() -> void:
	# Track the nearest underwater fish from its live position, so the chase
	# follows the fish as it swims.
	_brain.has_hunt_target = false
	var fish_system = _fish_system()
	if fish_system == null:
		return
	var best: float = hunt_sight
	for fish in fish_system.active_fish:
		if fish == null or not is_instance_valid(fish) or fish.global_position.y > _brain.water_level:
			continue
		var d: float = Vector2(fish.global_position.x - global_position.x, fish.global_position.z - global_position.z).length()
		if d < best:
			best = d
			_brain.has_hunt_target = true
			_brain.hunt_target_pos = fish.global_position

func _fish_system():
	if typeof(World) == TYPE_NIL:
		return null
	var water = World.get_water_system()
	if water == null or not "fish_system" in water:
		return null
	return water.fish_system

func _ground_y_at(x: float, z: float) -> float:
	if _terrain != null:
		return _terrain.get_terrain_height(x, z)
	return 0.0

func _snap_to_ground(p: Vector3) -> Vector3:
	var g: float = _ground_y_at(p.x, p.z)
	return Vector3(p.x, g + 0.2, p.z)

# ---------------------------------------------------------------------
# Procedural visuals — opossum silhouette: low-slung body, pointed
# head, bare long tail, stubby legs, ears, dark eyes.
# ---------------------------------------------------------------------
var _mat_fur: StandardMaterial3D
var _mat_belly: StandardMaterial3D
var _mat_snout: StandardMaterial3D
var _mat_tail: StandardMaterial3D
var _mat_eye: StandardMaterial3D
var _mat_ear: StandardMaterial3D
var _mat_paw: StandardMaterial3D

func _init_materials() -> void:
	_mat_fur = _m(Color(0.62, 0.6, 0.58), 0.9, 0.0)
	_mat_belly = _m(Color(0.82, 0.78, 0.72), 0.95, 0.0)
	_mat_snout = _m(Color(0.88, 0.75, 0.72), 0.9, 0.0)
	_mat_tail = _m(Color(0.78, 0.65, 0.6), 0.9, 0.0)
	_mat_eye = _m(Color(0.04, 0.04, 0.06), 0.3, 0.6)
	_mat_ear = _m(Color(0.52, 0.42, 0.42), 0.9, 0.0)
	_mat_paw = _m(Color(0.25, 0.22, 0.2), 0.95, 0.0)

static func _m(c: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.roughness = roughness
	mat.metallic = metallic
	return mat

func _build_visuals() -> void:
	# Convention: Uiop faces -Z. Body is roughly 40cm long, 16cm wide,
	# 14cm tall; tail adds another 40cm.
	var rig := Node3D.new()
	rig.name = "OpossumRig"
	rig.scale = Vector3.ONE * body_scale
	add_child(rig)

	# ---- Body (capsule along Z) ----
	var body := MeshInstance3D.new()
	var body_mesh := CapsuleMesh.new()
	body_mesh.radius = 0.09
	body_mesh.height = 0.42  # total length including hemispherical caps
	body_mesh.radial_segments = 12
	body_mesh.rings = 4
	body.mesh = body_mesh
	body.material_override = _mat_fur
	body.rotation.x = PI * 0.5   # lay capsule along Z
	body.position = Vector3(0, 0.12, 0)
	rig.add_child(body)

	# ---- Belly (lighter underside — flat prism) ----
	var belly := MeshInstance3D.new()
	var belly_mesh := BoxMesh.new()
	belly_mesh.size = Vector3(0.14, 0.03, 0.36)
	belly.mesh = belly_mesh
	belly.material_override = _mat_belly
	belly.position = Vector3(0, 0.06, 0)
	rig.add_child(belly)

	# ---- Head (pivot node + cone + snout) ----
	_head_pivot = Node3D.new()
	_head_pivot.name = "HeadPivot"
	_head_pivot.position = Vector3(0, 0.14, -0.22)
	rig.add_child(_head_pivot)

	var head := MeshInstance3D.new()
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.07
	head_mesh.height = 0.14
	head_mesh.radial_segments = 10
	head_mesh.rings = 6
	head.mesh = head_mesh
	head.material_override = _mat_fur
	head.scale = Vector3(1.0, 0.95, 1.4)
	_head_pivot.add_child(head)

	# Snout cone
	var snout := MeshInstance3D.new()
	var snout_mesh := CylinderMesh.new()
	snout_mesh.top_radius = 0.01
	snout_mesh.bottom_radius = 0.05
	snout_mesh.height = 0.10
	snout_mesh.radial_segments = 8
	snout.mesh = snout_mesh
	snout.material_override = _mat_snout
	snout.rotation.x = PI * 0.5
	snout.position = Vector3(0, -0.01, -0.10)
	_head_pivot.add_child(snout)

	# Nose tip (small dark sphere)
	var nose := MeshInstance3D.new()
	var nose_mesh := SphereMesh.new()
	nose_mesh.radius = 0.014
	nose_mesh.height = 0.028
	nose_mesh.radial_segments = 6
	nose_mesh.rings = 3
	nose.mesh = nose_mesh
	nose.material_override = _mat_eye
	nose.position = Vector3(0, -0.015, -0.17)
	_head_pivot.add_child(nose)

	# Ears
	for side in [-1.0, 1.0]:
		var ear := MeshInstance3D.new()
		var ear_mesh := SphereMesh.new()
		ear_mesh.radius = 0.035
		ear_mesh.height = 0.06
		ear_mesh.radial_segments = 6
		ear_mesh.rings = 3
		ear.mesh = ear_mesh
		ear.material_override = _mat_ear
		ear.scale = Vector3(0.6, 1.0, 1.0)
		ear.position = Vector3(side * 0.05, 0.065, -0.03)
		_head_pivot.add_child(ear)

	# Eyes — small dark beads
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = 0.012
		eye_mesh.height = 0.024
		eye_mesh.radial_segments = 6
		eye_mesh.rings = 3
		eye.mesh = eye_mesh
		eye.material_override = _mat_eye
		eye.position = Vector3(side * 0.045, 0.02, -0.08)
		_head_pivot.add_child(eye)

	# ---- Legs: 4 short stubby cylinders ----
	var leg_r := 0.025
	var leg_h := 0.14
	for leg in [
		{"x": -0.065, "z": -0.11},  # front left
		{"x":  0.065, "z": -0.11},  # front right
		{"x": -0.065, "z":  0.11},  # back left
		{"x":  0.065, "z":  0.11},  # back right
	]:
		var limb := MeshInstance3D.new()
		var limb_mesh := CylinderMesh.new()
		limb_mesh.top_radius = leg_r * 0.8
		limb_mesh.bottom_radius = leg_r
		limb_mesh.height = leg_h
		limb_mesh.radial_segments = 6
		limb.mesh = limb_mesh
		limb.material_override = _mat_fur
		limb.position = Vector3(leg.x, leg_h * 0.5, leg.z)
		rig.add_child(limb)

		# Paw at the bottom
		var paw := MeshInstance3D.new()
		var paw_mesh := SphereMesh.new()
		paw_mesh.radius = leg_r * 1.1
		paw_mesh.height = leg_r * 1.6
		paw_mesh.radial_segments = 6
		paw_mesh.rings = 3
		paw.mesh = paw_mesh
		paw.material_override = _mat_paw
		paw.position = Vector3(leg.x, 0.005, leg.z)
		rig.add_child(paw)

	# ---- Tail: pivot + long thin cylinder ----
	_tail_pivot = Node3D.new()
	_tail_pivot.name = "TailPivot"
	_tail_pivot.position = Vector3(0, 0.12, 0.18)
	rig.add_child(_tail_pivot)

	var tail := MeshInstance3D.new()
	var tail_mesh := CylinderMesh.new()
	tail_mesh.top_radius = 0.008
	tail_mesh.bottom_radius = 0.03
	tail_mesh.height = 0.40
	tail_mesh.radial_segments = 6
	tail.mesh = tail_mesh
	tail.material_override = _mat_tail
	# Lie horizontal, extending backward
	tail.rotation.x = PI * 0.5
	tail.position = Vector3(0, 0.0, 0.20)
	_tail_pivot.add_child(tail)

	# ---- Collision shape (capsule roughly matching body) ----
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.11 * body_scale
	cap.height = 0.5 * body_scale
	cs.shape = cap
	cs.rotation.x = PI * 0.5
	cs.position = Vector3(0, 0.14 * body_scale, 0)
	add_child(cs)
