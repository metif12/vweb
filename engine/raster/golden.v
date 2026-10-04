module raster

// Golden-image comparison for the pixel buffer.
//
// The comparison is on raw RGBA bytes, not on a PNG file. Two reasons. A PNG
// encoder's output is a function of its version and its compression settings,
// so comparing encoded bytes means a stb_image upgrade fails every test for a
// reason that has nothing to do with the engine. And the thing being tested is
// the pixel buffer: the PNG is a way of looking at it, not the artefact.
//
// The comparison is exact. That is not an aesthetic preference, it is what the
// integer arithmetic in this module was chosen to make possible, and a golden
// test that has to tolerate a per-channel tolerance is no longer able to catch
// a one-step rounding error — which is the class of bug most likely to appear
// when someone later "fixes" the rounding in blend_at.

import os

// goldens_dir is where expected buffers live, relative to the module root.
// @VMODROOT is the directory holding v.mod, so this does not depend on the
// working directory the test happened to be started from.
pub const goldens_dir = 'testdata/golden'

fn golden_path(name string, suffix string) string {
	return os.join_path(os.join_path(@VMODROOT, goldens_dir), name + suffix)
}

// check_golden compares a canvas against the stored buffer for `name`.
//
// On a match it does nothing and returns. On a mismatch it writes
// `name.actual.raw` and `name.actual.png` next to the expected file and fails
// the assertion, so a failure leaves behind something that can be looked at
// rather than only a count of differing pixels.
pub fn check_golden(c &Canvas, name string) ! {
	expected_path := golden_path(name, '.raw')
	actual_path := golden_path(name, '.actual.raw')
	png_path := golden_path(name, '.actual.png')
	// os.write_file takes a string, and V strings are byte arrays, so the
	// buffer goes across bytestr rather than being copied into a new string.
	// The length is the array length, so no terminator is implied and no
	// embedded NUL truncates anything.
	bytes := unsafe { c.pix.bytestr() }

	if !os.exists(expected_path) {
		// No expectation yet. Write one and fail, because a golden test that
		// passes the first time it runs has not been shown to detect anything.
		// write_golden is the supported way to create one deliberately; reaching
		// this branch means a test was added without creating its golden.
		os.mkdir_all(os.join_path(@VMODROOT, goldens_dir), os.MkdirParams{})!
		os.write_file(expected_path, bytes)!
		c.write_png(golden_path(name, '.png'))!
		eprintln('no golden for ${name}: wrote one to ${expected_path}')
		assert false, 'golden missing: ${name} (a golden test must be seen failing once)'
		return
	}

	want := os.read_file(expected_path)!
	if want.len != c.pix.len {
		c.write_png(png_path)!
		eprintln('${name}: size ${c.width}x${c.height} but golden is ${want.len / 4} pixels')
		assert false, 'golden size mismatch: ${name}'
		return
	}

	mut diff := 0
	mut first := -1
	mut i := 0
	for i < want.len {
		if unsafe { want[i] } != c.pix[i] {
			diff++
			if first < 0 {
				first = i
			}
		}
		i++
	}

	if diff > 0 {
		c.write_png(png_path)!
		os.write_file(actual_path, bytes)!
		px := first / 4
		eprintln('${name}: ${diff} of ${want.len} bytes differ')
		eprintln('  first at pixel (${px % c.width}, ${px / c.width}), byte ${first % 4}')
		eprintln('  want ${unsafe { want[first] }} got ${c.pix[first]}')
		eprintln('  wrote ${png_path}')
		assert false, 'golden mismatch: ${name}'
	}
}

// write_golden stores the current buffer as the expectation for `name`. Used by
// the -update-goldens flag and by the first run of a new test.
pub fn write_golden(c &Canvas, name string) ! {
	dir := os.join_path(@VMODROOT, goldens_dir)
	os.mkdir_all(dir, os.MkdirParams{})!
	path := os.join_path(dir, name + '.raw')
	os.write_file(path, unsafe { c.pix.bytestr() })!
	c.write_png(path.replace('.raw', '.png'))!
	eprintln('wrote golden ${name}')
}

// diff_golden reports how far a canvas is from its golden without failing, so a
// development build can keep going and show a summary. Returns -1 if there is
// no golden or the sizes disagree.
pub fn diff_golden(c &Canvas, name string) int {
	want := os.read_file(golden_path(name, '.raw')) or {
		return -1
	}
	if want.len != c.pix.len {
		return -1
	}
	mut diff := 0
	mut i := 0
	for i < want.len {
		if unsafe { want[i] } != c.pix[i] {
			diff++
		}
		i++
	}
	return diff
}