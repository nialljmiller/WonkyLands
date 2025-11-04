extends CharacterBody3D

@export var throttle_response: float = 1.8
@export var idle_gravity_force: float = 18.0
@export var mass: float = 1200.0
@export var max_thrust: float = 26000.0
@export var wing_area: float = 16.0
@export var wing_span: float = 10.5
@export var air_density: float = 1.225
@export var lift_curve_slope: float = 5.5
@export var max_lift_coefficient: float = 1.4
@export var base_drag_coefficient: float = 0.035
@export var induced_drag_factor: float = 0.045
@export var side_force_coefficient: float = 0.7
@export var stall_angle_deg: float = 16.0
@export var stall_recovery_angle_deg: float = 28.0
@export var stall_drag_multiplier: float = 4.0
@export var min_control_effectiveness: float = 0.2
@export var takeoff_speed: float = 32.0
@export var elevator_authority: float = 2.6
@export var rudder_authority: float = 2.0
@export var aileron_authority: float = 3.0
@export var angular_damping: float = 1.6
@export var pitch_stability: float = 0.8
@export var yaw_stability: float = 1.2
@export var roll_stability: float = 1.1
@export var max_angular_speed: float = 3.5
@export var ground_alignment_speed: float = 3.0
@export var exit_offset: Vector3 = Vector3(-2.2, 0.5, -1.5)

var throttle: float = 0.0
var current_speed: float = 0.0
var angular_velocity: Vector3 = Vector3.ZERO
var input_pitch: float = 0.0
var input_yaw: float = 0.0
var input_roll: float = 0.0
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

        input_pitch = Input.get_action_strength("plane_pitch_down") - Input.get_action_strength("plane_pitch_up")
        input_yaw = Input.get_action_strength("plane_yaw_right") - Input.get_action_strength("plane_yaw_left")
        input_roll = Input.get_action_strength("plane_roll_right") - Input.get_action_strength("plane_roll_left")

func _apply_flight_physics(delta):
        var basis = global_transform.basis
        var forward = -basis.z

        var speed = velocity.length()
        current_speed = speed

        var control_effectiveness = 0.0
        if takeoff_speed > 0.0:
                control_effectiveness = clamp(speed / takeoff_speed, 0.0, 1.5)
        control_effectiveness = lerp(min_control_effectiveness, 1.0, clamp(control_effectiveness, 0.0, 1.0))

        var local_velocity = basis.xform_inv(velocity)
        var airspeed = max(speed, 0.0)

        var angle_of_attack = 0.0
        var sideslip_angle = 0.0
        if airspeed > 0.5:
                angle_of_attack = atan2(local_velocity.y, -local_velocity.z)
                sideslip_angle = asin(clamp(local_velocity.x / airspeed, -1.0, 1.0))

        var angle_of_attack_deg = rad_to_deg(angle_of_attack)
        var stall_blend = 1.0
        if abs(angle_of_attack_deg) > stall_angle_deg:
                var recovery_angle = max(stall_recovery_angle_deg - stall_angle_deg, 1.0)
                var overshoot = min(abs(angle_of_attack_deg) - stall_angle_deg, recovery_angle)
                stall_blend = clamp(1.0 - overshoot / recovery_angle, 0.0, 1.0)

        var lift_coefficient = clamp(lift_curve_slope * angle_of_attack, -max_lift_coefficient, max_lift_coefficient)
        var effective_cl = lift_coefficient * stall_blend

        control_effectiveness *= stall_blend

        var aspect_ratio = 1.0
        if wing_area > 0.0:
                aspect_ratio = (wing_span * wing_span) / wing_area
        var induced_drag = 0.0
        if aspect_ratio > 0.01:
                induced_drag = (effective_cl * effective_cl) / (PI * aspect_ratio)

        var dynamic_pressure = 0.5 * air_density * airspeed * airspeed
        var side_force_coeff = -side_force_coefficient * sideslip_angle
        if takeoff_speed > 0.0:
                side_force_coeff *= clamp(speed / takeoff_speed, 0.0, 1.0)
        side_force_coeff *= stall_blend

        var drag_coefficient = base_drag_coefficient + induced_drag_factor * (effective_cl * effective_cl) + induced_drag
        drag_coefficient *= lerp(1.0, stall_drag_multiplier, 1.0 - stall_blend)

        var qS = dynamic_pressure * wing_area
        var local_force = Vector3(side_force_coeff * qS, effective_cl * qS, -drag_coefficient * qS)
        var aerodynamic_force = basis * local_force

        var thrust_force = forward * max_thrust * throttle
        var gravity_force = Vector3.DOWN * 9.81 * mass

        var total_force = thrust_force + aerodynamic_force + gravity_force
        var acceleration_vector = total_force / max(mass, 0.01)
        velocity += acceleration_vector * delta

        if speed < 0.1:
                velocity += forward * throttle * delta * 2.0

        var elevator_torque = input_pitch * elevator_authority * control_effectiveness
        var rudder_torque = input_yaw * rudder_authority * control_effectiveness
        var aileron_torque = input_roll * aileron_authority * control_effectiveness

        var stability_pitch = -pitch_stability * angle_of_attack
        var stability_yaw = -yaw_stability * sideslip_angle
        var roll_level = -roll_stability * basis.z.y

        var angular_acceleration = Vector3(
                (elevator_torque + stability_pitch) - angular_velocity.x * angular_damping * control_effectiveness,
                (rudder_torque + stability_yaw) - angular_velocity.y * angular_damping * control_effectiveness,
                (aileron_torque + roll_level) - angular_velocity.z * angular_damping * control_effectiveness
        )

        angular_velocity += angular_acceleration * delta
        if angular_velocity.length() > max_angular_speed:
                angular_velocity = angular_velocity.normalized() * max_angular_speed

        rotate_object_local(Vector3.RIGHT, angular_velocity.x * delta)
        rotate_y(angular_velocity.y * delta)
        rotate_object_local(Vector3.FORWARD, angular_velocity.z * delta)

func _apply_idle_physics(delta):
        throttle = lerp(throttle, 0.0, delta * 1.5)
        current_speed = lerp(current_speed, 0.0, delta * 1.2)

        angular_velocity = angular_velocity.lerp(Vector3.ZERO, delta * 2.0)

        var target_velocity = Vector3.ZERO
        if not is_on_floor():
                target_velocity.y = velocity.y - idle_gravity_force * delta

        velocity = velocity.lerp(target_velocity, delta * 3.0)

        if is_on_floor():
                var euler = rotation_degrees
                euler.x = lerp_angle(euler.x, 0.0, delta * ground_alignment_speed)
                euler.z = lerp_angle(euler.z, 0.0, delta * ground_alignment_speed)
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

        input_pitch = 0.0
        input_yaw = 0.0
        input_roll = 0.0
        angular_velocity = Vector3.ZERO

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
        input_pitch = 0.0
        input_yaw = 0.0
        input_roll = 0.0
        angular_velocity = Vector3.ZERO
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
