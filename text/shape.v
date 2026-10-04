module text

// Measuring and drawing text. This is the whole surface the layout engine uses.
//
// Two shapes of call, and the distinction matters more than it looks: `advance`
// and `line_metrics` are pure and cacheable and get called constantly during
// layout, while `draw_run` composites pixels and is called once per visible line.
// Layout must never need to rasterize, because intrinsic sizing in phase 2
// measures content at widths that are never displayed, and a layout that
// rasterizes to answer "how narrow can this be" would be unusable.
//
// Note the parameter name: it is `content`, never `text`. A parameter named
// after the module shadows the module name, and V then parses the calls in the
// same function as arguments to the shadowed identifier, which produces a
// cascade of errors that all point somewhere else.

import vtext
import engine.raster

// advance returns the total advance width of `content` at `style`, in CSS
// pixels. This includes letter spacing and the extra word spacing on each space,
// both of which count toward line length in CSS even though neither is a glyph
// advance.
pub fn (mut lib FontLibrary) advance(style &FontStyle, content string) f64 {
	if content.len == 0 {
		return 0.0
	}
	fs := lib.font_set_for(lib.primary_id(style))
	line := shape_line(lib, content, style, fs)
	mut w := line.width
	if style.letter_spacing != 0.0 {
		w += style.letter_spacing * f64(content.runes().len)
	}
	if style.word_spacing != 0.0 {
		w += style.word_spacing * f64(content.count(' '))
	}
	return w
}

// line_metrics returns the vertical numbers a line box needs.
//
// CSS line-height is one of three things: a number (a multiple of the font size),
// a length, or `normal`. The engine resolves that to a length before it gets
// here, so what arrives is either 0 for normal or a positive pixel length.
pub fn (mut lib FontLibrary) line_metrics(style &FontStyle) Metrics {
	f := lib.font_at(style) or {
		return Metrics{}
	}
	em := style.size
	natural := f.line_height(em)
	x := f.glyph_index(`x`)
	return Metrics{
		ascent:        f.ascent(em)
		descent:       f.descent(em)
		line_height:   if style.line_height > 0.0 { style.line_height } else { natural }
		space_advance: f.glyph_advance(f.glyph_index(` `), em)
		// x_height drives the default cap height of small text and is the usual
		// measure for whether a line box is taller than its content.
		x_height:      if x != 0 { f.glyph_advance(x, em) } else { em * 0.5 }
	}
}

// primary_id resolves a style's family list to a font, opening one if needed.
pub fn (mut lib FontLibrary) primary_id(style &FontStyle) int {
	lib.ensure_arabic_chain(style.weight)
	return lib.open_face(faces_for(generic_of(style.family), style.weight, style.italic))
}

// font_at is primary_id plus the resolved font, for callers that need both.
pub fn (mut lib FontLibrary) font_at(style &FontStyle) ?&vtext.Font {
	return lib.font(lib.primary_id(style))
}

// font resolves an id to its font.
pub fn (lib &FontLibrary) font(id int) ?&vtext.Font {
	e := lib.get(id) or {
		return none
	}
	return e.font
}

fn (mut lib FontLibrary) id_for_path(path string) int {
	return lib.by_path[path] or { -1 }
}

fn shape_line(lib &FontLibrary, content string, style &FontStyle, fs &vtext.FontSet) vtext.Line {
	return vtext.layout_paragraph(lib.ctx, content.runes(), style.direction, fs, style.size)
}

fn generic_of(family string) Generic {
	lower := family.to_lower()
	// An explicit family would be preferred if we had a per-family table; the
	// candidate lists are keyed by generic, so every family resolves to its
	// nearest generic for now. That is wrong for `font-family: Consolas` and
	// right for `font-family: Tahoma`. A real per-family table is a phase 6
	// question, when there is a UI to show a font picker in.
	if lower.starts_with('mono') || lower.starts_with('courier') {
		return .monospace
	}
	if lower.starts_with('serif') && !lower.starts_with('sans') {
		return .serif
	}
	if lower.starts_with('cursive') {
		return .cursive
	}
	if lower.starts_with('fantasy') {
		return .fantasy
	}
	return .sans
}

// A positioned, rasterized glyph ready to composite: where to put it and what
// coverage to put there.
pub struct PositionedGlyph {
pub:
	x       f64 // pen x, CSS pixels, relative to the text origin
	y       f64 // baseline y
	font_id int
	gid     int
	size    f64
	sub_x   int // quarter pixels
	sub_y   int
pub mut:
	bitmap vtext.GlyphBitmap
}

// shape breaks `content` into positioned glyphs at `style`, caching each
// glyph's rasterization as it goes.
//
// Subpixel positioning is quantised to quarters of a pixel on purpose. Beyond
// that the cache would hold a separate entry per device pixel for the same glyph
// and the hit rate would collapse, and the visual gain is invisible — which is
// why this is a decision and not an arbitrary threshold.
pub fn (mut lib FontLibrary) shape(content string, style &FontStyle, origin_x f64, baseline_y f64) []PositionedGlyph {
	if content.len == 0 {
		return []PositionedGlyph{}
	}
	fs := lib.font_set_for(lib.primary_id(style))
	line := shape_line(lib, content, style, fs)
	return lib.place_glyphs(line.glyphs, style, origin_x, baseline_y)
}

// place_glyphs turns shaped glyphs into drawable ones at an absolute position, caching
// each rasterization as it goes.
//
// `shape` and `wrap` both go through here rather than each building their own list,
// because a glyph's cache key contains the subpixel part of its position: two callers
// that shaped the same text with slightly different arithmetic would each miss the
// other's entries and rasterize everything twice.
fn (mut lib FontLibrary) place_glyphs(glyphs []vtext.Glyph, style &FontStyle, origin_x f64, baseline_y f64) []PositionedGlyph {
	mut out := []PositionedGlyph{cap: glyphs.len}
	for g in glyphs {
		mut fid := -1
		if gf := g.font {
			fid = lib.id_for_path(gf.path())
		}
		pen := origin_x + g.x
		out << PositionedGlyph{
			x:       pen
			y:       baseline_y + g.y
			font_id: fid
			gid:     int(g.gid)
			size:    style.size
			sub_x:   quantise_subpixel(pen - f64(int(pen)))
			sub_y:   0
		}
	}
	// Rasterize after the whole run is placed, so a glyph that repeats within one
	// line is looked up once per occurrence and the cache still does its job on
	// the second one.
	for mut pg in out {
		f := lib.font(pg.font_id) or {
			continue
		}
		k := GlyphKey{
			font_id: pg.font_id
			gid:     pg.gid
			size_q:  quantise_size(pg.size)
			sub_x:   pg.sub_x
			sub_y:   pg.sub_y
		}
		pg.bitmap = lib.bitmap_for(f, k)
	}
	return out
}

// WrapRequest is everything `wrap` needs, as one value.
//
// It is a struct rather than six positional arguments because four of them are
// consecutive f64s: `wrap_at(content, style, 400, 16, 30, 20)` cannot be read, and a
// caller that swapped two of them would get a paragraph silently shaped at the wrong
// baseline rather than a compile error.
pub struct WrapRequest {
pub mut:
	content string
	style   &FontStyle
	// max_width is the width to break at, in CSS pixels. A value larger than any line
	// means "do not break", which is how `white-space: nowrap` and `pre` are expressed.
	max_width f64
	// origin_x and first_baseline place the *first* line. Every later line is
	// first_baseline plus its own line_height, so a caller cannot accidentally stack
	// lines by their own idea of the spacing.
	origin_x       f64
	first_baseline f64
	line_height    f64
}

// Line is one line of a wrapped paragraph: its glyphs in drawing order, and the numbers
// layout needs about it.
pub struct Line {
pub mut:
	glyphs []PositionedGlyph
	// width is the line's advance, including letter and word spacing, which count toward
	// line length in CSS even though neither is a glyph advance.
	width f64
	// ascent and descent are this line's own ink extent, which is not the box's: a line
	// containing a glyph from a taller fallback face is taller than its neighbours.
	ascent  f64
	descent f64
}

// wrap breaks a paragraph into lines and shapes each one where it will be drawn.
//
// It shapes at the final position rather than shaping at the origin and moving the
// result, because the glyph cache is keyed on the quarter-pixel part of the pen
// position: a glyph moved after rasterization keeps the bitmap of the position it was
// rasterized for, which is a slightly soft glyph on every non-integral x.
//
// A word longer than max_width overflows its line rather than being split. That is
// vtext's rule and it is the right one here: a caller cannot map a click on half a word
// back to the text, which is a worse failure than a line that is too wide.
pub fn (mut lib FontLibrary) wrap(r WrapRequest) []Line {
	if r.content.len == 0 {
		return []Line{}
	}
	fs := lib.font_set_for(lib.primary_id(r.style))
	wrapped := vtext.wrap_paragraph(lib.ctx, r.content.runes(), r.style.direction, fs,
		r.style.size, r.max_width)
	mut out := []Line{cap: wrapped.len}
	for i, w in wrapped {
		mut line := Line{
			// Letter spacing is added per glyph and word spacing per space, and neither
			// is a glyph advance -- which is why the line's width is not vtext's and has
			// to be corrected here or the box will be measured too narrow.
			width:   w.line.width + r.spacing_of(w)
			ascent:  w.line.ascent
			descent: w.line.descent
		}
		line.glyphs = lib.place_glyphs(w.line.glyphs, r.style, r.origin_x,
			r.first_baseline + f64(i) * r.line_height)
		out << line
	}
	return out
}

// spacing_of is the letter and word spacing a line has to be widened by. CSS counts
// both toward line length even though neither moves a glyph, so a line measured
// without them is narrower than it will be drawn.
fn (r WrapRequest) spacing_of(w vtext.WrappedLine) f64 {
	if r.style.letter_spacing == 0.0 && r.style.word_spacing == 0.0 {
		return 0.0
	}
	mut spaces := 0
	mut i := w.from
	for i < w.to {
		if r.content.runes()[i] == ` ` {
			spaces++
		}
		i++
	}
	return r.style.letter_spacing * f64(w.line.glyphs.len) + r.style.word_spacing * f64(spaces)
}

// bitmap_for returns a glyph's rasterization, from the cache when it is there.
pub fn (mut lib FontLibrary) bitmap_for(f &vtext.Font, k GlyphKey) vtext.GlyphBitmap {
	if cached := lib.cache.get(k) {
		return cached
	}
	bm := f.rasterize(u16(k.gid), f64(k.size_q) / 64.0, k.sub_x, k.sub_y)
	lib.cache.put(k, bm)
	return bm
}

// draw_run composites shaped glyphs onto a canvas. Each glyph's own baseline is
// the y it was shaped at, and its top comes from the bitmap, which is measured
// above the baseline and can be negative.
pub fn draw_run(mut c raster.Canvas, glyphs []PositionedGlyph, col raster.Color) {
	for g in glyphs {
		if g.bitmap.width <= 0 || g.bitmap.height <= 0 {
			continue
		}
		x := int(g.x) + g.bitmap.left
		y := int(g.y) - g.bitmap.top
		c.blend_bitmap(x, y, g.bitmap.width, g.bitmap.height, g.bitmap.width,
			g.bitmap.coverage, col)
	}
}

// quantise_size converts a CSS pixel size into the integer the cache key uses.
// The 1/64 px grid is finer than any device pixel ratio in use and coarse enough
// that 16px and 16.01px do not each get their own cache entries.
pub fn quantise_size(px f64) int {
	return int(px * 64.0)
}

// quantise_subpixel turns a fractional pixel offset into whole quarter pixels,
// rounding to nearest so a glyph centred on a pixel boundary is not biased to one
// side.
pub fn quantise_subpixel(frac f64) int {
	q := int((frac + 0.125) * f64(subpixels_per_pixel))
	if q < 0 {
		return 0
	}
	if q > subpixels_per_pixel - 1 {
		return subpixels_per_pixel - 1
	}
	return q
}

// min_content_width is the narrowest the text can be without a single glyph
// breaking out of it: every word on its own line.
//
// It lives here rather than in layout because the answer is a property of the
// text, and because it is the question phase 2 keeps asking. `wrap_paragraph`
// shapes once and slices, so measuring at a width that is never displayed costs
// no extra shaping — which is what makes this cheap enough to call from an
// intrinsic sizing loop.
pub fn (mut lib FontLibrary) min_content_width(style &FontStyle, content string) f64 {
	if content.len == 0 {
		return 0.0
	}
	fs := lib.font_set_for(lib.primary_id(style))
	lines := vtext.wrap_paragraph(lib.ctx, content.runes(), style.direction, fs, style.size, 0.0)
	mut widest := 0.0
	for l in lines {
		if l.line.width > widest {
			widest = l.line.width
		}
	}
	return widest + if style.letter_spacing != 0.0 { style.letter_spacing } else { 0.0 }
}

// max_content_width is the width of the text with no line breaks at all.
pub fn (mut lib FontLibrary) max_content_width(style &FontStyle, content string) f64 {
	return lib.advance(style, content)
}
