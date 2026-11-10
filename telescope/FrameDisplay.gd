extends RefCounted
## FrameDisplay — turns a float CCD frame into a viewable Image.
##
## zscale-ish limits (median and MAD-based sigma from a pixel sample)
## followed by an asinh stretch, so faint field stars and a bright
## target both show. Row 0 of the frame is the bottom (FITS), so the
## image is flipped to put north up on screen.

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

static func to_image(img: PackedFloat32Array, n: int, full_well: float) -> Image:
	var st: Vector2 = stats(img)
	var med: float = st.x
	var sig: float = maxf(st.y, 1.0)
	var black: float = med - 2.0 * sig
	var white: float = minf(med + 400.0 * sig, full_well)
	var soft: float = 4.0 * sig
	var norm: float = 1.0 / _asinh(maxf(white - black, 1.0) / soft)
	var bytes := PackedByteArray()
	bytes.resize(n * n)
	var blown: bool = med >= full_well * 0.95
	for y in n:
		var src: int = (n - 1 - y) * n
		var dst: int = y * n
		for x in n:
			var v: float
			if blown:
				v = 1.0
			else:
				v = clampf(_asinh(maxf(img[src + x] - black, 0.0) / soft) * norm, 0.0, 1.0)
			bytes[dst + x] = int(v * 255.0)
	return Image.create_from_data(n, n, false, Image.FORMAT_L8, bytes)

static func _asinh(x: float) -> float:
	return log(x + sqrt(x * x + 1.0))
