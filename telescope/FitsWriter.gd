extends RefCounted
## FitsWriter — minimal FITS (BITPIX = −32) image writer.
##
## Header: 80-character ASCII cards, END, space-padded to 2880 bytes.
## Data: big-endian IEEE float32, row 1 = bottom (our frames already
## are), zero-padded to 2880 bytes.

const BLOCK: int = 2880

static func card(key: String, value, comment: String = "") -> String:
	var v: String
	match typeof(value):
		TYPE_STRING:
			v = ("'%s'" % String(value).replace("'", "''")).rpad(20)
		TYPE_BOOL:
			v = ("T" if value else "F").lpad(20)
		TYPE_INT:
			v = str(value).lpad(20)
		_:
			var t: String = String.num(float(value), 10)
			if not ("." in t or "e" in t):
				t += ".0"
			v = t.to_upper().lpad(20)
	var s: String = key.to_upper().rpad(8).substr(0, 8) + "= " + v
	if comment != "":
		s += " / " + comment
	return s.rpad(80).substr(0, 80)

## cards: Array of [key, value, comment].
static func write(path: String, img: PackedFloat32Array, n: int, cards: Array) -> Error:
	var hdr: String = card("SIMPLE", true, "conforms to FITS standard")
	hdr += card("BITPIX", -32, "IEEE single precision")
	hdr += card("NAXIS", 2)
	hdr += card("NAXIS1", n)
	hdr += card("NAXIS2", n)
	for c in cards:
		hdr += card(c[0], c[1], c[2] if c.size() > 2 else "")
	hdr += "END".rpad(80)
	while hdr.length() % BLOCK != 0:
		hdr += " "
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(hdr.to_ascii_buffer())
	f.big_endian = true
	for v in img:
		f.store_float(v)
	var pad: int = (BLOCK - (img.size() * 4) % BLOCK) % BLOCK
	var zeros := PackedByteArray()
	zeros.resize(pad)
	f.store_buffer(zeros)
	f.close()
	return OK
