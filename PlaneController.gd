extends CharacterBody3D

@export var max_speed: float = 85.0
@export var acceleration: float = 18.0
@export var throttle_response: float = 1.8
@export var idle_gravity_force: float = 18.0
@export var takeoff_speed: float = 35.0
@export var pitch_speed: float = 1.2
@export var yaw_speed: float = 0.8
@export var roll_speed: float = 1.8
@export var mass: float = 1200.0
@export var max_thrust: float = 26000.0
@export var wing_area: float = 16.0
@export var air_density: float = 1.225
@export var lift_coefficient_slope: float = 5.5
@export var max_lift_coefficient: float = 1.4
@export var base_drag_coefficient: float = 0.035
@export var induced_drag_factor: float = 0.045
@export var stall_angle_deg: float = 16.0
@export var stall_drag_multiplier: float = 3.0
@export var min_control_effectiveness: float = 0.2
@export var exit_offset: Vector3 = Vector3(-2.2, 0.5, -1.5)

var throttle: float = 0.0
var current_speed: float = 0.0
var controlling_player: CharacterBody3D = null
var nearby_player: CharacterBody3D = null
var camera_mount: Marker3D
var seat_marker: Marker3D
var propeller: Node3D
var original_camera_parent: Node = null
var original_camera_transform: Transform3D = Transform3D.IDENTITY
var stored_player_visibility: bool = true
var stored_process_input: bool = true
var stored_process_physics: bool = true
var disabled_colliders: Array[CollisionShape3D] = []

@onready var entry_area: Area3D = $EntryArea

func _ready():
        camera_mount = $CameraMount
        seat_marker = $Seat
        propeller = $Propeller

        entry_area.body_entered.connect(_on_entry_body_entered)
        entry_area.body_exited.connect(_on_entry_body_exited)

func _physics_process(delta):
        _update_propeller(delta)

        if controlling_player:
                _attach_player_to_seat()
                _handle_flight_input(delta)
                _apply_flight_physics(delta)

                if Input.is_action_just_pressed("interact"):
                        exit_plane()
        else:
                _apply_idle_physics(delta)

                if nearby_player and Input.is_action_just_pressed("interact"):
                        enter_plane(nearby_player)

        move_and_slide()

func _handle_flight_input(delta):
        var throttle_input = Input.get_action_strength("plane_throttle_up") - Input.get_action_strength("plane_throttle_down")
        throttle = clamp(throttle + throttle_input * throttle_response * delta, 0.0, 1.0)

        var pitch_input = Input.get_action_strength("plane_pitch_down") - Input.get_action_strength("plane_pitch_up")
        var yaw_input = Input.get_action_strength("plane_yaw_right") - Input.get_action_strength("plane_yaw_left")
        var roll_input = Input.get_action_strength("plane_roll_right") - Input.get_action_strength("plane_roll_left")

        var control_effectiveness = clamp(velocity.length() / max(takeoff_speed, 0.01), 0.0, 1.0)
        control_effectiveness = lerp(min_control_effectiveness, 1.0, control_effectiveness)

        rotate_object_local(Vector3.RIGHT, pitch_input * pitch_speed * delta * control_effectiveness)
        rotate_y(yaw_input * yaw_speed * delta * control_effectiveness)
        rotate_object_local(Vector3.FORWARD, roll_input * roll_speed * delta * control_effectiveness)

func _apply_flight_physics(delta):
        var forward = -global_transform.basis.z
        var right = global_transform.basis.x
        var up_dir = global_transform.basis.y

        var speed = velocity.length()
        current_speed = speed

        var thrust_force = forward * max_thrust * throttle

        var relative_wind: Vector3
        if speed > 0.1:
                relative_wind = -velocity.normalized()
        else:
                relative_wind = -forward

        var angle_of_attack = asin(clamp(relative_wind.dot(up_dir), -1.0, 1.0))
        var angle_of_attack_deg = rad_to_deg(angle_of_attack)

        var lift_coefficient = clamp(lift_coefficient_slope * angle_of_attack, -max_lift_coefficient, max_lift_coefficient)
        var stall_factor = 1.0
        if abs(angle_of_attack_deg) > stall_angle_deg:
                var excess = abs(angle_of_attack_deg) - stall_angle_deg
                stall_factor = clamp(1.0 - (excess / max(1.0, stall_angle_deg)), 0.0, 1.0)

        var speed_lift_factor = clamp(speed / max(takeoff_speed, 0.01), 0.0, 1.0)
        lift_coefficient *= stall_factor * speed_lift_factor

        var dynamic_pressure = 0.5 * air_density * speed * speed

        var lift_direction = right.cross(relative_wind)
        if lift_direction.length_squared() > 0.001:
                lift_direction = lift_direction.normalized()
        else:
                lift_direction = up_dir

        var lift_force = lift_direction * (dynamic_pressure * wing_area * lift_coefficient)

        var drag_coefficient = base_drag_coefficient + (lift_coefficient * lift_coefficient) * induced_drag_factor
        if stall_factor < 0.999:
                drag_coefficient *= (1.0 + (1.0 - stall_factor) * stall_drag_multiplier)
        var drag_force = relative_wind * (dynamic_pressure * wing_area * drag_coefficient)

        var gravity_force = Vector3.DOWN * 9.81 * mass

        var total_force = thrust_force + lift_force - drag_force + gravity_force
        var acceleration_vector = total_force / max(mass, 0.01)

        velocity += acceleration_vector * delta

        var target_forward_speed = throttle * max_speed
        if target_forward_speed > 0.0:
                var forward_velocity = forward * forward.dot(velocity)
                var desired_forward_velocity = forward * target_forward_speed
                var forward_adjustment = (desired_forward_velocity - forward_velocity) * acceleration * delta * 0.1
                velocity += forward_adjustment

func _apply_idle_physics(delta):
        throttle = lerp(throttle, 0.0, delta * 1.5)
        current_speed = lerp(current_speed, 0.0, delta * 1.2)

        var target_velocity = Vector3.ZERO
        if not is_on_floor():
                target_velocity.y = velocity.y - idle_gravity_force * delta

        velocity = velocity.lerp(target_velocity, delta * 3.0)

        if is_on_floor():
                var euler = rotation_degrees
                euler.x = lerp_angle(euler.x, 0.0, delta * 3.0)
                euler.z = lerp_angle(euler.z, 0.0, delta * 3.0)
                rotation_degrees = euler

func _update_propeller(delta):
        if propeller:
                var spin_speed = lerp(3.0, 40.0, throttle)
                propeller.rotate_z(spin_speed * delta)

func _attach_player_to_seat():
        if not controlling_player:
                return

        controlling_player.global_transform = seat_marker.global_transform
        controlling_player.velocity = Vector3.ZERO

func enter_plane(player: CharacterBody3D):
        if controlling_player:
                return

        controlling_player = player
        nearby_player = null

        if controlling_player.has_method("set_control_enabled"):
                controlling_player.set_control_enabled(false)

        stored_player_visibility = controlling_player.visible
        controlling_player.visible = false

        stored_process_input = controlling_player.is_processing_input()
        stored_process_physics = controlling_player.is_physics_processing()
        controlling_player.set_process_input(false)
        controlling_player.set_physics_process(false)

        disabled_colliders.clear()
        for child in controlling_player.get_children():
                if child is CollisionShape3D:
                        var collider: CollisionShape3D = child
                        collider.disabled = true
                        disabled_colliders.append(collider)

        _attach_player_to_seat()

        var camera = controlling_player.get_node_or_null("Camera3D")
        if camera:
                original_camera_parent = camera.get_parent()
                original_camera_transform = camera.transform
                camera.get_parent().remove_child(camera)
                camera_mount.add_child(camera)
                camera.transform = Transform3D.IDENTITY
                camera.position = Vector3(0, 0.6, 0)
                camera.rotation_degrees = Vector3(-5, 0, 0)

        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func exit_plane():
        if not controlling_player:
                return

        var player = controlling_player

        var camera = camera_mount.get_node_or_null("Camera3D")
        if camera and original_camera_parent:
                camera_mount.remove_child(camera)
                original_camera_parent.add_child(camera)
                camera.transform = original_camera_transform

        player.visible = stored_player_visibility
        var exit_position = global_transform.origin + global_transform.basis * exit_offset
        player.global_position = exit_position
        player.velocity = Vector3.ZERO

        player.set_process_input(stored_process_input)
        player.set_physics_process(stored_process_physics)

        if player.has_method("set_control_enabled"):
                player.set_control_enabled(true)

        for collider in disabled_colliders:
                if is_instance_valid(collider):
                        collider.disabled = false
        disabled_colliders.clear()

        nearby_player = player
        controlling_player = null
        original_camera_parent = null
        original_camera_transform = Transform3D.IDENTITY
        throttle = 0.0
        current_speed = 0.0
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_entry_body_entered(body):
        if body.name == "Player" and body is CharacterBody3D and body != controlling_player:
                nearby_player = body

func _on_entry_body_exited(body):
        if body == nearby_player:
                nearby_player = null

func lerp_angle(from_angle: float, to_angle: float, weight: float) -> float:
        var difference = wrapf((to_angle - from_angle), -180.0, 180.0)
        return from_angle + difference * clamp(weight, 0.0, 1.0)
