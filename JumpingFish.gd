extends "res://Fish.gd"

class_name JumpingFish

# Jumping parameters
@export var jump_interval_min: float = 5.0  # Minimum time between jumps
@export var jump_interval_max: float = 20.0  # Maximum time between jumps
@export var jump_height: float = 3.0  # How high the fish jumps
@export var jump_distance: float = 2.0  # How far the fish jumps

var time_until_jump: float = 0.0
var is_jumping: bool = false
var jump_start_pos: Vector3
var jump_target_pos: Vector3
var jump_progress: float = 0.0
var jump_duration: float = 1.0

func _ready():
	fish_color = Color(0.7, 0.9, 0.3)
	fish_size = Vector3(0.45, 0.2, 0.1)
	swim_speed = 1.5

	super._ready()

	time_until_jump = randf_range(jump_interval_min, jump_interval_max)


func _physics_process(delta):
	if is_jumping:
		process_jump(delta)
	else:
		super._physics_process(delta)

		time_until_jump -= delta
		if time_until_jump <= 0 and water_system and global_position.y < water_system.water_level - 1.0:
			start_jump()


func process_jump(delta):
	jump_progress += delta / jump_duration

	if jump_progress >= 1.0:
		is_jumping = false
		time_until_jump = randf_range(jump_interval_min, jump_interval_max)

		velocity = Vector3.ZERO
	else:
		var t = jump_progress

		var horizontal_pos = jump_start_pos.lerp(jump_target_pos, t)

		var vertical_offset = jump_height * 4 * t * (1 - t)

		global_position = Vector3(horizontal_pos.x, horizontal_pos.y + vertical_offset, horizontal_pos.z)

		var angle = atan2(vertical_offset * (0.5 - t), 0.1)
		rotation.z = angle


func start_jump():
	is_jumping = true
	jump_progress = 0.0

	jump_start_pos = global_position

	var random_dir = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
	jump_target_pos = jump_start_pos + random_dir * jump_distance

	if water_system:
		jump_target_pos.y = water_system.water_level - randf_range(1.0, 3.0)

	create_splash(jump_start_pos)


func create_splash(splash_pos):
	var splash = GPUParticles3D.new()
	splash.name = "FishSplash"

	var particle_material = ParticleProcessMaterial.new()
	particle_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	particle_material.emission_sphere_radius = 0.2
	particle_material.direction = Vector3(0, 1, 0)
	particle_material.spread = 45.0
	particle_material.initial_velocity_min = 2.0
	particle_material.initial_velocity_max = 4.0
	particle_material.gravity = Vector3(0, -9.8, 0)
	particle_material.scale_min = 0.05
	particle_material.scale_max = 0.2
	particle_material.color = Color(0.7, 0.8, 1.0, 0.8)

	splash.process_material = particle_material

	var splash_mesh = SphereMesh.new()
	splash_mesh.radius = 0.03
	splash_mesh.height = 0.06

	splash.draw_pass_1 = splash_mesh
	splash.amount = 30
	splash.lifetime = 1.0
	splash.explosiveness = 0.8
	splash.one_shot = true

	var splash_position = splash_pos
	if water_system:
		splash_position.y = water_system.water_level

	splash.position = splash_position

	var scene_tree = get_tree()
	if scene_tree and scene_tree.current_scene:
		scene_tree.current_scene.add_child(splash)
	else:
		add_child(splash)

	splash.emitting = true

	var timer = Timer.new()
	timer.wait_time = 2.0
	timer.one_shot = true
	timer.timeout.connect(func():
		if is_instance_valid(splash):
			splash.queue_free()
	)
	splash.add_child(timer)
	timer.start()
