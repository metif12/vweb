module paint

import engine.display
import engine.raster

// Turning a box tree into a display list.
//
// The order is fixed and it is the whole of the compositing contract: a box's own
// background, then its borders, then its text, then its children, parents before
// children. Anything else and a later sibling would cover an earlier one, or a
// parent's background would land on top of its own text.
//
// Two things are deliberately absent, and both are stated here rather than left to be
// discovered on a page.
//
// Opacity is not applied. `opacity` below 1 needs the group composited offscreen and
// then blended, and a canvas with no offscreen buffer cannot express it. Applying it
// per fill instead would make a translucent parent *not* tint its children, which is
// the visible difference and the wrong one.
//
// Border styles are drawn as a solid band whatever they are. `double`, `groove` and
// `ridge` are three or five bands with lighter and darker halves, and drawing them as
// one band is wrong in a way a reader will notice on a styled page. Layout already
// reserves the right width for all of them, so the geometry is right and only the
// interior is flat.

// Painter builds a display list from a box tree.
@[heap]
pub struct Painter {
pub mut:
	list &DisplayList
}

pub fn new_painter() &Painter {
	return &Painter{ list: new_list() }
}

// paint appends every drawing operation for the tree, in compositing order.
pub fn (mut p Painter) paint(root &display.Box) {
	p.box(root)
}

fn (mut p Painter) box(b &display.Box) {
	// `visibility: hidden` hides a box *and* its descendants, which is the difference
	// from `display: none` that the two keywords exist to make. A display:none box
	// never reaches here at all: layout drops it.
	if b.style.visibility != .visible {
		return
	}
	p.background(b)
	p.borders(b)
	// Decoration before the glyphs, so the text sits on top of its own underline the
	// way it does in a browser.
	p.decoration(b)
	if b.glyphs.len > 0 {
		p.list.glyph_run(b.glyphs, b.style.color)
	}
	// Atomic inline-level boxes are painted here rather than with the children, because
	// their position comes from the line layout: they sit at the point the line breaker put
	// them, which is not where block layout would put them.
	for bx in b.atomics {
		p.box(bx)
	}
	for child in b.children {
		p.box(child)
	}
}

fn (mut p Painter) background(b &display.Box) {
	p.list.fill_rect(b.rect, b.style.background_color)
}

// borders draws the four sides as bands inside the border box.
//
// The bands are drawn as overlapping rectangles rather than as four disjoint strips,
// top first and bottom last, because that is what makes a `double` border's middle
// band show once the styles are implemented: the corner belongs to both sides, and
// whichever is drawn last owns it. Drawing disjoint strips needs four corner cases
// that no test would cover.
fn (mut p Painter) borders(b &display.Box) {
	r := b.rect
	mut w := [4]int{}
	mut i := 0
	for i < 4 {
		w[i] = b.border_px[i]
		i++
	}
	if w[0] > 0 {
		p.list.fill_rect(display.Rect{ x: r.x, y: r.y, width: r.width, height: w[0] },
			b.style.border_color[0])
	}
	if w[1] > 0 {
		p.list.fill_rect(display.Rect{
			x:      r.x + r.width - w[1]
			y:      r.y
			width:  w[1]
			height: r.height
		}, b.style.border_color[1])
	}
	if w[2] > 0 {
		p.list.fill_rect(display.Rect{
			x:      r.x
			y:      r.y + r.height - w[2]
			width:  r.width
			height: w[2]
		}, b.style.border_color[2])
	}
	if w[3] > 0 {
		p.list.fill_rect(display.Rect{ x: r.x, y: r.y, width: w[3], height: r.height },
			b.style.border_color[3])
	}
}

// decoration draws an underline, a line through, or an overline across the ink of the
// box's own glyphs.
//
// The extent is the ink box rather than the advance width, which is why a trailing
// space is not underlined. That is a deliberate choice: the alternative needs the
// advance of the last glyph, and the ink box is what a reader perceives as "under
// the text". The line is one pixel high and sits a fraction of the font size below the
// baseline, which is close enough to a real underline to read as one at text sizes.
fn (mut p Painter) decoration(b &display.Box) {
	if b.style.text_decoration == .none || b.glyphs.len == 0 {
		return
	}
	mut left := 0
	mut right := 0
	mut baseline := 0.0
	mut first := true
	for g in b.glyphs {
		if g.bitmap.width <= 0 || g.bitmap.height <= 0 {
			continue
		}
		x := int(g.x) + g.bitmap.left
		if first {
			left = x
			first = false
		}
		right = x + g.bitmap.width
		baseline = g.y
	}
	if first || right <= left {
		return
	}
	mut offset := int(round_up(b.font_size * 0.08))
	if offset < 1 {
		offset = 1
	}
	// The three lines sit at fixed fractions of the font size from the baseline. They
	// are not the font's own underline and strike-through metrics, which vtext does not
	// expose; these are close enough at text sizes to read correctly, and a wrong
	// underline is a far smaller error than a missing one.
	y := match b.style.text_decoration {
		.underline { int(baseline) + offset }
		.line_through { int(baseline) - int(b.font_size * 0.3) }
		.overline { int(baseline) - int(b.font_size * 1.0) }
		else { return }
	}
	p.list.fill_rect(display.Rect{ x: left, y: y, width: right - left, height: 1 },
		b.style.color)
}

// round_up is not a rounding helper for layout: the decoration offset must never be
// zero, and `int(f)` truncates toward zero, which would put the line *on* the
// baseline at small sizes.
fn round_up(v f64) f64 {
	mut r := int(v)
	if f64(r) < v {
		r++
	}
	return f64(r)
}

// render_page is the whole pipeline from a box tree to a canvas: the shape a caller
// outside the engine wants, so that `cmd/vweb` does not have to know that painting is
// two steps.
pub fn render_page(root &display.Box, mut canvas &raster.Canvas) &DisplayList {
	mut p := new_painter()
	p.paint(root)
	composite(mut canvas, p.list)
	return p.list
}
