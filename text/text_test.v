module text

import vtext
import engine.raster

// A library with nothing opened reports the failure rather than inventing a
// metric. Everything downstream of an unresolved font is silently wrong — text
// at zero height, lines that collapse — so this has to be visible.

fn test_empty_library_opens_a_font_for_a_default_style() {
	// A fresh library holds nothing, but resolving the default style has to find
	// something or every page would render with no font at all. Asserting -1 here
	// would be asserting that the default is unrenderable, which is not the same
	// as "nothing is loaded yet".
	lib := new_font_library()
	assert lib.len() == 0
	assert lib.primary_id(&FontStyle{}) >= 0
	assert lib.len() > 0
}

fn test_line_metrics_of_an_unresolvable_style_are_zero() {
	// The failure path has to be visible rather than inventing a metric: text at
	// zero height with lines that collapse is a bug report that takes an hour to
	// trace back to here. Pointing the library at a directory that does not exist
	// is how that state is reached deterministically, without depending on what
	// the host happens to have installed.
	mut lib := new_font_library()
	lib.use_only_from('C:/definitely-not-a-font-directory')
	assert lib.primary_id(&FontStyle{}) == -1
	m := lib.line_metrics(&FontStyle{})
	assert m.line_height == 0.0
	assert m.ascent == 0.0
	assert m.space_advance == 0.0
}

fn test_add_opens_an_existing_font_and_dedupes_it() {
	mut lib := new_font_library()
	id := lib.add(lib.find_face(sans_faces[0]))
	if id < 0 {
		assert false, '${sans_faces[0]} must exist on a Windows host for this test'
		return
	}
	assert lib.len() == 1
	// Adding the same path again returns the same id rather than opening a second
	// copy, because the glyph cache is keyed on the id and a duplicate would
	// silently halve its hit rate.
	again := lib.add(lib.entries[id].path)
	assert again == id
	assert lib.len() == 1
}

fn test_add_of_a_missing_path_returns_minus_one() {
	// Not an error. A family list is a suggestion, and a font that is not
	// installed is the normal case, not an exceptional one.
	mut lib := new_font_library()
	assert lib.add('C:/Windows/Fonts/definitely-not-a-font.ttf') == -1
	assert lib.len() == 0
}

fn test_find_face_returns_empty_when_nothing_matches() {
	lib := new_font_library()
	lib.use_only_from('C:/definitely-not-a-font-directory')
	assert lib.find_face(sans_faces[0]) == ''
	assert lib.find_face('anything-at-all.ttf') == ''
}

fn test_use_only_from_forgets_previously_loaded_fonts() {
	// This is what makes a golden test reproducible: point the library at
	// vendored fonts and the host's installed fonts must stop being reachable,
	// or the same test would render differently on two machines.
	mut lib := new_font_library()
	assert lib.primary_id(&FontStyle{}) >= 0
	assert lib.len() > 0
	lib.use_only_from('C:/definitely-not-a-font-directory')
	assert lib.len() == 0
	assert lib.primary_id(&FontStyle{}) == -1
}

fn test_open_face_picks_the_first_available_candidate() {
	mut lib := new_font_library()
	// Two names that do not exist, then one that does.
	id := lib.open_face(['nope1.ttf', 'nope2.ttf', sans_faces[0]])
	assert id >= 0
	assert lib.entries[id].path.ends_with(sans_faces[0])
}

fn test_open_face_returns_minus_one_when_nothing_is_available() {
	mut lib := new_font_library()
	assert lib.open_face(['a.ttf', 'b.ttf']) == -1
}

fn test_bold_face_resolves_to_a_different_file_than_regular() {
	// If this ever fails, weight is being ignored and every heading on every page
	// renders in the regular face.
	mut lib := new_font_library()
	regular := lib.open_face(sans_faces)
	bold := lib.open_face(sans_bold_faces)
	assert regular >= 0
	assert bold >= 0
	assert regular != bold
}

fn test_get_is_bounds_checked() {
	lib := new_font_library()
	assert lib.get(-1) == none
	assert lib.get(0) == none
	assert lib.get(9999) == none
}

fn test_faces_for_picks_bold_at_600_and_above() {
	// CSS puts the bold threshold at 600. Using 700 instead would render a
	// font-weight of 600 as regular, which is a visible difference on Persian
	// headings where the bold face also has different proportions.
	normal := faces_for(.sans, 400, false)
	bold := faces_for(.sans, 700, false)
	at600 := faces_for(.sans, 600, false)
	assert normal != bold
	assert at600 == bold
	// 1000 is the clamp; anything at or above it is the same face.
	assert faces_for(.sans, 1400, false) == bold
	// And below the threshold stays regular.
	assert faces_for(.sans, 599, false) == normal
	assert faces_for(.sans, 100, false) == normal
}

fn test_faces_candidates_are_base_names_not_paths() {
	// A golden test cannot depend on a host's installed fonts, so face lookup
	// goes through a search directory and the lists must not carry paths. A
	// backslash or slash in any candidate means the search directory is being
	// bypassed and the host's fonts are back in charge.
	for name in [...sans_faces, ...serif_faces, ...mono_faces, ...arabic_faces,
		...sans_bold_faces, ...serif_bold_faces, ...mono_bold_faces] {
		assert !name.contains('/')
		assert !name.contains('\\')
		assert name.ends_with('.ttf') || name.ends_with('.ttc') || name.ends_with('.otf')
	}
}

fn test_faces_for_honours_the_generic_family() {
	sans := faces_for(.sans, 400, false)
	serif := faces_for(.serif, 400, false)
	mono := faces_for(.monospace, 400, false)
	assert sans != serif
	assert sans != mono
	assert serif != mono
}

fn test_line_metrics_are_positive_and_ordered() {
	mut lib := new_font_library()
	style := FontStyle{
		family: 'sans-serif'
		size:   32.0
	}
	m := lib.line_metrics(&style)
	assert m.line_height > 0.0
	// A line box is taller than either half of it, and the ascent is positive.
	assert m.ascent > 0.0
	assert m.descent != 0.0
	assert m.line_height >= m.ascent - 0.001
	assert m.space_advance > 0.0
}

fn test_line_height_from_the_style_wins_over_the_font() {
	mut lib := new_font_library()
	mut style := FontStyle{
		family: 'sans-serif'
		size:   20.0
	}
	natural := lib.line_metrics(&style).line_height
	style.line_height = 100.0
	explicit := lib.line_metrics(&style).line_height
	assert explicit == 100.0
	assert explicit != natural
	// 0 means normal, so it falls back to the font's own value rather than
	// collapsing the box to nothing.
	style.line_height = 0.0
	assert lib.line_metrics(&style).line_height == natural
}

fn test_advance_of_empty_text_is_zero() {
	mut lib := new_font_library()
	assert lib.advance(&FontStyle{}, '') == 0.0
}

fn test_advance_grows_with_length() {
	mut lib := new_font_library()
	style := FontStyle{
		family: 'sans-serif'
		size:   32.0
	}
	one := lib.advance(&style, 'a')
	many := lib.advance(&style, 'aaaaaaaa')
	assert one > 0.0
	assert many > one
	// Roughly linear. A multiplier would show up here as a jump.
	assert many < one * 12.0
}

fn test_advance_scales_with_font_size() {
	mut lib := new_font_library()
	mut small := FontStyle{
		family: 'sans-serif'
		size:   10.0
	}
	mut large := small
	large.size = 40.0
	lo := lib.advance(&small, 'hello')
	hi := lib.advance(&large, 'hello')
	assert hi > lo * 2.0
}

fn test_letter_spacing_adds_per_glyph() {
	mut lib := new_font_library()
	mut style := FontStyle{
		family: 'sans-serif'
		size:   20.0
	}
	plain := lib.advance(&style, 'abcd')
	style.letter_spacing = 2.0
	spaced := lib.advance(&style, 'abcd')
	// Four glyphs, so four times the letter spacing on top.
	assert spaced > plain + 7.0
	assert spaced < plain + 9.0
}

fn test_word_spacing_only_counts_spaces() {
	mut lib := new_font_library()
	mut style := FontStyle{
		family: 'sans-serif'
		size:   20.0
	}
	plain := lib.advance(&style, 'a b')
	style.word_spacing = 5.0
	with_spacing := lib.advance(&style, 'a b')
	assert with_spacing > plain + 4.0
	// The same style on text with no space must not change at all.
	assert lib.advance(&style, 'ab') == lib.advance(&FontStyle{
		family:        'sans-serif'
		size:          20.0
		word_spacing:  5.0
	}, 'ab')
}

fn test_arabic_text_has_a_nonzero_advance() {
	// The content this browser is built for. If the Arabic chain were missing
	// this would be zero or would fail to find a font.
	mut lib := new_font_library()
	style := FontStyle{
		family: 'sans-serif'
		size:   32.0
	}
	w := lib.advance(&style, 'سلام')
	assert w > 0.0
}

fn test_ensure_arabic_chain_is_populated_once() {
	mut lib := new_font_library()
	lib.ensure_arabic_chain(400)
	first := lib.arabic_chain.len()
	assert first > 0
	// Calling it again must not add the same faces a second time, which would
	// grow the chain without bound across a long session.
	lib.ensure_arabic_chain(400)
	assert lib.arabic_chain.len() == first
}

fn test_font_set_falls_back_past_a_latin_face() {
	// The point of new_script_font_set: a primary face with no Arabic coverage
	// must not stop the Persian text from finding one.
	mut lib := new_font_library()
	lib.ensure_arabic_chain(400)
	fs := lib.font_set_for(lib.primary_id(&FontStyle{
		family: 'sans-serif'
		size:   32.0
	}))
	arabic_font := fs.pick_in(lib.ctx, `س`)
	assert arabic_font != none
}

fn test_shape_produces_positioned_glyphs() {
	mut lib := new_font_library()
	style := FontStyle{
		family: 'sans-serif'
		size:   32.0
	}
	glyphs := lib.shape('hello', &style, 0.0, 20.0)
	assert glyphs.len > 0
	for g in glyphs {
		// A glyph with no font is one the cache cannot key, and it would be
		// silently skipped at draw time.
		assert g.font_id >= 0
		assert g.gid >= 0
	}
}

fn test_shape_of_empty_text_is_empty() {
	mut lib := new_font_library()
	assert lib.shape('', &FontStyle{}, 0.0, 0.0).len == 0
}

fn test_shape_populates_the_glyph_cache() {
	mut lib := new_font_library()
	style := FontStyle{
		family: 'sans-serif'
		size:   32.0
	}
	assert lib.cache.len() == 0
	lib.shape('hello', &style, 0.0, 20.0)
	assert lib.cache.len() > 0
	// A space has no outline, so it must not be cached: caching empty bitmaps
	// would grow the map for nothing.
	for _, bm in lib.cache.entries {
		assert bm.width > 0
		assert bm.height > 0
	}
	// Every key that packed successfully must round-trip through the packer to
	// an unpackable-free value, which is what stops a font or size outside the
	// documented ranges being silently cached under a truncated key.
	assert lib.cache.unpackable() == 0
}

fn test_cache_hit_rate_improves_on_a_second_pass() {
	mut lib := new_font_library()
	style := FontStyle{
		family: 'sans-serif'
		size:   32.0
	}
	lib.shape('hello world', &style, 0.0, 20.0)
	first_rate := lib.cache.hit_rate()
	// Shaping the same text again must hit the cache, not rasterize again.
	lib.shape('hello world', &style, 0.0, 20.0)
	assert lib.cache.hit_rate() > first_rate
}

fn test_glyph_cache_stores_and_returns() {
	mut gc := new_glyph_cache()
	assert gc.len() == 0
	assert gc.get(GlyphKey{
		font_id: 0
		gid:     1
		size_q:  2048
	}) == none
	gc.put(GlyphKey{
			font_id: 0
			gid:     1
			size_q:  2048
		}, vtext.GlyphBitmap{
		coverage: []u8{len: 4}
		width:    2
		height:   2
		left:     0
		top:      0
	})
	assert gc.len() == 1
	assert gc.get(GlyphKey{
		font_id: 0
		gid:     1
		size_q:  2048
	}) != none
	assert gc.bytes == 4
}

fn test_glyph_cache_skips_empty_bitmaps() {
	// vtext returns a zero-area bitmap for a space and for a codepoint the font
	// has no outline for. Caching those costs a map entry and saves nothing.
	mut gc := new_glyph_cache()
	gc.put(GlyphKey{
		font_id: 0
		gid:     2
		size_q:  2048
	}, vtext.GlyphBitmap{
		coverage: []u8{}
		width:    0
		height:   0
		left:     0
		top:      0
	})
	assert gc.len() == 0
}

fn test_glyph_cache_clear_resets_counters() {
	mut gc := new_glyph_cache()
	gc.put(GlyphKey{
		font_id: 0
		gid:     1
		size_q:  1
	}, vtext.GlyphBitmap{
		coverage: []u8{len: 4}
		width:    2
		height:   2
		left:     0
		top:      0
	})
	_ := gc.get(GlyphKey{
		font_id: 0
		gid:     9
		size_q:  1
	})
	assert gc.hits + gc.misses == 1
	gc.clear()
	assert gc.len() == 0
	assert gc.bytes == 0
	assert gc.hits == 0
	assert gc.misses == 0
}

fn test_cache_key_distinguishes_the_fields_that_matter() {
	mut a := FontStyle{
		family: 'sans-serif'
		size:   16.0
	}
	mut b := a
	assert a.key() == b.key()

	// Each of these must change the key, or two different measurements would
	// share one cache entry.
	for field in ['weight', 'size', 'line_height', 'letter_spacing', 'word_spacing'] {
		mut changed := a
		match field {
			'weight' { changed.weight = 700 }
			'size' { changed.size = 17.0 }
			'line_height' { changed.line_height = 2.0 }
			'letter_spacing' { changed.letter_spacing = 1.0 }
			'word_spacing' { changed.word_spacing = 1.0 }
		}
		assert changed.key() != a.key()
	}
}

fn test_cache_key_distinguishes_direction() {
	mut a := FontStyle{
		family:    'sans-serif'
		size:      16.0
		direction: .rtl
	}
	mut b := a
	b.direction = .ltr
	assert a.key() != b.key()
}

fn test_quantise_size_is_finer_than_a_device_pixel() {
	// A cache keyed on 1/64 px must collapse sizes that no display can tell
	// apart, or the cache fills with near-duplicates.
	assert quantise_size(16.0) == quantise_size(16.01)
	// But must not collapse sizes a display can tell apart.
	assert quantise_size(16.0) != quantise_size(24.0)
}

fn test_quantise_subpixel_snaps_to_quarter_pixels() {
	// Subpixel arguments are QUARTERS of a pixel. Treating them as sixtieths,
	// which the same argument name suggests in stb_truetype's own
	// documentation, is sixteen times too far.
	assert quantise_subpixel(0.0) == 0
	assert quantise_subpixel(0.24) == 1
	assert quantise_subpixel(0.26) == 1
	assert quantise_subpixel(0.49) == 2
	// Clamped, never negative and never a whole pixel.
	assert quantise_subpixel(-0.5) == 0
	assert quantise_subpixel(1.0) == 3
	assert quantise_subpixel(9.0) == 3
}

fn test_min_content_is_not_greater_than_max_content() {
	// The invariant intrinsic sizing rests on. If it ever fails, min-content
	// and max-content have been computed against different shaping and phase 2
	// cannot size anything.
	mut lib := new_font_library()
	style := FontStyle{
		family: 'sans-serif'
		size:   24.0
	}
	txt := 'the quick brown fox jumps'
	assert lib.min_content_width(&style, txt) <= lib.max_content_width(&style, txt)
}

fn test_min_content_of_single_word_equals_its_advance() {
	// A word that cannot break has the same width whether or not wrapping is
	// allowed, so the two must agree.
	mut lib := new_font_library()
	style := FontStyle{
		family: 'sans-serif'
		size:   24.0
	}
	assert lib.min_content_width(&style, 'unbreakable') == lib.advance(&style, 'unbreakable')
}

fn test_min_content_of_empty_text_is_zero() {
	mut lib := new_font_library()
	assert lib.min_content_width(&FontStyle{}, '') == 0.0
}

fn test_draw_run_writes_pixels_where_glyphs_are() {
	// The end of the chain: shaped glyphs, rasterized, composited. If this
	// paints nothing, the text layer is broken regardless of what the
	// measurement tests say.
	mut lib := new_font_library()
	style := FontStyle{
		family: 'sans-serif'
		size:   48.0
	}
	glyphs := lib.shape('Hi', &style, 4.0, 40.0)
	mut c := raster.new_canvas(120, 60)
	c.clear(raster.white)
	raster_before := count_non_background(c)
	text.draw_run(mut c, glyphs, raster.black)
	assert count_non_background(c) > raster_before
}

fn count_non_background(c &raster.Canvas) int {
	mut n := 0
	for y in 0 .. c.height {
		for x in 0 .. c.width {
			if c.at(x, y) != raster.white {
				n++
			}
		}
	}
	return n
}

fn test_draw_run_of_empty_glyphs_paints_nothing() {
	mut c := raster.new_canvas(8, 8)
	c.clear(raster.white)
	before := count_non_background(c)
	text.draw_run(mut c, []PositionedGlyph{}, raster.black)
	assert count_non_background(c) == before
}

fn test_draw_run_skips_glyphs_with_no_outline() {
	// A zero-area bitmap means the font has no outline for this glyph. It must
	// be skipped rather than passed to blend_bitmap, which would read past the
	// end of an empty coverage slice.
	mut c := raster.new_canvas(8, 8)
	c.clear(raster.white)
	before := count_non_background(c)
	text.draw_run(mut c, [PositionedGlyph{
		x:     0.0
		y:     0.0
		gid:   1
		bitmap: vtext.GlyphBitmap{
			coverage: []u8{}
			width:    0
			height:   0
			left:     0
			top:      0
		}
	}], raster.black)
	assert count_non_background(c) == before
}

fn test_glyph_key_packs_and_unpacks_without_collisions() {
	// A collision here draws one glyph where another belongs. That is corrupt
	// text, not a slow path, so the packer is checked at its boundaries rather
	// than only for the values the current tests happen to use.
	base := GlyphKey{
		font_id: 7
		gid:     1234
		size_q:  quantise_size(16.0)
		sub_x:   2
		sub_y:   1
	}
	p0 := pack_glyph_key(base) or {
		assert false, 'a realistic key must pack'
		return
	}

	// Every field must move the packed value, or two of them are aliasing.
	mut seen := map[u64]bool{}
	seen[p0] = true
	for variant in [
		GlyphKey{
			font_id: 8
			gid:     base.gid
			size_q:  base.size_q
			sub_x:   base.sub_x
			sub_y:   base.sub_y
		},
		GlyphKey{
			font_id: base.font_id
			gid:     1235
			size_q:  base.size_q
			sub_x:   base.sub_x
			sub_y:   base.sub_y
		},
		GlyphKey{
			font_id: base.font_id
			gid:     base.gid
			size_q:  quantise_size(17.0)
			sub_x:   base.sub_x
			sub_y:   base.sub_y
		},
		GlyphKey{
			font_id: base.font_id
			gid:     base.gid
			size_q:  base.size_q
			sub_x:   3
			sub_y:   base.sub_y
		},
		GlyphKey{
			font_id: base.font_id
			gid:     base.gid
			size_q:  base.size_q
			sub_x:   base.sub_x
			sub_y:   2
		},
	] {
		p := pack_glyph_key(variant) or {
			assert false, 'a realistic key must pack'
			return
		}
		assert !seen[p]
		seen[p] = true
	}
}

fn test_glyph_key_uses_the_whole_64_bits_without_a_sign_problem() {
	// The packed value legitimately occupies all 64 bits, so a large font_id sets
	// the sign bit. That is why pack returns an Option instead of a sentinel: a
	// sentinel of -1 would itself be a value the packer can produce. Checked with
	// the extremes so the allocation is not quietly narrowed later.
	big := GlyphKey{
		font_id: (1 << key_font_bits) - 1
		gid:     (1 << key_gid_bits) - 1
		size_q:  (1 << (key_size_bits - 1)) - 1
		sub_x:   3
		sub_y:   3
	}
	p := pack_glyph_key(big) or {
		assert false, 'the maximum key must pack'
		return
	}
	// Every one of the 64 bits is set, so the value is u64 max.
	assert p == ~u64(0)
}

fn test_glyph_key_rejects_out_of_range_fields_instead_of_truncating() {
	// Silently dropping the high bits of a glyph id would draw a different glyph
	// and call it a cache hit. Refusing is the only safe answer.
	assert pack_glyph_key(GlyphKey{ font_id: -1 }) == none
	assert pack_glyph_key(GlyphKey{ font_id: 1 << key_font_bits }) == none
	assert pack_glyph_key(GlyphKey{ gid: -1 }) == none
	assert pack_glyph_key(GlyphKey{ gid: 1 << key_gid_bits }) == none
	assert pack_glyph_key(GlyphKey{ sub_x: -1 }) == none
	assert pack_glyph_key(GlyphKey{ sub_y: -1 }) == none
	// Subpixel offsets are quarter pixels, so only 0..3 is meaningful. This is the
	// boundary that was previously wrong: an allocation of four bits per axis
	// accepted sub_x == 4, a value quantise_subpixel can never produce.
	assert pack_glyph_key(GlyphKey{ sub_x: 4 }) == none
	assert pack_glyph_key(GlyphKey{ sub_y: 4 }) == none
	// And the extremes are still accepted, so the ranges are not off by one.
	assert pack_glyph_key(GlyphKey{ sub_x: 3 }) != none
	assert pack_glyph_key(GlyphKey{ sub_y: 3 }) != none
	assert pack_glyph_key(GlyphKey{ font_id: (1 << key_font_bits) - 1 }) != none
	assert pack_glyph_key(GlyphKey{ gid: (1 << key_gid_bits) - 1 }) != none
}

fn test_glyph_key_size_range_covers_real_font_sizes() {
	// The size field is 1/64 px biased by half, so the representable range is
	// -131072 px to 131071.98 px. Nobody renders at that size, and the point is
	// only that a real font size can never be refused or wrapped.
	for px in [f64(1), 8.0, 9.0, 12.0, 16.0, 48.0, 96.0, 200.0, 2048.0] {
		assert pack_glyph_key(GlyphKey{ size_q: quantise_size(px) }) != none
	}
	// The first size above the field is refused rather than wrapped into a
	// valid-looking one.
	assert pack_glyph_key(GlyphKey{ size_q: (1 << (key_size_bits - 1)) - 1 }) != none
	assert pack_glyph_key(GlyphKey{ size_q: 1 << (key_size_bits - 1) }) == none
	assert pack_glyph_key(GlyphKey{ size_q: 1 << key_size_bits }) == none
}

fn test_glyph_cache_counts_unpackable_keys_separately() {
	// A key that cannot be packed must be visible, not just dropped. A cache
	// silently serving nothing looks identical to one that is working.
	mut gc := new_glyph_cache()
	bm := vtext.GlyphBitmap{
		coverage: []u8{len: 4}
		width:    2
		height:   2
		left:     0
		top:      0
	}
	gc.put(GlyphKey{ sub_x: 9 }, bm)
	assert gc.len() == 0
	assert gc.unpackable() == 1
	assert gc.get(GlyphKey{ sub_x: 9 }) == none
}

fn test_every_family_has_at_least_one_candidate_present() {
	// These tests assert real measurements, so they depend on real fonts. But the
	// candidate lists are deliberately allowed to name files that are not
	// installed — that is what a fallback chain is — so the assertion is that each
	// family can be satisfied, not that every name resolves. If a whole family
	// went unsatisfiable the tests would silently measure against no font.
	lib := new_font_library()
	for name in [...sans_faces, ...serif_faces, ...mono_faces] {
		_ := name
	}
	assert lib.open_face(sans_faces) >= 0
	assert lib.open_face(sans_bold_faces) >= 0
	assert lib.open_face(serif_faces) >= 0
	assert lib.open_face(serif_bold_faces) >= 0
	assert lib.open_face(mono_faces) >= 0
	assert lib.open_face(mono_bold_faces) >= 0
	assert lib.open_face(arabic_faces) >= 0
	assert lib.open_face(arabic_bold_faces) >= 0
}

fn test_some_named_candidates_are_absent_and_that_is_fine() {
	// Pinning the fact that made test_every_family fail. cambria.ttf and
	// constantia.ttf are listed as serif candidates and are not installed on this
	// host. The chain skips them and takes georgia.ttf instead, which is the
	// behaviour the design calls for. If a future Windows release installs them,
	// this test starts failing and the correct response is to delete it, not to
	// add special handling.
	lib := new_font_library()
	assert lib.find_face('cambria.ttf') == ''
	assert lib.find_face(serif_faces[0]) != ''
}
// --- every shaped glyph must be drawable --------------------------------------

// A glyph whose font the library cannot resolve is skipped by `place_glyphs`, and a
// skipped glyph is a hole in the page: the text reads "Block layout and pai" because
// the last two characters went missing and nothing said so.
//
// The count is asserted rather than a boolean so that a failure says how many glyphs
// went missing, which is the difference between "one face is unregistered" and "most
// of this run never had a font".

fn test_every_glyph_of_a_shaped_run_has_a_registered_font() {
	mut lib := new_font_library()
	mut style := FontStyle{ family: 'sans-serif', size: 16.0 }
	run := lib.shape('Block layout and paint', &style, 0.0, 20.0)
	assert run.len > 0
	mut missing := 0
	for g in run {
		if g.font_id < 0 {
			missing++
		}
	}
	assert missing == 0
}

fn test_every_glyph_of_a_bold_run_has_a_registered_font() {
	// Bold resolves to a different face, and a face resolved through the candidate
	// list is the one most likely to be missing from the path map.
	mut lib := new_font_library()
	mut style := FontStyle{ family: 'sans-serif', size: 32.0, weight: 700 }
	run := lib.shape('Block layout and paint', &style, 0.0, 40.0)
	assert run.len > 0
	mut missing := 0
	for g in run {
		if g.font_id < 0 {
			missing++
		}
	}
	assert missing == 0
}

fn test_every_glyph_of_a_wrapped_run_has_a_registered_font() {
	// The path layout actually uses. Wrapping shapes through the font set rather than
	// through one face, so it is a different route to the same place.
	mut lib := new_font_library()
	mut style := FontStyle{ family: 'sans-serif', size: 16.0 }
	lines := lib.wrap(WrapRequest{
		content:        'A paragraph with enough words in it that it has to be broken'
		style:          &style
		max_width:      120.0
		origin_x:       0.0
		first_baseline: 20.0
		line_height:    20.0
	})
	assert lines.len > 1
	mut missing := 0
	mut total := 0
	for line in lines {
		for g in line.glyphs {
			total++
			if g.font_id < 0 {
				missing++
			}
		}
	}
	assert total > 0
	assert missing == 0
}

fn test_every_glyph_of_a_persian_run_has_a_registered_font() {
	// Persian shapes against the Arabic chain, which is a second set of faces entirely.
	// A page in Persian is why this project exists, so this is the one that matters most.
	mut lib := new_font_library()
	mut style := FontStyle{ family: 'sans-serif', size: 24.0 }
	run := lib.shape('سلام دنیا', &style, 0.0, 30.0)
	assert run.len > 0
	mut missing := 0
	for g in run {
		if g.font_id < 0 {
			missing++
		}
	}
	assert missing == 0
}
fn test_shaping_a_bold_run_first_does_not_break_later_runs() {
	// The page shapes its heading before its body text, and the heading is the only
	// bold thing on it. If the first run leaves the library in a state where later runs
	// cannot resolve their fonts, this is where it shows -- and it is the difference
	// between "shaping is broken" and "shaping is broken after something else ran
	// first", which are very different bugs.
	mut lib := new_font_library()
	mut bold := FontStyle{ family: 'sans-serif', size: 32.0, weight: 700 }
	mut regular := FontStyle{ family: 'sans-serif', size: 16.0 }
	_ = lib.shape('Block layout and paint', &bold, 0.0, 40.0)

	mut missing_after_bold := 0
	for text in ['A paragraph with enough words in it that it has to be broken across',
		'A bordered box with a background.', 'A box with a thick left border.',
		'Second paragraph.'] {
		for g in lib.shape(text, &regular, 0.0, 20.0) {
			if g.font_id < 0 {
				missing_after_bold++
			}
		}
	}
	assert missing_after_bold == 0
}

fn test_wrapping_after_a_bold_run_keeps_every_glyph() {
	mut lib := new_font_library()
	mut bold := FontStyle{ family: 'sans-serif', size: 32.0, weight: 700 }
	mut regular := FontStyle{ family: 'sans-serif', size: 16.0 }
	_ = lib.shape('Block layout and paint', &bold, 0.0, 40.0)
	lines := lib.wrap(WrapRequest{
		content:        'A bordered box with a background.'
		style:          &regular
		max_width:      400.0
		origin_x:       0.0
		first_baseline: 20.0
		line_height:    20.0
	})
	mut missing := 0
	for line in lines {
		for g in line.glyphs {
			if g.font_id < 0 {
				missing++
			}
		}
	}
	assert missing == 0
}
// --- the glyph cache, on its own ----------------------------------------------

// The cache round-trip is the fork in the open bug: every cache hit has been coming
// back with an empty bitmap, and either the cache is losing the value or the caller is
// throwing it away. These two tests say which.

fn test_the_cache_returns_what_was_put_into_it() {
	mut lib := new_font_library()
	mut style := FontStyle{ family: 'sans-serif', size: 16.0 }
	fid := lib.primary_id(&style)
	assert fid >= 0
	f := lib.font(fid) or { panic('no font') }
	gid := int(f.glyph_index(`m`))
	bm := f.rasterize(u16(gid), 16.0, 0, 0)
	assert bm.width > 0

	mut gc := new_glyph_cache()
	k := GlyphKey{ font_id: fid, gid: gid, size_q: quantise_size(16.0), sub_x: 0, sub_y: 0 }
	gc.put(k, bm)
	assert gc.len() == 1

	got := gc.get(k) or {
		assert false, 'the cache missed a key it holds'
		return
	}
	// The width is the assertion. A cache that returns the zero bitmap for a key it
	// holds is indistinguishable, from the outside, from a cache that stores nothing.
	assert got.width == bm.width
	assert got.height == bm.height
}

fn test_the_cache_stores_one_entry_per_distinct_key() {
	// Ten glyphs over four quarter-pixel offsets is four keys, not ten. If the count came
	// out as ten, two glyphs were sharing a key and one of them was being drawn with the
	// other's ink.
	mut lib := new_font_library()
	mut style := FontStyle{ family: 'sans-serif', size: 16.0 }
	fid := lib.primary_id(&style)
	f := lib.font(fid) or { panic('no font') }
	gid := int(f.glyph_index(`m`))
	mut gc := new_glyph_cache()
	for sub in [0, 1, 2, 3, 0, 1, 2, 3, 0, 1] {
		bm := f.rasterize(u16(gid), 16.0, sub, 0)
		gc.put(GlyphKey{ font_id: fid, gid: gid, size_q: quantise_size(16.0), sub_x: sub,
			sub_y: 0 }, bm)
	}
	assert gc.len() == 4
	assert gc.unpackable() == 0
}