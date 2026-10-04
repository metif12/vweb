module main

// vweb -- render a page to a PNG.
//
// This is the whole engine behind one command, and it is deliberately the only place
// that knows the order of the passes. Everything below it is a library that can be used
// on its own; nothing above it exists yet.
//
// The order is fixed and each step is a place where a page can be wrong in a different
// way, which is why they are separate functions with names rather than one main:
//
//	parse     HTML text to a tree          (net/html, with `a stray end tag swallowed)
//	collect   tree to stylesheets          (`a <style>` body, and `a <link rel=stylesheet>`)
//	cascade   sheets to computed styles    (`a declaration lost to specificity`)
//	layout    styles to a box tree         (`a margin that did not collapse`)
//	paint     boxes to a display list      (`a background drawn over its own text`)
//	composite list to pixels               (`a blend that is subtly dark`)

// Both engine/html and net/html are module `html`, so both are aliased. `nhtml` is
// the tree type from vlib; `dom` is this project's wrapper over it.
import engine.css
import engine.display
import engine.document as dom
import engine.paint
import engine.raster
import engine.selector
import engine.style
import engine.tree
import loader
import net.html as nhtml
import os
import text

fn main() {
	args := os.args
	if args.len < 2 {
		eprintln('usage: vweb <url-or-path> [out.png] [--width N] [--height N]')
		exit(1)
	}
	target := args[1]
	mut out_path := 'out.png'
	mut width := 800
	mut height := 600
	mut i := 2
	for i < args.len {
		match args[i] {
			'--width' {
				width = args[i + 1].int()
				i += 2
				continue
			}
			'--height' {
				height = args[i + 1].int()
				i += 2
				continue
			}
			else {
				out_path = args[i]
				i++
				continue
			}
		}
		break
	}

	render(target, out_path, width, height) or {
		eprintln('vweb: ' + err.msg())
		exit(1)
	}
	println('wrote ' + out_path)
}

// render loads a page and writes it as a PNG. It is the shape a caller outside this
// program wants, and it is a function rather than only a main so that the golden test can
// call it without shelling out.
pub fn render(target string, out_path string, width int, height int) ! {
	mut ld := loader.Loader{ base: '.' }
	res := ld.load(target)!
	// The mime type is the loader's answer and the first non-space character is the
	// document's own. Either one is enough; requiring both would refuse a server that
	// sends pplication/octet-stream for a page, which is common and harmless.
	head := res.body.bytestr().trim_space()
	if !head.starts_with('<') {
		return error('not an html document: ' + res.mime)
	}
	doc := dom.parse(res.body.bytestr())

	// The viewport is needed twice and in the right order: the media queries are resolved
	// when the cascade is built, which is before layout knows anything.
	viewport := css.screen_context(width, height)
	// Named styles, not engine: a local called engine shadows every engine.* import
	// in this file, and the error it produces is on the line that uses paint.
	styles := style.new_engine_for(collect_sheets(doc, mut ld), viewport)
	// mut because layout has a mut receiver, and named page_boxes rather than
	// oxes because engine/display exports a function called boxes.
	mut lay := display.Layouter{
		engine: styles
		state: &selector.State{}
		fonts: text.new_font_library()
		viewport_width: width
		viewport_height: height
		// A page whose root sets `font-size` changes what every `rem` in it means, and the
		// stylesheet has to be resolved against that before the media queries are asked.
		root_font_size: viewport.root_font_size
	}
	page_boxes := lay.layout(doc)

	mut canvas := raster.new_canvas(width, height)
	canvas.clear(raster.white)
	paint.render_page(page_boxes, mut canvas)
	canvas.write_png(out_path)!
}

// collect_sheets gathers every stylesheet that applies to the document.
//
// The UA sheet is first and the author's sheets follow, in document order. That order is
// the cascade's: a later sheet of the same origin wins a tie on source order, and this is
// what makes two `<style>` blocks in one page mean what a reader expects.
fn collect_sheets(doc &nhtml.Tag, mut ld loader.Loader) []style.Sheet {
	mut sheets := [style.Sheet{ style: css.parse(css.user_agent_css), origin: .user_agent }]
	for el in dom.elements(doc) {
		if el.name == 'style' {
			// A `<style>` body is a raw text node rather than child elements, which is the
			// one place where reading markup as a tree is the wrong shape.
			sheets << style.Sheet{ style: css.parse(dom.text_content(el)),
				origin: .author }
		}
		if el.name == 'link' {
			rel := el.attributes['rel'].to_lower()
			if rel == 'stylesheet' {
				href := el.attributes['href']
				if href == '' {
					continue
				}
				// A stylesheet that cannot be fetched is skipped rather than fatal. A page
				// with one broken link is still a page, and refusing to render it at all
				// would make the failure much harder to see than the missing styles.
				//
				// The message goes to stderr and the page still renders. A silently
				// unstyled page is the hardest kind of bug to report, because nothing
				// says the stylesheet was ever looked for.
				res := ld.load(href) or {
					eprintln('vweb: skipping stylesheet ' + href + ': ' + err.msg())
					continue
				}
				sheets << style.Sheet{ style: css.parse(res.body.bytestr()),
					origin: .author }
			}
		}
	}
	return sheets
}
