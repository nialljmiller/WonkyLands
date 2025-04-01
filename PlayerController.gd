extends CharacterBody3D

# Movement settings
@export var move_speed: float = 10.0
@export var jump_strength: float = 15.0
@export var gravity_magnitude: float = 30.0
@export var look_sensitivity: float = 0.3

# Swimming settings
@export var swim_speed: float = 6.0
@export var swim_vertical_speed: float = 5.0
@export var water_drag: float = 0.7

# Camera variables
var camera_rotation = Vector2()

# State flags
var is_swimming = false

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta):
	# Check if we're in water (set by water system)
	is_swimming = get_meta("is_swimming", false)
	
	if is_swimming:
		process_swimming(delta)
	else:
		process_walking(delta)
	
	# Apply camera rotation
	var camera = get_node("Camera3D")
	camera.rotation_degrees.x = clamp(camera.rotation_degrees.x + camera_rotation.y * look_sensitivity, -89, 89)
	rotate_y(-camera_rotation.x * look_sensitivity * 0.01)
	
	# Reset camera rotation
	camera_rotation = Vector2()

func process_walking(delta):
	# Apply gravity when not on floor
	if not is_on_floor():
		velocity.y -= gravity_magnitude * delta
	
	# Get movement input
	var input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	
	# Get the camera's horizontal rotation to determine forward direction
	var forward_dir = -get_node("Camera3D").global_transform.basis.z
	forward_dir.y = 0
	forward_dir = forward_dir.normalized()
	
	# Get the right direction relative to the camera
	var right_dir = forward_dir.cross(Vector3.UP)
	
	# Calculate movement direction relative to camera orientation
	var direction = (right_dir * input_dir.x + forward_dir * -input_dir.y).normalized()
	
	# Set horizontal velocity
	if direction:
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
	else:
		velocity.x = move_toward(velocity.x, 0, move_speed)
		velocity.z = move_toward(velocity.z, 0, move_speed)
	
	# Handle jumping
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_strength
	
	# Move with physics
	move_and_slide()

func process_swimming(delta):
	# In water, we want 3D movement controlled by camera direction
	var input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	
	# Camera-based movement directions
	var camera = get_node("Camera3D")
	var forward_dir = -camera.global_transform.basis.z.normalized()
	var right_dir = camera.global_transform.basis.x.normalized()
	
	# Calculate movement direction in 3D space
	var direction = (right_dir * input_dir.x + forward_dir * -input_dir.y).normalized()
	
	# Apply swimming controls
	if direction:
		velocity.x = direction.x * swim_speed
		velocity.z = direction.z * swim_speed
		
		# Forward movement also affects vertical position based on camera angle
		velocity.y = direction.y * swim_speed
	else:
		# Apply water drag
		velocity.x = move_toward(velocity.x, 0, swim_speed * water_drag)
		velocity.z = move_toward(velocity.z, 0, swim_speed * water_drag)
		velocity.y = move_toward(velocity.y, 0, swim_speed * water_drag)
	
	# Vertical swimming controls (up/down)
	if Input.is_action_pressed("ui_accept"):  # Space to swim up
		velocity.y = swim_vertical_speed
	elif Input.is_action_pressed("ui_focus_next"):  # Tab to swim down (can change control)
		velocity.y = -swim_vertical_speed
	
	# Apply very slight gravity while swimming (buoyancy almost cancels it)
	velocity.y -= 0.5 * delta
	
	# Move with physics
	move_and_slide()
	
	# When swimming to the surface, transition smoothly
	if !is_swimming and velocity.y > 0:
		# Allow a bit of "jump" out of water
		velocity.y = max(velocity.y, jump_strength / 2)

func _input(event):
	if event is InputEventMouseMotion:
		camera_rotation = Vector2(-event.relative.x, -event.relative.y)

# Add water splash effect when entering water
func _on_enter_water():
	# Play splash sound
	var splash_audio = AudioStreamPlayer3D.new()
	# splash_audio.stream = load("res://sounds/splash.wav")  # Create this sound file
	splash_audio.autoplay = true
	splash_audio.max_distance = 10.0
	add_child(splash_audio)
	
	# Spawn splash particles
	var splash = GPUParticles3D.new()
	splash.name = "WaterSplash"
	
	var particle_material = ParticleProcessMaterial.new()
	particle_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	particle_material.emission_sphere_radius = 0.5
	particle_material.direction = Vector3(0, 1, 0)
	particle_material.spread = 45.0
	particle_material.initial_velocity_min = 2.0
	particle_material.initial_velocity_max = 5.0
	particle_material.gravity = Vector3(0, -9.8, 0)
	particle_material.scale_min = 0.1
	particle_material.scale_max = 0.3
	particle_material.color = Color(0.7, 0.8, 1.0, 0.8)
	
	splash.process_material = particle_material
	
	# Create splash mesh
	var splash_mesh = SphereMesh.new()
	splash_mesh.radius = 0.05
	splash_mesh.height = 0.1
	
	splash.draw_pass_1 = splash_mesh
	splash.amount = 50
	splash.lifetime = 1.0
	splash.explosiveness = 0.8
	splash.one_shot = true
	
	add_child(splash)
	splash.position.y = -0.5  # Slightly below player origin
	splash.emitting = true
