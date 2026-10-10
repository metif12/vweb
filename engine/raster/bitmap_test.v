module raster

// Tests for the bitmap path: the premultiplied conversion, the row-copy
// primitive, and the tiling loop. The invariant the rest of this module's tests
// keep -- r <= a (ARCHITECTURE.md 2) -- gets its sharpest test here, because a
// bitmap is the first source of pixels that arrives from outside the module
// already holding an alpha channel.

fn solid_bitmap(w int, h int, col Color) &Bitmap {
	mut src := []u8{len: w * h * 4}
	mut i := 0
	for i < w * h {
		src[i * 4] = col.r
		src[i * 4 + 1] = col.g
		src[i * 4 + 2] = col.b
		src[i * 4 + 3] = 255
		i++
	}
	return from_straight_rgba(w, h, src, w * 4)
}

// corner_bitmap is a 2x2 with one opaque pixel at (0,0) and nothing else, so a
// tiling test can count tiles by counting coloured pixels.
fn corner_bitmap() &Bitmap {
	mut src := []u8{len: 2 * 2 * 4}
	src[0] = 255
	src[1] = 255
	src[2] = 255
	src[3] = 255
	return from_straight_rgba(2, 2, src, 8)
}

// --- the premultiplied conversion --------------------------------------------

fn test_from_straight_rgba_premultiplies_every_channel() {
	mut src := []u8{len: 2 * 4}
	src[0] = 255
	src[1] = 0
	src[2] = 0
	src[3] = 128
	src[4] = 0
	src[5] = 0
	src[6] = 255
	src[7] = 255
	bm := from_straight_rgba(2, 1, src, 8)
	assert bm.width == 2
	assert bm.height == 1
	// Half-transparent red is (128, 0, 0, 128), not (255, 0, 0, 128): the channels
	// are already multiplied by the alpha, which is the whole convention.
	assert bm.pix == [u8(128), 0, 0, 128, 0, 0, 255, 255]
}

fn test_from_straight_rgba_leaves_an_opaque_image_alone() {
	// Alpha 255 is a no-op multiply, so an opaque image must come through byte for
	// byte. This is what makes an opaque PNG a copy rather than a recolour.
	src := [u8(200), 100, 50, 255, 0, 0, 0, 255]
	bm := from_straight_rgba(2, 1, src, 8)
	assert bm.pix == src
}

fn test_from_straight_rgba_respects_a_padded_source_stride() {
	// Two rows of two pixels, padded to twelve bytes each. The padding must not
	// be read as pixels: a stride taken as width * 4 would shift row 1 left by
	// four bytes and drop its last pixel.
	mut src := []u8{len: 2 * 12}
	// row 0: red, green, then four bytes of padding
	src[0] = 255
	src[3] = 255
	src[4] = 0
	src[5] = 255
	src[7] = 255
	src[8] = 9
	src[9] = 9
	src[10] = 9
	src[11] = 9
	// row 1: white, black, padding
	src[12] = 255
	src[13] = 255
	src[14] = 255
	src[15] = 255
	src[16] = 0
	src[19] = 255
	src[20] = 9
	src[21] = 9
	src[22] = 9
	src[23] = 9
	bm := from_straight_rgba(2, 2, src, 12)
	assert bm.pix.len == 2 * 2 * 4
	assert bm.pix == [u8(255), 0, 0, 255, 0, 255, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255]
}

fn test_from_straight_rgba_refuses_a_source_that_is_too_short() {
	// A decoder that lies about its own dimensions is a bug to report; an
	// out-of-bounds read in the middle of a composite is a crash that says
	// nothing. So the answer is an empty bitmap and no image.
	bm := from_straight_rgba(4, 4, [u8(1), u8(2)], 16)
	assert bm.width == 0
	assert bm.height == 0
	assert bm.pix.len == 0
}

fn test_from_straight_rgba_of_nothing_is_empty() {
	bm := from_straight_rgba(0, 0, []u8{}, 0)
	assert bm.width == 0
	assert bm.pix.len == 0
}

// --- the row-copy primitive --------------------------------------------------

fn test_blend_image_an_opaque_bitmap_is_a_row_copy() {
	mut c := new_canvas(3, 2)
	c.clear(black)
	bm := solid_bitmap(3, 2, rgb(200, 100, 50))
	c.blend_image(0, 0, bm.width, bm.height, bm)
	for y in 0 .. 2 {
		for x in 0 .. 3 {
			assert c.at(x, y) == rgb(200, 100, 50)
		}
	}
}

fn test_blend_image_a_translucent_bitmap_is_source_over() {
	mut c := new_canvas(1, 1)
	c.clear(white)
	// Straight alpha: red at half opacity. The conversion multiplies, so the
	// bitmap holds (128, 0, 0, 128) -- which is the same colour `rgba` builds and
	// what the blend below expects.
	mut src := [u8(255), 0, 0, 128]
	bm := from_straight_rgba(1, 1, src, 4)
	c.blend_image(0, 0, bm.width, bm.height, bm)
	// Source-over can only add: white already has 255 red, so red saturates at
	// 255 and the half alpha halves the two channels white had and red did not.
	// `blend_at`'s rounding is to nearest, so 127 rather than 128.
	assert c.at(0, 0) == Color{ r: 255, g: 127, b: 127, a: 255 }
}

fn test_blend_image_a_transparent_pixel_leaves_the_destination() {
	mut c := new_canvas(1, 1)
	c.clear(white)
	mut src := [u8(0), 0, 0, 0]
	bm := from_straight_rgba(1, 1, src, 4)
	c.blend_image(0, 0, bm.width, bm.height, bm)
	assert c.at(0, 0) == white
}

fn test_blend_image_keeps_the_premultiplied_invariant() {
	// r <= a, for every pixel, over a coloured destination. A bitmap is where the
	// invariant could break: it arrives from a decoder holding straight alpha,
	// and if the conversion did not multiply, every translucent pixel here would
	// come out brighter than its own alpha.
	mut c := new_canvas(8, 1)
	c.clear(rgb(10, 200, 90))
	mut src := []u8{len: 8 * 4}
	mut i := 0
	for i < 8 {
		src[i * 4] = 250
		src[i * 4 + 1] = 10
		src[i * 4 + 2] = 128
		src[i * 4 + 3] = u8(i * 30)
		i++
	}
	bm := from_straight_rgba(8, 1, src, 32)
	c.blend_image(0, 0, bm.width, bm.height, bm)
	for x in 0 .. 8 {
		px := c.at(x, 0)
		assert px.r <= px.a
		assert px.g <= px.a
		assert px.b <= px.a
	}
}

fn test_blend_image_clips_at_the_canvas_edges() {
	mut c := new_canvas(2, 2)
	c.clear(black)
	bm := solid_bitmap(4, 4, white)
	c.blend_image(-2, -2, bm.width, bm.height, bm)
	for y in 0 .. 2 {
		for x in 0 .. 2 {
			assert c.at(x, y) == white
		}
	}
	assert c.pix.len == 2 * 2 * 4
}

fn test_blend_image_entirely_off_canvas_changes_nothing() {
	mut c := new_canvas(2, 2)
	c.clear(black)
	bm := solid_bitmap(4, 4, white)
	c.blend_image(100, 100, bm.width, bm.height, bm)
	c.blend_image(-100, -100, bm.width, bm.height, bm)
	assert c.at(0, 0) == black
}

// --- scaling ------------------------------------------------------------------

fn test_blend_image_at_the_source_size_is_an_exact_copy() {
	// Nearest-neighbour with equal sizes is the identity, so a background whose
	// `background-size` is `auto` must be byte for byte the source.
	mut c := new_canvas(3, 2)
	c.clear(black)
	bm := solid_bitmap(3, 2, rgb(200, 100, 50))
	c.blend_image(0, 0, 3, 2, bm)
	for y in 0 .. 2 {
		for x in 0 .. 3 {
			assert c.at(x, y) == rgb(200, 100, 50)
		}
	}
}

// two_colour_row is a 2x1 opaque image of red then blue, so a scaling test can
// tell which half of the destination came from which source pixel.
fn two_colour_row() &Bitmap {
	mut src := []u8{len: 2 * 4}
	src[0] = 255
	src[3] = 255
	src[6] = 255
	src[7] = 255
	return from_straight_rgba(2, 1, src, 8)
}

fn test_blend_image_scales_up_by_nearest_neighbour() {
	// A 2x1 tile drawn 6 wide: the destination splits into two halves, one per
	// source pixel. `background-size` has to reach the pixels and not only the
	// display list.
	mut c := new_canvas(6, 1)
	c.clear(black)
	bm := two_colour_row()
	c.blend_image(0, 0, 6, 1, bm)
	assert c.at(0, 0) == red
	assert c.at(2, 0) == red
	assert c.at(3, 0) == blue
	assert c.at(5, 0) == blue
}

fn test_blend_image_scales_down_by_nearest_neighbour() {
	// A 4x1 tile drawn 2 wide takes source pixels 0 and 2 -- 1*4/2 is 2 -- so the
	// two destinations are the first and third source pixel, red and blue, rather
	// than a blend of all four.
	mut c := new_canvas(2, 1)
	c.clear(black)
	mut src := []u8{len: 4 * 4}
	src[0] = 255
	src[3] = 255
	src[4] = 0
	src[5] = 255
	src[7] = 255
	src[8] = 0
	src[9] = 0
	src[10] = 255
	src[11] = 255
	src[12] = 255
	src[15] = 255
	bm := from_straight_rgba(4, 1, src, 16)
	c.blend_image(0, 0, 2, 1, bm)
	assert c.at(0, 0) == red
	assert c.at(1, 0) == blue
}

fn test_blend_image_a_scaled_translucent_bitmap_keeps_the_invariant() {
	// Scaling must not move alpha into the channels: each destination pixel is
	// still one source pixel, so r <= a holds exactly as it did before.
	mut c := new_canvas(12, 1)
	c.clear(rgb(10, 200, 90))
	mut src := []u8{len: 2 * 4}
	src[0] = 255
	src[1] = 255
	src[2] = 255
	src[3] = 128
	bm := from_straight_rgba(1, 1, src, 4)
	c.blend_image(0, 0, 12, 1, bm)
	for x in 0 .. 12 {
		px := c.at(x, 0)
		assert px.r <= px.a
		assert px.g <= px.a
		assert px.b <= px.a
	}
}

// --- tiling ------------------------------------------------------------------

fn test_blend_image_area_tiles_from_the_position_origin() {
	mut c := new_canvas(4, 4)
	c.clear(black)
	bm := corner_bitmap()
	// The tile's one pixel sits at (1,1) -- the position -- and the pattern
	// repeats from there in both directions.
	c.blend_image_area(0, 0, 4, 4, 1, 1, 2, 2, bm, true, true)
	assert c.at(1, 1) == white
	assert c.at(3, 1) == white
	assert c.at(1, 3) == white
	assert c.at(3, 3) == white
	assert c.at(0, 0) == black
	assert c.at(2, 2) == black
}

fn test_blend_image_area_with_no_repeat_draws_one_tile() {
	mut c := new_canvas(6, 6)
	c.clear(black)
	bm := corner_bitmap()
	c.blend_image_area(0, 0, 6, 6, 1, 1, 2, 2, bm, false, false)
	assert c.at(1, 1) == white
	assert c.at(3, 1) == black
	assert c.at(1, 3) == black
	assert c.at(5, 5) == black
}

fn test_blend_image_area_repeat_x_only_fills_one_row() {
	mut c := new_canvas(6, 6)
	c.clear(black)
	bm := corner_bitmap()
	c.blend_image_area(0, 0, 6, 6, 1, 1, 2, 2, bm, true, false)
	assert c.at(1, 1) == white
	assert c.at(3, 1) == white
	assert c.at(5, 1) == white
	assert c.at(1, 3) == black
	assert c.at(3, 3) == black
}

fn test_blend_image_area_repeat_y_only_fills_one_column() {
	mut c := new_canvas(6, 6)
	c.clear(black)
	bm := corner_bitmap()
	c.blend_image_area(0, 0, 6, 6, 1, 1, 2, 2, bm, false, true)
	assert c.at(1, 1) == white
	assert c.at(1, 3) == white
	assert c.at(1, 5) == white
	assert c.at(3, 1) == black
	assert c.at(3, 3) == black
}

fn test_blend_image_area_tiles_leftwards_from_a_centred_origin() {
	// The common shape: a repeating background positioned in the middle of a box
	// wider than the tile. C's integer division truncates toward zero, so a
	// naive offset would find the first visible tile to the *right* of the origin
	// and leave the left half of the box the background colour.
	mut c := new_canvas(6, 1)
	c.clear(black)
	bm := solid_bitmap(2, 1, white)
	c.blend_image_area(0, 0, 6, 1, 3, 0, 2, 1, bm, true, false)
	for x in 0 .. 6 {
		assert c.at(x, 0) == white
	}
}

fn test_blend_image_area_draws_a_tile_that_hangs_off_the_left_edge() {
	// The same origin with no repeat: the tile is clipped rather than skipped,
	// because a background positioned off the box is still partly visible.
	mut c := new_canvas(6, 1)
	c.clear(black)
	bm := solid_bitmap(4, 1, white)
	c.blend_image_area(0, 0, 6, 1, 2, 0, 4, 1, bm, false, false)
	assert c.at(2, 0) == white
	assert c.at(5, 0) == white
	assert c.at(1, 0) == black
}

fn test_blend_image_area_clips_a_cover_sized_tile_to_the_area() {
	// `background-size: cover` grows the image past the box, and the background
	// painting area is the box. Without the clip, a 2x1 tile scaled to 4x4 over a
	// 4x2 box paints the two rows below the box too -- which is the next box down on
	// a real page.
	mut c := new_canvas(4, 4)
	c.clear(black)
	bm := two_colour_row()
	c.blend_image_area(0, 0, 4, 2, 0, 0, 4, 4, bm, false, false)
	assert c.at(0, 0) == red
	assert c.at(2, 1) == blue
	// Rows 2 and 3 are outside the area and must be untouched.
	assert c.at(0, 2) == black
	assert c.at(3, 3) == black
}

fn test_blend_image_area_with_a_zero_area_or_bitmap_changes_nothing() {
	mut c := new_canvas(2, 2)
	c.clear(black)
	bm := solid_bitmap(2, 2, white)
	c.blend_image_area(0, 0, 0, 2, 0, 0, 2, 2, bm, true, true)
	c.blend_image_area(0, 0, 2, 0, 0, 0, 2, 2, bm, true, true)
	c.blend_image_area(0, 0, 2, 2, 0, 0, 2, 2, new_bitmap(0, 0), true, true)
	c.blend_image_area(0, 0, 2, 2, 0, 0, 2, 2, new_bitmap(-4, -4), true, true)
	assert c.at(0, 0) == black
	assert c.at(1, 1) == black
}
