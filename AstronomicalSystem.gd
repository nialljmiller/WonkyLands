extends Node3D

class_name AstronomicalSystem

# Time settings
@export var day_length: float = 1200.0  # Seconds per full day cycle
@export var time_scale: float = 1000.0  # Speed multiplier for time
@export var start_time: float = 8.0  # Starting hour (24-hour format)

# World parameters (Earth-like by default)
@export var planet_axial_tilt: float = 23.5  # Axial tilt in degrees
@export var planet_rotation_period: float = 24.0  # Hours
@export var planet_orbital_period: float = 365.25  # Days
@export_range(0, 365) var current_day_of_year: int = 80  # Day number of the year (1-365)
@export var latitude: float = 45.0  # Observer latitude in degrees

# Sun properties
# Astronomical sizes & distances, scaled 1/1000 from real so that angular
# dimensions match reality (sun ≈ 0.53°, moons ≈ 0.52°) while staying
# well inside float32 precision. 1 Godot unit = 1 meter for gameplay;
# celestial numbers are large because the sky really is that far away.
@export var sun_size: float = 696_340.0            # real: 696,340 km → 696 km scaled
@export var sun_intensity_day: float = 1.5  # Max light intensity
@export var sun_intensity_night: float = 0.0  # Min light intensity
@export var sun_color_day: Color = Color(1.0, 0.98, 0.92)  # Daylight color
@export var sun_color_sunset: Color = Color(1.0, 0.6, 0.3)  # Sunset/sunrise color
@export var ambient_day_intensity: float = 0.3  # Ambient light during day
@export var ambient_night_intensity: float = 0.02  # Ambient light during night

# Moon properties — real Earth–Moon proportions (angular size 0.52°)
@export var primary_moon_size: float = 1_737.4     # real: 1,737.4 km → 1.74 km scaled
@export var primary_moon_orbit_period: float = 27.3  # Days for full orbit (like Earth's moon)
@export var primary_moon_phase_offset: float = 0.0  # Initial phase offset (0-1)
@export var primary_moon_inclination: float = 5.1  # Orbit inclination in degrees
@export var primary_moon_color: Color = Color(0.9, 0.9, 0.85)  # Moon surface color
@export var primary_moon_intensity: float = 0.2  # Light intensity from moon

# Secondary moon properties
@export var secondary_moon_size: float = 750.0     # fictional smaller moon
@export var secondary_moon_orbit_period: float = 43.6  # Days for full orbit (longer than primary)
@export var secondary_moon_phase_offset: float = 0.5  # Initial phase offset (0-1)
@export var secondary_moon_inclination: float = 12.3  # Orbit inclination in degrees
@export var secondary_moon_eccentricity: float = 0.4  # Orbital eccentricity (0-1 scale)
@export var secondary_moon_color: Color = Color(0.85, 0.82, 0.75)  # Slightly different color
@export var secondary_moon_intensity: float = 0.15  # Light intensity from moon

# Stars
@export var star_count: int = 1000  # Number of stars to generate (each is its own MeshInstance3D — keep modest)
@export var milky_way_concentration: float = 0.7  # Concentration of stars along galactic plane
@export var milky_way_width: float = 30.0  # Width of the galactic plane in degrees
@export var galactic_plane_inclination: float = 60.0  # Galactic plane inclination in degrees
@export var galactic_center_direction: Vector2 = Vector2(45, 15)  # Az/Alt of galactic center in degrees

# Internal variables
var current_time: float = 23.0  # Current time in hours (0-24)
var day_phase: float = 0.0  # 0-1 representing daylight cycle
var year_phase: float = 0.0  # 0-1 representing yearly cycle
var sun_altitude: float = 0.0  # Current sun altitude angle
var sun_azimuth: float = 0.0  # Current sun azimuth angle

# Node references
var sun_light: DirectionalLight3D
var sun_mesh: MeshInstance3D
var primary_moon_light: DirectionalLight3D
var primary_moon_mesh: MeshInstance3D
var primary_moon_material: ShaderMaterial
var secondary_moon_light: DirectionalLight3D
var secondary_moon_mesh: MeshInstance3D
var secondary_moon_material: ShaderMaterial
var sky_environment: WorldEnvironment
var star_multimesh_node: MultiMeshInstance3D = null
var star_material: ShaderMaterial = null

# Orbital offsets for each celestial body (direction × orbit_radius),
# computed per frame. The mesh's world position each frame is this
# offset plus the player's world position — otherwise flying around
# shifts celestials with parallax and they feel close.
var _sun_offset: Vector3 = Vector3.ZERO
var _primary_moon_offset: Vector3 = Vector3.ZERO
var _secondary_moon_offset: Vector3 = Vector3.ZERO

# Orbit calculation variables — real-ish astronomical radii, scaled 1/1000.
var sun_orbit_radius: float = 149_600_000.0        # real: 1 AU = 149.6 Mm → 149,600 km scaled
var primary_moon_orbit_radius: float = 384_400.0   # real: 384,400 km → 384 km scaled
var secondary_moon_orbit_radius: float = 200_000.0 # fictional closer moon

func _ready():
	if typeof(World) != TYPE_NIL:
		World.register_astronomical_system(self)

	# Initialize time based on starting hour
	current_time = start_time
	year_phase = float(current_day_of_year) / planet_orbital_period

	# Create celestial objects
	initialize_sky_environment()
	create_sun()
	create_primary_moon()
	create_secondary_moon()
	create_stars()

	# Initial positioning
	update_celestial_positions(0)

func _process(delta):
	# Update time with time scale
	current_time += delta * time_scale / day_length * 24.0

	# Keep time within 24-hour range
	while current_time >= 24.0:
		current_time -= 24.0
		current_day_of_year = (current_day_of_year + 1) % int(planet_orbital_period)

	# Update day and year phases
	day_phase = current_time / 24.0
	year_phase = float(current_day_of_year) / planet_orbital_period

	# Update positions based on new time
	update_celestial_positions(delta)

	# Update lighting based on celestial positions
	update_celestial_lighting()

	# Broadcast state to anyone listening via World
	if typeof(World) != TYPE_NIL:
		World.notify_time_changed(current_time, current_day_of_year)
		World.notify_sun_direction(get_sun_direction())

func get_sun_direction() -> Vector3:
	if sun_mesh == null:
		return Vector3.DOWN
	# Direction from sun toward world origin is "where sun is shining from"
	var d: Vector3 = -sun_mesh.position
	if d.length_squared() < 1e-6:
		return Vector3.DOWN
	return d.normalized()

func initialize_sky_environment():
	# Own our WorldEnvironment as a child — no more hardcoded scene-tree
	# lookups across subsystems.
	sky_environment = WorldEnvironment.new()
	sky_environment.name = "WorldEnvironment"
	add_child(sky_environment)
	
	# Create or update environment resource
	var environment = sky_environment.environment
	if not environment:
		environment = Environment.new()
		sky_environment.environment = environment
	
	# Configure sky
	environment.background_mode = Environment.BG_SKY
	
	# Create procedural sky
	var sky = Sky.new()
	var sky_material = ProceduralSkyMaterial.new()
	
	# Configure sky parameters
	sky_material.sky_top_color = Color(0.05, 0.05, 0.1)
	sky_material.sky_horizon_color = Color(0.1, 0.1, 0.2)
	sky_material.sky_curve = 0.15
	
	sky_material.ground_bottom_color = Color(0.05, 0.05, 0.05)
	sky_material.ground_horizon_color = Color(0.1, 0.1, 0.15)
	sky_material.ground_curve = 0.15
	
	sky_material.sun_angle_max = 30.0
	sky_material.sun_curve = 0.15
	
	# Assign material to sky
	sky.sky_material = sky_material
	environment.sky = sky
	
	# Configure ambient light
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_color = Color(0.2, 0.2, 0.3)
	environment.ambient_light_energy = ambient_night_intensity
	
	# Configure tone mapping
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.0
	environment.tonemap_white = 1.0
	
	# Enable fog for atmospheric effect
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.5, 0.5, 0.8)
	environment.fog_light_energy = 0.1
	environment.fog_sun_scatter = 0.2
	environment.fog_density = 0.001
	environment.fog_sky_affect = 0.5
	
	# Configure sky for night/day transition
	#environment.sky_rotation = Vector3(0, 0, deg_to_rad(90 - latitude))
	environment.sky_rotation = Vector3(0, 0, 0)  # Reset sky rotation to default
	
func create_sun():
	# Create sun light
	sun_light = DirectionalLight3D.new()
	sun_light.name = "SunLight"
	sun_light.light_color = sun_color_day
	sun_light.light_energy = sun_intensity_day
	sun_light.shadow_enabled = true
	
	# Configure shadow parameters
	sun_light.shadow_bias = 0.03
	sun_light.directional_shadow_max_distance = 500.0
	sun_light.directional_shadow_split_1 = 0.1
	sun_light.directional_shadow_split_2 = 0.2
	sun_light.directional_shadow_split_3 = 0.5
	
	# Create sun visual mesh
	var sun_material = StandardMaterial3D.new()
	sun_material.emission_enabled = true
	sun_material.emission = sun_color_day
	sun_material.emission_energy = 5.0
	sun_material.billboard_mode = StandardMaterial3D.BILLBOARD_ENABLED
	
	var sun_sphere = SphereMesh.new()
	sun_sphere.radius = sun_size
	sun_sphere.height = sun_size * 2.0
	
	sun_mesh = MeshInstance3D.new()
	sun_mesh.name = "SunMesh"
	sun_mesh.mesh = sun_sphere
	sun_mesh.material_override = sun_material
	
	# Add to scene hierarchy
	add_child(sun_light)
	add_child(sun_mesh)

func create_primary_moon():
	# Create moon light
	primary_moon_light = DirectionalLight3D.new()
	primary_moon_light.name = "PrimaryMoonLight"
	primary_moon_light.light_color = primary_moon_color
	primary_moon_light.light_energy = 0.0  # Start with no light, will be updated based on phase
	primary_moon_light.shadow_enabled = false

	# Configure shadow parameters
	primary_moon_light.shadow_bias = 0.05
	primary_moon_light.directional_shadow_max_distance = 300.0

	# Improved moon material with physically-motivated shading
	primary_moon_material = create_moon_shader_material(primary_moon_color)

	var moon_sphere = SphereMesh.new()
	moon_sphere.radius = primary_moon_size
	moon_sphere.height = primary_moon_size * 2.0

	primary_moon_mesh = MeshInstance3D.new()
	primary_moon_mesh.name = "PrimaryMoonMesh"
	primary_moon_mesh.mesh = moon_sphere
	primary_moon_mesh.material_override = primary_moon_material
	primary_moon_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Add to scene hierarchy
	add_child(primary_moon_light)
	add_child(primary_moon_mesh)

func create_secondary_moon():
	# Create moon light
	secondary_moon_light = DirectionalLight3D.new()
	secondary_moon_light.name = "SecondaryMoonLight"
	secondary_moon_light.light_color = secondary_moon_color
	secondary_moon_light.light_energy = 0.0  # Start with no light, will be updated based on phase
	secondary_moon_light.shadow_enabled = false

	# Configure shadow parameters
	secondary_moon_light.shadow_bias = 0.05
	secondary_moon_light.directional_shadow_max_distance = 200.0

	# Improved moon material with physically-motivated shading
	secondary_moon_material = create_moon_shader_material(secondary_moon_color)

	var moon_sphere = SphereMesh.new()
	moon_sphere.radius = secondary_moon_size
	moon_sphere.height = secondary_moon_size * 2.0

	secondary_moon_mesh = MeshInstance3D.new()
	secondary_moon_mesh.name = "SecondaryMoonMesh"
	secondary_moon_mesh.mesh = moon_sphere
	secondary_moon_mesh.material_override = secondary_moon_material
	secondary_moon_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Add to scene hierarchy
	add_child(secondary_moon_light)
	add_child(secondary_moon_mesh)

func create_moon_shader_material(base_color: Color) -> ShaderMaterial:
	# All the lighting comes from EMISSION (unshaded) and we fade the
	# ALPHA with brightness so the dark side of the moon becomes
	# TRANSPARENT instead of rendering as a dark disc against the sky
	# — the previous shader did `ALBEDO = color * brightness` and the
	# shadow side came out dim-grey against bright blue, which the user
	# saw as a "black diffuse spot" during daytime.
	var shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, blend_mix;

uniform vec4 albedo_color : source_color = vec4(0.9, 0.9, 0.85, 1.0);
uniform vec3 sun_direction = vec3(0.0, 0.0, -1.0);
uniform float phase_strength = 1.0;
uniform float ambient_term = 0.1;
uniform float glow_strength = 0.6;
uniform float terminator_softness = 0.35;
uniform float visibility = 1.0;   // 0 = invisible (bright day), 1 = fully visible (night)

void fragment() {
	vec3 normal_dir = normalize(NORMAL);
	float lambert = max(dot(normal_dir, -sun_direction), 0.0);
	lambert = smoothstep(0.0, terminator_softness, lambert);
	float brightness = clamp(ambient_term + phase_strength * lambert, 0.0, 1.0);

	ALBEDO = vec3(0.0);
	EMISSION = albedo_color.rgb * (ambient_term * 0.3 + glow_strength * brightness);
	// Dark side → ALPHA near 0 → transparent. Lit side → ALPHA near 1.
	// Multiplied by visibility so the whole mesh fades during day.
	ALPHA = clamp(brightness * 2.5, 0.0, 1.0) * visibility;
}
"""

	var material = ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("albedo_color", base_color)
	return material

func create_stars():
	# Single MultiMeshInstance3D for all stars — one draw call instead of
	# star_count, one per-frame uniform update for visibility instead of
	# iterating per star. Per-star color + baked brightness encoded in
	# INSTANCE_COLOR; the shader reads it.
	var skybox_radius: float = 12000.0

	var star_mesh := SphereMesh.new()
	star_mesh.radius = 1.0         # unit-radius; per-instance transform sets actual size
	star_mesh.height = 2.0
	star_mesh.radial_segments = 6  # cheap — stars are dots at this distance
	star_mesh.rings = 3

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = star_mesh
	mm.instance_count = star_count

	for i in range(star_count):
		var in_galactic_plane: bool = randf() < milky_way_concentration
		var pos: Vector3 = random_point_on_sphere(in_galactic_plane) * skybox_radius
		var size_lo: float = 5.0 if in_galactic_plane else 3.0
		var size_hi: float = 20.0 if in_galactic_plane else 15.0
		var star_size: float = randf_range(size_lo, size_hi)

		var xf := Transform3D(Basis().scaled(Vector3.ONE * star_size), pos)
		mm.set_instance_transform(i, xf)

		var color_type: float = randf()
		var star_color: Color
		if color_type < 0.1:
			star_color = Color(0.7, 0.8, 1.0)       # Blue O/B
		elif color_type < 0.3:
			star_color = Color(1.0, 1.0, 1.0)       # White A
		elif color_type < 0.6:
			star_color = Color(1.0, 0.96, 0.84)     # Yellow F/G
		elif color_type < 0.85:
			star_color = Color(1.0, 0.8, 0.6)       # Orange K
		else:
			star_color = Color(1.0, 0.6, 0.5)       # Red M

		var brightness: float = randf_range(0.5, 1.5)
		if in_galactic_plane:
			brightness *= 1.3
		# Encode brightness in alpha channel; shader multiplies RGB by it.
		mm.set_instance_color(i, Color(star_color.r, star_color.g, star_color.b, brightness))

	star_material = _make_star_material()

	star_multimesh_node = MultiMeshInstance3D.new()
	star_multimesh_node.name = "Stars"
	star_multimesh_node.multimesh = mm
	star_multimesh_node.material_override = star_material
	star_multimesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(star_multimesh_node)

func _make_star_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
// Stars: never write depth. Material render_priority is set very low
// so they draw first (before sun/moons/terrain), while the depth
// buffer is still clear. Everything closer then draws on top of them.
render_mode unshaded, cull_disabled, depth_draw_never;

uniform float visibility : hint_range(0.0, 1.0) = 1.0;
uniform float base_energy = 5.0;

void vertex() {
	COLOR = INSTANCE_CUSTOM;
}

void fragment() {
	ALBEDO = vec3(0.0);
	float brightness = COLOR.a;
	EMISSION = COLOR.rgb * brightness * base_energy * visibility;
	ALPHA = 1.0;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	# Draw before everything else — see depth_draw_never explanation.
	mat.render_priority = -128
	return mat

func random_point_on_sphere(in_galactic_plane: bool) -> Vector3:
	if in_galactic_plane:
		# Generate points concentrated around the galactic plane
		# Using galactic coordinates
		var lon = randf_range(0, TAU)  # Galactic longitude (0-2π)
		
		# Concentrate points toward the galactic plane
		var lat_distribution = randf()
		lat_distribution = (lat_distribution * 2.0 - 1.0)  # Range -1 to 1
		lat_distribution = sign(lat_distribution) * pow(abs(lat_distribution), 3)  # Concentrate toward 0
		var lat = lat_distribution * deg_to_rad(milky_way_width / 2.0)  # Galactic latitude
		
		# Convert to Cartesian coordinates
		var x = cos(lat) * cos(lon)
		var y = cos(lat) * sin(lon)
		var z = sin(lat)
		
		# Apply galactic plane orientation
		var galactic_rotation = Quaternion(Vector3(1, 0, 0), deg_to_rad(galactic_plane_inclination))
		var galactic_rotation2 = Quaternion(Vector3(0, 1, 0), deg_to_rad(galactic_center_direction.x))
		var galactic_rotation3 = Quaternion(Vector3(1, 0, 0), deg_to_rad(90 - galactic_center_direction.y))
		
		var point = Vector3(x, z, y)  # Remap to match the expected orientation
		point = galactic_rotation.normalized() * point
		point = galactic_rotation2.normalized() * point
		point = galactic_rotation3.normalized() * point
		
		return point
	else:
		# Generate random points uniformly distributed on sphere
		var theta = randf_range(0, TAU)  # Azimuthal angle (0-2π)
		var phi = acos(2.0 * randf() - 1.0)  # Polar angle (0-π)
		
		# Convert to Cartesian coordinates
		var x = sin(phi) * cos(theta)
		var y = sin(phi) * sin(theta)
		var z = cos(phi)
		
		return Vector3(x, z, y)  # Remap for correct orientation

func update_celestial_positions(delta):
	# Calculate sun position based on time and axial tilt
	calculate_sun_position()

	# Calculate moon positions
	calculate_primary_moon_position()
	calculate_secondary_moon_position()

	# Anchor celestials to the player so they don't parallax when flying.
	_anchor_celestials_to_player()

	# Update sky environment colors based on sun position
	update_sky_colors()

func _anchor_celestials_to_player() -> void:
	var player_pos: Vector3 = Vector3.ZERO
	if typeof(World) != TYPE_NIL:
		var p = World.get_player()
		if p != null:
			player_pos = p.global_position
	if sun_mesh != null:
		sun_mesh.global_position = _sun_offset + player_pos
	if primary_moon_mesh != null:
		primary_moon_mesh.global_position = _primary_moon_offset + player_pos
	if secondary_moon_mesh != null:
		secondary_moon_mesh.global_position = _secondary_moon_offset + player_pos
	if star_multimesh_node != null:
		star_multimesh_node.global_position = player_pos

func calculate_sun_position():
	# Calculate solar position using astronomical formulae
	
	# Calculate solar declination (seasonal variation due to axial tilt)
	var day_angle = year_phase * TAU  # Converting year_phase to angle
	var declination = deg_to_rad(planet_axial_tilt) * sin(day_angle - PI/2.0)  # Peak at summer solstice
	
	# Calculate hour angle (time of day variation)
	var hour_angle = PI * (current_time / 12.0 - 1.0)  # -π at midnight, 0 at noon, π at midnight
	
	# Convert latitude to radians
	var lat_rad = deg_to_rad(latitude)
	
	# Calculate sun altitude and azimuth
	sun_altitude = asin(sin(lat_rad) * sin(declination) + cos(lat_rad) * cos(declination) * cos(hour_angle))
	
	# Calculate sun azimuth (measured from north, clockwise)
	var cos_az = (sin(declination) - sin(lat_rad) * sin(sun_altitude)) / (cos(lat_rad) * cos(sun_altitude))
	cos_az = clamp(cos_az, -1.0, 1.0)  # Ensure value is in valid range for acos
	sun_azimuth = acos(cos_az)
	
	# Adjust azimuth for afternoon (mirror across north-south line)
	if hour_angle > 0:
		sun_azimuth = TAU - sun_azimuth
	
	# Convert altitude and azimuth to 3D position (relative to player;
	# actual world position is set in _anchor_celestials_to_player).
	_sun_offset = spherical_to_cartesian(sun_azimuth, sun_altitude, sun_orbit_radius)
	sun_mesh.position = _sun_offset

	# Point sun light in the correct direction (toward origin — the
	# direction vector for a directional light is what matters, not the
	# exact position).
	sun_light.look_at_from_position(_sun_offset, Vector3.ZERO, Vector3.UP)

func calculate_primary_moon_position():
	# Calculate moon orbital position (phase)
	# Moon's position is determined by its orbital period and phase offset
		
	var moon_cycle_fraction = day_phase + (current_day_of_year / primary_moon_orbit_period) + primary_moon_phase_offset
	var moon_angle = TAU * (moon_cycle_fraction - floor(moon_cycle_fraction))	
	
	# Account for inclination
	var moon_inclination_rad = deg_to_rad(primary_moon_inclination)
	
	# Calculate moon's position in its orbital plane
	var moon_x = cos(moon_angle) * primary_moon_orbit_radius
	var moon_z = sin(moon_angle) * primary_moon_orbit_radius
	
	# Apply inclination
	var moon_y = sin(moon_angle) * sin(moon_inclination_rad) * primary_moon_orbit_radius
	
	# Store orbital offset — mesh world position is set in anchor step.
	_primary_moon_offset = Vector3(moon_x, moon_y, moon_z)
	primary_moon_mesh.position = _primary_moon_offset

	# Phase + altitude are computed from the orbital offset vectors
	# (relative to player horizon), not the world positions.
	var moon_to_sun_angle = angle_between_positions(_primary_moon_offset, _sun_offset)
	primary_moon_light.look_at_from_position(_primary_moon_offset, Vector3.ZERO, Vector3.UP)
	var moon_altitude = calculate_altitude(_primary_moon_offset)
	var moon_visibility = clamp(sin(moon_altitude) + 0.2, 0.0, 1.0)
	# Hide the moon when below the horizon so we don't render a dark
	# disc clipping through the sky dome.
	primary_moon_mesh.visible = moon_altitude > -0.03

	# Phase factor: 1 when sun and moon are opposite (full moon → bright),
	# 0 when they're aligned (new moon → dark). Earlier version used
	# (1+cos)/2 which was reversed.
	var phase_factor = (1.0 - cos(moon_to_sun_angle)) / 2.0
	# Daytime attenuation. At high sun altitude, the sky is very bright
	# and the moon washes out; fade its emission so it doesn't read as
	# a shadow on the sky.
	# Steep fade: moon practically invisible once the sun clears ~10° of
	# altitude, full brightness around and below the horizon.
	var day_dim = 1.0 - clamp(sin(sun_altitude) * 4.0, 0.0, 0.98)
	primary_moon_light.light_energy = primary_moon_intensity * phase_factor * moon_visibility * day_dim

	if primary_moon_material:
		var sun_direction = sun_mesh.position - primary_moon_mesh.position
		if sun_direction.length_squared() > 0.0001:
			primary_moon_material.set_shader_parameter("sun_direction", sun_direction.normalized())
		else:
			primary_moon_material.set_shader_parameter("sun_direction", Vector3(0, 0, -1))

		var illumination = clamp(phase_factor * moon_visibility, 0.0, 1.0)
		primary_moon_material.set_shader_parameter("phase_strength", illumination)
		var ambient_term = clamp(0.08 + 0.35 * moon_visibility, 0.05, 0.6)
		primary_moon_material.set_shader_parameter("ambient_term", ambient_term)
		# Whole-moon visibility (day fade). Separate uniform so the
		# shader can also use it for ALPHA, not just colour scaling.
		primary_moon_material.set_shader_parameter("visibility", day_dim * moon_visibility)

func calculate_secondary_moon_position():
	# Calculate secondary moon position using Kepler's laws for elliptical orbit
	var moon_cycle_fraction = day_phase + (current_day_of_year / secondary_moon_orbit_period) + secondary_moon_phase_offset
	var base_angle = TAU * (moon_cycle_fraction - floor(moon_cycle_fraction))
	# Use true anomaly calculation for elliptical orbit
	var eccentric_anomaly = base_angle
	
	# Solve Kepler's equation iteratively (simplified approximation)
	for i in range(5):  # 5 iterations should be enough for good approximation
		eccentric_anomaly = base_angle + secondary_moon_eccentricity * sin(eccentric_anomaly)
	
	# Calculate true anomaly
	var true_anomaly = 2.0 * atan2(
		sqrt(1.0 + secondary_moon_eccentricity) * sin(eccentric_anomaly / 2.0),
		sqrt(1.0 - secondary_moon_eccentricity) * cos(eccentric_anomaly / 2.0)
	)
	
	# Calculate distance based on elliptical orbit
	var distance = secondary_moon_orbit_radius * (1.0 - secondary_moon_eccentricity * cos(eccentric_anomaly))
	
	# Calculate position in orbital plane
	var moon_x = cos(true_anomaly) * distance
	var moon_z = sin(true_anomaly) * distance
	
	# Apply inclination
	var moon_inclination_rad = deg_to_rad(secondary_moon_inclination)
	var moon_y = sin(true_anomaly) * sin(moon_inclination_rad) * distance
	
	_secondary_moon_offset = Vector3(moon_x, moon_y, moon_z)
	secondary_moon_mesh.position = _secondary_moon_offset
	var moon_to_sun_angle = angle_between_positions(_secondary_moon_offset, _sun_offset)
	secondary_moon_light.look_at_from_position(_secondary_moon_offset, Vector3.ZERO, Vector3.UP)
	var moon_altitude = calculate_altitude(_secondary_moon_offset)
	var moon_visibility = clamp(sin(moon_altitude) + 0.2, 0.0, 1.0)
	secondary_moon_mesh.visible = moon_altitude > -0.03

	# Phase factor: 1 when opposite sun (full moon), 0 when aligned (new moon).
	var phase_factor = (1.0 - cos(moon_to_sun_angle)) / 2.0
	# Steep fade: moon practically invisible once the sun clears ~10° of
	# altitude, full brightness around and below the horizon.
	var day_dim = 1.0 - clamp(sin(sun_altitude) * 4.0, 0.0, 0.98)
	secondary_moon_light.light_energy = secondary_moon_intensity * phase_factor * moon_visibility * day_dim

	if secondary_moon_material:
		var sun_direction = sun_mesh.position - secondary_moon_mesh.position
		if sun_direction.length_squared() > 0.0001:
				secondary_moon_material.set_shader_parameter("sun_direction", sun_direction.normalized())
		else:
				secondary_moon_material.set_shader_parameter("sun_direction", Vector3(0, 0, -1))

		var illumination = clamp(phase_factor * moon_visibility, 0.0, 1.0)
		secondary_moon_material.set_shader_parameter("phase_strength", illumination)
		var ambient_term = clamp(0.08 + 0.35 * moon_visibility, 0.05, 0.6)
		secondary_moon_material.set_shader_parameter("ambient_term", ambient_term)
		secondary_moon_material.set_shader_parameter("visibility", day_dim * moon_visibility)

func calculate_altitude(position: Vector3) -> float:
	# Calculate altitude angle of a celestial object from the horizon
	return atan2(position.y, sqrt(position.x * position.x + position.z * position.z))

func update_sky_colors():
	# Get sky material
	var sky_material = sky_environment.environment.sky.sky_material
	
	# Calculate day/night transition factor based on sun altitude
	var day_night_factor = smoothstep(-0.1, 0.12, sin(sun_altitude))  # Smoother transition
	# Sunset/sunrise factor (strongest when sun is near horizon)
	var sunset_factor = 1.0 - abs(day_night_factor * 2.0 - 1.0)
	sunset_factor *= sunset_factor  # Square for faster falloff
	
	# Update sky colors
	var night_sky_top = Color(0.02, 0.02, 0.05)
	var day_sky_top = Color(0.3, 0.6, 0.8)
	var sunset_sky_top = Color(0.5, 0.3, 0.2)
	
	var night_horizon = Color(0.05, 0.05, 0.1)
	var day_horizon = Color(0.7, 0.8, 0.9)
	var sunset_horizon = Color(0.9, 0.6, 0.3)
	
	# Blend between day, sunset and night colors
	var sky_top = night_sky_top.lerp(day_sky_top, day_night_factor)
	sky_top = sky_top.lerp(sunset_sky_top, sunset_factor)
	
	var sky_horizon = night_horizon.lerp(day_horizon, day_night_factor)
	sky_horizon = sky_horizon.lerp(sunset_horizon, sunset_factor)
	
	# Apply colors to sky material
	sky_material.sky_top_color = sky_top
	sky_material.sky_horizon_color = sky_horizon
	
	sky_material.ground_bottom_color = Color(0.05, 0.05, 0.05)
	sky_material.ground_horizon_color = sky_horizon

	# Update ambient light with moonlight contribution at night
	var moonlight = 0.0
	if primary_moon_light:
		moonlight = max(moonlight, primary_moon_light.light_energy)
	if secondary_moon_light:
		moonlight = max(moonlight, secondary_moon_light.light_energy)

	var night_ambient = clamp(ambient_night_intensity + moonlight * 0.15, ambient_night_intensity, ambient_day_intensity)
	var ambient_intensity = lerp(night_ambient, ambient_day_intensity, day_night_factor)
	sky_environment.environment.ambient_light_energy = ambient_intensity

	# Update fog during day/night transition
	var fog_color = sky_horizon
	sky_environment.environment.fog_light_color = fog_color
	sky_environment.environment.fog_density = lerp(0.005, 0.001, day_night_factor)  # More fog at night
	
	# Update star visibility
	update_star_visibility(1.0 - day_night_factor)
	
	# Update sun color and intensity
	var sun_transition = clamp((sin(sun_altitude) + 0.1) / 0.3, 0.0, 1.0)
	sun_light.light_color = sun_color_sunset.lerp(sun_color_day, sun_transition)
	sun_light.light_energy = lerp(0.0, sun_intensity_day, sun_transition)

	# Update sun mesh material
	var sun_material = sun_mesh.material_override
	sun_material.emission = sun_light.light_color
	sun_material.emission_energy = lerp(3.0, 8.0, sun_transition)

	# Make sun visible only when above horizon
	sun_mesh.visible = sun_altitude > -0.05

func update_star_visibility(night_factor: float):
	# One uniform update covers every star — no per-star iteration.
	if star_material:
		star_material.set_shader_parameter("visibility", clamp(night_factor, 0.0, 1.0))

func update_celestial_lighting():
	# Update shadow cascade distances based on sun altitude
	# At night, reduce shadow distance for better performance
	var shadow_distance_factor = clamp(sin(sun_altitude) * 2.0, 0.3, 1.0)
	sun_light.directional_shadow_max_distance = 500.0 * shadow_distance_factor

func spherical_to_cartesian(azimuth: float, altitude: float, radius: float) -> Vector3:
	# Convert spherical coordinates to Cartesian
	# Azimuth: angle from north (clockwise), Altitude: angle from horizon
	var x = radius * cos(altitude) * sin(azimuth)
	var y = radius * sin(altitude)
	var z = radius * cos(altitude) * cos(azimuth)
	
	return Vector3(x, y, z)

func angle_between_positions(pos1: Vector3, pos2: Vector3) -> float:
	# Calculate the angle between two position vectors
	var dir1 = pos1.normalized()
	var dir2 = pos2.normalized()
	return acos(clamp(dir1.dot(dir2), -1.0, 1.0))

# Public methods for external access

func set_time(hour: float):
	# Set the current time (0-24 hours)
	current_time = clamp(hour, 0.0, 24.0)

func set_day_of_year(day: int):
	# Set the current day of the year (1-365)
	current_day_of_year = clamp(day, 0, int(planet_orbital_period) - 1)
	year_phase = float(current_day_of_year) / planet_orbital_period

func get_current_time() -> Dictionary:
	# Return current time as a dictionary
	var hours = floor(current_time)
	var minutes = floor((current_time - hours) * 60.0)
	var seconds = floor(((current_time - hours) * 60.0 - minutes) * 60.0)
	
	return {
		"hours": hours,
		"minutes": minutes, 
		"seconds": seconds,
		"day_of_year": current_day_of_year,
		"year_phase": year_phase,
		"sun_altitude": rad_to_deg(sun_altitude),
		"sun_azimuth": rad_to_deg(sun_azimuth)
	}

# Get information about sun's current illumination state
func get_sun_state() -> Dictionary:
	var sun_angle_deg = rad_to_deg(sun_altitude)
	var state = "day"
	
	if sun_angle_deg < -6:
		state = "night"
	elif sun_angle_deg < 0:
		state = "civil_twilight"
	elif sun_angle_deg < 6:
		state = "golden_hour"
		
	return {
		"state": state,
		"altitude": sun_angle_deg,
		"azimuth": rad_to_deg(sun_azimuth),
		"intensity": sun_light.light_energy,
		"day_factor": clamp((sin(sun_altitude) + 0.15) / 0.3, 0.0, 1.0)
	}

# Get information about moon phases and positions
func get_moon_state() -> Dictionary:
	# Calculate moon phases (0 = new moon, 0.5 = full moon)
	var primary_phase = (1.0 + cos(angle_between_positions(primary_moon_mesh.position, sun_mesh.position))) / 2.0
	var secondary_phase = (1.0 + cos(angle_between_positions(secondary_moon_mesh.position, sun_mesh.position))) / 2.0
	
	var primary_phase_name = get_moon_phase_name(primary_phase)
	var secondary_phase_name = get_moon_phase_name(secondary_phase)
	
	return {
		"primary_moon": {
			"phase": primary_phase,
			"phase_name": primary_phase_name,
			"altitude": rad_to_deg(calculate_altitude(primary_moon_mesh.position)),
			"azimuth": rad_to_deg(atan2(primary_moon_mesh.position.x, primary_moon_mesh.position.z)),
			"intensity": primary_moon_light.light_energy,
			"visible": primary_moon_light.light_energy > 0.01
		},
		"secondary_moon": {
			"phase": secondary_phase,
			"phase_name": secondary_phase_name,
			"altitude": rad_to_deg(calculate_altitude(secondary_moon_mesh.position)),
			"azimuth": rad_to_deg(atan2(secondary_moon_mesh.position.x, secondary_moon_mesh.position.z)),
			"intensity": secondary_moon_light.light_energy,
			"visible": secondary_moon_light.light_energy > 0.01
		}
	}

# Get name of moon phase
func get_moon_phase_name(phase: float) -> String:
	if phase < 0.01:
		return "New Moon"
	elif phase < 0.25:
		return "Waxing Crescent"
	elif phase < 0.26:
		return "First Quarter"
	elif phase < 0.49:
		return "Waxing Gibbous"
	elif phase < 0.51:
		return "Full Moon"
	elif phase < 0.75:
		return "Waning Gibbous"
	elif phase < 0.76:
		return "Last Quarter"
	else:
		return "Waning Crescent"

# Set time scale (speed of day-night cycle)
func set_time_scale(scale: float):
	time_scale = max(0.0, scale)

# Set season manually
func set_season(season_name: String):
	match season_name.to_lower():
		"spring":
			current_day_of_year = int(planet_orbital_period * 0.2)
		"summer":
			current_day_of_year = int(planet_orbital_period * 0.4)
		"fall", "autumn":
			current_day_of_year = int(planet_orbital_period * 0.7)
		"winter":
			current_day_of_year = int(planet_orbital_period * 0.9)
	
	year_phase = float(current_day_of_year) / planet_orbital_period

# Pause time progression
func pause_time():
	time_scale = 0.0

# Resume time progression with previous time scale
func resume_time(scale: float = -1.0):
	if scale > 0.0:
		time_scale = scale
	elif time_scale == 0.0:
		time_scale = 1.0
