// boxes -- print the box tree and the display list for a page.
//
//	v run tools/boxes.v page.html
//	v run tools/boxes.v page.html --width 400 --list
//
// This exists because "the page looks wrong" is not a diagnosis. Every question about a
// rendering bug starts with "what boxes did it make", and answering that by writing a
// throwaway program is how six near-identical copies came to exist in one session -- each
// slightly different, and each measuring a slightly different thing.
//
// The output is meant to be read top to bottom. A box's position and size, then its text,
// then its glyph count: a box at the wrong y, the wrong width, or with no glyphs is
// visible without scrolling anywhere else. That last one is not hypothetical -- glyphs
// disappearing mid-word is the open bug in notes/JOURNAL.md, and this is the tool that
// would show it.

import engine.display
import engine.paint
import engine.page
import loader
import os
import strings

fn main() {
	args := os.args
	if args.len < 2 {
		eprintln('usage: v run tools/boxes.v <url-or-path> [--width N] [--height N] [--list]')
		exit(1)
	}
	target := args[1]
	mut opts := page.Options{}
	mut show_list := false
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
			'--list' {
				show_list = true
				i++
				continue
			}
			else {
				eprintln('boxes: unexpected argument ' + args[i])
				exit(1)
			}
		}
		break
	}

	mut ld := loader.Loader{ base: '.' }
	doc := page.load(target, mut ld) or {
		eprintln('boxes: ' + err.msg())
		exit(1)
	}
	for w in doc.warnings {
		eprintln('boxes: warning: ' + w)
	}

	println('viewport ' + opts.width.str() + 'x' + opts.height.str() + ', ' +
		doc.sheets.len.str() + ' stylesheets')
	show_boxes(page.layout(doc, opts.width, opts.height), 0)

	if !show_list {
		return
	}
	// The display list needs its own pass, because a document is parsed twice otherwise
	// and the two would not be the same document if anything were stateful.
	println('')
	println('display list')
	mut n := 0
	for cmd in page.display_list_from_document(doc, opts).commands {
		println(pad(n.str()) + describe(cmd))
		n++
	}
	println(pad(n.str()) + 'commands')
}

fn describe(cmd paint.Command) string {
	match cmd.kind {
		.fill_rect {
			return 'fill    ' + rect_str(cmd.rect) + '  ' + cmd.color.str()
		}
		.glyph_run {
			mut b := strings.new_builder(64)
			b.write_string('glyphs  ' + cmd.glyphs.len.str() + ' at')
			mut shown := 8
			if cmd.glyphs.len < shown {
				shown = cmd.glyphs.len
			}
			for g in cmd.glyphs[..shown] {
				b.write_string(' ' + int(g.x).str() + ',' + int(g.y).str())
			}
			if cmd.glyphs.len > 8 {
				b.write_string(' ...')
			}
			b.write_string('  ' + cmd.color.str())
			return b.str()
		}
		.image {
			// The area the image fills, then the first tile inside it: one command
			// per background however many tiles it becomes, so the list stays
			// readable and the tiling is the compositor's business.
			return 'image   ' + rect_str(cmd.image.draw) + ' in ' + rect_str(cmd.rect) + '  ' +
				cmd.image.bitmap.width.str() + 'x' + cmd.image.bitmap.height.str() + ' ' +
				cmd.image.repeat.str()
		}
	}
}

fn rect_str(r display.Rect) string {
	return '(' + r.x.str() + ',' + r.y.str() + ' ' + r.width.str() + 'x' + r.height.str() + ')'
}

fn pad(n string) string {
	return ' '.repeat(4 - n.len) + n + '  '
}

// show_boxes prints the box tree parents first, which is the order paint composites in.
fn show_boxes(root &display.Box, depth int) {
	mut line := ' '.repeat(depth * 2)
	line += label(root)
	line += '  ' + rect_str(root.rect)
	if root.text != '' {
		line += '  text=' + quoted(root.text)
	}
	if root.line_count > 0 {
		line += '  lines=' + root.line_count.str()
	}
	if root.glyphs.len > 0 {
		line += '  glyphs=' + root.glyphs.len.str()
	}
	println(line)
	for child in root.children {
		show_boxes(child, depth + 1)
	}
}

// label names a box after its element, and says so plainly when it has none -- an
// anonymous box is a real thing the reader has to be able to see, not an absence.
fn label(b &display.Box) string {
	if b.is_anonymous {
		return '<anonymous>'
	}
	if b.element == unsafe { nil } {
		return '<detached>'
	}
	mut name := b.element.name
	id := b.element.attributes['id']
	if id != '' {
		name += '#' + id
	}
	class := b.element.attributes['class']
	if class != '' {
		name += '.' + class.split(' ')[0]
	}
	return name
}

fn quoted(s string) string {
	mut t := s.trim_space()
	if t == '' {
		return '""'
	}
	if t.len > 40 {
		t = t[..40] + '...'
	}
	return '"' + t.replace('\n', '\\n') + '"'
}
