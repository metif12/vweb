module page

// One document, rendered: load, parse, collect stylesheets, cascade, lay out, paint.
//
// This is the whole engine behind a single call, and it lives here rather than in
// cmd/vweb so that the command, the examples and the tools all use the same one. Three
// copies of six steps is how a tool starts disagreeing with the program about what a page
// looks like, and then the tool is not measuring the program any more.
//
// Each step is a separate function because each is a different way for a page to be
// wrong, and the order is fixed:
//
//	load     bytes for a URL or path          (loader)
//	parse    HTML text to a tree              (net/html, via engine/document)
//	sheets   the UA sheet plus every <style> and <link> in the document
//	cascade  sheets to computed styles        (a declaration lost to specificity)
//	layout   styles to a box tree             (a margin that did not collapse)
//	paint    boxes to a display list          (a background over its own text)
//	composite list to pixels                 (a blend that is subtly dark)

import engine.css
import engine.display
import engine.document as dom
import engine.paint
import engine.raster
import engine.selector
import engine.style
import loader
import net.html as nhtml
import text

// Options is the small number of things about a render that are not the page.
pub struct Options {
pub mut:
	// width and height are the viewport in CSS pixels. Media queries are answered
	// against width, so this is not merely the size of the output image.
	width  int = 800
	height int = 600
	// background is what the canvas starts as. A browser starts from white and so does
	// this; a caller that wants transparency says so here rather than clearing after.
	background raster.Color = raster.white
}

// document is a parsed page with its stylesheets already collected.
@[heap]
pub struct Document {
pub mut:
	root   &nhtml.Tag
	sheets []style.Sheet
	// images are the decoded background images, keyed by URL as the stylesheet
	// wrote it. They are collected here rather than fetched by the painter because
	// ARCHITECTURE.md 1 gives the engine no I/O: this is the module that already
	// owns the loader for `<link>` stylesheets, and a background image is the same
	// kind of thing. A URL with no entry here draws nothing and leaves a warning.
	images map[string]&raster.Bitmap
	// warnings are things that went wrong but did not stop the render: a stylesheet or
	// an image that could not be fetched, most often. They are collected rather than printed so that a
	// tool can show them and a library caller can decide what to do.
	warnings []string
}

// parse turns HTML text into a document with its stylesheets collected, using `ld` to
// resolve any `<link href>` it finds and to fetch every image the styles reference.
//
// The loader is a parameter because relative stylesheet URLs have to resolve against the
// document's own location, and that is the loader's base, not the process's working
// directory.
pub fn parse(src string, mut ld loader.Loader) &Document {
	mut doc := &Document{
		root:   dom.parse(src)
		sheets: []style.Sheet{}
		images: map[string]&raster.Bitmap{}
	}
	doc.sheets << style.Sheet{ style: css.parse(css.user_agent_css), origin: .user_agent }
	for el in dom.elements(doc.root) {
		if el.name == 'style' {
			// A <style> body is a raw text node rather than child elements, which is the
			// one place where reading markup as a tree is the wrong shape.
			doc.sheets << style.Sheet{
				style:  css.parse(dom.text_content(el))
				origin: .author
			}
			continue
		}
		if el.name == 'link' && el.attributes['rel'].to_lower() == 'stylesheet' {
			href := el.attributes['href']
			if href == '' {
				continue
			}
			// A stylesheet that cannot be fetched is skipped rather than fatal. A page
			// with one broken link is still a page, and refusing to render it at all
			// would make the failure much harder to see than the missing styles. The
			// warning is kept because a silently unstyled page is the hardest kind of bug
			// to report: nothing says the stylesheet was ever looked for.
			res := ld.load(href) or {
				doc.warnings << 'cannot fetch stylesheet ' + href + ': ' + err.msg()
				continue
			}
			doc.sheets << style.Sheet{
				style:  css.parse(res.body.bytestr())
				origin: .author
			}
		}
	}
	doc.collect_images(mut ld)
	return doc
}

// collect_images fetches and decodes every image the document's styles reference,
// once each.
//
// It walks the declarations rather than the box tree because a URL has to be known
// before the box that uses it is laid out, and because a style that applies to an
// element this page does not contain should not cost a fetch. `background-image`
// and `background` are the only two properties that can carry a URL; the others are
// longhands of one or the other.
//
// A URL that cannot be fetched, or that decodes to nothing, is a warning and not a
// failure -- the same rule a broken `<link>` follows, for the same reason. The
// alternative is a page that renders nothing because one image 404'd.
fn (mut d Document) collect_images(mut ld loader.Loader) {
	mut urls := []string{}
	for url in declaration_urls(d.sheets) {
		if url !in urls {
			urls << url
		}
	}
	// Inline `style` attributes are scanned too, because a `style="background-image:
	// url(...)"` is a real declaration that no stylesheet holds.
	for el in dom.elements(d.root) {
		attr := el.attributes['style']
		if attr == '' {
			continue
		}
		for decl in css.parse_declarations(attr) {
			if decl.name != 'background' && decl.name != 'background-image' {
				continue
			}
			for url in style.background_image_urls(decl.value) {
				if url != '' && url !in urls {
					urls << url
				}
			}
		}
	}
	for url in urls {
		res := ld.load(url) or {
			d.warnings << 'cannot fetch image ' + url + ': ' + err.msg()
			continue
		}
		bm := raster.decode_bitmap(res.body) or {
			d.warnings << 'cannot decode image ' + url + ': ' + err.msg()
			continue
		}
		d.images[url] = bm
	}
}

// declaration_urls returns the image URLs a set of sheets refers to, descending
// through the conditional group rules the cascade also descends through.
fn declaration_urls(sheets []style.Sheet) []string {
	mut out := []string{}
	for sheet in sheets {
		for rule in sheet.style.rules {
			out << rule_urls(rule)
		}
	}
	return out
}

fn rule_urls(rule css.Rule) []string {
	mut out := []string{}
	match rule {
		css.QualifiedRule {
			for decl in rule.declarations {
				if decl.name == 'background' || decl.name == 'background-image' {
					out << style.background_image_urls(decl.value)
				}
			}
		}
		css.NestedRule {
			for inner in rule.rules {
				out << rule_urls(inner)
			}
		}
		css.AtDeclarationRule {
			// `@font-face` and `@keyframes` describe things this engine does not
			// draw. Neither can carry a background image.
		}
	}
	return out
}

// load fetches a URL or path and parses it.
pub fn load(target string, mut ld loader.Loader) !&Document {
	res := ld.load(target)!
	if !res.body.bytestr().trim_space().starts_with('<') {
		return error('not an html document: ' + res.mime)
	}
	return parse(res.body.bytestr(), mut ld)
}

// layout lays a document out at a viewport, resolving the media queries against it.
pub fn layout(doc &Document, width int, height int) &display.Box {
	viewport := css.screen_context(width, height)
	mut styles := style.new_engine_for(doc.sheets, viewport)
	mut lay := display.Layouter{
		engine:          styles
		state:           &selector.State{}
		fonts:           text.new_font_library()
		viewport_width:  width
		viewport_height: height
	}
	return lay.layout(doc.root)
}

// render draws a document and returns the canvas.
pub fn render(doc &Document, opts Options) raster.Canvas {
	page_boxes := layout(doc, opts.width, opts.height)
	mut canvas := raster.new_canvas(opts.width, opts.height)
	canvas.clear(opts.background)
	paint.render_page_with_images(page_boxes, doc.images, mut canvas)
	return canvas
}

// render_source is the one call most callers want: text in, canvas out.
pub fn render_source(src string, opts Options) raster.Canvas {
	mut ld := loader.Loader{ base: '.' }
	doc := parse(src, mut ld)
	return render(doc, opts)
}

// render_to_png is the one call a command wants.
pub fn render_to_png(src string, out_path string, opts Options) ! {
	render_source(src, opts).write_png(out_path)!
}

// boxes returns every box in a laid-out document, parents before children.
//
// It is here because the natural next question after "does it render" is "what boxes did
// it make", and answering that by walking the tree at three call sites is how the three
// sites start disagreeing.
pub fn boxes(src string, opts Options) []&display.Box {
	mut ld := loader.Loader{ base: '.' }
	doc := parse(src, mut ld)
	return display.boxes(layout(doc, opts.width, opts.height))
}

// display_list_from_document is display_list for a document already parsed, so a caller
// that has one does not pay for a second parse.
pub fn display_list_from_document(doc &Document, opts Options) &paint.DisplayList {
	mut p := paint.new_painter_with_images(doc.images)
	p.paint(layout(doc, opts.width, opts.height))
	return p.list
}

// display_list builds the drawing commands for a document without compositing them.
//
// This is a different question from render and is worth a separate call: it answers "what
// was paint told to draw, in order", which is where a background drawn over its own text
// or a border drawn twice becomes visible. Compositing first would hide it.
pub fn display_list(src string, opts Options) &paint.DisplayList {
	mut ld := loader.Loader{ base: '.' }
	doc := parse(src, mut ld)
	mut p := paint.new_painter_with_images(doc.images)
	p.paint(layout(doc, opts.width, opts.height))
	return p.list
}
