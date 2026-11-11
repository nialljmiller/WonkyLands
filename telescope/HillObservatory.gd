extends "res://telescope/Telescope.gd"
## HillObservatory — the storybook observatory on the hill near spawn.
##
## A chunky, tapered brick tower under an oversized starry dome with a
## gold collar and a star on top; a comically long red-and-brass barrel
## pokes out of the slit. Telescope.gd's slew turns the dome (barrel and
## all) to the target's azimuth and tilts the barrel to its altitude.
## After sunset the slit shutter rolls back and the windows and path
## lanterns glow. Built once from CSG + primitives; static collision on
## the plinth and tower only, one shadowless warm light inside. Local −Z
## is the door side (faces the base).

const FLOOR: float = 0.3         # plinth top = room floor, above the plateau
const R_BASE: float = 5.0        # tower radius at the floor
const R_TOP: float = 4.4         # … at the top (slight taper)
const R_IN: float = 3.9          # room radius
const WALL_TOP: float = 4.9
const DOME_R: float = 5.4        # overhangs the tower like a mushroom cap
const PIVOT_Y: float = 2.6       # barrel altitude axis
const SHUTTER_OPEN: float = 1.4  # rad the shutter rolls back at night

const SHADER: String = """
shader_type spatial;
// kind 0: brick courses (cylindrical, object space); 1: gold stars;
// 2: barrel with brass hoops along local y.
uniform int kind = 0;
uniform vec3 base_col : source_color = vec3(0.8, 0.5, 0.35);
uniform vec3 alt_col : source_color = vec3(0.95, 0.88, 0.72);
uniform float cells = 32.0;
uniform float glow = 0.0;     // stars light up at night
varying vec3 p;
void vertex() { p = VERTEX; }
float hash(vec2 v) { return fract(sin(dot(v, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec3 c = base_col;
	float rough = 0.9;
	float a = atan(p.z, p.x) / 6.2831853;
	if (kind == 0) {
		float row = floor(p.y / 0.42);
		float u = a * cells + row * 0.5;
		vec2 f = vec2(fract(u), fract(p.y / 0.42));
		float brick = step(0.05, f.x) * step(0.1, f.y);
		c = mix(alt_col, base_col * (0.82 + 0.36 * hash(vec2(floor(u), row))), brick);
	} else if (kind == 1) {
		float el = asin(clamp(p.y / max(length(p), 1e-3), -1.0, 1.0)) / 1.5708;
		vec2 g = vec2(a * cells, el * cells * 0.3);
		vec2 id = floor(g);
		vec2 q = fract(g) - 0.25 - 0.5 * vec2(hash(id), hash(id + 7.1));
		float r = length(q), t = atan(q.y, q.x);
		float star = step(r, 0.11 * (0.6 + 0.4 * cos(5.0 * t))) * step(0.35, hash(id + 3.3));
		c = mix(base_col, alt_col, star);
		rough = mix(0.6, 0.3, star);
		METALLIC = star * 0.6;
		EMISSION = alt_col * star * glow;
	} else {
		float hoop = step(fract(p.y / 2.2), 0.09);
		c = mix(base_col, alt_col, hoop);
		METALLIC = hoop * 0.8;
		rough = mix(0.45, 0.3, hoop);
	}
	ALBEDO = c;
	ROUGHNESS = rough;
}
"""

var _room: Area3D = null
var _shutter: Node3D = null
var _glow: StandardMaterial3D = null   # windows, lamp and lanterns
var _stars: Array[ShaderMaterial] = []   # dome and shutter
var _night: int = -1

func _build() -> void:
	slew_deg_per_s = 14.0
	min_alt = deg_to_rad(30.0)    # lower and the barrel would clip the collar
	var shader := Shader.new()
	shader.code = SHADER
	var brick := _shader_mat(shader, 0, Color(0.92, 0.5, 0.3), Color(0.9, 0.7, 0.5), 32.0)
	var stone := _shader_mat(shader, 0, Color(0.8, 0.72, 0.6), Color(0.55, 0.47, 0.38), 40.0)
	var dome_mat := _shader_mat(shader, 1, Color(0.16, 0.24, 0.58), Color(1.0, 0.8, 0.3), 26.0)
	var shutter_mat := _shader_mat(shader, 1, Color(0.12, 0.18, 0.45), Color(1.0, 0.8, 0.3), 26.0)
	_stars = [dome_mat, shutter_mat]
	var barrel_mat := _shader_mat(shader, 2, Color(0.72, 0.13, 0.12), Color(0.95, 0.72, 0.3), 0.0)
	var plaster := _mat(Color(0.96, 0.88, 0.7))
	var wood := _mat(Color(0.62, 0.36, 0.2))
	var door_paint := _mat(Color(0.2, 0.55, 0.45))
	var gold := _mat(Color(1.0, 0.78, 0.25), 0.3, 0.7)
	var dark := _mat(Color(0.1, 0.09, 0.1), 0.5)
	_glow = _mat(Color(1.0, 0.78, 0.4), 0.4)
	_glow.emission_enabled = true
	_glow.emission = Color(1.0, 0.7, 0.35)
	_glow.emission_energy_multiplier = 0.3
	_glow.cull_mode = BaseMaterial3D.CULL_DISABLED   # the flat star

	# Plinth + tower: one CSG with collision. Doorway on −Z, four portholes.
	var tower := CSGCombiner3D.new()
	tower.use_collision = true
	add_child(tower)
	_csg(tower, _frustum(R_IN + 3.5, R_IN + 4.6, 0.8), Vector3(0, FLOOR - 0.4, 0), stone)
	_csg(tower, _frustum(R_TOP, R_BASE, WALL_TOP - FLOOR + 0.2), Vector3(0, (WALL_TOP + FLOOR - 0.2) * 0.5, 0), brick)
	_csg(tower, _frustum(R_IN, R_IN, 6.0), Vector3(0, FLOOR + 3.0, 0), plaster, CSGShape3D.OPERATION_SUBTRACTION)
	_csg(tower, _box(Vector3(1.8, 2.5, 3.0)), Vector3(0, FLOOR + 1.252, -R_IN - 0.6), brick, CSGShape3D.OPERATION_SUBTRACTION)
	_csg(tower, _frustum(0.9, 0.9, 3.0), Vector3(0, FLOOR + 2.5, -R_IN - 0.6), brick, CSGShape3D.OPERATION_SUBTRACTION, Vector3(PI * 0.5, 0, 0))
	var pane := _frustum(0.42, 0.42, 0.06)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.4
	ring.outer_radius = 0.58
	# Portholes: glowing panes on both faces of the wall (no holes, so no
	# CSG seams), brass rings outside on the tapered face.
	var r_out: float = lerpf(R_BASE, R_TOP, 2.9 / (WALL_TOP - FLOOR + 0.2))
	for deg in [62.0, 128.0, 232.0, 298.0]:
		var yaw := Basis(Vector3.UP, deg_to_rad(deg))
		var out: Vector3 = yaw * Vector3(0, 0, -1)
		var h := Vector3(0, FLOOR + 2.7, 0)
		var tilt: Basis = yaw * Basis(Vector3.RIGHT, PI * 0.5 + atan((R_BASE - R_TOP) / (WALL_TOP - FLOOR + 0.2)))
		_mesh(self, pane, _glow, Transform3D(yaw * Basis(Vector3.RIGHT, PI * 0.5), out * R_IN + h))
		_mesh(self, pane, _glow, Transform3D(tilt, out * (r_out - 0.01) + h))
		_mesh(self, ring, gold, Transform3D(tilt, out * r_out + h))
	_csg(tower, _frustum(0.45, 0.6, 1.25), Vector3(0, FLOOR + 0.6, 0), stone)   # pier

	# Collar over the wall top hides the dome's overhang from below.
	var collar := TorusMesh.new()
	collar.inner_radius = R_IN + 0.05
	collar.outer_radius = DOME_R + 0.3
	collar.rings = 48
	_mesh(self, collar, gold, Transform3D(Basis.from_scale(Vector3(1, 0.35, 1)), Vector3(0, WALL_TOP, 0)), true)
	# Big arched door, swung wide open, with a gold keystone.
	var door := Node3D.new()
	door.position = Vector3(-0.9, FLOOR, -4.92)
	door.rotation.y = deg_to_rad(150.0)
	add_child(door)
	_mesh(door, _box(Vector3(1.8, 2.5, 0.12)), door_paint, Transform3D(Basis(), Vector3(0.9, 1.25, 0)), true)
	_mesh(door, _frustum(0.9, 0.9, 0.12), door_paint, Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.9, 2.5, 0)))
	_mesh(door, _sphere(0.09), gold, Transform3D(Basis(), Vector3(1.55, 1.2, -0.1)))
	_mesh(self, _box(Vector3(0.6, 0.7, 0.5)), gold, Transform3D(Basis(), Vector3(0, FLOOR + 3.55, -4.6)))

	# Inside: wooden floor, rug, stone pier, desk, chair, lamp, star chart, warm light.
	_mesh(self, _frustum(R_IN, R_IN, 0.04), wood, Transform3D(Basis(), Vector3(0, FLOOR + 0.02, 0)))
	_mesh(self, _frustum(1.8, 1.8, 0.05), _mat(Color(0.62, 0.16, 0.22)), Transform3D(Basis(), Vector3(0, FLOOR + 0.04, 0)))
	var desk := Node3D.new()
	desk.position = Vector3(2.6, FLOOR, 1.9)
	desk.rotation.y = deg_to_rad(-126.0)
	add_child(desk)
	_mesh(desk, _box(Vector3(1.6, 0.08, 0.75)), wood, Transform3D(Basis(), Vector3(0, 0.85, 0)))
	for sx in [-0.72, 0.72]:
		_mesh(desk, _box(Vector3(0.08, 0.85, 0.7)), wood, Transform3D(Basis(), Vector3(sx, 0.42, 0)))
	_mesh(desk, _box(Vector3(0.5, 0.45, 0.45)), wood, Transform3D(Basis(), Vector3(0, 0.25, 0.9)))
	_mesh(desk, _box(Vector3(0.5, 0.6, 0.06)), wood, Transform3D(Basis(), Vector3(0, 0.75, 1.1)))
	_mesh(desk, _sphere(0.14), _glow, Transform3D(Basis(), Vector3(-0.5, 1.15, -0.1)))
	_mesh(desk, _frustum(0.03, 0.08, 0.3), gold, Transform3D(Basis(), Vector3(-0.5, 1.0, -0.1)))
	_mesh(desk, _box(Vector3(0.5, 0.02, 0.35)), plaster, Transform3D(Basis(Vector3.UP, 0.2), Vector3(0.2, 0.9, 0)))
	var chart := Node3D.new()
	chart.rotation.y = deg_to_rad(-140.0)
	add_child(chart)
	_mesh(chart, _box(Vector3(1.7, 1.2, 0.05)), gold, Transform3D(Basis(), Vector3(0, FLOOR + 2.1, R_IN - 0.05)))
	var sky := _shader_mat(shader, 1, Color(0.08, 0.1, 0.25), Color(1.0, 0.95, 0.75), 60.0)
	_mesh(chart, _box(Vector3(1.55, 1.05, 0.06)), sky, Transform3D(Basis(), Vector3(0, FLOOR + 2.1, R_IN - 0.08)))
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(0, WALL_TOP - 0.8, 0)
	lamp.light_color = Color(1.0, 0.76, 0.48)
	lamp.light_energy = 2.2
	lamp.omni_range = R_IN * 2.0     # light range ignores the building's scale
	lamp.omni_attenuation = 0.6
	lamp.shadow_enabled = false
	add_child(lamp)
	_room = Area3D.new()
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = R_IN
	cyl.height = 3.0
	shape.shape = cyl
	shape.position = Vector3(0, FLOOR + 1.5, 0)
	_room.add_child(shape)
	add_child(_room)

	# Turning part: dome, shutter, star finial, fork and barrel.
	_az_pivot = Node3D.new()
	add_child(_az_pivot)
	var cap := Node3D.new()
	cap.position = Vector3(0, WALL_TOP, 0)
	cap.scale = Vector3(1, 0.9, 1)
	_az_pivot.add_child(cap)
	var dome := CSGCombiner3D.new()
	cap.add_child(dome)
	_csg(dome, _sphere(DOME_R), Vector3.ZERO, dome_mat)
	_csg(dome, _sphere(DOME_R - 0.25), Vector3.ZERO, plaster, CSGShape3D.OPERATION_SUBTRACTION)
	_csg(dome, _box(Vector3(14, 7, 14)), Vector3(0, -3.5, 0), plaster, CSGShape3D.OPERATION_SUBTRACTION)
	_csg(dome, _box(Vector3(1.9, 8.0, 7.4)), Vector3(0, 3.5, -2.8), plaster, CSGShape3D.OPERATION_SUBTRACTION)
	_shutter = CSGCombiner3D.new()
	cap.add_child(_shutter)
	_csg(_shutter, _sphere(DOME_R + 0.06), Vector3.ZERO, shutter_mat)
	_csg(_shutter, _sphere(DOME_R - 0.1), Vector3.ZERO, shutter_mat, CSGShape3D.OPERATION_SUBTRACTION)
	_csg(_shutter, _box(Vector3(2.3, 7.95, 7.8)), Vector3(0, 4.02, -2.8), shutter_mat, CSGShape3D.OPERATION_INTERSECTION)
	_mesh(cap, _frustum(0.05, 0.08, 1.2), gold, Transform3D(Basis(), Vector3(0, DOME_R + 0.5, 0)))
	_mesh(cap, _sphere(0.22), gold, Transform3D(Basis(), Vector3(0, DOME_R + 0.2, 0)))
	_mesh(cap, _star_mesh(0.55, 0.24), _glow, Transform3D(Basis(Vector3.UP, 0.4), Vector3(0, DOME_R + 1.35, 0)))
	for sx in [-0.7, 0.7]:
		_mesh(_az_pivot, _box(Vector3(0.18, 1.5, 0.5)), dark, Transform3D(Basis(), Vector3(sx, PIVOT_Y - 0.6, 0)))
	_mesh(_az_pivot, _frustum(0.8, 0.8, 0.15), dark, Transform3D(Basis(), Vector3(0, FLOOR + 1.27, 0)))
	_target_dir = (global_basis * Vector3(0, 0.6, -0.8)).normalized()   # park: barrel over the door
	_az = rotation.y
	_alt = asin(_target_dir.y)
	_alt_pivot = Node3D.new()
	_alt_pivot.position = Vector3(0, PIVOT_Y, 0)
	_az_pivot.add_child(_alt_pivot)
	var along := Basis(Vector3.RIGHT, -PI * 0.5)      # mesh +Y → pivot −Z
	_mesh(_alt_pivot, _frustum(0.5, 0.4, 10.8), barrel_mat, Transform3D(along, Vector3(0, 0, -4.5)), true)
	_mesh(_alt_pivot, _frustum(0.75, 0.52, 1.0), gold, Transform3D(along, Vector3(0, 0, -10.3)))
	_mesh(_alt_pivot, _frustum(0.1, 0.12, 1.6), gold, Transform3D(along, Vector3(0, 0.62, -1.6)))
	_mesh(_alt_pivot, _frustum(0.12, 0.16, 0.35), dark, Transform3D(along, Vector3(0, 0, 1.0)))

	# A winding stepping-stone path down toward the base, with lanterns.
	_build_path(_mat(Color(0.82, 0.76, 0.66)), dark)
	var t := Timer.new()
	t.wait_time = 1.0
	t.autostart = true
	t.timeout.connect(_update_night)
	add_child(t)
	_update_night()

## Inside the room (F works anywhere in it).
func can_use(p: Node3D) -> bool:
	return _room != null and _room.overlaps_body(p)

func _build_path(stone: Material, dark: Material) -> void:
	var stones: Array[Transform3D] = []
	var posts: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 27
	var d: float = R_BASE + 3.4
	while d < 45.0:
		var side: float = sin(d * 0.11) * 4.0 * clampf((d - R_BASE - 3.0) / 8.0, 0.0, 1.0)
		var at: Vector3 = to_global(Vector3(side, 0, -d))
		at.y = World.get_terrain_height(at.x, at.z) - 0.04   # sunk: flush on slopes
		var s: float = rng.randf_range(0.8, 1.15)
		stones.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, 1, s)), at))
		if stones.size() % 6 == 3:
			var lp: Vector3 = to_global(Vector3(side + (1.4 if stones.size() % 12 == 3 else -1.4), 0, -d))
			lp.y = World.get_terrain_height(lp.x, lp.z)
			posts.append(Transform3D(Basis(), lp))
		d += 1.7
	var slab := _frustum(0.55, 0.6, 0.14)
	slab.radial_segments = 7
	_multi(slab, stone, stones, Vector3.ZERO)
	_multi(_box(Vector3(0.12, 1.5, 0.12)), dark, posts, Vector3(0, 0.75, 0))
	_multi(_box(Vector3(0.32, 0.36, 0.32)), _glow, posts, Vector3(0, 1.6, 0))

## Night (sun below the horizon): open the slit, light the windows.
func _update_night() -> void:
	var night: int = int(World.get_sun_direction().y > 0.0)
	if night == _night:
		return
	_night = night
	_glow.emission_energy_multiplier = 3.0 if night else 0.3
	for m in _stars:
		m.set_shader_parameter("glow", 1.5 if night else 0.0)
	create_tween().tween_property(_shutter, "rotation:x", SHUTTER_OPEN if night else 0.0, 4.0) \
		.set_trans(Tween.TRANS_SINE)

# ---------------------------------------------------------------------
# Tiny builders
# ---------------------------------------------------------------------
static func _mat(c: Color, rough: float = 0.85, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m

static func _shader_mat(sh: Shader, kind: int, a: Color, b: Color, cells: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("kind", kind)
	m.set_shader_parameter("base_col", a)
	m.set_shader_parameter("alt_col", b)
	m.set_shader_parameter("cells", cells)
	return m

static func _frustum(top: float, bottom: float, h: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = h
	m.radial_segments = 40 if bottom > 2.0 else 16
	m.rings = 1
	return m

static func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m

static func _sphere(r: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = 2.0 * r
	m.radial_segments = 40 if r > 2.0 else 12
	m.rings = 20 if r > 2.0 else 6
	return m

## A chunky five-pointed star (flat prism) for the finial.
static func _star_mesh(r_out: float, r_in: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 10:
		var a0: float = TAU * k / 10.0
		var a1: float = TAU * (k + 1) / 10.0
		var p0 := Vector3(sin(a0), cos(a0), 0) * (r_out if k % 2 == 0 else r_in)
		var p1 := Vector3(sin(a1), cos(a1), 0) * (r_in if k % 2 == 0 else r_out)
		for z in [0.08, -0.08]:
			var c := Vector3(0, 0, z * 1.5)
			if z > 0:
				st.add_vertex(c); st.add_vertex(p1 + Vector3(0, 0, z)); st.add_vertex(p0 + Vector3(0, 0, z))
			else:
				st.add_vertex(c); st.add_vertex(p0 + Vector3(0, 0, z)); st.add_vertex(p1 + Vector3(0, 0, z))
		st.add_vertex(p0 + Vector3(0, 0, 0.08)); st.add_vertex(p1 + Vector3(0, 0, 0.08)); st.add_vertex(p1 + Vector3(0, 0, -0.08))
		st.add_vertex(p0 + Vector3(0, 0, 0.08)); st.add_vertex(p1 + Vector3(0, 0, -0.08)); st.add_vertex(p0 + Vector3(0, 0, -0.08))
	st.generate_normals()
	return st.commit()

func _csg(parent: Node, mesh: Mesh, pos: Vector3, mat: Material, op: int = CSGShape3D.OPERATION_UNION, rot: Vector3 = Vector3.ZERO) -> void:
	var c := CSGMesh3D.new()
	c.mesh = mesh
	c.material = mat
	c.operation = op
	c.position = pos
	c.rotation = rot
	parent.add_child(c)

## Small parts don't cast shadows (each caster costs a draw per cascade).
func _mesh(parent: Node, mesh: Mesh, mat: Material, xf: Transform3D, shadow: bool = false) -> void:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.material_override = mat
	m.transform = xf
	if not shadow:
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(m)

## World-space instances (top-level so the building's yaw isn't applied twice).
func _multi(mesh: Mesh, mat: Material, xfs: Array[Transform3D], offset: Vector3) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i].translated(offset))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.top_level = true
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
