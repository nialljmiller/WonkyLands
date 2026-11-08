extends Node3D
## SkyRenderer — the "what the eye sees" layer.
##
## Reads AstronomyEngine state each frame and places visual proxies at
## the apparent direction of each celestial body, at a fixed render
## distance, scaled to the correct apparent angular size. The render
## distance is cosmetic — what matters is the direction and angular
## size the viewer actually sees.
##
## Everything is anchored to the player each frame so there's no
## parallax regardless of where the player flies.

@export var render_distance: float = 10000.0    # sky-dome radius in world units
# Sun base brightness at midday; dimmed via shader uniform near horizon.
@export var sun_peak_brightness: float = 12.0
@export var moon_peak_brightness: float = 2.5
# Shadow + light energy maxima for the celestial DirectionalLights.
@export var sun_light_peak_energy: float = 1.5
@export var moon1_light_peak_energy: float = 0.2
@export var moon2_light_peak_energy: float = 0.15

# Set externally by TerrainGenerator at spawn.
var engine = null

# --- Scene elements ---
var world_env: WorldEnvironment = null
var env: Environment = null
var sky_material: ProceduralSkyMaterial = null

var sun_light: DirectionalLight3D = null
var sun_mesh: MeshInstance3D = null
var sun_material: ShaderMaterial = null

var moon1_light: DirectionalLight3D = null
var moon1_mesh: MeshInstance3D = null
var moon1_material: ShaderMaterial = null

var moon2_light: DirectionalLight3D = null
var moon2_mesh: MeshInstance3D = null
var moon2_material: ShaderMaterial = null

# ---------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------
func _ready() -> void:
	_build_environment()
	_build_sun()
	_build_moons()

func _process(_delta: float) -> void:
	if engine == null:
		return
	_update_position(sun_mesh, sun_light, engine.sun_dir, engine.sun_angular_radius)
	_update_position(moon1_mesh, moon1_light, engine.moon1_dir, engine.moon1_angular_radius)
	_update_position(moon2_mesh, moon2_light, engine.moon2_dir, engine.moon2_angular_radius)
	_anchor_to_player()
	_update_sun_appearance()
	_update_moon_appearance(moon1_material, moon1_light, engine.moon1_dir, engine.moon1_phase, moon1_light_peak_energy, engine.moon1_color)
	_update_moon_appearance(moon2_material, moon2_light, engine.moon2_dir, engine.moon2_phase, moon2_light_peak_energy, engine.moon2_color)
	_update_sky_colors()

func _update_position(mesh: MeshInstance3D, light: DirectionalLight3D, dir: Vector3, angular_radius: float) -> void:
	# Place mesh at direction * render_distance, scaled so its angular
	# size matches the engine's reported apparent angular size.
	if mesh == null:
		return
	mesh.position = dir * render_distance
	var render_radius: float = render_distance * tan(maxf(angular_radius, 1e-6))
	mesh.scale = Vector3.ONE * render_radius
	# Point the directional light from the body toward the observer.
	if light != null:
		light.look_at_from_position(mesh.position, Vector3.ZERO, Vector3.UP)
		# Below-horizon bodies cast no light.
		var below: bool = dir.y < -0.03
		light.visible = not below
		mesh.visible = not below

func _anchor_to_player() -> void:
	var player_pos: Vector3 = Vector3.ZERO
	if typeof(World) != TYPE_NIL:
		var p = World.get_player()
		if p != null:
			player_pos = p.global_position
	global_position = player_pos

# ---------------------------------------------------------------------
# Environment (sky + fog + ambient)
# ---------------------------------------------------------------------
func _build_environment() -> void:
	world_env = WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	sky_material = ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.3, 0.55, 0.85)
	sky_material.sky_horizon_color = Color(0.7, 0.8, 0.9)
	sky_material.ground_bottom_color = Color(0.1, 0.1, 0.1)
	sky_material.ground_horizon_color = Color(0.6, 0.65, 0.7)
	sky_material.sun_angle_max = 0.0   # We draw our own sun — procedural can stay off
	sky_material.sun_curve = 0.1
	var sky := Sky.new()
	sky.sky_material = sky_material
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.ambient_light_energy = 0.3
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.fog_enabled = true
	env.fog_light_color = Color(0.5, 0.5, 0.8)
	env.fog_density = 0.001
	env.fog_sky_affect = 0.4
	world_env.environment = env
	add_child(world_env)

# ---------------------------------------------------------------------
# Sun
# ---------------------------------------------------------------------
func _build_sun() -> void:
	sun_light = DirectionalLight3D.new()
	sun_light.name = "SunLight"
	sun_light.light_color = Color(1.0, 0.98, 0.92)
	sun_light.light_energy = sun_light_peak_energy
	sun_light.shadow_enabled = true
	sun_light.shadow_bias = 0.03
	sun_light.directional_shadow_max_distance = 500.0
	add_child(sun_light)

	sun_material = _make_emissive_material(Color(1.0, 0.98, 0.92), sun_peak_brightness)
	sun_mesh = _make_celestial_mesh("Sun", sun_material)
	add_child(sun_mesh)

func _update_sun_appearance() -> void:
	# Dim near horizon; shift color toward red at sunset / dawn.
	var alt: float = asin(clampf(engine.sun_dir.y, -1.0, 1.0))
	var day_factor: float = clampf((sin(alt) + 0.12) / 0.22, 0.0, 1.0)
	var sunset_factor: float = clampf(1.0 - absf(day_factor * 2.0 - 1.0), 0.0, 1.0)
	var sunset_color: Color = Color(1.0, 0.55, 0.3)
	var current_sun_color: Color = sunset_color.lerp(engine.sun_color, day_factor)
	sun_material.set_shader_parameter("tint", current_sun_color)
	sun_material.set_shader_parameter("brightness", lerp(1.0, sun_peak_brightness, day_factor))
	sun_light.light_color = current_sun_color
	sun_light.light_energy = lerp(0.0, sun_light_peak_energy, day_factor)

# ---------------------------------------------------------------------
# Moons
# ---------------------------------------------------------------------
func _build_moons() -> void:
	moon1_light = DirectionalLight3D.new()
	moon1_light.name = "Moon1Light"
	moon1_light.shadow_enabled = false
	add_child(moon1_light)
	moon1_material = _make_moon_material()
	moon1_mesh = _make_celestial_mesh("Moon1", moon1_material)
	add_child(moon1_mesh)

	moon2_light = DirectionalLight3D.new()
	moon2_light.name = "Moon2Light"
	moon2_light.shadow_enabled = false
	add_child(moon2_light)
	moon2_material = _make_moon_material()
	moon2_mesh = _make_celestial_mesh("Moon2", moon2_material)
	add_child(moon2_mesh)

func _update_moon_appearance(mat: ShaderMaterial, light: DirectionalLight3D, moon_dir: Vector3, phase: float, peak_energy: float, color: Color) -> void:
	# Sun direction as seen FROM the moon = direction from moon to sun
	# ≈ sun_dir (since the moon is close to the observer compared to the
	# sun). We pass this to the shader so lambertian shading lights only
	# the sun-facing hemisphere of the moon mesh.
	mat.set_shader_parameter("sun_direction", -engine.sun_dir)   # light propagates sun → observer
	mat.set_shader_parameter("tint", color)
	# Fade whole moon as sun rises (prevent dark-side-as-black-disc).
	var sun_alt_sin: float = engine.sun_dir.y
	var day_hide: float = clampf((sun_alt_sin + 0.05) / 0.08, 0.0, 1.0)  # 0 when sun below, 1 when sun above
	var visibility: float = (1.0 - day_hide) * 0.8 + 0.2    # min 20% at day so phase still visible sometimes
	# But if the moon's lit side is pointed AWAY (new moon in daylight),
	# don't render at all — nothing to show.
	if sun_alt_sin > 0.1 and phase < 0.1:
		visibility = 0.0
	mat.set_shader_parameter("visibility", visibility)
	light.light_color = color
	light.light_energy = peak_energy * phase * clampf(-sun_alt_sin, 0.0, 1.0)

# ---------------------------------------------------------------------
# Sky colors driven by sun altitude
# ---------------------------------------------------------------------
func _update_sky_colors() -> void:
	var alt: float = asin(clampf(engine.sun_dir.y, -1.0, 1.0))
	var day_factor: float = clampf((sin(alt) + 0.12) / 0.22, 0.0, 1.0)
	var sunset_factor: float = clampf(1.0 - absf(day_factor * 2.0 - 1.0), 0.0, 1.0)
	sunset_factor *= sunset_factor
	var night_top: Color = Color(0.02, 0.02, 0.05)
	var day_top: Color = Color(0.3, 0.55, 0.85)
	var sunset_top: Color = Color(0.45, 0.28, 0.2)
	var night_horizon: Color = Color(0.05, 0.05, 0.1)
	var day_horizon: Color = Color(0.7, 0.8, 0.9)
	var sunset_horizon: Color = Color(0.9, 0.55, 0.3)
	var top: Color = night_top.lerp(day_top, day_factor).lerp(sunset_top, sunset_factor)
	var horizon: Color = night_horizon.lerp(day_horizon, day_factor).lerp(sunset_horizon, sunset_factor)
	sky_material.sky_top_color = top
	sky_material.sky_horizon_color = horizon
	sky_material.ground_horizon_color = horizon
	env.ambient_light_energy = lerp(0.02, 0.4, day_factor)
	env.fog_density = lerp(0.005, 0.001, day_factor)

# ---------------------------------------------------------------------
# Mesh + material helpers
# ---------------------------------------------------------------------
func _make_celestial_mesh(mesh_name: String, mat: ShaderMaterial) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	var mi := MeshInstance3D.new()
	mi.name = mesh_name
	mi.mesh = sphere
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Never cull — we scale and reposition every frame.
	mi.extra_cull_margin = 16384.0
	return mi

func _make_emissive_material(default_color: Color, default_brightness: float) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, depth_draw_opaque;

uniform vec4 tint : source_color = vec4(1.0, 0.98, 0.92, 1.0);
uniform float brightness = 12.0;

void fragment() {
	ALBEDO = vec3(0.0);
	EMISSION = tint.rgb * brightness;
	ALPHA = 1.0;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("tint", default_color)
	mat.set_shader_parameter("brightness", default_brightness)
	return mat

func _make_moon_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
// Fully transparent on the dark side so it doesn't render as a black
// disc against a bright sky. Lit side still visible.
render_mode unshaded, depth_draw_opaque, blend_mix;

uniform vec4 tint : source_color = vec4(0.9, 0.9, 0.85, 1.0);
uniform vec3 sun_direction = vec3(0.0, 0.0, -1.0);
uniform float visibility = 1.0;
uniform float ambient = 0.05;
uniform float glow_strength = 0.9;

void fragment() {
	vec3 n = normalize(NORMAL);
	// Lambert from the moon-space normal against sun direction.
	float lambert = max(dot(n, -sun_direction), 0.0);
	lambert = smoothstep(0.0, 0.3, lambert);
	float brightness = clamp(ambient + glow_strength * lambert, 0.0, 1.0);
	ALBEDO = vec3(0.0);
	EMISSION = tint.rgb * brightness;
	ALPHA = clamp(brightness * 2.5, 0.0, 1.0) * visibility;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat
