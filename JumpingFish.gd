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
	# Call parent ready function
	super._ready()
	
	# Jumping fish specific settings
	fish_color = Color(0.7, 0.9, 0.3)
	fish_size = Vector3(0.45, 0.2, 0.1)
	swim_speed = 1.5
	
	# Set initial jump timer
	time_until_jump = randf_range(jump_interval_min, jump_interval_max)
	
	# Create mesh with these settings
	create_fish_mesh()

func _physics_process(delta):
	if is_jumping:
		# Handle jump movement
		process_jump(delta)
	else:
		# Use normal fish behavior
		super._physics_process(delta)
		
		# Decrease jump timer
		time_until_jump -= delta
		if time_until_jump <= 0 and global_position.y < water_system.water_level - 1.0:
			start_jump()

func process_jump(delta):
	# Update jump progress
	jump_progress += delta / jump_duration
	
	if jump_progress >= 1.0:
		# Jump completed
		is_jumping = false
		time_until_jump = randf_range(jump_interval_min, jump_interval_max)
		
		# Reset physics velocity
		velocity = Vector3.ZERO
	else:
		# Calculate jump arc
		var t = jump_progress
		
		# Horizontal movement (linear)
		var horizontal_pos = jump_start_pos.lerp(jump_target_pos, t)
		
		# Vertical movement (parabolic)
		var vertical_offset = jump_height * 4 * t * (1 - t)  # Parabola with max at t=0.5
		
		# Combine for final position
		global_position = Vector3(horizontal_pos.x, horizontal_pos.y + vertical_offset, horizontal_pos.z)
		
		# Rotate fish to follow jump arc
		var angle = atan2(vertical_offset * (0.5 - t), 0.1)  # Gives upward/downward angle
		rotation.z = angle

func start_jump():
	is_jumping = true
	jump_progress = 0.0
	
	# Store current position as jump start
	jump_start_pos = global_position
	
	# Calculate random target within jump distance
	var random_dir = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
	jump_target_pos = jump_start_pos + random_dir * jump_distance
	
	# Ensure target is back under water
	jump_target_pos.y = water_system.water_level - randf_range(1.0, 3.0)
	
	# Create splash effect
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
	
	# Position splash at water level
	var splash_position = splash_pos
	splash_position.y = water_system.water_level
	
	# Add to scene
	get_tree().root.add_child(splash)
	splash.global_position = splash_position
	splash.emitting = true
	
	# Setup timer to remove splash
	var timer = Timer.new()
	timer.wait_time = 2.0
	timer.one_shot = true
	timer.autostart = true
	splash.add_child(timer)
	timer.timeout.connect(func(): splash.queue_free())
