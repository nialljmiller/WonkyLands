extends Node3D
## StarField — the real night sky, from the SED_Tools star catalog.
##
## One MultiMeshInstance3D holds every catalog star as a camera-facing
## quad, built ONCE in the equatorial frame. Per frame only this node's
## transform changes: the basis rotates with local sidereal time and
## latitude (SkyModel.equatorial_basis), and the origin follows the
## player like SkyRenderer does, so there's no parallax.
##
## Brightness and size come from V magnitude, colour from the catalog's
## SED-derived rgb. Visibility follows a naked-eye limiting magnitude
## computed from the sky brightness (twilight + moonlight), so bright
## stars come out first at dusk. Variable stars get their V light curve
## applied to their few instances at low rate.

const SkyCatalog = preload("res://telescope/SkyCatalog.gd")
const SkyModel = preload("res://telescope/SkyModel.gd")

## Beyond the moons (10 000) so they draw over us, inside every camera's
## far plane (50 000).
@export var star_distance: float = 20000.0
## Angular half-size (radians) of the faintest star's quad.
@export var base_size_rad: float = 0.0024
## Perceptual brightness slope: intensity ∝ flux^gamma.
@export var brightness_gamma: float = 0.45
@export var twinkle_amount: float = 0.12
## Overall display gain (tonemapping eats faint stars otherwise).
@export var brightness_gain: float = 5.0
@export var appearance_update_hz: float = 10.0
@export var variable_update_hz: float = 2.0

var engine = null   # AstronomyEngine, set by TerrainGenerator

var _catalog = null
var _mmi: MultiMeshInstance3D = null
var _material: ShaderMaterial = null
var _appearance_accum: float = 0.0
var _var_accum: float = 0.0
var _v_band_dark: float = 21.8
var limiting_mag: float = 6.5

func _ready() -> void:
	_catalog = SkyCatalog.shared()
	if _catalog.is_loaded:
		_build()
	elif _catalog.error == "":
		_catalog.loaded.connect(_build, CONNECT_ONE_SHOT)

func _process(delta: float) -> void:
	if _mmi == null or engine == null:
		return
	_appearance_accum += delta
	if _appearance_accum >= 1.0 / appearance_update_hz:
		_appearance_accum = 0.0
		_update_appearance()
	if not _mmi.visible:
		return
	# Rotation from the engine's JD every frame (not its 10 Hz cache) so
	# stars glide smoothly even under time warp. A few trig calls.
	var lst: float = SkyModel.lst_hours(engine.current_jd, engine.observer_longitude_deg)
	var b: Basis = SkyModel.equatorial_basis(lst, engine.observer_latitude_deg)
	var origin: Vector3 = Vector3.ZERO
	if typeof(World) != TYPE_NIL:
		var p = World.get_player()
		if p != null:
			origin = p.global_position
	global_transform = Transform3D(b, origin)
	if not _catalog.variables.is_empty():
		_var_accum += delta
		if _var_accum >= 1.0 / variable_update_hz:
			_var_accum = 0.0
			_update_variables()

# ---------------------------------------------------------------------
# Build (once)
# ---------------------------------------------------------------------
func _build() -> void:
	var n: int = _catalog.stars.size()
	if n == 0:
		return
	var vb: Dictionary = _catalog.bands.get("V", {})
	_v_band_dark = float(vb.get("sky_dark_mag_arcsec2", _v_band_dark))

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = n
	var r: float = star_distance
	mm.custom_aabb = AABB(Vector3(-r, -r, -r), Vector3(2.0 * r, 2.0 * r, 2.0 * r))

	# One packed upload: 12 transform + 4 colour + 4 custom floats each.
	var buf := PackedFloat32Array()
	buf.resize(n * 20)
	for i in n:
		var u: Vector3 = _catalog.unit_eq[i] * star_distance
		# Catalog rgb is gamma-encoded sRGB; the 3D pipeline wants linear.
		var c: Color = _catalog.star_color(i).srgb_to_linear()
		var o: int = i * 20
		buf[o + 0] = 1.0; buf[o + 3] = u.x
		buf[o + 5] = 1.0; buf[o + 7] = u.y
		buf[o + 10] = 1.0; buf[o + 11] = u.z
		buf[o + 12] = c.r; buf[o + 13] = c.g; buf[o + 14] = c.b; buf[o + 15] = 1.0
		var look: Vector2 = _look_for_mag(_catalog.vmag[i])
		buf[o + 16] = look.x
		buf[o + 17] = look.y
		buf[o + 18] = _catalog.vmag[i]
		buf[o + 19] = fposmod(float(i) * 0.6180339, 1.0)   # twinkle seed
	mm.buffer = buf

	_material = ShaderMaterial.new()
	_material.shader = _make_shader()
	_material.render_priority = -10   # moons/sun (priority 0) draw over stars
	_material.set_shader_parameter("extinction_k", float(vb.get("extinction_k", 0.15)))
	_material.set_shader_parameter("twinkle", twinkle_amount)
	_material.set_shader_parameter("gain", brightness_gain)

	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Stars"
	_mmi.multimesh = mm
	_mmi.material_override = _material
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_mmi.extra_cull_margin = 16384.0
	add_child(_mmi)
	_update_appearance()

## (angular half-size, intensity) for a V magnitude. Size grows gently
## for the brightest stars; intensity carries the rest, compressed so a
## −1.5 Sirius and a 6th-mag star both read on screen.
func _look_for_mag(v: float) -> Vector2:
	var size: float = base_size_rad * clampf(1.0 + 0.4 * (3.0 - v), 1.0, 3.2)
	var intensity: float = pow(10.0, -0.4 * brightness_gamma * (v - 1.0))
	intensity /= (size / base_size_rad) * 0.6 + 0.4
	return Vector2(size, clampf(intensity, 0.03, 4.0))

func _update_appearance() -> void:
	var snap: Dictionary = SkyModel.snapshot(engine)
	var sky_v: float = SkyModel.sky_mag_arcsec2(_v_band_dark, snap)
	limiting_mag = SkyModel.naked_eye_limit(sky_v)
	# In daylight nothing is visible: skip the draw entirely.
	var show: bool = limiting_mag > -1.6
	if _mmi.visible != show:
		_mmi.visible = show
	if show:
		_material.set_shader_parameter("lim_mag", limiting_mag)

func _update_variables() -> void:
	var jd: float = engine.current_jd
	var mm: MultiMesh = _mmi.multimesh
	for vi in _catalog.variables.size():
		var si: int = _catalog.variable_star_index[vi]
		if si < 0:
			continue
		var v: float = _catalog.vmag[si] + _catalog.variable_dmag(vi, "V", jd)
		var look: Vector2 = _look_for_mag(v)
		mm.set_instance_custom_data(si, Color(look.x, look.y, v, fposmod(float(si) * 0.6180339, 1.0)))

func _make_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled,
	skip_vertex_transform, shadows_disabled;

// custom: x = angular half-size (rad), y = intensity, z = V mag, w = seed
uniform float lim_mag = 6.5;
uniform float extinction_k = 0.15;
uniform float twinkle = 0.12;
uniform float gain = 5.0;
varying float v_bright;

void vertex() {
	vec3 c = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float d = length(c);
	vec3 wdir = mat3(INV_VIEW_MATRIX) * (c / d);   // world-space direction to the star
	float alt_s = wdir.y;
	// Below the horizon: gone. Near it: airmass extinction dims stars.
	float above = smoothstep(-0.004, 0.02, alt_s);
	float airmass = 1.0 / max(alt_s + 0.04, 0.04);
	float ext = pow(10.0, -0.4 * extinction_k * (min(airmass, 25.0) - 1.0));
	float vis = clamp(lim_mag - INSTANCE_CUSTOM.z + 0.3, 0.0, 1.0);
	float seed = INSTANCE_CUSTOM.w;
	float tw = 1.0 + twinkle * (0.4 + 1.6 * (1.0 - alt_s)) * sin(TIME * (6.0 + 9.0 * seed) + seed * 80.0);
	v_bright = gain * INSTANCE_CUSTOM.y * vis * above * ext * tw;
	float s = INSTANCE_CUSTOM.x * d * 2.0;
	VERTEX = c + vec3(VERTEX.xy * s, 0.0);
	if (v_bright <= 0.0005) {
		VERTEX = vec3(0.0, 0.0, 1.0);  // collapse invisible stars behind the camera
	}
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r2 = dot(p, p);
	float core = exp(-r2 * 9.0);
	float halo = exp(-r2 * 3.0) * 0.25;
	ALBEDO = COLOR.rgb * (core + halo) * v_bright;
}
"""
	return sh
