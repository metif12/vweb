module main

import engine.css
import engine.display
import engine.document as dom
import engine.paint
import engine.raster
import engine.selector
import engine.style
import loader
import os
import text

// These tests are about the pipeline, not about how the page looks.
//
// A golden image would be the wrong tool here, for a reason worth stating: the text
// rasterizer currently drops glyphs (see notes/JOURNAL.md), so a golden image taken today
// would record the bug as the expected output and then defend it. What these tests pin is
// the shape of the pipeline -- that each pass runs, that ink lands on the canvas, that a
// stylesheet in the document is honoured -- so that the failure modes that produce a
// *blank page* cannot come back unnoticed.
//
// The blank page is not a hypothetical. `document_element` once returned a text node when
// a file had a newline after its doctype, and the result was a silently empty render.

fn tmp(name string) string {
	dir := os.vtmp_dir() + '@vweb_render_test'
	os.mkdir_all(dir) or { panic(err) }
	return dir + '/' + name
}

fn write_page(name string, body string) string {
	path := tmp(name)
	os.write_file(path, body) or { panic(err) }
	return path
}

const page = '<!DOCTYPE html>
<html>
<head>
<style>
  body { font-family: sans-serif; }
  h1 { color: #12407a; }
  .band { background-color: #336699; height: 40px; }
</style>
</head>
<body>
<h1>Heading</h1>
<div class="band"></div>
<p>Some text that will be broken across more than one line by the line breaker.</p>
</body>
</html>
'

// render_pixels renders a page and returns the canvas, so a test can look at it without
// going through a file.
fn render_pixels(src string, width int, height int) raster.Canvas {
	doc := dom.parse(src)
	viewport := css.screen_context(width, height)
	mut styles := style.new_engine_for(sheets_of(src), viewport)
	mut lay := display.Layouter{
		engine:         styles
		state:          &selector.State{}
		fonts:          text.new_font_library()
		viewport_width: width
		viewport_height: height
	}
	page_boxes := lay.layout(doc)
	mut canvas := raster.new_canvas(width, height)
	canvas.clear(raster.white)
	paint.render_page(page_boxes, mut canvas)
	return canvas
}

fn sheets_of(src string) []style.Sheet {
	doc := dom.parse(src)
	mut out := [style.Sheet{ style: css.parse(css.user_agent_css), origin: .user_agent }]
	for el in dom.elements(doc) {
		if el.name == 'style' {
			out << style.Sheet{ style: css.parse(dom.text_content(el)),
				origin: .author }
		}
	}
	return out
}

fn count_inked(c &raster.Canvas) int {
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

// --- the pipeline runs -------------------------------------------------------

fn test_a_page_puts_ink_on_the_canvas() {
	// The regression this whole file exists for. A page that parses but whose document
	// element is a text node lays out to a single empty box and renders nothing at all,
	// with no error anywhere.
	c := render_pixels(page, 640, 480)
	assert count_inked(c) > 500
}

fn test_a_document_with_a_newline_after_the_doctype_still_renders() {
	// The specific shape that produced the blank page.
	with_newline := '<!DOCTYPE html>\n<html><body><p>text</p></body></html>'
	c := render_pixels(with_newline, 400, 300)
	assert count_inked(c) > 0
}

fn test_an_empty_document_does_not_crash_the_renderer() {
	c := render_pixels('', 200, 200)
	assert c.width == 200
}

// --- the stylesheet in the document is honoured -------------------------------

fn test_a_background_from_the_documents_own_stylesheet_is_painted() {
	// A page whose `<style>` was not collected renders unstyled, and an unstyled page
	// still has text on it -- so "there is ink" does not catch this. Only looking for the
	// colour does.
	c := render_pixels(page, 640, 480)
	mut found := false
	for y in 0 .. 480 {
		for x in 0 .. 640 {
			if c.at(x, y) == raster.Color{ r: 0x33, g: 0x66, b: 0x99, a: 255 } {
				found = true
			}
		}
	}
	assert found
}

fn test_without_a_stylesheet_the_band_is_not_painted() {
	// The same page with the rule removed must not paint that colour, which is what says
	// the previous test found the rule and not something incidental.
	plain := '<html><body><div class="band"></div></body></html>'
	c := render_pixels(plain, 200, 200)
	for y in 0 .. 200 {
		for x in 0 .. 200 {
			assert c.at(x, y) != raster.Color{ r: 0x33, g: 0x66, b: 0x99, a: 255 }
		}
	}
}

fn test_the_user_agent_sheet_is_always_applied() {
	// `body { margin: 8px }` comes from the UA sheet. If it is not applied, content sits
	// at x == 0, and that is a whole class of "why is there no margin" report.
	//
	// The rule is in a `<style>` block rather than a `style` attribute because inline
	// attributes are not implemented: the cascade reads stylesheets only, and a test that
	// quietly depended on them would pass for the wrong reason. See the note on inline
	// styles below.
	src := '<html><head><style>div { height: 20px; background-color: red }</style></head>' +
		'<body><div></div></body></html>'
	c := render_pixels(src, 400, 200)
	// The div starts at y == 8 because that is body's margin, and it is 20 tall, so the
	// row to look at is 15 and not the middle of the canvas.
	assert c.at(0, 15) == raster.white
	assert c.at(20, 15) == raster.red
	assert c.at(20, 40) == raster.white
}

// --- a known gap, stated rather than tested ----------------------------------

fn test_an_inline_style_attribute_reaches_the_pixels() {
	// The whole loop for inline styles: the parser has to keep the attribute, the cascade
	// has to read it, and the paint has to show it. A test at the cascade level cannot see
	// the first step, and this is the step that was never written.
	src := '<html><body><div style="height:20px; background-color: #ff0000"></div></body></html>'
	c := render_pixels(src, 200, 200)
	assert c.at(20, 15) == raster.Color{ r: 255, g: 0, b: 0, a: 255 }
}

// Inline `style="..."` attributes are parsed and applied, but only on the element that
// carries them: they are not inherited, which is correct, and they do not reach a child,
// which is also correct and is why the rule above styles the div rather than its
// contents.
//
// What is *not* implemented, and is recorded here because it is a small thing that a
// page will eventually need:
//
//   - `style` on an SVG or MathML element, where the property set is not CSS's.
//   - The `style` attribute as a source of custom property values. `--x: 1` parses as a
//     declaration and is stored nowhere, so `var(--x)` finds nothing.

// --- rendering to a file -----------------------------------------------------

fn test_render_writes_a_png() {
	page_path := write_page('page.html', page)
	out := tmp('out.png')
	os.mkdir_all(os.vtmp_dir() + '@vweb_render_test') or { panic(err) }
	render(page_path, out, 200, 150) or { panic(err) }
	assert os.exists(out)
	data := os.read_file(out) or { panic(err) }
	// A PNG starts with the eight-byte signature. Enough to know a file was written and
	// it is an image; the rest is raster's business.
	sig := data[..4]
	assert sig == '\x89PNG'
}

fn test_render_reports_a_missing_file() {
	// An error, not a panic and not an empty image.
	if _ := render(tmp('definitely-absent.html'), tmp('x.png'), 100, 100) {
		assert false, 'expected an error for a missing page'
	}
}

fn test_render_refuses_something_that_is_not_a_document() {
	not_html := tmp('data.json')
	os.write_file(not_html, '{"a":1}') or { panic(err) }
	if _ := render(not_html, tmp('y.png'), 100, 100) {
		assert false, 'expected an error for a non-document'
	}
}

fn test_render_is_repeatable() {
	// ARCHITECTURE.md 4: rendering is a pure function of the tree. Two renders of the
	// same page must be byte-identical, or nothing downstream can be compared.
	first := render_pixels(page, 320, 240)
	second := render_pixels(page, 320, 240)
	mut differing := 0
	for y in 0 .. 240 {
		for x in 0 .. 320 {
			if first.at(x, y) != second.at(x, y) {
				differing++
			}
		}
	}
	assert differing == 0
}

fn test_the_loader_and_the_renderer_agree_on_a_path() {
	// `render` takes a path, goes through the loader, and the loader resolves relative
	// paths against a base. This is the seam where a path that works in one and not the
	// other becomes a blank page rather than an error.
	page_path := write_page('seam.html', '<html><body><p>seam</p></body></html>')
	mut ld := loader.Loader{ base: '.' }
	res := ld.load(page_path) or { panic(err) }
	assert res.mime == 'text/html'
	c := render_pixels(res.body.bytestr(), 200, 200)
	assert count_inked(c) > 0
}
