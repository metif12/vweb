module raster

// Decoding an image from bytes.
//
// This is the only path that produces a Bitmap, and it takes bytes rather than a
// path or a URL. That is ARCHITECTURE.md 1 in practice: the engine reads bytes
// and writes a pixel buffer, so the fetching belongs to whoever owns the loader
// (engine/page) and the decoding belongs here. Nothing below opens a file.
//
// vlib/image ships a format registry with no formats registered, so `decode` has
// always answered "image: unknown format" for everything. `register_stbi_formats`
// installs the stb_image decoders, which is the same code the PNG writer in
// png.c.v already links. Calling it more than once is harmless: registration
// replaces by name rather than appending, so a second call does not leave two
// decoders sniffing the same magic.

import image
import io

// ByteReader is an io.Reader over a byte slice. vlib's decode takes a reader, and
// the bytes have already arrived by the time this is called, so wrapping them is
// what keeps the engine from opening the file a second time -- which would also
// mean the engine needed the path, and the path is not this module's business.
//
// It is passed by pointer, not by value: the reader is handed to vlib as an
// io.Reader, and an interface holding a *copy* would advance the copy's position
// and leave this one at zero, so every read after the first would restart from
// the beginning.
@[heap]
struct ByteReader {
	src []u8
mut:
	pos int
}

fn (mut r ByteReader) read(mut buf []u8) !int {
	if r.pos >= r.src.len {
		return io.Eof{}
	}
	n := copy(mut buf, r.src[r.pos..])
	r.pos += n
	return n
}

// decode_bitmap decodes PNG, JPEG, GIF, BMP, PSD, PNM or HDR bytes into a
// premultiplied bitmap.
//
// Bytes that match no format, or that match one and fail to decode, are an
// error. The caller turns that into a warning and draws nothing, which is what a
// page with a broken image should do.
pub fn decode_bitmap(data []u8) !&Bitmap {
	if data.len == 0 {
		return error('image: empty input')
	}
	image.register_stbi_formats()
	mut rd := &ByteReader{ src: data }
	mut img, _ := image.decode(rd) or { return error('cannot decode image: ' + err.msg()) }
	nrgba := img as image.NRGBA
	r := nrgba.bounds()
	return from_straight_rgba(r.dx(), r.dy(), nrgba.pix, nrgba.stride)
}
