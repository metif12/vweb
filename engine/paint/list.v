module paint

import engine.display
import engine.raster
import engine.style
import text

// A display list: the drawing operations a box tree turned into, in the order they
// must be composited.
//
// The list exists so that "what would be drawn" and "what does it look like" are two
// questions with two answers. Every assertion in paint_test.v about a page's painting
// is made against the list, not against pixels, because a list says *which* rectangle
// and *which* colour, while a pixel only says that something is not the background.
// The renderer at the bottom is then small enough to read in one sitting, which is
// the point of having it.
//
// Commands are integers and premultiplied colours throughout, and the order is
// parents before children, so a golden image can compare bytes rather than a
// tolerance.

pub enum Kind {
	fill_rect
	glyph_run
	image
}

// ImagePainting is what an image command carries beyond the bitmap itself.
//
// `draw` is where one tile of the image lands, already resolved from
// background-position and background-size; `repeat` says whether that tile repeats.
// The list never holds the tiles -- a repeated background is one command whose
// repetition the compositor decides -- because the number of tiles is a question
// about the target, not about the page.
pub struct ImagePainting {
pub mut:
	bitmap &raster.Bitmap = unsafe { nil }
	draw   display.Rect
	repeat style.BackgroundRepeat
}

// Command is one drawing operation.
//
// `kind` is a tag rather than a sum type because V has no sum types in this version,
// and a struct with three fields where one is meaningful per kind is the honest shape
// of that limitation: `rect` and `color` belong to a fill, `glyphs` and `color` to a
// run, `image` to a background image, and the unused field of each is zero rather
// than unset.
pub struct Command {
pub mut:
	kind   Kind
	rect   display.Rect
	color  raster.Color
	glyphs []text.PositionedGlyph
	image  ImagePainting
}

@[heap]
pub struct DisplayList {
pub mut:
	commands []Command
}

pub fn new_list() &DisplayList {
	return &DisplayList{}
}

pub fn (mut l DisplayList) fill_rect(rect display.Rect, color raster.Color) {
	// A zero-area or fully transparent fill changes nothing, so it is not recorded.
	// A golden image that contained thousands of no-op commands would still compare
	// equal, and the noise would make a real difference hard to find in a diff.
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 {
		return
	}
	mut cmd := Command{ kind: .fill_rect, rect: rect, color: color }
	l.commands << cmd
}

pub fn (mut l DisplayList) glyph_run(glyphs []text.PositionedGlyph, color raster.Color) {
	if glyphs.len == 0 || color.a == 0 {
		return
	}
	mut cmd := Command{ kind: .glyph_run, color: color }
	cmd.glyphs = glyphs
	l.commands << cmd
}

// image records one background image. `area` is the box's background area and `x`,
// `y`, `width`, `height` is the first tile inside it; the compositor does the tiling.
pub fn (mut l DisplayList) image(area display.Rect, x int, y int, width int, height int, bitmap &raster.Bitmap, repeat style.BackgroundRepeat) {
	if area.width <= 0 || area.height <= 0 || width <= 0 || height <= 0 {
		return
	}
	mut cmd := Command{ kind: .image, rect: area }
	cmd.image = ImagePainting{
		bitmap: bitmap
		draw:   display.Rect{ x: x, y: y, width: width, height: height }
		repeat: repeat
	}
	l.commands << cmd
}

pub fn (l &DisplayList) len() int {
	return l.commands.len
}

// count returns how many commands are of one kind, for tests that care about "there is
// exactly one background here" rather than about the whole sequence.
pub fn (l &DisplayList) count(kind Kind) int {
	mut n := 0
	for cmd in l.commands {
		if cmd.kind == kind {
			n++
		}
	}
	return n
}

// composite draws the list onto a canvas, in order.
//
// It is a plain function and not a method on raster.Canvas because V only allows a
// type's methods to be declared in that type's own module, and this one belongs to
// paint.
//
// This is the only place in paint that touches pixels, and it holds no policy: what
// to draw was decided when the list was built. Keeping it that way is what lets a
// later phase replay the same list onto a different target -- a tile, a texture, a
// window -- with no change to the walk that produced it.
pub fn composite(mut c raster.Canvas, l &DisplayList) {
	for cmd in l.commands {
		match cmd.kind {
			.fill_rect {
				c.fill_rect(cmd.rect.x, cmd.rect.y, cmd.rect.width, cmd.rect.height, cmd.color)
			}
			.glyph_run {
				text.draw_run(mut c, cmd.glyphs, cmd.color)
			}
			.image {
				// Repeat flags rather than the enum, because the tiling loop asks the
				// two axes separately and a `match` here would only serve to spell out
				// which of the four combinations sets which.
				mut rx := false
				mut ry := false
				match cmd.image.repeat {
					.repeat {
						rx = true
						ry = true
					}
					.repeat_x {
						rx = true
					}
					.repeat_y {
						ry = true
					}
					.no_repeat {}
				}
				c.blend_image_area(cmd.rect.x, cmd.rect.y, cmd.rect.width, cmd.rect.height,
					cmd.image.draw.x, cmd.image.draw.y, cmd.image.draw.width, cmd.image.draw.height,
					cmd.image.bitmap, rx, ry)
			}
		}
	}
}
