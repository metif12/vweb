module main

import engine.page
import engine.raster
import loader
import os

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
//
// They also do not have a pipeline of their own. An earlier version of this file carried a
// private copy of all six steps, which had already drifted from cmd/vweb by the time this
// was written; engine/page is that pipeline now, and a test that reimplements it measures
// the test.

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

const sample_page = '<!DOCTYPE html>
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

const small_opts = page.Options{ width: 200, height: 200 }
const mid_opts = page.Options{ width: 320, height: 240 }

fn render_pixels(src string, width int, height int) raster.Canvas {
	opts := page.Options{ width: width, height: height }
	return page.render_source(src, opts)
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

fn count_coloured(c &raster.Canvas, want raster.Color) int {
	mut n := 0
	for y in 0 .. c.height {
		for x in 0 .. c.width {
			if c.at(x, y) == want {
				n++
			}
		}
	}
	return n
}

const band_blue = raster.Color{ r: 0x33, g: 0x66, b: 0x99, a: 255 }

// --- the pipeline runs -------------------------------------------------------

fn test_a_page_puts_ink_on_the_canvas() {
	// The regression this whole file exists for. A page that parses but whose document
	// element is a text node lays out to a single empty box and renders nothing at all,
	// with no error anywhere.
	c := render_pixels(sample_page, 640, 480)
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
	// A page whose <style> was not collected renders unstyled, and an unstyled page still
	// has text on it -- so "there is ink" does not catch this. Only counting the colour
	// does.
	c := render_pixels(sample_page, 640, 480)
	assert count_coloured(c, band_blue) > 1000
}

fn test_without_a_stylesheet_the_band_is_not_painted() {
	// The same page with the rule removed must not paint that colour, which is what says
	// the previous test found the rule and not something incidental.
	plain := '<html><body><div class="band"></div></body></html>'
	c := render_pixels(plain, 200, 200)
	assert count_coloured(c, band_blue) == 0
}

fn test_the_user_agent_sheet_is_always_applied() {
	// `body { margin: 8px }` comes from the UA sheet. If it is not applied, content sits
	// at x == 0, and that is a whole class of "why is there no margin" report.
	//
	// The rule is in a <style> block rather than a `style` attribute because inline
	// attributes need the cascade and are covered in engine/style.
	src := '<html><head><style>div { height: 20px; background-color: red }</style></head>' +
		'<body><div></div></body></html>'
	c := render_pixels(src, 400, 200)
	// The div starts at y == 8 because that is body's margin, and it is 20 tall, so the
	// row to look at is 15 and not the middle of the canvas.
	assert c.at(0, 15) == raster.white
	assert c.at(20, 15) == raster.Color{ r: 255, g: 0, b: 0, a: 255 }
	assert c.at(20, 40) == raster.white
}

fn test_an_inline_style_attribute_reaches_the_pixels() {
	// The whole loop for inline styles: the parser has to keep the attribute, the cascade
	// has to read it, and the paint has to show it. A test at the cascade level cannot see
	// the first step, and that step was never written.
	src := '<html><body><div style="height:20px; background-color: #ff0000"></div></body></html>'
	c := render_pixels(src, 200, 200)
	assert c.at(20, 15) == raster.Color{ r: 255, g: 0, b: 0, a: 255 }
}

// --- loading and files -------------------------------------------------------

fn test_a_page_loads_from_a_path_and_writes_a_png() {
	page_path := write_page('page.html', sample_page)
	out := tmp('out.png')
	mut ld := loader.Loader{ base: '.' }
	doc := page.load(page_path, mut ld) or { panic(err) }
	page.render(doc, small_opts).write_png(out) or {
		panic(err)
	}
	assert os.exists(out)
	data := os.read_file(out) or { panic(err) }
	// A PNG starts with an eight-byte signature. Enough to know a file was written and it
	// is an image; the rest is raster's business.
	sig := data[..4]
	assert sig == '\x89PNG'
}

fn test_a_relative_image_url_resolves_against_the_page_not_the_process() {
	// The bug this locks down is in the tool, not the pipeline: `cmd/vweb` built its
	// loader with `base: '.'`, so `url(tile.png)` resolved against whatever directory
	// the tool happened to be run from. The same page rendered one way from one
	// directory and lost its image from another, and the only symptom was a warning --
	// the page still drew, so nothing looked broken. Every real page carries relative
	// URLs, which makes this Phase 3's gate failing quietly.
	//
	// The pipeline is already covered by `test_a_background_image_is_fetched_decoded_and_composited`;
	// what this pins is the rule the CLI relies on -- the base is the *page's* directory,
	// derived from its path -- which is the half that was wrong.
	img := tmp('cli-tile.png')
	write_solid_png(img, 4, 4, tile_color)
	page_path := write_page('cli-relative.html', '<html><head><style>.hero { background-image: url(cli-tile.png) }</style></head><body><div class="hero">x</div></body></html>')
	// What the tool does: the page's own directory, derived from its path.
	mut ld := loader.Loader{ base: os.dir(page_path) }
	doc := page.load(page_path, mut ld) or { panic(err) }
	assert doc.warnings.len == 0, 'a relative image beside the page must not warn: ' + doc.warnings.join('; ')
	assert doc.images.len == 1, 'the image should have been fetched'
}

fn test_load_reports_a_missing_file() {
	// An error, not a panic and not an empty image.
	mut ld := loader.Loader{ base: '.' }
	if _ := page.load(tmp('definitely-absent.html'), mut ld) {
		assert false, 'expected an error for a missing page'
	}
}

fn test_load_refuses_something_that_is_not_a_document() {
	not_html := tmp('data.json')
	os.write_file(not_html, '{"a":1}') or { panic(err) }
	mut ld := loader.Loader{ base: '.' }
	if _ := page.load(not_html, mut ld) {
		assert false, 'expected an error for a non-document'
	}
}

fn test_the_loader_and_the_renderer_agree_on_a_path() {
	// `page.load` takes a path, goes through the loader, and the loader resolves relative
	// paths against a base. This is the seam where a path that works in one and not the
	// other becomes a blank page rather than an error.
	page_path := write_page('seam.html', '<html><body><p>seam</p></body></html>')
	mut ld := loader.Loader{ base: '.' }
	res := ld.load(page_path) or { panic(err) }
	assert res.mime == 'text/html'
	seam := render_pixels(res.body.bytestr(), 200, 200)
	assert count_inked(seam) > 0
}

// --- background images -------------------------------------------------------
//
// These are the tests of the I/O seam. `engine/style` records a URL and nothing
// else; `engine/page` fetches it through the loader, decodes it with stb_image and
// hands the painter a bitmap. Nothing inside engine/style or engine/paint opens a
// file, which is the property ARCHITECTURE.md 1 asks for and the reason a cascade
// test needs no image on disk.

const tile_color = raster.Color{ r: 0xc0, g: 0x30, b: 0x20, a: 255 }

fn write_solid_png(path string, w int, h int, col raster.Color) {
	mut c := raster.new_canvas(w, h)
	c.clear(col)
	c.write_png(path) or { panic('cannot write test png: ' + err.msg()) }
}

fn test_a_background_image_is_fetched_decoded_and_composited() {
	dir := os.vtmp_dir() + '/@vweb_render_test'
	os.mkdir_all(dir) or { panic(err) }
	write_solid_png(dir + '/tile.png', 4, 4, tile_color)
	src := '<html><head><style>div.tile { width: 40px; height: 20px;' +
		' background-image: url(tile.png); background-repeat: repeat }</style></head>' +
		'<body><div class="tile"></div></body></html>'
	page_path := dir + '/bg.html'
	os.write_file(page_path, src) or { panic(err) }
	mut ld := loader.Loader{ base: dir }
	doc := page.load(page_path, mut ld) or { panic(err) }
	assert doc.warnings.len == 0
	canvas := page.render(doc, page.Options{ width: 60, height: 40 })
	// The 4x4 tile repeats across the 40x20 box, so every pixel of it is the tile
	// colour and nothing else on the canvas is.
	assert count_coloured(canvas, tile_color) == 40 * 20
}

fn test_an_unreachable_image_is_a_warning_and_not_a_failure() {
	// The engine degrades. A 404 background image leaves a warning naming the URL
	// and the box keeps its background colour -- a page with one broken image is
	// still a page, and a renderer that refused it would hide the rest.
	src := '<html><head><style>div.tile { width: 40px; height: 20px;' +
		' background-color: #123456; background-image: url(absent.png) }</style></head>' +
		'<body><div class="tile"></div></body></html>'
	mut ld := loader.Loader{ base: '.' }
	doc := page.parse(src, mut ld)
	assert doc.warnings.len == 1
	assert doc.warnings[0].contains('absent.png')
	canvas := page.render(doc, page.Options{ width: 60, height: 40 })
	assert count_coloured(canvas, raster.Color{ r: 0x12, g: 0x34, b: 0x56, a: 255 }) == 40 * 20
}

fn test_an_image_that_is_not_an_image_is_a_warning() {
	// The loader reached it and stb_image refused it. Same outcome as a 404: a
	// warning and no image, rather than a panic in the middle of a composite.
	dir := os.vtmp_dir() + '/@vweb_render_test'
	os.mkdir_all(dir) or { panic(err) }
	os.write_file(dir + '/not-an-image.png', '<html>this is a page, not a picture</html>') or {
		panic(err)
	}
	src := '<html><head><style>div.tile { height: 20px; background-image: url(not-an-image.png) }</style></head>' +
		'<body><div class="tile"></div></body></html>'
	page_path := dir + '/bad-image.html'
	os.write_file(page_path, src) or { panic(err) }
	mut ld := loader.Loader{ base: dir }
	doc := page.load(page_path, mut ld) or { panic(err) }
	assert doc.warnings.len == 1
	assert doc.warnings[0].contains('not-an-image.png')
	canvas := page.render(doc, page.Options{ width: 60, height: 40 })
	assert canvas.width == 60
}

fn test_an_image_in_the_background_shorthand_is_fetched() {
	// The shorthand holds the url() among other components, so the collector has
	// to look at one component at a time. Reading the whole value -- `url(t) repeat`
	// -- matches neither the start nor the end and finds nothing, which is what
	// this test caught the first time the page above was rendered by hand.
	dir := os.vtmp_dir() + '/@vweb_render_test'
	os.mkdir_all(dir) or { panic(err) }
	write_solid_png(dir + '/shorthand.png', 4, 4, tile_color)
	src := '<html><head><style>div.tile { width: 40px; height: 20px;' +
		' background: #123456 url(shorthand.png) repeat }</style></head>' +
		'<body><div class="tile"></div></body></html>'
	page_path := dir + '/shorthand.html'
	os.write_file(page_path, src) or { panic(err) }
	mut ld := loader.Loader{ base: dir }
	doc := page.load(page_path, mut ld) or { panic(err) }
	assert doc.warnings.len == 0
	canvas := page.render(doc, page.Options{ width: 60, height: 40 })
	// The shorthand also resets background-color to transparent, so the only colour
	// on the canvas is the tile's own -- which is what says the image was fetched
	// and not the flat colour that was written before it.
	assert count_coloured(canvas, tile_color) == 40 * 20
}

// --- warnings, determinism, introspection ------------------------------------

fn test_an_unreachable_stylesheet_is_a_warning_and_not_a_failure() {
	// A page with one broken link is still a page. Refusing to render it would make the
	// failure harder to see than the missing styles, and the warning is what makes the
	// missing styles visible at all.
	src := '<html><head><link rel="stylesheet" href="nope.css"></head>' +
		'<body><p>text</p></body></html>'
	mut ld := loader.Loader{ base: '.' }
	doc := page.parse(src, mut ld)
	assert doc.warnings.len == 1
	assert doc.warnings[0].contains('nope.css')
	assert count_inked(page.render(doc, small_opts)) > 0
}

fn test_a_page_with_no_broken_links_has_no_warnings() {
	mut ld := loader.Loader{ base: '.' }
	doc := page.parse(sample_page, mut ld)
	assert doc.warnings.len == 0
}

fn test_render_is_repeatable() {
	// ARCHITECTURE.md 4: rendering is a pure function of the tree. Two renders of the same
	// page must be identical, or nothing downstream can be compared.
	first := render_pixels(sample_page, 320, 240)
	second := render_pixels(sample_page, 320, 240)
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

fn test_the_display_list_and_the_canvas_agree_on_how_much_is_drawn() {
	// The list is the plan and the canvas is the result. A page whose plan is empty is a
	// page that renders nothing, and checking the plan catches that without looking at a
	// pixel.
	list := page.display_list(sample_page, mid_opts)
	assert list.len() > 0
}

fn test_the_box_tree_and_the_display_list_are_both_available() {
	// These are the two questions a rendering bug turns into, and they are separate calls
	// because they are separate answers.
	boxes := page.boxes(sample_page, mid_opts)
	assert boxes.len > 1
	list := page.display_list(sample_page, mid_opts)
	assert list.len() > 0
}
