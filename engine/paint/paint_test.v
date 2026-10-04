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
	mut p := new_painter()
	p.paint(layout(root, src, width))
	return p.list
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
