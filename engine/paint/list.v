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
//
// Why clipping lives here and not in the compositor.
//
// A clip is a property of the page, not of the target: which boxes confine their
// descendants is decided when the tree is walked, and it is decided exactly once.
// Leaving it to the compositor would mean the list held the child's command at the
// geometry it would have had anyway, and every consumer replaying the list -- a
// tile, a texture, a window in a later phase -- would have to reconstruct the box
// structure to know that the command should have been confined. A list that omits
// the clip is not a complete plan.
//
// The alternative -- a clip stack pushed by a box and popped by the compositor --
// buys nothing here, because the compositor would still have to be told the
// rectangle. What it costs is that the list no longer says what it means: a tool
// reading the list cannot see the confinement, and `tools/boxes.v --list` is that
// tool. So a clip is a command, and the compositor keeps a stack of saved
// rectangles to undo it, which is four integers and no box knowledge.
pub enum Kind {
	fill_rect
	glyph_run
	image
	rounded_rect
	rounded_band
	clip_push
	clip_pop
	group_begin
	group_end
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
// than unset. The kinds added for Phase 3's visual properties follow the same rule:
// a rounded fill adds `corners`, a rounded border side adds `band`, a clip adds
// nothing but its rectangle, and a group carries its alpha.
pub struct Command {
pub mut:
	kind    Kind
	rect    display.Rect
	color   raster.Color
	glyphs  []text.PositionedGlyph
	image   ImagePainting
	corners raster.Corners
	band    raster.Band
	alpha   int
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

// rounded_rect records a rounded fill. It is a different kind from `fill_rect`
// rather than a field on it, because the compositor's work is different: a rounded
// fill decides each pixel's coverage, and a golden image of a corner has to be
// reproducible from the list alone.
pub fn (mut l DisplayList) rounded_rect(rect display.Rect, corners raster.Corners, color raster.Color) {
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 {
		return
	}
	mut cmd := Command{ kind: .rounded_rect, rect: rect, color: color, corners: corners }
	l.commands << cmd
}

// rounded_band records one side of a rounded border. Four of them make a border
// whose corners follow the ellipse instead of being clipped by it.
pub fn (mut l DisplayList) rounded_band(band raster.Band, side raster.Side, color raster.Color) {
	if color.a == 0 {
		return
	}
	mut cmd := Command{ kind: .rounded_band, color: color, band: band }
	cmd.rect = display.Rect{ x: band.x, y: band.y, width: band.w, height: band.h }
	cmd.alpha = int(side)
	l.commands << cmd
}

// clip_push confines every later command to `rect` until the matching clip_pop.
//
// The rectangle is the box's padding box, which is what CSS 2.1 11.1 clips to: an
// `overflow: hidden` box still shows its own border, and clips only what is inside
// the border. A rectangle with no area records nothing -- there is no region to
// confine anything to, and a command that cannot do anything is noise in a golden
// diff.
pub fn (mut l DisplayList) clip_push(rect display.Rect) {
	if rect.width <= 0 || rect.height <= 0 {
		return
	}
	mut cmd := Command{ kind: .clip_push, rect: rect }
	l.commands << cmd
}

pub fn (mut l DisplayList) clip_pop() {
	l.commands << Command{ kind: .clip_pop }
}

// group_begin opens an opacity group: everything until the matching group_end is
// composited among themselves and then blended onto what was behind them at
// `alpha`, which is the one number that makes the subtree translucent rather than
// each command in it.
pub fn (mut l DisplayList) group_begin(alpha int) {
	mut cmd := Command{ kind: .group_begin, alpha: alpha }
	l.commands << cmd
}

pub fn (mut l DisplayList) group_end() {
	l.commands << Command{ kind: .group_end }
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

// Group is one open opacity group: the buffer its subtree was composited into, and
// the alpha the buffer is blended out at. The alpha travels with the buffer rather
// than with the closing command because the list is read linearly and a reader that
// wants to undo a group has to find the number that opened it.
struct Group {
mut:
	buf   &raster.Canvas
	alpha int
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
//
// The two structures this walks are the two the list asks for. A clip is a stack of
// rectangles on the canvas, one entry per open clip. A group is a stack of
// offscreen buffers, one per open group, and the commands inside it are drawn into
// the innermost buffer rather than onto the canvas; when the group closes, that
// buffer is blended onto the new innermost one at its alpha. Both are balanced by
// the walk that built the list, and an unmatched pop is dropped rather than allowed
// to widen the clip past the canvas or blend an empty buffer.
pub fn composite(mut c raster.Canvas, l &DisplayList) {
	c.set_clip(0, 0, c.width, c.height)
	// The clip stack, as flattened x, y, w, h quadruples. Four separate arrays would
	// be four chances to pop the wrong number of entries.
	mut clips := []int{}
	// The group buffers, innermost last.
	mut groups := []Group{}
	for cmd in l.commands {
		match cmd.kind {
			.clip_push {
				cx, cy, cw, ch := c.save_clip()
				clips << cx
				clips << cy
				clips << cw
				clips << ch
				c.narrow_clip(cmd.rect.x, cmd.rect.y, cmd.rect.width, cmd.rect.height)
				// The innermost group buffer is narrowed by the same rectangle, and
				// that is the whole of the interaction between the two stacks. A group
				// is an offscreen canvas the subtree is composited into, so a clip
				// inside it has to confine *that*: narrowing the destination instead
				// leaves the group's own contents unconfined and clips only what is
				// drawn after the group closes. Both are narrowed by the same
				// rectangle and both were opened at the same clip, so they stay in
				// step without either needing to know about the other.
				if groups.len > 0 {
					mut inner := groups[groups.len - 1].buf
					inner.narrow_clip(cmd.rect.x, cmd.rect.y, cmd.rect.width, cmd.rect.height)
				}
			}
			.clip_pop {
				if clips.len >= 4 {
					c.set_clip(clips[clips.len - 4], clips[clips.len - 3], clips[clips.len - 2],
						clips[clips.len - 1])
					if groups.len > 0 {
						mut inner := groups[groups.len - 1].buf
						inner.set_clip(clips[clips.len - 4], clips[clips.len - 3], clips[clips.len - 2],
							clips[clips.len - 1])
					}
					clips.delete_last()
					clips.delete_last()
					clips.delete_last()
					clips.delete_last()
				}
			}
			.group_begin {
				mut g := Group{
					buf:   raster.new_canvas(c.width, c.height)
					alpha: cmd.alpha
				}
				// The buffer inherits the clip it was opened inside, so a group
				// inside a clipped box is confined by both and the region the buffer
				// can have anything in is exactly the region it is blended over.
				cx, cy, cw, ch := c.save_clip()
				g.buf.set_clip(cx, cy, cw, ch)
				groups << g
			}
			.group_end {
				if groups.len > 0 {
					done := groups[groups.len - 1]
					groups.delete_last()
					if groups.len == 0 {
						c.blend_group(done.buf, done.alpha)
					} else {
						mut outer := groups[groups.len - 1]
						outer.buf.blend_group(done.buf, done.alpha)
					}
				}
			}
			else {
				if groups.len > 0 {
					mut target := groups[groups.len - 1].buf
					draw_cmd(mut target, cmd)
				} else {
					draw_cmd(mut c, cmd)
				}
			}
		}
	}
}

// draw_cmd composites one drawing command onto whatever the current target is. It
// is the part of the old `composite` body that was never about state.
fn draw_cmd(mut c raster.Canvas, cmd Command) {
	match cmd.kind {
		.fill_rect {
			c.fill_rect(cmd.rect.x, cmd.rect.y, cmd.rect.width, cmd.rect.height, cmd.color)
		}
		.rounded_rect {
			c.fill_rounded_rect(cmd.rect.x, cmd.rect.y, cmd.rect.width, cmd.rect.height,
				cmd.corners, cmd.color)
		}
		.rounded_band {
			c.fill_band(cmd.band, unsafe { raster.Side(cmd.alpha) }, cmd.color)
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
		.clip_push, .clip_pop, .group_begin, .group_end {}
	}
}
