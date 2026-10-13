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
// Three of CSS's painting-affecting properties are applied here, and each in the
// place that keeps the list the complete plan:
//
//   - `overflow` becomes a clip command, because which boxes confine their
//     descendants is a fact about the page and not about the target (list.v says
//     the rest of that argument).
//   - `opacity` becomes a group, because a translucent subtree has to be composited
//     against itself before it is blended onto what is behind it. Scaling each
//     command's alpha instead would tint the parent and then tint the child again
//     on top of the already-tinted parent.
//   - `visibility` becomes an inheritance flag rather than an early return, because
//     the one override CSS defines is a descendant that says `visible` again.
//
// What is still absent, stated rather than left to be discovered on a page:
// `background-image` is not clipped to a rounded corner, because the tile path in
// raster is a rectangle; a rounded box with an image shows the image past its
// corners. Border *styles* are drawn as a solid band whatever they are -- `double`,
// `groove` and `ridge` are three or five bands with lighter and darker halves, and
// drawing them as one band is wrong in a way a reader will notice on a styled page.
// Layout already reserves the right width for all of them, so the geometry is right
// and only the interior is flat. And `scroll`/`auto` do not scroll: they clip, which
// is the half a static render shows.

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
	// `false` is the starting answer to "is this box inside a group that blends
	// nothing", which is the root's own question to answer and not the tree's.
	p.box(root, false)
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
//
// A group does close part of that gap, and not by accident: an `opacity` box is a
// stacking context in CSS, and painting its whole subtree into one buffer is exactly
// that. A `z-index` inside a translucent box now stops competing with a sibling of the
// translucent box, because the two are no longer painted as one sequence.
fn (mut p Painter) box(b &display.Box, invisible bool) {
	// Two properties make a box paint nothing, and both of them hide the subtree
	// rather than only the box:
	//
	//   - `visibility: hidden`, and `collapse` with it. CSS inherits it, and the one
	//     override it defines is a descendant declaring `visible` again -- so the
	//     inherited value already carries the answer and no flag is needed here.
	//   - `opacity: 0`, which in CSS is a group whose blend is nothing. A group at
	//     alpha zero would composite an entire buffer to no effect, so the answer is
	//     given here instead.
	//
	// `invisible` is what an ancestor passed down: this box sits inside a group that
	// blends nothing, so nothing it names can make it appear. A child of an
	// `opacity: 0` box that asks for `opacity: 0.5` is hidden by it, which is what
	// the group does and the only case where the shortcut and the group can
	// disagree.
	zero_opacity := b.style.opacity == 0.0
	hidden_now := b.style.visibility != .visible || invisible || zero_opacity
	force := invisible || zero_opacity
	// The clip is the padding box, and it is only interesting when it has an area: a
	// box with no padding box left inside its borders has nothing to confine.
	pad := padding_rect(b)
	clips := b.style.overflow.clips() && pad.width > 0 && pad.height > 0
	// A group is only interesting below 1. `opacity: 1` is the initial value and must
	// not cost a buffer.
	translucent := b.style.opacity > 0.0 && b.style.opacity < 1.0
	if translucent {
		p.list.group_begin(alpha_of(b.style.opacity))
	}
	// The box's own background and its borders are painted *before* the clip opens,
	// and that ordering is the rule rather than a convenience: `overflow` confines
	// what is inside the padding box, and a background that runs under the border is
	// deliberately wider than that. Clipping it would cut a stripe off the inside of
	// every border on a box that only asked for its overflow to be hidden.
	if !hidden_now {
		p.background(b)
		p.borders(b)
	}
	if clips {
		p.list.clip_push(pad)
	}
	if !hidden_now {
		// Decoration before the glyphs, so the text sits on top of its own underline the
		// way it does in a browser.
		p.decoration(b)
		if b.glyphs.len > 0 {
			p.list.glyph_run(b.glyphs, b.style.color)
		}
		// The marker is drawn after the text so that a `list-style-position: inside`
		// marker -- which this engine does not place inside -- and the item's own text
		// never fight over the same pixel. A disc is a rounded rectangle of the right
		// size, which is the coverage idiom the raster module already has for a partial
		// pixel, so a bullet is the same shape at every diameter.
		if b.marker_glyphs.len > 0 {
			p.list.glyph_run(b.marker_glyphs, b.style.color)
		}
		if b.marker_kind == .disc {
			r := b.marker_rect
			p.list.rounded_rect(r, disc_corners(r), b.style.color)
		}
		if b.marker_kind == .square {
			p.list.fill_rect(b.marker_rect, b.style.color)
		}
	}
	// Atomic inline-level boxes are painted here rather than with the children, because
	// their position comes from the line layout: they sit at the point the line breaker put
	// them, which is not where block layout would put them.
	for bx in b.atomics {
		p.box(bx, force)
	}
	// The in-flow children, in document order.
	for child in b.children {
		if child.style.position == .static {
			p.box(child, force)
		}
	}
	// Then the positioned ones -- a relative box that kept its place in the flow, and
	// every out-of-flow box this box is the containing block for -- in z-index order.
	// That is what puts an overlay above the content it covers whatever the document
	// order said, and it is E.2's step 6 rather than a special case.
	for child in positioned_of(b) {
		p.box(child, force)
	}
	if clips {
		p.list.clip_pop()
	}
	if translucent {
		p.list.group_end()
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
	// A rounded background is the outer rounded rectangle of the border box: the
	// colour runs to the outer edge with the border drawn on top of it, and the
	// corners are cut off before either of those questions is asked. Square corners
	// keep the plain command, so a page with no `border-radius` has exactly the list
	// it had before.
	corners := corners_of(b)
	if !corners.is_zero() {
		p.list.rounded_rect(b.rect, corners, b.style.background_color)
	} else {
		p.list.fill_rect(b.rect, b.style.background_color)
	}
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
//
// A rounded border takes the other path, because the corner is not a rectangle: the
// bands have to follow the ellipse and be split between the two sides that meet at
// each corner.
// BorderBand is one painted run of a single border side.
//
// The two extents are separate because a band runs along one of two axes depending on the
// style, and one number cannot mean both. `double` and the two-tone styles stack *across*
// the border width, so their extent is `across` and they span the whole side; `dashed` and
// `dotted` run *along* the side, so their extent is `length` and they take the whole
// border width. Conflating them drew a dashed border's 18px marks as an 18px-thick solid
// band running the length of the box, which is the first version of this.
struct BorderBand {
	at     int
	across int
	length int
	color  raster.Color
}

// across_of and length_of are the two extents with the "the whole side" default filled
// in, so a stacked band spans the side and a dashed band takes the whole border width.
fn (b BorderBand) across_of(side_width int) int {
	if b.across > 0 {
		return b.across
	}
	return side_width
}

fn (b BorderBand) length_of(side_length int) int {
	if b.length > 0 {
		return b.length
	}
	return side_length
}

// The two shade scales a two-tone border style uses, as the numerator over 256 that
// `shade` takes.
//
// CSS 2.1 leaves the exact shades of `groove`/`ridge`/`inset`/`outset` to the user
// agent, so this engine's rule is written down rather than borrowed: half as bright for
// the dark tone and half again brighter for the light one. The numbers matter less
// than that they are fixed, because a golden image has to reproduce them.
const dark_shade = 128

const light_shade = 384

// two_tone reports the dark and light tone a two-tone style paints, in the order the
// *outer* half of a side takes them.
//
// `groove` and `ridge` split the difference across the whole border width, and
// `inset`/`outset` split it across the two sides of the same axis -- which is why the
// answer depends on which side it is rather than only on the style. A top or left side
// and a bottom or right side swap, and that swap is the entire visible difference
// between `inset` and `outset`.
fn two_tone(s style.BorderStyle, is_top_or_left bool, col raster.Color) (raster.Color, raster.Color) {
	dark := raster.shade(col, dark_shade)
	light := raster.shade(col, light_shade)
	match s {
		// `inset` reads as pressed in: the whole top and left go dark, the whole bottom
		// and right go light, and the two bands of a side all share one tone -- which is
		// the same thing as one shaded band, and is why `inset` needs no gap.
		.inset {
			if is_top_or_left {
				return dark, dark
			}
			return light, light
		}
		.outset {
			if is_top_or_left {
				return light, light
			}
			return dark, dark
		}
		// `groove` is a channel cut along the border: the outer edge is shadowed and the
		// inner lip is lit, and the two swap on the opposite side. `ridge` is the same
		// channel with the light and the dark exchanged, which is the whole difference
		// between the two.
		.groove {
			if is_top_or_left {
				return dark, light
			}
			return light, dark
		}
		.ridge {
			if is_top_or_left {
				return light, dark
			}
			return dark, light
		}
		else {
			return col, col
		}
	}
}

// side_bands splits one border side into the bands its style paints, from the outer
// edge inwards, and is what turns `border: 6px double black` into two bands instead of
// one solid one.
//
// The rules, all of them this engine's own where CSS 2.1 leaves them open:
//
//   - `solid` is one band of the whole width, unchanged.
//   - `double` is two bands with a gap the same width between them, so a width that
//     cannot carry three stripes (less than 3) degrades to solid rather than drawing
//     one stripe and calling it a rule.
//   - `groove`, `ridge`, `inset` and `outset` are two bands, the outer half and the
//     inner half, in the two tones.
//   - `dashed` and `dotted` are a run of squares whose side is the border width, at a
//     spacing that scales with it: `3:2` for dashes and `1:1` for dots.
//
// The dash geometry has to come from the width because a 1px border has to show the
// smallest mark it can, and a 12px one a mark a reader can see as a dash rather than as
// a dotted line. The last band is never trimmed to fit the length: the list is a plan
// of rectangles, and the compositor's clip takes the overhang off the end.
fn side_bands(s style.BorderStyle, length int, width int, col raster.Color, is_top_or_left bool) []BorderBand {
	if width <= 0 || s == .none || s == .solid {
		if width <= 0 {
			return []BorderBand{}
		}
		return [BorderBand{ at: 0, across: width, color: col }]
	}
	match s {
		.double {
			if width < 3 {
				return [BorderBand{ at: 0, across: width, color: col }]
			}
			third := width / 3
			inner := width - 2 * third
			// The gap is the middle third, and it is skipped rather than left between two
			// touching bands: `double` is two rules with a space between them, and a space
			// drawn as a band is not a space.
			return [
				BorderBand{ at: 0, across: third, color: col },
				BorderBand{ at: 2 * third, across: inner, color: col },
			]
		}
		.groove, .ridge, .inset, .outset {
			outer, inner := two_tone(s, is_top_or_left, col)
			half := width / 2
			rest := width - half
			return [
				BorderBand{ at: 0, across: half, color: outer },
				BorderBand{ at: half, across: rest, color: inner },
			]
		}
		.dashed {
			return dash_bands(length, width, col, 3, 2)
		}
		.dotted {
			return dash_bands(length, width, col, 1, 1)
		}
		else {
			return [BorderBand{ at: 0, across: width, color: col }]
		}
	}
}

// dash_bands is the run of square marks a dashed or dotted side paints. `on` and `off`
// are the mark and the gap, in units of the border width, so a 6px dashed border marks
// 18px and gaps 12px, and a 6px dotted one marks and gaps 6px.
//
// Each mark carries where it starts, so the gap between two marks is a gap and not a
// shorter mark: painting them contiguously would draw a dashed border as a run of solid
// bands with no spaces, which is what the first version did.
fn dash_bands(length int, width int, col raster.Color, on int, off int) []BorderBand {
	mark := width * on
	mut gap := width * off
	if mark <= 0 {
		return []BorderBand{}
	}
	if gap <= 0 {
		gap = mark
	}
	// The marks run until the side ends. The last one is not trimmed to a whole mark:
	// the list is a plan of rectangles and the compositor's clip takes the overhang off
	// the end, which is what keeps the far end of a side from ending on a gap.
	mut out := []BorderBand{}
	mut at := 0
	for at < length {
		out << BorderBand{ at: at, across: width, length: mark, color: col }
		at += mark
		if at >= length {
			break
		}
		at += gap
	}
	return out
}

// disc_corners is a disc of the given rectangle's size: four corners whose radius is
// half the side, which is what the coverage function in `rounded.v` takes to draw a
// circle. It is a helper rather than an inline literal because a disc's radius being
// half its side is the fact that makes it a disc and not an ellipse.
fn disc_corners(r display.Rect) raster.Corners {
	rad := if r.width < r.height { r.width / 2 } else { r.height / 2 }
	return raster.Corners{
		tl: raster.Radius{ x: rad, y: rad }
		tr: raster.Radius{ x: rad, y: rad }
		br: raster.Radius{ x: rad, y: rad }
		bl: raster.Radius{ x: rad, y: rad }
	}
}

fn (mut p Painter) borders(b &display.Box) {
	r := b.rect
	mut w := [4]int{}
	mut i := 0
	for i < 4 {
		w[i] = b.border_px[i]
		i++
	}
	corners := corners_of(b)
	if !corners.is_zero() {
		p.rounded_borders(b, corners, w)
		return
	}
	// Each side is drawn as the bands its style asks for, outer edge inwards, in the
	// top, right, bottom, left order the compositor's corner geometry assumes. A side
	// with a style has more than one band, which is the whole point of this loop: it
	// used to be four single fills, and a `double` border drew as a solid one.
	bands := [
		side_bands(b.style.border_style[0], r.width, w[0], b.style.border_color[0], true),
		side_bands(b.style.border_style[1], r.height, w[1], b.style.border_color[1], false),
		side_bands(b.style.border_style[2], r.width, w[2], b.style.border_color[2], false),
		side_bands(b.style.border_style[3], r.height, w[3], b.style.border_color[3], true),
	]
	// Each side's outer edge, the length along it and the border's thickness across it.
	sides := [
		Side{ x: r.x, y: r.y, length: r.width, thickness: w[0], horizontal: true },
		Side{ x: r.x + r.width, y: r.y, length: r.height, thickness: w[1], horizontal: false },
		Side{ x: r.x, y: r.y + r.height, length: r.width, thickness: w[2], horizontal: true },
		Side{ x: r.x, y: r.y, length: r.height, thickness: w[3], horizontal: false },
	]
	// A band's two extents say which axis it is on, and that decides where its offset
	// goes. A band with no `length` is stacked *across* the border — `double`, the
	// two-tone styles — so its offset advances into the border and it spans the whole
	// side. A band with a `length` is a dash running *along* the side, so its offset is a
	// position along it and the band takes the whole border width. Reading
	// `band.at` as the wrong one is what drew a double border's inner rule four pixels
	// to the right and a dashes' marks marching diagonally down the box.
	for si in 0 .. 4 {
		mut at := sides[si]
		for band in bands[si] {
			thick := band.across_of(at.thickness)
			if thick <= 0 {
				continue
			}
			if band.length > 0 {
				// A dash: fixed across the border, positioned along the side.
				if at.horizontal {
					y := if si == 2 { at.y - at.thickness } else { at.y }
					p.list.fill_rect(display.Rect{
						x:      at.x + band.at
						y:      y
						width:  band.length
						height: thick
					}, band.color)
				} else {
					x := if si == 1 { at.x - at.thickness } else { at.x }
					p.list.fill_rect(display.Rect{
						x:      x
						y:      at.y + band.at
						width:  thick
						height: band.length
					}, band.color)
				}
				continue
			}
			// A stacked band: whole side wide, offset into the border from the outer edge,
			// which for a bottom or right side is measured from the far edge.
			if at.horizontal {
				by := if si == 2 { at.y - band.at - thick } else { at.y + band.at }
				p.list.fill_rect(display.Rect{ x: at.x, y: by, width: at.length, height: thick },
					band.color)
			} else {
				bx := if si == 1 { at.x - band.at - thick } else { at.x + band.at }
				p.list.fill_rect(display.Rect{ x: bx, y: at.y, width: thick, height: at.length },
					band.color)
			}
		}
	}
}

// Side is one border side: its outer edge, the length along it, the thickness of the
// border across it, and which way it runs. The loop above lays a band along it without a
// special case per side, because the two extents of the band say which axis it uses.
struct Side {
mut:
	x          int
	y          int
	length     int
	thickness  int
	horizontal bool
}

// rounded_borders draws the four sides as bands that follow the corner ellipse.
//
// The inner rectangle is the padding box, and each inner radius is the outer one less
// the borders on both sides of that corner -- CSS Backgrounds 3's rule that a
// border's inner edge is the same curve pulled in by its own width. Drawing the
// bands as overlapping rectangles and letting the corner be clipped to the rounded
// shape instead would put a square corner on an already-round background, which is
// the difference between a card with a border and a card with a bitten corner.
fn (mut p Painter) rounded_borders(b &display.Box, outer raster.Corners, w [4]int) {
	mut inner := raster.Corners{}
	inner.tl = raster.Radius{ x: max_of(outer.tl.x - w[3], 0), y: max_of(outer.tl.y - w[0], 0) }
	inner.tr = raster.Radius{ x: max_of(outer.tr.x - w[1], 0), y: max_of(outer.tr.y - w[0], 0) }
	inner.br = raster.Radius{ x: max_of(outer.br.x - w[1], 0), y: max_of(outer.br.y - w[2], 0) }
	inner.bl = raster.Radius{ x: max_of(outer.bl.x - w[3], 0), y: max_of(outer.bl.y - w[2], 0) }
	pad := padding_rect(b)
	band := raster.Band{
		x:       b.rect.x
		y:       b.rect.y
		w:       b.rect.width
		h:       b.rect.height
		outer:   outer
		inner:   inner
		inner_x: pad.x
		inner_y: pad.y
		inner_w: pad.width
		inner_h: pad.height
		top:     w[0]
		right:   w[1]
		bottom:  w[2]
		left:    w[3]
	}
	// The same top, right, bottom, left order the square path draws in, so the corner
	// belongs to the same side it did before.
	if w[0] > 0 {
		p.list.rounded_band(band, .top, b.style.border_color[0])
	}
	if w[1] > 0 {
		p.list.rounded_band(band, .right, b.style.border_color[1])
	}
	if w[2] > 0 {
		p.list.rounded_band(band, .bottom, b.style.border_color[2])
	}
	if w[3] > 0 {
		p.list.rounded_band(band, .left, b.style.border_color[3])
	}
}

// padding_rect is the box's padding box: the border box less the four borders.
//
// It is the rectangle `overflow` confines descendants to, because CSS 2.1 11.1 clips
// to the padding box and not to the border box -- an `overflow: hidden` box still
// shows its own border, which is what makes the clip look like a frame rather than
// like a hole. It is also the inner rectangle of a rounded border's corners.
fn padding_rect(b &display.Box) display.Rect {
	mut w := b.rect.width - b.border_px[1] - b.border_px[3]
	mut h := b.rect.height - b.border_px[0] - b.border_px[2]
	if w < 0 {
		w = 0
	}
	if h < 0 {
		h = 0
	}
	return display.Rect{
		x:      b.rect.x + b.border_px[3]
		y:      b.rect.y + b.border_px[0]
		width:  w
		height: h
	}
}

// alpha_of turns a CSS opacity into the 0..255 alpha a group blends at. The rounding
// happens once, here, for the same reason every float in this engine becomes an int
// once: `opacity: 0.5` is 128 and not 127, and a second rounding somewhere else would
// be a second opinion about what half means.
fn alpha_of(opacity f64) int {
	if opacity <= 0.0 {
		return 0
	}
	if opacity >= 1.0 {
		return 255
	}
	return int(opacity * 255.0 + 0.5)
}

// corners_of resolves the box's border-radius to pixels against its own border box.
//
// This is the one rounding step for a radius, and it is here rather than in layout
// because the percentages are of the border box's own dimensions -- a fact the box
// has once it is placed, and not before.
fn corners_of(b &display.Box) raster.Corners {
	r := b.style.border_radius
	ctx := style.Context{ font_size: b.font_size, root_font_size: b.font_size }
	mut c := raster.Corners{}
	c.tl = corner_px(r.x[0], r.y[0], b.rect.width, b.rect.height, &ctx)
	c.tr = corner_px(r.x[1], r.y[1], b.rect.width, b.rect.height, &ctx)
	c.br = corner_px(r.x[2], r.y[2], b.rect.width, b.rect.height, &ctx)
	c.bl = corner_px(r.x[3], r.y[3], b.rect.width, b.rect.height, &ctx)
	return reduce_corners(c, b.rect.width, b.rect.height)
}

// corner_px resolves one corner's two radii. The horizontal one is a percentage of
// the box's own width and the vertical one of its height, which is CSS 14.1's rule
// and the reason the two axes are resolved separately.
fn corner_px(hx style.Length, vy style.Length, w int, h int, ctx &style.Context) raster.Radius {
	return raster.Radius{
		x: radius_axis(hx, w, ctx)
		y: radius_axis(vy, h, ctx)
	}
}

// radius_axis resolves one radius to pixels. `none` -- which is what an unset radius
// is -- and `auto` both answer zero, and a negative length does too: CSS does not
// accept one, and a negative radius is a corner curve that opens the wrong way.
fn radius_axis(l style.Length, basis int, ctx &style.Context) int {
	if l.unit == .none || l.unit == .auto {
		return 0
	}
	mut v := 0
	if l.unit == .percent {
		v = round_px(l.value * f64(basis) / 100.0)
	} else {
		v = round_px(l.to_px_or(ctx, 0.0))
	}
	if v < 0 {
		return 0
	}
	return v
}

// reduce_corners applies the rule that keeps the four radii from overrunning their
// own sides.
//
// CSS Backgrounds 3 5.5: when the two radii on one side add up to more than that side
// is long, every radius is scaled by the same factor. Without it a
// `border-radius: 100px` on a 50px box asks for a corner curve wider than the box
// itself, and the ellipse test then covers nothing at all where the corner should be
// -- which reads as a hole in the middle of the rectangle rather than as rounding.
//
// The scaling is integer division by the side's own total, so the result is exact and
// identical on every machine.
fn reduce_corners(c raster.Corners, w int, h int) raster.Corners {
	top := c.tl.x + c.tr.x
	right := c.tr.y + c.br.y
	bottom := c.br.x + c.bl.x
	left := c.bl.y + c.tl.y
	mut out := c
	if top > w && top > 0 {
		out.tl.x = c.tl.x * w / top
		out.tr.x = c.tr.x * w / top
	}
	if bottom > w && bottom > 0 {
		out.br.x = c.br.x * w / bottom
		out.bl.x = c.bl.x * w / bottom
	}
	if right > h && right > 0 {
		out.tr.y = c.tr.y * h / right
		out.br.y = c.br.y * h / right
	}
	if left > h && left > 0 {
		out.bl.y = c.bl.y * h / left
		out.tl.y = c.tl.y * h / left
	}
	return out
}

// round_px rounds to the nearest pixel, which is the same rounding `px` in
// engine/display does. Two roundings of one value in two modules would be two
// opinions about where a corner starts.
fn round_px(v f64) int {
	if v >= 0.0 {
		return int(v + 0.5)
	}
	return -int(-v + 0.5)
}

fn max_of(a int, b int) int {
	if a > b {
		return a
	}
	return b
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
