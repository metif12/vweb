module main

// vweb -- render a page to a PNG.
//
// The engine is engine/page; this is the command line around it. Everything it does is
// parse arguments and print, because anything else here would be a second place where the
// pipeline is defined.
//
//	vweb page.html out.png --width 640 --height 480
//	vweb https://example.com out.png

import engine.page
import loader
import os

fn main() {
	args := os.args
	if args.len < 2 {
		eprintln('usage: vweb <url-or-path> [out.png] [--width N] [--height N]')
		exit(1)
	}
	target := args[1]
	mut opts := page.Options{}

	mut out_path := ''
	mut i := 2
	for i < args.len {
		match args[i] {
			'--width' {
				opts.width = args[i + 1].int()
				i += 2
				continue
			}
			'--height' {
				opts.height = args[i + 1].int()
				i += 2
				continue
			}
			else {
				if out_path != '' {
					eprintln('vweb: unexpected argument ' + args[i])
					exit(1)
				}
				out_path = args[i]
				i++
				continue
			}
		}
		break
	}
	if out_path == '' {
		out_path = default_out_path(target)
	}

	// The base is the *page's* directory, not the process's working directory. Every
	// relative URL a page carries -- a `url(tile.png)` background, a `<link href>` -- is
	// relative to where the page was found, and resolving it against `.` instead makes
	// the same page render differently depending on which directory the tool was run
	// from. `os.dir` returns `.` for a bare name, which is the right answer for that
	// case, so it needs no special handling here.
	mut ld := loader.Loader{ base: os.dir(target) }
	doc := page.load(target, mut ld) or {
		eprintln('vweb: ' + err.msg())
		exit(1)
	}
	// Warnings do not stop the render. A page with one unreachable stylesheet is still a
	// page, and saying so is more use than refusing.
	for w in doc.warnings {
		eprintln('vweb: ' + w)
	}
	canvas := page.render(doc, opts)
	canvas.write_png(out_path) or {
		eprintln('vweb: cannot write ' + out_path + ': ' + err.msg())
		exit(1)
	}
	println('wrote ' + out_path + '  (' + opts.width.str() + 'x' + opts.height.str() + ')')
}

// default_out_path derives a name from the target so that rendering five URLs in a shell
// loop does not overwrite one file five times.
fn default_out_path(target string) string {
	mut name := target.all_after_last('/')
	name = name.all_after_last('\\')
	if name == '' {
		name = 'page.html'
	}
	mut base := name.all_before_last('.')
	if base == '' {
		base = name
	}
	return base + '.png'
}
