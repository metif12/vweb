module raster

// The one place this module reaches outside itself. Keeping it in a .c.v file
// means raster.v stays pure V and can be checked with -Wimpure-v, which is
// worth having on a file that does all of the pixel arithmetic.

import stbi

// write_png_rgba writes straight-alpha RGBA, which is what stb_image_write
// expects. Canvas holds premultiplied pixels, so the caller unpremultiplies
// first; see Canvas.write_png.
fn write_png_rgba(path string, w int, h int, buf []u8, stride int) ! {
	if buf.len == 0 {
		return
	}
	stbi.stbi_write_png(path, w, h, 4, &buf[0], stride)!
}