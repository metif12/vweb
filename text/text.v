module text

import strings
import vtext

// The bridge between the engine and vtext.
//
// Everything about how a page's text is shaped, measured and rasterized lives
// here, so that no other module has to know vtext exists. vtext ends at a
// positioned glyph with an 8-bit coverage bitmap; the engine ends at "paint this
// colour through this coverage at this position". This module is the seam.
//
// Two things are added on top of vtext, and both are needed by layout rather
// than by shaping:
//
//   - A glyph cache. vtext rasterizes on every call and keeps nothing, so a
//     page that scrolls would re-walk the font's outlines for every glyph every
//     frame. The key includes the subpixel position, so a glyph reused at two
//     different subpixel offsets is stored twice rather than being rounded into
//     one and looking soft.
//
//   - A style type that carries the CSS properties text actually needs. vtext
//     takes a font, a size and a feature list. CSS has weight, stretch, line
//     height, alignment and letter and word spacing, and the layout engine
//     wants them in one value it can compare and key a cache by.

// The subpixel arguments to vtext's rasterize are QUARTERS OF A PIXEL. This is
// not stb_truetype's sixtieths, which is what the same argument name suggests
// in its own documentation. Reading sixtieths as quarters is sixteen times too
// far, and it shows up as a whole pixel of jitter that is very hard to trace
// back to here. Anything that converts a CSS length into a subpixel position
// must multiply by 4, not by 60.
pub const subpixels_per_pixel = 4

pub struct Metrics {
pub:
	ascent      f64
	descent     f64
	line_height f64
	// The advance of a space at this style, which line breaking needs before it
	// has anything else.
	space_advance f64
	x_height      f64
}

// FontStyle is the subset of CSS font properties that changes shaping or
// measurement. It is deliberately not the whole computed style: only these
// fields can invalidate a measurement, and keeping the type narrow is what makes
// it usable as a cache key.
//
// The fields are mutable because the cascade fills them in one at a time, and a
// caller that copied a style to adjust a single field should not have to rebuild
// it from nine named arguments.
pub struct FontStyle {
pub mut:
	family         string = 'sans-serif'
	weight         int    = 400
	italic         bool
	size           f64   = 16.0
	line_height    f64   = 0.0 // 0 means the font's natural line height
	letter_spacing f64   = 0.0
	word_spacing   f64   = 0.0
	direction      vtext.Direction = .auto
}

// key returns a string that identifies this style for caching purposes. It is
// built from the raw bits rather than a formatted float, so two styles that
// differ only below the formatting precision do not silently collapse into one
// cache entry with the wrong metrics.
pub fn (s &FontStyle) key() string {
	// size and spacing are stored as integers of a 1/64 px so the cache key is
	// short and exact for the sizes a browser actually uses. Below 1/64 px the
	// difference is not visible at any reasonable device pixel ratio.
	mut b := strings.new_builder(96)
	b.write_string(s.family)
	b << u8(s.weight >> 8)
	b << u8(s.weight & 0xff)
	b << if s.italic { u8(1) } else { u8(0) }
	for v in [s.size, s.line_height, s.letter_spacing, s.word_spacing] {
		q := int(v * 64.0)
		b << u8(q >> 8)
		b << u8(q & 0xff)
	}
	b << u8(int(s.direction))
	return b.str()
}

// GlyphKey identifies one rasterized glyph, packed into a single u64.
//
// It is packed rather than a struct because V maps do not accept struct keys, and
// it is packed by hand rather than hashed because a collision means the wrong
// bitmap is drawn for a glyph — visible as text corruption, not as a slow path.
// The layout below keeps the fields apart for any realistic font and size, and
// pack_glyph_key has a test that pins the boundaries.
pub struct GlyphKey {
pub:
	font_id int
	gid     int
	size_q  int // size * 64
	sub_x   int
	sub_y   int
}

// Field widths, in bits, of the packed key. The sum is exactly 64.
//
// These are not arbitrary. Subpixel offsets are quarter pixels, so there are
// four of them per axis and two bits is the exact allocation — an earlier version
// gave four bits per axis and validated against 1 << 4, which accepted sub_x == 4.
// That is a value quantise_subpixel can never produce, so it was dead space that
// looked like a supported input.
pub const (
	key_font_bits = 12 // 4096 fonts
	key_gid_bits  = 24 // 16.7 million glyphs; the largest CJK fonts are ~65k
	key_size_bits = 24 // 1/64 px, biased by half, so ±131072 px
	key_sub_bits  = 2  // quarter pixels: 0..3
)

// pack folds a key into a u64, or returns none if a field does not fit.
//
// It returns an Option rather than a sentinel like -1 for two reasons, both of
// which were found the hard way. The packed value legitimately uses all 64 bits,
// so a large font_id sets the sign bit and a sentinel of -1 is a value the packer
// can itself produce; and "does this fit" is not a question with a numeric answer,
// so folding it into the return type keeps every caller from having to remember.
//
// Refusing is the correct behaviour rather than truncating: silently dropping the
// high bits of a glyph id would draw a different glyph and call it a cache hit.
pub fn pack_glyph_key(k GlyphKey) ?u64 {
	if k.font_id < 0 || k.font_id >= (1 << key_font_bits) {
		return none
	}
	if k.gid < 0 || k.gid >= (1 << key_gid_bits) {
		return none
	}
	size := k.size_q + (1 << (key_size_bits - 1))
	if size < 0 || size >= (1 << key_size_bits) {
		return none
	}
	if k.sub_x < 0 || k.sub_x >= (1 << key_sub_bits) {
		return none
	}
	if k.sub_y < 0 || k.sub_y >= (1 << key_sub_bits) {
		return none
	}
	mut packed := u64(k.font_id)
	packed = packed << key_gid_bits | u64(k.gid)
	packed = packed << key_size_bits | u64(size)
	packed = packed << key_sub_bits | u64(k.sub_x)
	packed = packed << key_sub_bits | u64(k.sub_y)
	return packed
}

pub struct GlyphCache {
mut:
	entries map[u64]vtext.GlyphBitmap
	hits    int
	misses  int
	// Bytes of coverage held, so a long-running scroll session can be watched
	// rather than guessed at.
	bytes int
	// Keys that could not be packed and were therefore not cached. Nonzero means
	// a font or size is outside the ranges in key_*_bits.
	unpackable int
}

pub fn new_glyph_cache() &GlyphCache {
	return &GlyphCache{
		entries: map[u64]vtext.GlyphBitmap{}
	}
}

// get returns the bitmap stored under a key, or none.
//
// The stored value is bound to a local and returned explicitly. It used to be written as
// the map lookup with an `or` block and nothing after it but the counter:
//
//	gc.entries[p] or { gc.misses++; return none }
//	gc.hits++
//
// which returns the *counter's* value, not the bitmap. V accepted it, and the signature
// said `?vtext.GlyphBitmap`, so nothing complained -- but every hit came back as the zero
// bitmap and drew nothing.
//
// That is the whole of the "empty bitmap" bug this module had for a day: a page rendered
// with holes in it, roughly half its glyphs missing, worse for narrow glyphs because a
// narrow one is more likely to be a repeat. It was read here, as a cache miss followed by a
// bad rasterize, and in the rasterizer, which is correct. `notes/JOURNAL.md` has the
// measurements.
pub fn (mut gc GlyphCache) get(k GlyphKey) ?vtext.GlyphBitmap {
	p := pack_glyph_key(k) or {
		return none
	}
	got := gc.entries[p] or {
		gc.misses++
		return none
	}
	gc.hits++
	return got
}

// put stores a bitmap. A zero-area bitmap is not stored: vtext returns one for
// a space and for a glyph the font has no outline for, and caching those would
// grow the map for nothing.
pub fn (mut gc GlyphCache) put(k GlyphKey, bm vtext.GlyphBitmap) {
	if bm.width <= 0 || bm.height <= 0 {
		return
	}
	p := pack_glyph_key(k) or {
		gc.unpackable++
		return
	}
	gc.entries[p] = bm
	gc.bytes += bm.width * bm.height
}

pub fn (gc &GlyphCache) len() int {
	return gc.entries.len
}

pub fn (gc &GlyphCache) bytes() int {
	return gc.bytes
}

pub fn (gc &GlyphCache) unpackable() int {
	return gc.unpackable
}

// hit_rate is a rough health check. A low rate on a real page usually means the
// cache is being keyed on something that varies per glyph, such as a float size
// that should have been quantised.
pub fn (gc &GlyphCache) hit_rate() f64 {
	total := gc.hits + gc.misses
	if total == 0 {
		return 0.0
	}
	return f64(gc.hits) / f64(total)
}

pub fn (mut gc GlyphCache) clear() {
	gc.entries.clear()
	gc.bytes = 0
	gc.hits = 0
	gc.misses = 0
	gc.unpackable = 0
}