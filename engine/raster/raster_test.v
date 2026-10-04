module raster

fn test_new_canvas_is_zeroed_and_transparent() {
	c := new_canvas(4, 3)
	assert c.width == 4
	assert c.height == 3
	assert c.pix.len == 4 * 3 * 4
	assert c.stride() == 16
	// A fresh canvas must be fully transparent, not black-at-alpha-zero in some
	// channels. Premultiplied transparency is all zeros in every channel.
	assert c.pix == []u8{len: c.pix.len}
	assert c.at(0, 0) == transparent
	assert c.at(3, 2) == transparent
}

fn test_new_canvas_clamps_negative_size() {
	c := new_canvas(-5, -1)
	assert c.width == 0
	assert c.height == 0
	assert c.pix.len == 0
}

fn test_rgb_is_opaque() {
	c := rgb(255, 128, 0)
	assert c.a == 255
	assert c.r == 255
	assert c.g == 128
	assert c.b == 0
}

fn test_rgb_clamps_out_of_range() {
	c := rgb(300, -20, 128)
	assert c.r == 255
	assert c.g == 0
	assert c.b == 128
}

fn test_rgba_premultiplies() {
	// Half-transparent white is (128,128,128,128), not (255,255,255,128).
	// The invariant r <= a is what makes source-over correct for every blend.
	c := rgba(255, 255, 255, 128)
	assert c.a == 128
	assert c.r <= c.a
	assert c.g <= c.a
	assert c.b <= c.a
	assert c.r == 128
}

fn test_unpremultiply_roundtrips_opaque() {
	c := rgb(10, 20, 30)
	u := c.unpremultiply()
	assert u == [u8(10), u8(20), u8(30), u8(255)]
}

fn test_unpremultiply_roundtrips_translucent() {
	c := rgba(200, 100, 50, 128)
	u := c.unpremultiply()
	assert u[3] == 128
	// Premultiplying the result again must land back within one step of the
	// original, which is the property that matters: a canvas round-tripped
	// through a PNG must not drift.
	back := rgba(int(u[0]), int(u[1]), int(u[2]), int(u[3]))
	assert int(back.r) - int(c.r) <= 1
	assert int(back.g) - int(c.g) <= 1
	assert int(back.b) - int(c.b) <= 1
}

fn test_unpremultiply_of_transparent_is_zero() {
	u := transparent.unpremultiply()
	assert u == [u8(0), u8(0), u8(0), u8(0)]
}

fn test_clear_fills_every_pixel() {
	mut c := new_canvas(3, 2)
	c.clear(white)
	for y in 0 .. 2 {
		for x in 0 .. 3 {
			assert c.at(x, y) == white
		}
	}
}

fn test_fill_rect_paints_the_right_region() {
	mut c := new_canvas(8, 8)
	c.clear(black)
	c.fill_rect(2, 3, 3, 2, white)
	// Inside.
	assert c.at(2, 3) == white
	assert c.at(4, 4) == white
	// Just outside on every side.
	assert c.at(1, 3) == black
	assert c.at(5, 3) == black
	assert c.at(2, 2) == black
	assert c.at(2, 5) == black
}

fn test_fill_rect_clips_at_edges_without_wrapping() {
	mut c := new_canvas(4, 4)
	c.clear(black)
	// Starts off-canvas left and above, extends past the right and bottom edges.
	c.fill_rect(-2, -2, 10, 10, white)
	// Every pixel the rectangle actually covers is painted...
	for y in 0 .. 4 {
		for x in 0 .. 4 {
			assert c.at(x, y) == white
		}
	}
	// ...and nothing wrapped around to a negative index.
	assert c.pix.len == 4 * 4 * 4
}

fn test_fill_rect_entirely_off_canvas_is_a_no_op() {
	mut c := new_canvas(4, 4)
	c.clear(black)
	c.fill_rect(100, 100, 10, 10, white)
	c.fill_rect(-100, -100, 10, 10, white)
	assert c.at(0, 0) == black
	assert c.at(3, 3) == black
}

fn test_fill_rect_with_zero_or_negative_size_is_a_no_op() {
	mut c := new_canvas(4, 4)
	c.clear(black)
	c.fill_rect(1, 1, 0, 5, white)
	c.fill_rect(1, 1, 5, 0, white)
	c.fill_rect(1, 1, -5, -5, white)
	assert c.at(1, 1) == black
}

fn test_fill_rect_with_transparent_source_is_a_no_op() {
	mut c := new_canvas(4, 4)
	c.clear(white)
	c.fill_rect(0, 0, 4, 4, transparent)
	assert c.at(0, 0) == white
}

fn test_set_and_at_roundtrip() {
	mut c := new_canvas(3, 3)
	c.set(2, 1, rgb(7, 8, 9))
	assert c.at(2, 1) == rgb(7, 8, 9)
	// Out of bounds writes are dropped rather than panicking.
	c.set(-1, 0, white)
	c.set(0, 99, white)
	assert c.at(0, 0) == transparent
}

fn test_source_over_opaque_replaces() {
	mut c := new_canvas(1, 1)
	c.clear(black)
	c.fill_rect(0, 0, 1, 1, white)
	assert c.at(0, 0) == white
}

fn test_source_over_translucent_blends() {
	mut c := new_canvas(1, 1)
	c.clear(black)
	c.fill_rect(0, 0, 1, 1, rgba(255, 255, 255, 128))
	px := c.at(0, 0)
	// Half white over black is mid grey, and must not be either extreme.
	assert px.a == 255
	assert px.r > 100 && px.r < 155
	assert px.r == px.g && px.g == px.b
}

fn test_source_over_is_order_dependent_but_deterministic() {
	// Compositing the same source over the same destination twice must give the
	// same answer both times. This is the property a golden image depends on: if
	// a page is rendered in two runs, every pixel must match byte for byte.
	render := fn () Color {
		mut c := new_canvas(1, 1)
		c.fill_rect(0, 0, 1, 1, rgba(200, 100, 50, 77))
		c.fill_rect(0, 0, 1, 1, rgba(10, 220, 30, 199))
		return c.at(0, 0)
	}
	assert render() == render()
}

fn test_compositing_over_repeatedly_converges_and_never_overshoots() {
	// Blending the same translucent colour many times over itself must settle
	// near the source, not accumulate past it. This is the check that the
	// rounding step in blend_at is right: a truncating divide biases every
	// composite dark, and over a long run of adjacent glyph pixels that bias
	// shows up as a visible seam.
	//
	// "Near", not "equal". Real compositing in fixed point converges to a
	// fixed point of the integer recurrence, not to the mathematical limit, and
	// the round-to-nearest offset of 127 against a divisor of 255 biases very
	// slightly downward. For src.a == 64 both 254 and 255 are stable fixed
	// points of a_{n+1} = 64 + (191*a_n + 127)/255, so this settles at 254 and
	// stays there. Real browsers have the same property; a test demanding 255
	// would be asserting something arithmetic does not guarantee.
	mut c := new_canvas(1, 1)
	src := rgba(255, 255, 255, 64)
	for _ in 0 .. 200 {
		c.fill_rect(0, 0, 1, 1, src)
	}
	px := c.at(0, 0)
	assert px.a >= 253 && px.a <= 255
	assert px.r == px.g && px.g == px.b
	assert px.r <= px.a
}

fn test_compositing_converges_and_then_holds_still() {
	// Determinism is the property a golden image depends on, and convergence is
	// what makes the composite independent of how many times a box happened to
	// be painted. Once settled, the pixel must not keep drifting.
	mut c := new_canvas(1, 1)
	src := rgba(30, 200, 90, 77)
	for _ in 0 .. 400 {
		c.fill_rect(0, 0, 1, 1, src)
	}
	settled := c.at(0, 0)
	for _ in 0 .. 50 {
		c.fill_rect(0, 0, 1, 1, src)
	}
	assert c.at(0, 0) == settled
}

fn test_tint_scales_alpha_and_keeps_premultiplied() {
	t := tint(rgb(200, 100, 50), 255)
	assert t == rgb(200, 100, 50)
	t0 := tint(rgb(200, 100, 50), 0)
	assert t0 == transparent
	t128 := tint(rgb(200, 100, 50), 128)
	assert t128.a == 128
	assert t128.r <= t128.a
}

fn test_blend_bitmap_draws_coverage_as_alpha() {
	mut c := new_canvas(4, 1)
	c.clear(black)
	cov := [u8(0), u8(255), u8(128), u8(0)]
	c.blend_bitmap(0, 0, 4, 1, 4, cov, white)
	assert c.at(0, 0) == black // zero coverage leaves the destination alone
	assert c.at(1, 0) == white // full coverage is opaque
	half := c.at(2, 0)
	assert half.r > 0 && half.r < 255
	assert c.at(3, 0) == black
}

fn test_blend_bitmap_respects_stride_and_offset() {
	// A glyph bitmap arrives with its own stride and is drawn at an offset from
	// the destination origin, so neither the source origin nor the source width
	// may be assumed to be the destination position. 4 glyph columns, padded to
	// a 6-byte stride, drawn 1 pixel in from the left.
	mut c := new_canvas(6, 3)
	c.clear(black)
	cov := [
		u8(0), u8(0), u8(0), u8(0), u8(0), u8(0),
		u8(255), u8(255), u8(255), u8(255), u8(0), u8(0),
		u8(255), u8(255), u8(255), u8(255), u8(0), u8(0),
	]
	c.blend_bitmap(1, 0, 4, 3, 6, cov, white)

	// The padding row at the top draws nothing.
	assert c.at(1, 0) == black
	assert c.at(2, 0) == black
	// The four glyph columns land at x = 1..4, shifted right by the x argument.
	assert c.at(1, 1) == white
	assert c.at(2, 1) == white
	assert c.at(3, 1) == white
	assert c.at(4, 1) == white
	// The stride padding columns must not be drawn.
	assert c.at(5, 1) == black
	assert c.at(1, 2) == white
	assert c.at(4, 2) == white
	// Nothing to the left of the requested x.
	assert c.at(0, 1) == black
}

fn test_blend_bitmap_clips() {
	mut c := new_canvas(2, 2)
	c.clear(black)
	cov := [u8(255), u8(255), u8(255), u8(255)]
	// Hangs off the top-left corner; only the visible quarter lands.
	c.blend_bitmap(-1, -1, 2, 2, 2, cov, white)
	assert c.at(0, 0) == white
	assert c.at(1, 0) == black
	assert c.at(0, 1) == black
	assert c.at(1, 1) == black
}

fn test_blend_bitmap_with_zero_size_is_a_no_op() {
	mut c := new_canvas(2, 2)
	c.clear(black)
	cov := [u8(255), u8(255), u8(255), u8(255)]
	c.blend_bitmap(0, 0, 0, 2, 2, cov, white)
	c.blend_bitmap(0, 0, 2, 0, 2, cov, white)
	assert c.at(0, 0) == black
}