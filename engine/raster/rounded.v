module raster

// Rounded rectangles: the corner geometry, the coverage function that decides how
// much of a pixel is inside one, and the two fills built on it.
//
// This is a separate file rather than a section of raster.v because the idiom is
// the text idiom and not the rectangle idiom: a corner is a *partial* pixel, and
// the only way to say how partial without a float is to count samples. `fill_rect`
// has no opinion about coverage because a rectangle's edge always lands on a pixel
// boundary; an ellipse's does not.
//
// The corners are ellipses rather than circles because `border-radius: 50%` is an
// ellipse, because CSS's own `/` syntax asks for one, and because a circle would be
// a special case of the same test that is wrong on any box that is not square.
//
// The arithmetic is integer throughout. A sample point is held in 1/8-pixel units
// so the ellipse test multiplies out to whole numbers, and the division that turns
// sixteen samples into one byte truncates. That is ARCHITECTURE.md 3: a float
// accumulator would give a different byte on a different compiler, and a
// golden-image test that has to tolerate that is not testing the render.

// Radius is one corner's two radii in pixels. A zero in either axis makes that
// corner square on that axis, which is what `border-radius: 8px 0` asks for.
pub struct Radius {
pub mut:
	x int
	y int
}

// Corners is the four corner radii, in CSS's own order: top-left, top-right,
// bottom-right, bottom-left.
pub struct Corners {
pub mut:
	tl Radius
	tr Radius
	br Radius
	bl Radius
}

// is_zero reports that every radius is zero, which is a plain rectangle. It exists
// so a caller can keep its square-corner path unchanged -- the same command with
// the same geometry -- rather than paying for sixteen samples per pixel on a page
// whose CSS never mentions a radius.
pub fn (c Corners) is_zero() bool {
	return c.tl.x == 0 && c.tl.y == 0 && c.tr.x == 0 && c.tr.y == 0 && c.br.x == 0
		&& c.br.y == 0 && c.bl.x == 0 && c.bl.y == 0
}

// cov_samples is the supersampling grid a corner pixel is tested at, per axis, so a
// pixel is sixteen samples. Sixteen is coarse enough that the multiplication stays
// inside an int and fine enough that a corner reads as a curve rather than as a
// staircase; it is also the same order as the coverage a glyph bitmap carries, so
// the two kinds of edge look the same weight on a page.
const cov_samples = 4

// rounded_covers answers 0..255: how much of the pixel whose top-left corner is
// (px, py) lies inside the rounded rectangle at (x, y, w, h) with radii `c`.
//
// The answer is the count of samples inside, scaled by 255. Truncating rather than
// rounding is deliberate and matches `tint`: the coverage is then exactly the
// alpha `blend_bitmap` would have been handed for the same shape, so a rounded fill
// and a glyph over the same background agree.
pub fn rounded_covers(x int, y int, w int, h int, c Corners, px int, py int) u8 {
	if w <= 0 || h <= 0 {
		return 0
	}
	if c.is_zero() {
		return if px >= x && px < x + w && py >= y && py < y + h { u8(255) } else { u8(0) }
	}
	// Two fast paths that between them cover every pixel not touching a corner,
	// which is all but a handful of them on any real box: a pixel wholly inside
	// the middle of the rectangle, and one wholly outside it.
	if px >= x + c.tl.x && px + 1 <= x + w - c.tr.x && py >= y + c.tl.y
		&& py + 1 <= y + h - c.bl.y {
		return u8(255)
	}
	if px + 1 <= x || py + 1 <= y || px >= x + w || py >= y + h {
		return u8(0)
	}
	mut inside := 0
	mut j := 0
	for j < cov_samples {
		mut i := 0
		for i < cov_samples {
			if sample_inside(w, h, c, 8 * (px - x) + 2 * i + 1, 8 * (py - y) + 2 * j + 1) {
				inside++
			}
			i++
		}
		j++
	}
	return u8(inside * 255 / (cov_samples * cov_samples))
}

// sample_inside tests one sample point against the rounded rectangle.
//
// `ex` and `ey` are the point's position relative to the rectangle's top-left, in
// 1/8-pixel units, which is what keeps the ellipse test in integers:
//
//	((ex - cx) / (8 * rx))^2 + ((ey - cy) / (8 * ry))^2 <= 1
//
// multiplied through by 64 * rx^2 * ry^2. `cx` and `cy` are the corner ellipse's
// centre in the same units, and the quadrant test is what finds the corner the
// sample is in; a sample in none of them is inside the rectangle by construction,
// because the quadrant test already ran the bounds check.
fn sample_inside(w int, h int, c Corners, ex int, ey int) bool {
	if ex < 0 || ey < 0 || ex >= w * 8 || ey >= h * 8 {
		return false
	}
	mut cx := 0
	mut cy := 0
	mut rx := 0
	mut ry := 0
	if ex < c.tl.x * 8 && ey < c.tl.y * 8 {
		cx = c.tl.x * 8
		cy = c.tl.y * 8
		rx = c.tl.x
		ry = c.tl.y
	} else if ex >= (w - c.tr.x) * 8 && ey < c.tr.y * 8 {
		cx = (w - c.tr.x) * 8
		cy = c.tr.y * 8
		rx = c.tr.x
		ry = c.tr.y
	} else if ex >= (w - c.br.x) * 8 && ey >= (h - c.br.y) * 8 {
		cx = (w - c.br.x) * 8
		cy = (h - c.br.y) * 8
		rx = c.br.x
		ry = c.br.y
	} else if ex < c.bl.x * 8 && ey >= (h - c.bl.y) * 8 {
		cx = c.bl.x * 8
		cy = (h - c.bl.y) * 8
		rx = c.bl.x
		ry = c.bl.y
	} else {
		// Not in any corner quadrant, and the bounds check above passed.
		return true
	}
	dx := i64(ex - cx)
	dy := i64(ey - cy)
	rxi := i64(rx)
	ryi := i64(ry)
	return dx * dx * ryi * ryi + dy * dy * rxi * rxi <= 64 * rxi * rxi * ryi * ryi
}

// fill_rounded_rect composites a rounded rectangle, blending each pixel at its own
// coverage exactly as blend_bitmap blends a glyph's. A zero radius is the plain
// rectangle and takes `fill_rect`'s path.
pub fn (mut c Canvas) fill_rounded_rect(x int, y int, w int, h int, corners Corners, col Color) {
	if w <= 0 || h <= 0 || col.a == 0 {
		return
	}
	if corners.is_zero() {
		c.fill_rect(x, y, w, h, col)
		return
	}
	mut yy := y
	for yy < y + h {
		mut xx := x
		for xx < x + w {
			cov := rounded_covers(x, y, w, h, corners, xx, yy)
			if cov != 0 {
				c.blend_pixel(xx, yy, tint(col, cov))
			}
			xx++
		}
		yy++
	}
}

// Side names which of a border's four sides a band belongs to. The order is the
// drawing order CSS 2.1 asks for -- top, right, bottom, left -- so that the corner
// between two sides belongs to the one drawn last, which is the convention
// `paint.borders` already uses for square corners.
pub enum Side {
	top
	right
	bottom
	left
}

// Band is the geometry of one rounded border: the outer rounded rectangle (the
// border box), the inner one (the padding box), and the four side widths that say
// which part of the ring each side owns.
//
// The ring between the two is not four trapezoids and not a clipped rectangle: a
// corner of it follows the outer ellipse, so painting the top side as a band
// *clipped* to the rounded rectangle would leave the corner's outer curve unpainted
// while painting the corner square twice. The side's own region is the ring
// restricted to that side's strip, plus the part of each adjacent corner square
// that is closer to that side's edge than to its neighbour's, which is the
// diagonal of the corner square.
pub struct Band {
pub mut:
	x       int
	y       int
	w       int
	h       int
	outer   Corners
	inner   Corners
	inner_x int
	inner_y int
	inner_w int
	inner_h int
	top     int
	right   int
	bottom  int
	left    int
}

// owns reports whether the pixel belongs to `side`'s half of the ring.
//
// The strip is the same rectangle a square border draws, so a side's straight part
// is identical to what it was before. In a corner square the two sides are divided
// by that square's diagonal -- for the top-left corner, the line from the box's own
// outer corner to the corner curve's centre -- which puts a pixel nearer the top
// edge on the top side and one nearer the left edge on the left side. Any other
// split leaves a wedge of the corner unowned by either side, which shows as a
// notch out of the corner on a page that uses one.
fn (b Band) owns(side Side, px int, py int) bool {
	match side {
		.top {
			if py < b.y + b.top {
				return true
			}
			if px < b.x + b.outer.tl.x && py < b.y + b.outer.tl.y {
				return py - b.y <= px - b.x
			}
			if px >= b.x + b.w - b.outer.tr.x && py < b.y + b.outer.tr.y {
				return py - b.y <= b.x + b.w - px
			}
			return false
		}
		.right {
			if px >= b.x + b.w - b.right {
				return true
			}
			if px >= b.x + b.w - b.outer.tr.x && py < b.y + b.outer.tr.y {
				return b.x + b.w - px <= py - b.y
			}
			if px >= b.x + b.w - b.outer.br.x && py >= b.y + b.h - b.outer.br.y {
				return b.x + b.w - px <= b.y + b.h - py
			}
			return false
		}
		.bottom {
			if py >= b.y + b.h - b.bottom {
				return true
			}
			if px >= b.x + b.w - b.outer.br.x && py >= b.y + b.h - b.outer.br.y {
				return b.y + b.h - py <= b.x + b.w - px
			}
			if px < b.x + b.outer.bl.x && py >= b.y + b.h - b.outer.bl.y {
				return b.y + b.h - py <= px - b.x
			}
			return false
		}
		.left {
			if px < b.x + b.left {
				return true
			}
			if px < b.x + b.outer.tl.x && py < b.y + b.outer.tl.y {
				return px - b.x < py - b.y
			}
			if px < b.x + b.outer.bl.x && py >= b.y + b.h - b.outer.bl.y {
				return px - b.x < b.y + b.h - py
			}
			return false
		}
	}
}

// band_covers answers how much of the pixel belongs to one side's band: the outer
// coverage less the inner one, and nothing at all where the side does not own the
// pixel.
//
// The difference of two coverages is the coverage of the ring between them, which
// is the same approximation `tint` makes when it scales one glyph's coverage to an
// alpha. It is exact where either pixel is wholly inside or wholly outside the
// corresponding rectangle, which is everywhere but along the corner curve itself.
pub fn band_covers(b Band, side Side, px int, py int) u8 {
	if !b.owns(side, px, py) {
		return 0
	}
	o := rounded_covers(b.x, b.y, b.w, b.h, b.outer, px, py)
	if o == 0 {
		return 0
	}
	i := rounded_covers(b.inner_x, b.inner_y, b.inner_w, b.inner_h, b.inner, px, py)
	if o <= i {
		return 0
	}
	return u8(int(o) - int(i))
}

// fill_band composites one side of a rounded border.
pub fn (mut c Canvas) fill_band(b Band, side Side, col Color) {
	if col.a == 0 || b.w <= 0 || b.h <= 0 {
		return
	}
	mut yy := b.y
	for yy < b.y + b.h {
		mut xx := b.x
		for xx < b.x + b.w {
			cov := band_covers(b, side, xx, yy)
			if cov != 0 {
				c.blend_pixel(xx, yy, tint(col, cov))
			}
			xx++
		}
		yy++
	}
}
