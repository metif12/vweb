module paint

import engine.display
import engine.raster
import engine.style

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
	// images are the decoded background images, keyed by URL exactly as the
	// stylesheet wrote it. The painter is handed them rather than fetching them,
	// because ARCHITECTURE.md 1 gives the engine no I/O: a URL is a reference and
	// `engine/page` -- the module that owns the loader -- is what turns one into
	// bytes. A URL with no entry here draws nothing, which is how a broken image
	// degrades instead of failing the render.
	images map[string]&raster.Bitmap
}

pub fn new_painter() &Painter {
	return &Painter{ list: new_list(), images: map[string]&raster.Bitmap{} }
}

// new_painter_with_images is the constructor for a caller that has decoded the
// page's background images. An empty map is the same as `new_painter`, and is what
// a caller with no images passes rather than being handed a default it cannot see.
pub fn new_painter_with_images(images map[string]&raster.Bitmap) &Painter {
	return &Painter{ list: new_list(), images: images }
}

// paint appends every drawing operation for the tree, in compositing order.
pub fn (mut p Painter) paint(root &display.Box) {
	p.box(root)
}

// box draws one box and its descendants, in the order CSS 2.1 Appendix E.2's painting
// algorithm gives for the part of it this engine implements.
//
// The order inside one box: its own background, its borders, its decoration, its text,
// then its in-flow content, then its positioned content. Parents before children, and
// positioned boxes after the in-flow content of the box they sit in -- which is steps
// 1, 3, 4, 5 and 6 of E.2.
//
// What is not here, stated rather than left to be discovered on a page: step 2 (child
// stacking contexts with a negative z-index, which belong *behind* this box's own
// background), step 7's separate treatment of a positioned descendant that establishes
// a stacking context, and the inline-before-float ordering E.2 asks for within steps 4
// and 5 -- this draws an atomic inline box before the in-flow blocks that follow it, in
// tree order. A negative z-index therefore draws above the parent's background instead
// of below it, and a page that relies on that will show it.
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
	// The in-flow children, in document order.
	for child in b.children {
		if child.style.position == .static {
			p.box(child)
		}
	}
	// Then the positioned ones -- a relative box that kept its place in the flow, and
	// every out-of-flow box this box is the containing block for -- in z-index order.
	// That is what puts an overlay above the content it covers whatever the document
	// order said, and it is E.2's step 6 rather than a special case.
	for child in positioned_of(b) {
		p.box(child)
	}
}

// positioned_of returns the boxes of one parent that are positioned, in the order E.2
// paints them: z-index first, document order between equals.
//
// The sort is a stable insertion sort rather than a library sort for two reasons, and
// neither is speed. Stability *is* the specification -- equal z-index keeps document
// order (E.2) -- and a comparison sort that is not provably stable would leave a golden
// image depending on which V build made it.
//
// They come out of `children` rather than out of a separate list, so document order is
// the order the document wrote them in: a relative box stays in the flow, where its
// place in the tree is what the flow is, and an absolutely positioned one is stored
// there too for the document order it carries.
fn positioned_of(b &display.Box) []&display.Box {
	mut out := []&display.Box{}
	for child in b.children {
		if child.style.position != .static {
			out << child
		}
	}
	mut i := 1
	for i < out.len {
		mut j := i
		for j > 0 && z_of(out[j]) < z_of(out[j - 1]) {
			tmp := out[j]
			out[j] = out[j - 1]
			out[j - 1] = tmp
			j--
		}
		i++
	}
	return out
}

// z_of is the z-index a positioned box paints at. `auto` paints as zero, which is what
// E.2 step 6 says: it belongs to the same group as `z-index: 0`, ordered by document
// order rather than by a number the author never wrote.
fn z_of(b &display.Box) int {
	if b.style.z_index.auto {
		return 0
	}
	return b.style.z_index.value
}

fn (mut p Painter) background(b &display.Box) {
	p.list.fill_rect(b.rect, b.style.background_color)
	if b.style.background_image == '' {
		return
	}
	// A URL the caller could not fetch or decode has no bitmap, so there is no
	// command: the box keeps its background colour and nothing else happens. No
	// error, no panic -- a page with a broken image is still a page.
	bm := p.images[b.style.background_image] or { return }
	if bm.width <= 0 || bm.height <= 0 {
		return
	}
	// The percentage basis of a background-size or background-position is the box's
	// own rectangle, which only this function has. `size_context` supplies the font
	// sizes; see the note there about `rem`.
	ctx := size_context(b)
	tile_w, tile_h := b.style.background_size.resolve(b.rect.width, b.rect.height,
		bm.width, bm.height, &ctx)
	if tile_w <= 0 || tile_h <= 0 {
		return
	}
	tile_x, tile_y := b.style.background_position.resolve(b.rect.x, b.rect.y, b.rect.width,
		b.rect.height, tile_w, tile_h, &ctx)
	p.list.image(b.rect, tile_x, tile_y, tile_w, tile_h, bm, b.style.background_repeat)
}

// size_context is the context a background-position or background-size length
// resolves against.
//
// `em` is answered with the box's own font size, which is right: the box is the
// element whose background it is. `rem`, `vw` and `vh` are answered with the same
// number, because a box tree carries neither the root font size nor the viewport
// and `engine/display` -- the module that would hold them -- belongs to another
// stream. That is a recorded gap rather than a choice, and it costs nothing on any
// value written in pixels or percentages, which is what background-size is written
// with in practice.
fn size_context(b &display.Box) style.Context {
	return style.Context{ font_size: b.font_size, root_font_size: b.font_size }
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

// render_page_with_images is render_page for a caller that has decoded the page's
// background images. A caller with no images should pass `render_page`, which is
// the same call with an empty map.
pub fn render_page_with_images(root &display.Box, images map[string]&raster.Bitmap, mut canvas &raster.Canvas) &DisplayList {
	mut p := new_painter_with_images(images)
	p.paint(root)
	composite(mut canvas, p.list)
	return p.list
}
