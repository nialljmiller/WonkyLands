extends Camera3D

@export var move_speed: float = 10.0
@export var look_sensitivity: float = 0.3

var velocity = Vector3()
var rotation_velocity = Vector2()

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _process(delta):
	# Apply rotation
	rotation_degrees.x = clamp(rotation_degrees.x + rotation_velocity.y * look_sensitivity, -90, 90)
	rotation_degrees.y += rotation_velocity.x * look_sensitivity
	
	# Reset rotation velocity
	rotation_velocity = Vector2()
	
	# Calculate movement direction
	var direction = Vector3()
	if Input.is_action_pressed("ui_up"):
		direction -= transform.basis.z
	if Input.is_action_pressed("ui_down"):
		direction += transform.basis.z
	if Input.is_action_pressed("ui_left"):
		direction -= transform.basis.x
	if Input.is_action_pressed("ui_right"):
		direction += transform.basis.x
	
	# Apply movement
	velocity = direction.normalized() * move_speed
	position += velocity * delta

func _input(event):
	if event is InputEventMouseMotion:
		rotation_velocity = Vector2(-event.relative.x, -event.relative.y)
