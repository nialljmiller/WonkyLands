extends RefCounted
## FrameDisplay — how a float CCD frame is shown.
##
## The raw electrons go to the GPU as a 32-bit float texture (flipped
## so north is up: row 0 of the frame is the bottom, FITS-style). A small
## shader does the stretch, so changing asinh / linear / log or the
## brightness costs nothing. Levels are zscale-ish: median and MAD sigma
## from a pixel sample. Saturated pixels are tinted red.

const SHADER := """
shader_type canvas_item;
uniform float black = 0.0;
uniform float white = 1.0;
uniform float soft = 1.0;
uniform float full_well = 100000.0;
uniform int mode = 0;          // 0 asinh, 1 linear, 2 log
uniform float gain = 1.0;      // brightness: >1 brighter
uniform bool blown = false;
float ash(float x) { return log(x + sqrt(x * x + 1.0)); }
void fragment() {
	float e = texture(TEXTURE, UV).r;
	float x = max(e - black, 0.0);
	float w = max(white - black, 1.0) / gain;
	float v;
	if (mode == 0) v = ash(x / soft) / ash(w / soft);
	else if (mode == 1) v = x / w;
	else v = log(1.0 + 1000.0 * x / w) / log(1001.0);
	v = blown ? 1.0 : clamp(v, 0.0, 1.0);
	vec3 c = vec3(v);
	if (!blown && e >= full_well * 0.999) c = vec3(1.0, 0.25, 0.2);
	COLOR = vec4(c, 1.0);
}
"""

static func stats(img: PackedFloat32Array) -> Vector2:
	var sample := PackedFloat32Array()
	var step: int = maxi(1, img.size() / 4096)
	for k in range(0, img.size(), step):
		sample.append(img[k])
	sample.sort()
	var med: float = sample[sample.size() / 2]
	var dev := PackedFloat32Array()
	dev.resize(sample.size())
	for k in sample.size():
		dev[k] = absf(sample[k] - med)
	dev.sort()
	return Vector2(med, 1.4826 * dev[dev.size() / 2])

## Stretch limits for the shader.
static func levels(img: PackedFloat32Array, full_well: float) -> Dictionary:
	var st: Vector2 = stats(img)
	var sig: float = maxf(st.y, 1.0)
	return {"black": st.x - 2.0 * sig, "white": minf(st.x + 400.0 * sig, full_well),
		"soft": 4.0 * sig, "blown": st.x >= full_well * 0.95}

## North-up float image (safe on a worker thread).
static func float_image(img: PackedFloat32Array, n: int) -> Image:
	var im := Image.create_from_data(n, n, false, Image.FORMAT_RF, img.to_byte_array())
	im.flip_y()
	return im
