extends Node3D
## Telescope — a little 80 mm refractor on a wooden tripod.
##
## Purely a prop: primitive meshes, no physics body, no shadows on the
## small parts. The Observatory places it and swings the tube toward
## whatever it's told to point at (local horizon-frame direction).

const SLEW_DEG_PER_S: float = 40.0

var _alt_pivot: Node3D = null     # rotates in altitude
var _az_pivot: Node3D = null      # rotates in azimuth
var _target_dir: Vector3 = Vector3(0, 0.7, -0.7).normalized()
var _alt: float = deg_to_rad(30.0)
var _az: float = 0.0

func _ready() -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.55, 0.38, 0.22)
	wood.roughness = 0.8
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.92, 0.92, 0.95)
	metal.metallic = 0.4
	metal.roughness = 0.35
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.08, 0.08, 0.1)

	# Tripod: three splayed legs meeting at the head.
	for k in 3:
		var leg := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.025
		cyl.bottom_radius = 0.035
		cyl.height = 1.35
		leg.mesh = cyl
		leg.material_override = wood
		var ang: float = TAU * k / 3.0
		var foot := Vector3(sin(ang) * 0.55, 0.0, cos(ang) * 0.55)
		var head := Vector3(0, 1.25, 0)
		leg.position = (foot + head) * 0.5
		var up: Vector3 = (head - foot).normalized()
		leg.basis = Basis(Quaternion(Vector3.UP, up))
		leg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(leg)

	_az_pivot = Node3D.new()
	_az_pivot.position = Vector3(0, 1.3, 0)
	add_child(_az_pivot)
	var mount := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.12, 0.14, 0.12)
	mount.mesh = box
	mount.material_override = dark
	_az_pivot.add_child(mount)

	_alt_pivot = Node3D.new()
	_alt_pivot.position = Vector3(0, 0.1, 0)
	_az_pivot.add_child(_alt_pivot)
	# Tube along local −Z (forward), slightly back-heavy like the real thing.
	var tube := MeshInstance3D.new()
	var tcyl := CylinderMesh.new()
	tcyl.top_radius = 0.055
	tcyl.bottom_radius = 0.05
	tcyl.height = 0.9
	tube.mesh = tcyl
	tube.material_override = metal
	tube.rotation = Vector3(-PI * 0.5, 0, 0)
	tube.position = Vector3(0, 0, -0.2)
	_alt_pivot.add_child(tube)
	var dew := MeshInstance3D.new()
	var dcyl := CylinderMesh.new()
	dcyl.top_radius = 0.065
	dcyl.bottom_radius = 0.065
	dcyl.height = 0.18
	dew.mesh = dcyl
	dew.material_override = dark
	dew.rotation = Vector3(-PI * 0.5, 0, 0)
	dew.position = Vector3(0, 0, -0.68)
	_alt_pivot.add_child(dew)
	var cam := MeshInstance3D.new()
	var cbox := BoxMesh.new()
	cbox.size = Vector3(0.11, 0.11, 0.12)
	cam.mesh = cbox
	cam.material_override = dark
	cam.position = Vector3(0, 0, 0.3)
	_alt_pivot.add_child(cam)
	_apply()

## Point the tube along a horizon-frame direction (+Y up, −Z north).
func point_at(dir: Vector3) -> void:
	_target_dir = dir.normalized()
	set_process(true)

func _process(delta: float) -> void:
	var t_alt: float = asin(clampf(_target_dir.y, -1.0, 1.0))
	var t_az: float = atan2(-_target_dir.x, -_target_dir.z)   # Godot yaw: 0 = −Z
	var step: float = deg_to_rad(SLEW_DEG_PER_S) * delta
	_alt = move_toward(_alt, maxf(t_alt, deg_to_rad(-5.0)), step)
	_az = _az + clampf(wrapf(t_az - _az, -PI, PI), -step, step)
	_apply()
	if absf(_alt - maxf(t_alt, deg_to_rad(-5.0))) < 1e-3 and absf(wrapf(t_az - _az, -PI, PI)) < 1e-3:
		set_process(false)

func _apply() -> void:
	if _az_pivot == null:
		return
	# The prop itself may be rotated; pivots work in world yaw.
	_az_pivot.global_rotation = Vector3(0, _az, 0)
	_alt_pivot.rotation = Vector3(_alt, 0, 0)
