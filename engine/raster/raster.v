module raster

// A software rasterizer that composites into a flat RGBA buffer.
//
// Everything the engine draws ends up here: box backgrounds, borders, glyph
// coverage, decoded images. Nothing here knows what HTML or CSS is, and nothing
// here opens a window, so a page can be rendered and checked with no graphics
// driver, no event loop and no display.
//
// Two decisions are deliberate and everything else follows from them.
//
// Colour is premultiplied. A straight-alpha buffer needs a different blend
// formula per operation and gets its edges wrong when alpha is low; with
// premultiplied alpha, source-over is one expression that is correct for every
// blend and composes associatively, which is what lets a glyph be blended onto
// a box that is itself already composited onto the page. `Color.r` is the
// channel value multiplied by `Color.a`, so an opaque colour is one where r, g
// and b are already what they look like.
//
// Arithmetic is integer. Every blend is exact integer arithmetic with an
// explicit rounding step, and every rectangle is given as an integer position
// and size. This is not only faster than float for this workload; it is what
// makes a golden-image test able to compare bytes rather than a tolerance.
// A float accumulator would produce a different byte on a different compiler, or
// after an unrelated change to the order of operations, and a test that has to
// tolerate that is not testing the thing it was written for.

// Color is a premultiplied RGBA colour. Because it is premultiplied, an opaque
// colour is one where r, g and b already hold what they look like, and a
// translucent one satisfies r, g, b <= a. Do not construct one by hand with
// translucent channels: use rgba(), which premultiplies for you.
pub struct Color {
pub:
	r u8
	g u8
	b u8
	a u8
}

pub const white = Color{255, 255, 255, 255}
pub const black = Color{0, 0, 0, 255}
pub const transparent = Color{0, 0, 0, 0}
pub const red = Color{255, 0, 0, 255}
pub const green = Color{0, 255, 0, 255}
pub const blue = Color{0, 0, 255, 255}

// rgb builds an opaque colour.
pub fn rgb(r int, g int, b int) Color {
	return Color{u8(clamp255(r)), u8(clamp255(g)), u8(clamp255(b)), 255}
}

// rgba builds a colour with an explicit alpha, premultiplying as it goes so the
// result satisfies r <= a.
pub fn rgba(r int, g int, b int, a int) Color {
	aa := u8(clamp255(a))
	return Color{u8(clamp255(r * int(aa) / 255)), u8(clamp255(g * int(aa) / 255)), u8(clamp255(b * int(aa) / 255)), aa}
}

@[inline]
fn clamp255(v int) int {
	if v < 0 {
		return 0
	}
	if v > 255 {
		return 255
	}
	return v
}

// unpremultiply returns the straight-alpha channels, for handing a pixel to an
// API that expects them (a PNG writer, for instance).
pub fn (c Color) unpremultiply() [4]u8 {
	if c.a == 0 {
		return [u8(0), u8(0), u8(0), u8(0)]
	}
	if c.a == 255 {
		return [c.r, c.g, c.b, c.a]
	}
	return [
		u8(clamp255((int(c.r) * 255 + int(c.a) / 2) / int(c.a))),
		u8(clamp255((int(c.g) * 255 + int(c.a) / 2) / int(c.a))),
		u8(clamp255((int(c.b) * 255 + int(c.a) / 2) / int(c.a))),
		c.a,
	]
}

// Canvas is an RGBA pixel buffer with premultiplied colour and a stride in
// bytes. Rows are contiguous and top-down.
pub struct Canvas {
pub mut:
	width  int
	height int
	pix    []u8
}

pub fn new_canvas(width int, height int) &Canvas {
	w := if width < 0 { 0 } else { width }
	h := if height < 0 { 0 } else { height }
	return &Canvas{
		width:  w
		height: h
		pix:    []u8{len: w * h * 4}
	}
}

pub fn (c &Canvas) stride() int {
	return c.width * 4
}

// at returns the premultiplied pixel at x, y, or transparent if it is outside
// the canvas. Callers should prefer fill_rect and blend_bitmap; this exists for
// tests and for the case where a box collapses to a single pixel.
pub fn (c &Canvas) at(x int, y int) Color {
	if x < 0 || y < 0 || x >= c.width || y >= c.height {
		return transparent
	}
	o := (y * c.width + x) * 4
	return Color{c.pix[o], c.pix[o + 1], c.pix[o + 2], c.pix[o + 3]}
}

pub fn (mut c Canvas) set(x int, y int, col Color) {
	if x < 0 || y < 0 || x >= c.width || y >= c.height {
		return
	}
	o := (y * c.width + x) * 4
	c.pix[o] = col.r
	c.pix[o + 1] = col.g
	c.pix[o + 2] = col.b
	c.pix[o + 3] = col.a
}

// clear fills the whole canvas, ignoring the clip.
pub fn (mut c Canvas) clear(col Color) {
	mut i := 0
	for i < c.pix.len {
		c.pix[i] = col.r
		c.pix[i + 1] = col.g
		c.pix[i + 2] = col.b
		c.pix[i + 3] = col.a
		i += 4
	}
}

// fill_rect composites an axis-aligned rectangle. Coordinates and size are
// integers, so a box at a fractional CSS position is rounded once by the
// caller rather than accumulating error through the whole tree.
pub fn (mut c Canvas) fill_rect(x int, y int, w int, h int, col Color) {
	if w <= 0 || h <= 0 || col.a == 0 {
		return
	}
	x0, y0, x1, y1 := c.clip(x, y, w, h)
	mut row := y0 * c.width
	mut yy := y0
	for yy < y1 {
		mut xx := x0
		mut o := (row + xx) * 4
		for xx < x1 {
			c.blend_at(o, col)
			xx++
			o += 4
		}
		row += c.width
		yy++
	}
}

// blend_bitmap composites an 8-bit coverage bitmap tinted with a single colour.
// This is how text is drawn: vtext returns one coverage byte per glyph pixel,
// never a colour, and a glyph is composited exactly once per pixel it covers.
// `stride` is in bytes and may exceed width for a source that is padded.
pub fn (mut c Canvas) blend_bitmap(x int, y int, w int, h int, stride int, coverage []u8, col Color) {
	if w <= 0 || h <= 0 || col.a == 0 {
		return
	}
	x0, y0, x1, y1 := c.clip(x, y, w, h)
	mut yy := y0
	for yy < y1 {
		sy := yy - y
		if sy >= h {
			break
		}
		so := sy * stride
		mut xx := x0
		mut o := (yy * c.width + xx) * 4
		for xx < x1 {
			sx := xx - x
			if sx >= w {
				break
			}
			cov := coverage[so + sx]
			if cov != 0 {
				c.blend_at(o, tint(col, cov))
			}
			xx++
			o += 4
		}
		yy++
	}
}

// tint scales a colour's alpha by a coverage byte, keeping it premultiplied.
@[inline]
fn tint(col Color, cov u8) Color {
	a := int(col.a) * int(cov) / 255
	if a == 0 {
		return transparent
	}
	// col is already premultiplied by its own alpha, so scaling alpha means
	// scaling the channels by the same factor.
	return Color{u8(int(col.r) * a / int(col.a)), u8(int(col.g) * a / int(col.a)), u8(int(col.b) * a / int(col.a)), u8(a)}
}

// blend_at composites one premultiplied source pixel into the buffer at byte
// offset o. This is source-over: dst = src + dst * (1 - src.a).
//
// The division rounds to nearest rather than truncating, because truncating
// biases every composite slightly dark and the error shows up as a visible
// seam along a long run of adjacent glyphs, where the same background is
// blended over and over.
@[inline]
fn (mut c Canvas) blend_at(o int, src Color) {
	if src.a == 255 {
		c.pix[o] = src.r
		c.pix[o + 1] = src.g
		c.pix[o + 2] = src.b
		c.pix[o + 3] = 255
		return
	}
	if src.a == 0 {
		return
	}
	ia := 255 - int(src.a)
	c.pix[o] = u8(int(src.r) + (int(c.pix[o]) * ia + 127) / 255)
	c.pix[o + 1] = u8(int(src.g) + (int(c.pix[o + 1]) * ia + 127) / 255)
	c.pix[o + 2] = u8(int(src.b) + (int(c.pix[o + 2]) * ia + 127) / 255)
	c.pix[o + 3] = u8(int(src.a) + (int(c.pix[o + 3]) * ia + 127) / 255)
}

// clip intersects a rectangle with the canvas and returns it as x0, y0, x1, y1
// half-open bounds. Clipping here rather than at every call site is what keeps
// the fill loops free of bounds checks.
fn (c &Canvas) clip(x int, y int, w int, h int) (int, int, int, int) {
	x0 := if x < 0 { 0 } else { x }
	y0 := if y < 0 { 0 } else { y }
	mut x1 := x + w
	mut y1 := y + h
	if x1 > c.width {
		x1 = c.width
	}
	if y1 > c.height {
		y1 = c.height
	}
	if x1 <= x0 || y1 <= y0 {
		return 0, 0, 0, 0
	}
	return x0, y0, x1, y1
}

// write_png saves the canvas. This is how a page is looked at during
// development and how a golden test is compared, and it is the only output the
// engine has until a window shell is attached in a later phase.
pub fn (c &Canvas) write_png(path string) ! {
	nbytes := c.width * c.height * 4
	mut straight := []u8{len: nbytes}
	mut o := 0
	for o < nbytes {
		px := Color{c.pix[o], c.pix[o + 1], c.pix[o + 2], c.pix[o + 3]}.unpremultiply()
		straight[o] = px[0]
		straight[o + 1] = px[1]
		straight[o + 2] = px[2]
		straight[o + 3] = px[3]
		o += 4
	}
	write_png_rgba(path, c.width, c.height, straight, c.stride())!
}
