module paint

import engine.css
import engine.display
import engine.raster
import engine.selector
import engine.style
import net.html
import text

// These tests build the tree by hand for the reason written in
// engine/display/display_test.v, and they duplicate that file's `el`/`attach`
// helpers rather than sharing them. A shared test helper would have to live in the
// non-test build of one module and be exported for the other, which is a worse trade
// than twenty duplicated lines that say what they do.

// Every sheet here sets `line-height: 20px` so vertical numbers are exact rather than
// a function of which face the machine has, and includes the UA sheet with the body
// margin reset, so a `div` is a block and `800` really is the page width.
const reset = 'body { margin: 0 } * { line-height: 20px; }'

fn el(name string, id string) &html.Tag {
	mut node := &html.Tag{ name: name, attributes: map[string]string{} }
	if id != '' {
		node.attributes['id'] = id
	}
	return node
}

fn text_el(content string) &html.Tag {
	return &html.Tag{ name: 'text', content: content }
}

fn attach(mut parent &html.Tag, children ...&html.Tag) {
	mut kids := []&html.Tag{}
	for child in children {
		kids << child
	}
	mut i := 0
	for i < kids.len {
		mut child := kids[i]
		parent.children << child
		child.parent = parent
		i++
	}
}

fn layout(root &html.Tag, src string, width int) &display.Box {
	l := style.new_engine([style.Sheet{
		style:  css.parse(css.user_agent_css + reset + ' ' + src)
		origin: style.Origin.author
	}])
	mut lo := display.Layouter{
		engine:          l
		state:           &selector.State{}
		fonts:           text.new_font_library()
		viewport_width:  width
		viewport_height: 600
	}
	return lo.layout(root)
}

fn list_of(root &html.Tag, src string, width int) &DisplayList {
	return image_list(root, src, width, map[string]&raster.Bitmap{})
}

// image_list is list_of for a caller that has decoded the page's background
// images, which is the only way a test can get an image command at all: the
// cascade records a URL and the painter looks the URL up in a map it was handed.
fn image_list(root &html.Tag, src string, width int, images map[string]&raster.Bitmap) &DisplayList {
	mut p := new_painter_with_images(images)
	p.paint(layout(root, src, width))
	return p.list
}

// two_by_one_bitmap is an opaque image of two differently coloured pixels, which is
// enough to find in the display list without a decoder in the test.
fn two_by_one_bitmap() &raster.Bitmap {
	mut src := []u8{len: 2 * 4}
	src[0] = 255
	src[3] = 255
	src[4] = 0
	src[5] = 0
	src[6] = 255
	src[7] = 255
	return raster.from_straight_rgba(2, 1, src, 8)
}

fn images_with(url string) map[string]&raster.Bitmap {
	mut m := map[string]&raster.Bitmap{}
	m[url] = two_by_one_bitmap()
	return m
}

fn box_for(root &display.Box, id string) &display.Box {
	for b in display.boxes(root) {
		if b.element != unsafe { nil } && b.element.attributes['id'] == id {
			return b
		}
	}
	return unsafe { nil }
}

fn page() (&html.Tag, &html.Tag) {
	mut root := el('html', '')
	mut body := el('body', 'body')
	attach(mut root, body)
	return root, body
}

// --- what is not drawn ------------------------------------------------------

fn test_a_page_with_no_colour_draws_nothing() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut div, text_el('hello'))
	attach(mut body, div)
	l := list_of(root, '', 800)
	assert l.len() > 0 // the text run is there
	assert l.count(.fill_rect) == 0
}

fn test_a_transparent_background_records_no_command() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := list_of(root, 'div { background-color: transparent }', 800)
	assert l.count(.fill_rect) == 0
}

fn test_an_empty_box_draws_no_command_at_all() {
	// A box with no background, no border and no text must not leave a no-op in the
	// list. If it did, every golden diff would be full of commands that changed
	// nothing.
	mut p := new_painter()
	mut b := &display.Box{ rect: display.Rect{ width: 10, height: 10 } }
	p.paint(b)
	assert p.list.len() == 0
}

// --- backgrounds ------------------------------------------------------------

fn test_a_background_is_the_border_box() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := list_of(root, 'div { background-color: red }', 800)
	assert l.count(.fill_rect) == 1
	assert l.commands[0].rect == display.Rect{ x: 0, y: 0, width: 800, height: 20 }
	assert l.commands[0].color == raster.red
}

fn test_a_background_covers_the_padding_and_border() {
	// The background is painted under the border box, not the content box. A
	// stylesheet that sets a background and a border expects the colour to run to the
	// outer edge, with the border drawn on top of it.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := list_of(root, 'div { background-color: red; border-width: 4px; border-style: solid; padding: 6px }', 800)
	assert l.commands[0].rect.height == 20 + 2 * (4 + 6)
}

// --- background images -------------------------------------------------------

fn test_a_background_image_is_one_command_at_the_box_rect() {
	// One command, not one per tile: a repeating background over an 800x20 box is
	// one decision, and a list holding the tiles would make every test that
	// counts commands count the canvas too.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := image_list(root, '#d { background-image: url(a.png) }', 800, images_with('a.png'))
	assert l.count(.image) == 1
	assert l.len() == 1
	assert l.commands[0].kind == .image
	assert l.commands[0].rect == display.Rect{ x: 0, y: 0, width: 800, height: 20 }
	assert l.commands[0].image.bitmap.width == 2
	assert l.commands[0].image.bitmap.height == 1
}

fn test_a_url_the_caller_could_not_load_draws_no_image_command() {
	// The engine degrades rather than crashing. The style records a reference; the
	// caller fetches it; if the fetch or the decode failed there is no bitmap and
	// the box keeps its background colour and nothing else.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := image_list(root, '#d { background-image: url(never-fetched.png) }', 800,
		map[string]&raster.Bitmap{})
	assert l.count(.image) == 0
	assert l.len() == 0
}

fn test_an_image_this_engine_cannot_draw_leaves_no_command() {
	// `linear-gradient()` is a valid CSS image and is recorded as "no image" rather
	// than dropped as invalid, so it still beats a lower-specificity url() -- but
	// nothing is drawn for it yet.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := image_list(root, '#d { background-image: linear-gradient(red, blue) }', 800,
		images_with('a.png'))
	assert l.count(.image) == 0
}

fn test_a_background_image_is_recorded_after_its_colour() {
	// The compositing contract, for the new kind: the colour is under the image, so
	// a box with both shows the image where the image is opaque and the colour
	// everywhere the image is transparent.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := image_list(root, '#d { background-color: rgb(0, 255, 0); background-image: url(a.png) }',
		800, images_with('a.png'))
	assert l.len() == 2
	assert l.commands[0].kind == .fill_rect
	assert l.commands[1].kind == .image
}

fn test_a_more_specific_none_overrides_a_url() {
	// `background-image: none` has to be *recorded*, not dropped. If it were
	// dropped, the cascade would keep the url() from the lower-specificity rule and
	// the box would show an image the author switched off.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	src := 'div { background-image: url(a.png) } #d { background-image: none }'
	l := image_list(root, src, 800, images_with('a.png'))
	assert l.count(.image) == 0
}

// --- repeat ------------------------------------------------------------------

fn test_background_repeat_values_reach_the_display_list() {
	// The list carries the repeat mode rather than the tiles, so the tile count is
	// one for all four values and this is the assertion that tells them apart.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	m := images_with('a.png')
	base := '#d { height: 60px; background-image: url(a.png); background-repeat: '

	l1 := image_list(root, base + 'repeat }', 800, m)
	assert l1.count(.image) == 1
	assert l1.commands[0].image.repeat == .repeat

	l2 := image_list(root, base + 'repeat-x }', 800, m)
	assert l2.count(.image) == 1
	assert l2.commands[0].image.repeat == .repeat_x

	l3 := image_list(root, base + 'repeat-y }', 800, m)
	assert l3.count(.image) == 1
	assert l3.commands[0].image.repeat == .repeat_y

	l4 := image_list(root, base + 'no-repeat }', 800, m)
	assert l4.count(.image) == 1
	assert l4.commands[0].image.repeat == .no_repeat
}

fn test_the_background_shorthand_carries_an_image_and_a_repeat() {
	// The shorthand is not `background-color` with extra text: it has to set the
	// image and the repeat too, or the commonest spelling of a background image on
	// the real web draws nothing.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := image_list(root, '#d { background: #fff url(a.png) no-repeat }', 800, images_with('a.png'))
	assert l.len() == 2
	assert l.commands[0].kind == .fill_rect
	assert l.commands[0].color == raster.white
	assert l.commands[1].kind == .image
	assert l.commands[1].image.repeat == .no_repeat
}

fn test_the_background_shorthand_resets_an_image_it_does_not_mention() {
	// A shorthand resets every longhand it stands for, so `background: red` clears
	// an image a lower-specificity rule had set. Without this the page shows an
	// image the author replaced with a flat colour.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	src := 'div { background-image: url(a.png) } #d { background: red }'
	l := image_list(root, src, 800, images_with('a.png'))
	assert l.count(.image) == 0
	assert l.count(.fill_rect) == 1
	assert l.commands[0].color == raster.red
}

// --- size and position -------------------------------------------------------

fn test_background_size_with_a_length_scales_the_tile() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := image_list(root, '#d { background-image: url(a.png); background-size: 40px 10px }',
		800, images_with('a.png'))
	assert l.commands[0].image.draw == display.Rect{ x: 0, y: 0, width: 40, height: 10 }
}

fn test_background_size_with_one_length_keeps_the_aspect_ratio() {
	// A 2x1 image drawn 50px wide is 25px tall: CSS sizes the axis that was left
	// `auto` from the one that was given.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := image_list(root, '#d { background-image: url(a.png); background-size: 50px }', 800,
		images_with('a.png'))
	assert l.commands[0].image.draw.width == 50
	assert l.commands[0].image.draw.height == 25
}

fn test_background_size_cover_fills_the_area() {
	// The box is 800x20 and the image is 2x1. `cover` takes the larger ratio, so
	// the tile is 800x400 and the box shows a 20-pixel slice of the middle of it.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := image_list(root, '#d { background-image: url(a.png); background-size: cover }', 800,
		images_with('a.png'))
	assert l.commands[0].image.draw.width == 800
	assert l.commands[0].image.draw.height == 400
}

fn test_background_size_contain_fits_inside_the_area() {
	// The smaller ratio, so the tile is 40x20 and the whole image is visible with
	// the background colour beside it.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := image_list(root, '#d { background-image: url(a.png); background-size: contain }',
		800, images_with('a.png'))
	assert l.commands[0].image.draw.width == 40
	assert l.commands[0].image.draw.height == 20
}

fn test_background_position_centres_the_tile() {
	// A 40x20 tile centred in an 800x20 box: the horizontal offset is the free
	// space over two, and the vertical offset is zero because the tile is exactly
	// as tall as the box.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	src := '#d { background-image: url(a.png); background-size: 40px 20px; background-position: center }'
	l := image_list(root, src, 800, images_with('a.png'))
	assert l.commands[0].image.draw == display.Rect{ x: 380, y: 0, width: 40, height: 20 }
}

fn test_background_position_a_percentage_is_of_the_space_left_over() {
	// Not of the area: `100%` puts the tile's right edge at the area's right edge
	// rather than placing the tile entirely outside it.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	src := '#d { background-image: url(a.png); background-size: 40px 20px; background-position: 100% 0% }'
	l := image_list(root, src, 800, images_with('a.png'))
	assert l.commands[0].image.draw.x == 760
}

fn test_background_position_and_size_from_the_shorthand() {
	// `<position> / <size>` in one declaration, which is how a real stylesheet
	// writes it.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	src := '#d { background: url(a.png) center / 50% 100% no-repeat }'
	l := image_list(root, src, 800, images_with('a.png'))
	assert l.commands[0].image.repeat == .no_repeat
	assert l.commands[0].image.draw.width == 400
	assert l.commands[0].image.draw.x == 200
}

// --- rendering ---------------------------------------------------------------

fn test_rendering_a_background_image_composites_it() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	mut c := raster.new_canvas(8, 8)
	c.clear(raster.white)
	b := layout(root, '#d { height: 8px; background-image: url(a.png); background-repeat: no-repeat }',
		8)
	render_page_with_images(b, images_with('a.png'), mut c)
	assert c.at(0, 0) == raster.red
	assert c.at(1, 0) == raster.blue
	// no-repeat, and the tile is one row tall, so nothing below or beside it.
	assert c.at(0, 1) == raster.white
	assert c.at(2, 0) == raster.white
}

fn test_rendering_a_resized_background_image_scales_the_pixels() {
	// `background-size` has to reach the pixels and not only the display list: a
	// 2x1 tile drawn 6 wide splits into two halves, one per source pixel. The first
	// version of this feature resolved the tile into the list and then drew the
	// bitmap at its own size, which is why the hand-rendered page above was all
	// background colour where the image should have been.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	mut c := raster.new_canvas(8, 8)
	c.clear(raster.white)
	src := '#d { height: 8px; background-image: url(a.png); background-size: 6px 1px; background-repeat: no-repeat }'
	b := layout(root, src, 8)
	render_page_with_images(b, images_with('a.png'), mut c)
	assert c.at(0, 0) == raster.red
	assert c.at(2, 0) == raster.red
	assert c.at(3, 0) == raster.blue
	assert c.at(5, 0) == raster.blue
	// nothing to the right of the six-pixel tile
	assert c.at(6, 0) == raster.white
}

fn test_rendering_a_repeated_background_fills_the_box() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	mut c := raster.new_canvas(8, 8)
	c.clear(raster.white)
	b := layout(root, '#d { height: 8px; background-image: url(a.png); background-repeat: repeat }',
		8)
	render_page_with_images(b, images_with('a.png'), mut c)
	mut y := 0
	for y < 8 {
		mut x := 0
		for x < 8 {
			// The 2x1 tile is red then blue, so the parity of the column is the colour.
			want := if x % 2 == 0 { raster.red } else { raster.blue }
			assert c.at(x, y) == want
			x++
		}
		y++
	}
}

fn test_rendering_a_translucent_image_composites_over_the_colour() {
	// Source-over, with the numbers. Half-transparent white over opaque green: the
	// premultiplied source is (128, 128, 128, 128), so red and blue -- the channels
	// green did not have -- arrive at 128 + 0, green (already 255 in the
	// destination) saturates at 128 + 127, and the alpha reaches 128 + 127.
	// Getting 255 in red or blue here would mean the alpha was applied twice.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	mut src := []u8{len: 4}
	src[0] = 255
	src[1] = 255
	src[2] = 255
	src[3] = 128
	mut m := map[string]&raster.Bitmap{}
	m['a.png'] = raster.from_straight_rgba(1, 1, src, 4)
	mut c := raster.new_canvas(8, 8)
	c.clear(raster.white)
	b := layout(root, '#d { height: 8px; background-color: rgb(0, 255, 0); background-image: url(a.png) }',
		8)
	render_page_with_images(b, m, mut c)
	assert c.at(0, 0) == raster.Color{ r: 128, g: 255, b: 128, a: 255 }
}

// --- borders ----------------------------------------------------------------

fn test_a_solid_border_draws_four_bands_inside_the_box() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := list_of(root, 'div { border-width: 3px; border-style: solid; border-color: blue }', 800)
	assert l.count(.fill_rect) == 4
	assert l.commands[0].rect == display.Rect{ x: 0, y: 0, width: 800, height: 3 }
	// The bands span the border box, which is the content plus three pixels on every
	// side -- so 26 tall, not 20. A band measured against the content box would leave
	// the corners unpainted.
	assert l.commands[1].rect == display.Rect{ x: 797, y: 0, width: 3, height: 26 }
	assert l.commands[2].rect == display.Rect{ x: 0, y: 23, width: 800, height: 3 }
	assert l.commands[3].rect == display.Rect{ x: 0, y: 0, width: 3, height: 26 }
	for cmd in l.commands {
		assert cmd.color == raster.blue
	}
}

fn test_only_the_sides_with_a_style_are_drawn() {
	// `border-width` on its own reserves nothing (layout zeroes it), so nothing is
	// drawn either. If paint drew a band here, the two layers would disagree and the
	// page would gain a border nobody asked for.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := list_of(root, 'div { border-width: 3px }', 800)
	assert l.count(.fill_rect) == 0
}

fn test_each_side_keeps_its_own_colour() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := list_of(root, 'div { border-width: 2px; border-style: solid; border-left-style: none; border-right-style: none; border-top-color: red; border-bottom-color: blue }', 800)
	n := l.commands.len
	assert n == 2
	assert l.commands[0].color == raster.red
	assert l.commands[1].color == raster.blue
}

fn test_a_border_band_is_inside_the_border_box() {
	// The right and bottom bands are anchored to the far edges, so a box that has
	// padding still gets its border on the outside of the padding.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	l := list_of(root, 'div { border-width: 5px; border-style: solid; padding: 10px; height: 100px }', 800)
	assert l.commands[1].rect.x == 795
	assert l.commands[2].rect.y == 95 // height 100, less the five-pixel band
}

// --- visibility -------------------------------------------------------------

fn test_a_hidden_box_and_its_children_draw_nothing() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	mut inner := el('div', 'inner')
	attach(mut inner, text_el('hidden text'))
	attach(mut div, inner)
	attach(mut body, div)
	l := list_of(root, '#d { visibility: hidden } #inner { background-color: red } div { display: block }', 800)
	assert l.len() == 0
}

fn test_visibility_hidden_on_one_sibling_leaves_the_other() {
	mut root, mut body := page()
	mut gone := el('div', 'gone')
	mut kept := el('div', 'kept')
	attach(mut body, gone, kept)
	l := list_of(root, '#gone { visibility: hidden } div { background-color: red }', 800)
	assert l.count(.fill_rect) == 1
}

// --- text -------------------------------------------------------------------

fn test_text_becomes_one_glyph_run_in_the_boxes_colour() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut div, text_el('abc'))
	attach(mut body, div)
	l := list_of(root, 'div { color: red }', 800)
	assert l.count(.glyph_run) == 1
	assert l.commands[0].kind == .glyph_run
	assert l.commands[0].color == raster.red
	assert l.commands[0].glyphs.len > 0
}

fn test_a_transparent_colour_draws_no_run() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut div, text_el('abc'))
	attach(mut body, div)
	l := list_of(root, 'div { color: transparent }', 800)
	assert l.count(.glyph_run) == 0
}

fn test_an_underline_is_drawn_below_the_baseline_and_before_the_text() {
	// Order matters: the glyphs come after the underline so the text sits on top of
	// it. A list with the run first would put a black line through the descenders.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut div, text_el('abc'))
	attach(mut body, div)
	l := list_of(root, 'div { text-decoration: underline }', 800)
	n := l.commands.len
	assert n == 2
	assert l.commands[0].kind == .fill_rect
	assert l.commands[1].kind == .glyph_run
	for cmd in l.commands {
		if cmd.kind == .fill_rect {
			assert cmd.rect.height == 1
		}
	}
}

fn test_no_decoration_draws_no_line() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut div, text_el('abc'))
	attach(mut body, div)
	l := list_of(root, 'div { text-decoration: none }', 800)
	for cmd in l.commands {
		assert cmd.kind != .fill_rect
	}
}

// --- order ------------------------------------------------------------------

fn test_a_child_is_drawn_after_its_parent() {
	// The whole compositing contract: a parent's background must be under its
	// children's, or the page is a stack of rectangles in the wrong order.
	mut root, mut body := page()
	mut outer := el('div', 'outer')
	mut inner := el('div', 'inner')
	attach(mut inner, text_el('x'))
	attach(mut outer, inner)
	attach(mut body, outer)
	l := list_of(root, '#outer { background-color: red } #inner { background-color: blue }', 800)
	// Asserted as an ordering rather than as a count: what this test is about is that
	// red comes before blue, and pinning the total would make it fail every time text
	// drawing or decoration adds a command.
	mut seen_red := false
	mut seen_blue := false
	for cmd in l.commands {
		if cmd.color == raster.red {
			seen_red = true
		}
		if cmd.color == raster.blue {
			assert seen_red
			seen_blue = true
		}
	}
	assert seen_red
	assert seen_blue
}

// --- z-index and painting order (CSS 2.1 Appendix E.2) ------------------------
//
// A positioned box with a z-index paints above the in-flow content of its parent,
// and among its positioned siblings the order is the z-index. The tiebreak is tree
// order, and it is not a convenience: ARCHITECTURE.md 4 makes determinism a design
// requirement, and the only ordering a golden image can rely on between two boxes
// that asked for the same z-index is the one the document wrote.
//
// What is asserted is the position of a colour in the command list, because that is
// what compositing order *is* here: the list is drawn in order, so "blue after red"
// and "blue on top of red" are the same statement.

// z_page builds body > first, second -- two blocks whose backgrounds are the two
// colours, in that document order. Every test in this section is the same tree with
// a different sheet, so what is being compared is always the order the sheet asked
// for against the order the document was written in.
fn z_page(src string) &DisplayList {
	mut root := el('html', '')
	mut body := el('body', 'body')
	mut first := el('div', 'first')
	mut second := el('div', 'second')
	attach(mut body, first, second)
	attach(mut root, body)
	return list_of(root, src, 800)
}

// first_at returns the index of the first command painted in `color`, or -1.
fn first_at(l &DisplayList, color raster.Color) int {
	mut i := 0
	for cmd in l.commands {
		if cmd.kind == .fill_rect && cmd.color == color {
			return i
		}
		i++
	}
	return -1
}

fn test_a_higher_z_index_paints_above_whatever_the_document_order_was() {
	// The rule, and the direction that matters: the blue box is written *first* and
	// asked for the higher z-index, so the red box has to be painted before it even
	// though it comes later in the document.
	l := z_page('#first { background-color: blue; position: relative; z-index: 2 } #second { background-color: red; position: relative; z-index: 1 }')
	red := first_at(l, raster.red)
	blue := first_at(l, raster.blue)
	assert red >= 0
	assert blue >= 0
	assert red < blue
}

fn test_equal_z_index_keeps_document_order() {
	// The tiebreak. Two boxes with the same z-index paint in the order the document
	// wrote them, so this is the control that says the ordering came from the sheet
	// above and not from an unstable sort of the same tree.
	l := z_page('#first { background-color: blue; position: relative; z-index: 2 } #second { background-color: red; position: relative; z-index: 2 }')
	assert first_at(l, raster.blue) < first_at(l, raster.red)
	// And the reverse document order gives the reverse paint order, which is what
	// "document order" has to mean.
	r := z_page('#second { background-color: blue; position: relative; z-index: 2 } #first { background-color: red; position: relative; z-index: 2 }')
	assert first_at(r, raster.red) < first_at(r, raster.blue)
}

fn test_a_z_index_on_a_box_that_is_not_positioned_is_ignored() {
	// CSS 2.1 9.3.2: z-index applies to positioned boxes only. A red box with
	// `z-index: 5` and no `position` stays in the flow and paints where the flow puts
	// it, which is *before* the later positioned box no matter what it asked for.
	l := z_page('#first { background-color: red; z-index: 5 } #second { background-color: blue; position: relative; z-index: 1 }')
	assert first_at(l, raster.red) < first_at(l, raster.blue)
	// And the mirror, so the assertion above is not just document order: a positioned
	// first box with a lower z-index than a *positioned* second one reverses it.
	r := z_page('#first { background-color: blue; position: relative; z-index: 1 } #second { background-color: red; z-index: 9 }')
	assert first_at(r, raster.red) < first_at(r, raster.blue)
}

fn test_a_relative_box_with_a_z_index_paints_above_the_block_after_it() {
	// `relative` keeps its place in the flow, so its position in the box tree is not
	// where it paints: it is a positioned box and joins the stacking order above the
	// in-flow content of its parent.
	l := z_page('#first { background-color: blue; position: relative; z-index: 3 } #second { background-color: red }')
	assert first_at(l, raster.red) < first_at(l, raster.blue)
}

fn test_an_absolute_box_paints_above_the_in_flow_content_around_it() {
	// The overlay case: an out-of-flow box is drawn on top of the content it was
	// placed over, whatever the document order said. Its parent here is positioned,
	// which is what makes the overlay's own containing block the parent at all.
	mut root := el('html', '')
	mut body := el('body', 'body')
	mut holder := el('div', 'holder')
	mut overlay := el('div', 'overlay')
	mut under := el('div', 'under')
	attach(mut overlay, text_el('over'))
	// The overlay is written *first*, so the document order says the opposite of the
	// painting order this test asserts.
	attach(mut holder, overlay, under)
	attach(mut body, holder)
	attach(mut root, body)
	l := list_of(root, '#holder { position: relative; background-color: green } #under { background-color: red } #overlay { position: absolute; top: 0; left: 0; width: 20px; height: 20px; background-color: blue }',
		800)
	assert first_at(l, raster.green) < first_at(l, raster.red)
	assert first_at(l, raster.red) < first_at(l, raster.blue)
}

fn test_a_stacked_page_paints_deterministically() {
	// ARCHITECTURE.md 4 on the new ordering: two independent layouts of the same
	// stacked page must give the same command sequence, or a golden image of a
	// positioned page is testing the sort rather than the page.
	src := '#first { background-color: blue; position: relative; z-index: 2 } #second { background-color: red; position: absolute; top: 0; left: 0; z-index: 1 }'
	a := z_page(src)
	b := z_page(src)
	mut i := 0
	for i < a.commands.len {
		assert a.commands[i].kind == b.commands[i].kind
		assert a.commands[i].rect == b.commands[i].rect
		assert a.commands[i].color == b.commands[i].color
		i++
	}
}

// --- determinism ------------------------------------------------------------

fn test_painting_the_same_tree_twice_gives_the_same_list() {
	// ARCHITECTURE.md 4: rendering is a pure function of the tree. If this fails, a
	// golden image is testing the run rather than the engine.
	mut root := el('html', '')
	mut body := el('body', 'body')
	mut div := el('div', 'd')
	attach(mut div, text_el('deterministic'))
	attach(mut body, div)
	attach(mut root, body)
	first := list_of(root, 'div { background-color: red; border-width: 2px; border-style: solid }', 400)
	again := list_of(root, 'div { background-color: red; border-width: 2px; border-style: solid }', 400)
	assert first.len() == again.len()
	mut i := 0
	for i < first.commands.len {
		assert first.commands[i].kind == again.commands[i].kind
		assert first.commands[i].rect == again.commands[i].rect
		assert first.commands[i].color == again.commands[i].color
		i++
	}
}

// --- rendering --------------------------------------------------------------

fn test_rendering_puts_the_background_colour_on_the_canvas() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	mut c := raster.new_canvas(800, 600)
	c.clear(raster.white)
	b := layout(root, 'div { background-color: red }', 800)
	render_page(b, mut c)
	assert c.at(400, 10) == raster.red
	assert c.at(400, 30) == raster.white
}

fn test_rendering_a_border_puts_its_colour_on_the_edge() {
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	mut c := raster.new_canvas(800, 600)
	c.clear(raster.white)
	b := layout(root, 'div { border-width: 4px; border-style: solid; border-color: blue }', 800)
	render_page(b, mut c)
	assert c.at(400, 1) == raster.blue
	assert c.at(400, 10) == raster.white
	assert c.at(797, 10) == raster.blue
}

fn test_a_translucent_background_composites_over_what_is_below() {
	// Premultiplied source-over: a half-alpha red over white is a lighter red, and
	// the test says exactly which one rather than "not white".
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut body, div)
	mut c := raster.new_canvas(800, 600)
	c.clear(raster.white)
	b := layout(root, 'div { background-color: rgba(255, 0, 0, 0.5) }', 800)
	render_page(b, mut c)
	got := c.at(400, 10)
	// Exactly (255, 127, 127, 255), and exactly is the point.
	//
	// Premultiplied source-over can only ever *add*: dst = src + dst * (1 - src.a).
	// White is already 255 red, and the source's own red is 128, so red saturates at
	// 255 rather than landing halfway -- the first version of this test expected 128
	// there, which is the arithmetic for a subtractive blend and not for this one.
	// Green and blue are the channels white had and red did not, so they are what the
	// half alpha actually halves.
	assert got == raster.Color{ r: 255, g: 127, b: 127, a: 255 }
}

fn test_painting_text_darkens_pixels() {
	// Not "the text is there" -- there is no coverage assertion available here -- but
	// that something was composited where the text was, and only there.
	mut root, mut body := page()
	mut div := el('div', 'd')
	attach(mut div, text_el('MMMM'))
	attach(mut body, div)
	mut c := raster.new_canvas(200, 60)
	c.clear(raster.white)
	b := layout(root, '', 200)
	render_page(b, mut c)
	mut inked := 0
	mut y := 0
	for y < 20 {
		mut x := 0
		for x < 200 {
			if c.at(x, y) != raster.white {
				inked++
			}
			x++
		}
		y++
	}
	assert inked > 0
	// Nothing above the box, which starts at y == 0, and nothing in the second line.
	assert c.at(100, 40) == raster.white
}
