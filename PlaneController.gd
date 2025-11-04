extends CharacterBody3D

@export var max_speed: float = 85.0
@export var acceleration: float = 18.0
@export var throttle_response: float = 1.8
@export var lift_force: float = 9.0
@export var gravity_force: float = 14.0
@export var idle_gravity_force: float = 18.0
@export var takeoff_speed: float = 35.0
@export var pitch_speed: float = 1.2
@export var yaw_speed: float = 0.8
@export var roll_speed: float = 1.8
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

        rotate_object_local(Vector3.RIGHT, pitch_input * pitch_speed * delta)
        rotate_y(yaw_input * yaw_speed * delta)
        rotate_object_local(Vector3.FORWARD, roll_input * roll_speed * delta)

func _apply_flight_physics(delta):
        current_speed = lerp(current_speed, throttle * max_speed, acceleration * delta)

        var forward = -global_transform.basis.z
        var up_dir = global_transform.basis.y
        var lift_ratio = clamp(current_speed / takeoff_speed, 0.0, 1.0)

        var target_velocity = forward * current_speed
        target_velocity += up_dir * lift_force * lift_ratio

        velocity = velocity.lerp(target_velocity, delta * 2.0)
        velocity.y -= gravity_force * delta * (1.0 - lift_ratio)

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
