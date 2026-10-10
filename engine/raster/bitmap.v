module raster

// A decoded image, in this module's own convention.
//
// The whole point of the type is the conversion, and the conversion happens in
// one function. Every decoder in the world hands back straight alpha -- the
// channel values as they were stored, with the alpha alongside them -- while
// this module's buffers are premultiplied (see the comment at the top of
// raster.v). A bitmap that arrived straight and was composited as if it were
// premultiplied would brighten every translucent pixel by exactly the amount of
// alpha it lost, which on a logo with a soft edge is a white halo.
//
// So `from_straight_rgba` is the only door, and the tests for it are in
// bitmap_test.v rather than next to the caller that happened to decode.

// Bitmap is premultiplied RGBA, tightly packed, top-down. `pix` is exactly
// width * height * 4 bytes long; a source that is padded is converted here
// rather than carried around with a stride, because tiling wants to index the
// row directly.
@[heap]
pub struct Bitmap {
pub mut:
	width  int
	height int
	pix    []u8
}

// new_bitmap makes a fully transparent bitmap of the given size. A negative
// dimension is clamped to zero rather than turned into a negative length, which
// would panic on allocation.
pub fn new_bitmap(width int, height int) &Bitmap {
	w := if width < 0 { 0 } else { width }
	h := if height < 0 { 0 } else { height }
	return &Bitmap{ width: w, height: h, pix: []u8{len: w * h * 4} }
}

// from_straight_rgba converts straight-alpha RGBA into a premultiplied bitmap.
//
// `src_stride` is the source row length in bytes, which may exceed width * 4 for
// a padded image. The arithmetic is `rgba`'s, so a pixel that came out of a
// decoder is the same colour as the same pixel written by hand.
//
// A source that is too short yields an empty bitmap rather than a panic. The one
// caller is a decoder, and a decode that lies about its own dimensions is a bug
// to report; an out-of-bounds read in the middle of a composite is a crash that
// says nothing.
pub fn from_straight_rgba(width int, height int, src []u8, src_stride int) &Bitmap {
	mut out := new_bitmap(width, height)
	if out.width <= 0 || out.height <= 0 {
		return out
	}
	// A stride narrower than a row would put row N's start inside row N-1, so the
	// wider of the two is used and the loop below reads whole rows of `src`.
	stride := if src_stride >= out.width * 4 { src_stride } else { out.width * 4 }
	if src.len < out.height * stride {
		return new_bitmap(0, 0)
	}
	mut y := 0
	for y < out.height {
		mut so := y * stride
		mut d := y * out.width * 4
		mut x := 0
		for x < out.width {
			a := int(src[so + 3])
			out.pix[d] = u8(clamp255(int(src[so]) * a / 255))
			out.pix[d + 1] = u8(clamp255(int(src[so + 1]) * a / 255))
			out.pix[d + 2] = u8(clamp255(int(src[so + 2]) * a / 255))
			out.pix[d + 3] = u8(a)
			so += 4
			d += 4
			x++
		}
		y++
	}
	return out
}

// blend_image composites one bitmap into a destination rectangle, clipped to the
// canvas.
//
// The destination size is not the bitmap's own: `background-size` scales the tile,
// and the display list records the size the caller asked for while this is where it
// becomes pixels. Scaling is nearest-neighbour in integer arithmetic, so the same
// source and the same destination give the same bytes on every run -- the property
// ARCHITECTURE.md 3 asks of everything a golden test looks at. A filtered resample
// would look better and would be a second opinion about what a pixel is.
//
// An opaque row is a copy and a row with alpha is source-over, which is what
// blend_at already is, so there is no second blend formula here to drift.
pub fn (mut c Canvas) blend_image(x int, y int, dest_w int, dest_h int, bm &Bitmap) {
	c.blend_image_clipped(x, y, dest_w, dest_h, 0, 0, c.width, c.height, bm)
}

// blend_image_clipped is blend_image clipped to a rectangle instead of to the
// whole canvas. blend_image_area calls it with the background's own box, because a
// tile that `background-size` has grown past the box must be cut off there rather
// than land on whatever the next box down happens to be.
//
// clip_rect's result is inside the tile on both axes, so mapping a destination
// pixel back onto the source needs no bounds check: the sample index is below the
// bitmap's own width and height by construction.
fn (mut c Canvas) blend_image_clipped(x int, y int, dest_w int, dest_h int, cx int, cy int, cw int, ch int, bm &Bitmap) {
	if dest_w <= 0 || dest_h <= 0 || bm.width <= 0 || bm.height <= 0 {
		return
	}
	x0, y0, x1, y1 := c.clip_rect(x, y, dest_w, dest_h, cx, cy, cw, ch)
	mut yy := y0
	for yy < y1 {
		sy := (yy - y) * bm.height / dest_h
		so := sy * bm.width * 4
		mut xx := x0
		mut o := (yy * c.width + xx) * 4
		for xx < x1 {
			s := so + (xx - x) * bm.width / dest_w * 4
			a := int(bm.pix[s + 3])
			if a == 255 {
				// A fully opaque source replaces the destination outright, which is
				// both the fast path and the exact one: source-over with alpha 255
				// degenerates to a copy.
				c.pix[o] = bm.pix[s]
				c.pix[o + 1] = bm.pix[s + 1]
				c.pix[o + 2] = bm.pix[s + 2]
				c.pix[o + 3] = 255
			} else if a != 0 {
				c.blend_at(o, Color{ r: bm.pix[s], g: bm.pix[s + 1], b: bm.pix[s + 2], a: u8(a) })
			}
			xx++
			o += 4
		}
		yy++
	}
}

// clip_rect intersects a rectangle with a clipping rectangle and with the canvas,
// and returns it as x0, y0, x1, y1 half-open bounds. The result is a subrange of the
// rectangle on both axes, which is what lets a caller map a destination pixel back
// onto a source without a bounds check.
fn (c &Canvas) clip_rect(x int, y int, w int, h int, cx int, cy int, cw int, ch int) (int, int, int, int) {
	mut x0 := if x > cx { x } else { cx }
	mut y0 := if y > cy { y } else { cy }
	mut x1 := if x + w < cx + cw { x + w } else { cx + cw }
	mut y1 := if y + h < cy + ch { y + h } else { cy + ch }
	if y1 > c.height {
		y1 = c.height
	}
	if x1 > c.width {
		x1 = c.width
	}
	if x1 <= x0 || y1 <= y0 {
		return 0, 0, 0, 0
	}
	return x0, y0, x1, y1
}

// blend_image_area tiles a bitmap across a rectangle.
//
// Tiling is here rather than in the display list because the list is the plan: a
// repeating background is one image command that says where the first tile goes,
// and the number of tiles is a question about the target, not about the page. A
// list that held the tiles would be thousands of commands describing one
// decision, and every test that counted them would be counting the canvas.
//
// `ox`, `oy`, `tile_w`, `tile_h` is the first tile's destination rectangle -- the
// size `background-size` resolved to, not the bitmap's own. When an axis repeats,
// earlier tiles are found by stepping back from there, because CSS puts the
// position at the *origin of the pattern* rather than at the left-most visible
// tile: a centred repeating background tiles outwards in both directions.
pub fn (mut c Canvas) blend_image_area(x int, y int, w int, h int, ox int, oy int, tile_w int, tile_h int, bm &Bitmap, repeat_x bool, repeat_y bool) {
	if w <= 0 || h <= 0 || tile_w <= 0 || tile_h <= 0 || bm.width <= 0 || bm.height <= 0 {
		return
	}
	mut sx := ox
	mut sy := oy
	if repeat_x {
		sx = ox + floor_div(x - ox, tile_w) * tile_w
	}
	if repeat_y {
		sy = oy + floor_div(y - oy, tile_h) * tile_h
	}
	mut ty := sy
	for ty < y + h {
		mut tx := sx
		for tx < x + w {
			// The tile is clipped to the area and not only to the canvas: `cover`
			// grows the image past the box, and the background painting area is the
			// box, so the overflow must not land on the box below it.
			c.blend_image_clipped(tx, ty, tile_w, tile_h, x, y, w, h, bm)
			// One tile on a non-repeating axis, however far the loop would otherwise
			// walk: `no-repeat` means exactly one tile, and `repeat-x` means one row.
			if !repeat_x {
				break
			}
			tx += tile_w
		}
		if !repeat_y {
			break
		}
		ty += tile_h
	}
}

// floor_div divides toward negative infinity.
//
// C's integer division truncates toward zero, so a positioned repeating
// background whose origin is to the right of the visible area would find its
// first tile *to the right of the origin* and leave everything left of it the
// background colour. `test_blend_image_area_tiles_leftwards_from_a_centred_origin`
// is the case that catches it.
fn floor_div(a int, b int) int {
	mut q := a / b
	if a % b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}
