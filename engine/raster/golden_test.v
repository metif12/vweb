module raster

import os

// This is the phase 0 acceptance gate: a page-shaped buffer of pixels comes out
// of the compositor and matches a stored expectation exactly.
//
// The image is drawn the way text will be drawn in phase 1: a tinted coverage
// bitmap rather than a fill, so the glyph path is covered by the very first
// golden rather than only by unit tests. The blocks and rule are filled
// rectangles, so both the fast opaque path and the general blend path are in
// the picture.

fn draw_reference(c &Canvas) {
	c.clear(rgb(250, 250, 248))
	// An opaque block and a translucent one over the background, to pin both
	// sides of the blend decision.
	c.fill_rect(8, 8, 40, 24, rgb(30, 90, 160))
	c.fill_rect(56, 8, 40, 24, rgba(200, 60, 40, 128))
	// A hairline rule, which is the shape borders reduce to.
	c.fill_rect(8, 36, 88, 1, rgb(120, 120, 120))
	// Two lines of "text" as coverage bitmaps, the second at partial coverage.
	line1 := [
		u8(0),
		u8(90),
		u8(200),
		u8(255),
		u8(255),
		u8(200),
		u8(90),
		u8(0),
		u8(0),
		u8(90),
		u8(200),
		u8(255),
		u8(255),
		u8(200),
		u8(90),
		u8(0),
	]
	line2 := [
		u8(30),
		u8(140),
		u8(210),
		u8(140),
		u8(30),
		u8(30),
		u8(140),
		u8(210),
		u8(140),
		u8(30),
	]
	c.blend_bitmap(8, 44, 8, 2, 8, line1, black)
	c.blend_bitmap(8, 50, 5, 2, 5, line2, rgb(40, 40, 40))
}

fn test_golden_reference_image() {
	mut c := new_canvas(104, 56)
	draw_reference(c)
	check_golden(c, 'phase0_reference')!
}

fn test_golden_is_reproducible() {
	// The same input must produce the same bytes, or the golden above proves
	// nothing. This is the test that would catch nondeterminism introduced by a
	// hash map iteration order or an uninitialised buffer.
	mut a := new_canvas(64, 48)
	mut b := new_canvas(64, 48)
	draw_reference(a)
	draw_reference(b)
	assert a.pix == b.pix
	// And a fresh buffer must be zeroed identically every time.
	assert new_canvas(17, 5).pix == []u8{len: 17 * 5 * 4}
}

fn test_golden_helper_detects_a_changed_pixel() {
	// Proving the gate can fail. A golden test that has never been seen red is
	// untested, not correct, so this deliberately renders a different image and
	// checks that diff_golden sees it. diff_golden is used here rather than
	// check_golden because check_golden asserts, and a failing assert inside a
	// test is not something to write on purpose.
	mut c := new_canvas(104, 56)
	draw_reference(c)
	assert diff_golden(c, 'phase0_reference') == 0

	// One channel of one pixel, off by one.
	c.pix[0] = u8(c.pix[0] ^ 1)
	assert diff_golden(c, 'phase0_reference') == 1
}

fn test_golden_helper_reports_a_size_mismatch() {
	// A canvas of a different size must report a mismatch rather than comparing
	// the leading bytes and calling it a match.
	mut c := new_canvas(8, 8)
	c.clear(white)
	assert diff_golden(c, 'phase0_reference') == -1
}

fn test_golden_png_is_written_and_readable() {
	// The PNG is how a human looks at a failure, so it has to be a real file
	// with plausible contents rather than something that merely does not crash.
	mut c := new_canvas(16, 16)
	c.clear(white)
	c.fill_rect(4, 4, 8, 8, red)
	path := golden_path('phase0_roundtrip', '.png')
	c.write_png(path)!
	defer {
		os.rm(path) or {}
	}
	info := os.stat(path)!
	assert info.size > 8
	// A PNG always starts with this signature, so a wrong byte order or a
	// truncated write is caught here rather than by whoever opens the file.
	head := os.read_file(path) or { panic('png vanished') }
	assert head.len > 40
	sig := [u8(137), u8(80), u8(78), u8(71), u8(13), u8(10), u8(26), u8(10)]
	for i, b in sig {
		assert head[i] == b
	}
	// The IHDR chunk carries the dimensions big-endian at a fixed offset, which
	// is a cheap way to prove the header describes the image we asked for
	// rather than some other one.
	w := (int(head[16]) << 24) | (int(head[17]) << 16) | (int(head[18]) << 8) | int(head[19])
	h := (int(head[20]) << 24) | (int(head[21]) << 16) | (int(head[22]) << 8) | int(head[23])
	assert w == 16
	assert h == 16
}
