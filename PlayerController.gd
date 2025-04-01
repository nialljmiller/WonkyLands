extends CharacterBody3D

# Movement settings
@export var move_speed: float = 10.0
@export var jump_strength: float = 15.0
@export var gravity_magnitude: float = 30.0
@export var look_sensitivity: float = 0.3

# Camera variables
var camera_rotation = Vector2()

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta):
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
	
	# Apply camera rotation
	var camera = get_node("Camera3D")
	camera.rotation_degrees.x = clamp(camera.rotation_degrees.x + camera_rotation.y * look_sensitivity, -89, 89)
	rotate_y(-camera_rotation.x * look_sensitivity * 0.01)
	
	# Reset camera rotation
	camera_rotation = Vector2()

func _input(event):
	if event is InputEventMouseMotion:
		camera_rotation = Vector2(-event.relative.x, -event.relative.y)
