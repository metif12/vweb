module raster

// Decode tests. They need an image on disk to decode, and rather than committing a
// binary fixture the PNG is written through this module's own writer and read back
// -- so the encode and the decode paths are tested against each other, and a test
// that stops working because a fixture went missing cannot happen.
//
// The pixels are given in premultiplied form and written as straight, which is
// exactly the round trip `Canvas.write_png` performs. Opaque colours survive it
// exactly, and so does a 50% colour whose channels already fit in eight bits
// (128, 0, 0, 128), which is what the second test uses.

import os

fn png_bytes(w int, h int, cols []Color) []u8 {
	dir := os.vtmp_dir()
	os.mkdir_all(dir) or { panic(err) }
	path := os.join_path(dir, 'vweb_decode_test.png')
	mut c := new_canvas(w, h)
	for i, col in cols {
		c.set(i % w, i / w, col)
	}
	c.write_png(path) or { panic('cannot write test png: ' + err.msg()) }
	defer {
		os.rm(path) or {}
	}
	return (os.read_file(path) or { panic(err) }).bytes()
}

fn test_decode_bitmap_reads_a_png_back() {
	data := png_bytes(2, 1, [rgb(255, 0, 0), rgba(0, 0, 255, 128)])
	bm := decode_bitmap(data) or { panic(err) }
	assert bm.width == 2
	assert bm.height == 1
	assert bm.pix == [u8(255), 0, 0, 255, 0, 0, 128, 128]
}

fn test_decode_bitmap_is_premultiplied() {
	// The one place the invariant can break: stb_image hands back straight alpha,
	// and a straight-alpha bitmap composited as if it were premultiplied
	// brightens every translucent pixel. Half-transparent white is 128 in every
	// channel, not 255.
	bm := decode_bitmap(png_bytes(1, 1, [rgba(255, 255, 255, 128)])) or { panic(err) }
	assert bm.width == 1
	assert bm.pix.len == 4
	assert bm.pix[0] <= bm.pix[3]
	assert bm.pix == [u8(128), 128, 128, 128]
}

fn test_decode_bitmap_refuses_bytes_that_are_not_an_image() {
	// A url() the loader reached but that is not an image is a warning the caller
	// reports, not a panic in the middle of a composite.
	if _ := decode_bitmap('<html>not an image</html>'.bytes()) {
		assert false, 'expected an error for non-image bytes'
	}
}

fn test_decode_bitmap_refuses_empty_bytes() {
	if _ := decode_bitmap([]u8{}) {
		assert false, 'expected an error for empty input'
	}
}
