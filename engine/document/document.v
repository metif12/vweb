module document

import net.html
import strings

// The seam onto vlib/net/html.
//
// This module adds no parsing of its own. An earlier version of this project had an
// `engine/dom` that was a second HTML parser, which is the exact duplication
// ARCHITECTURE.md was written to prevent; it was deleted for that reason and this is
// what replaced it. There is deliberately no query language here, no tree mutation and
// no serialiser -- everything above it works on `html.Tag` directly.
//
// It exists for two reasons, both small.
//
// First, `html.parse` returns a `DocumentObjectModel` whose `root` field is private.
// The public door is the `get_root` method, and that is the sort of thing worth writing
// down once rather than rediscovering. (It was recorded in notes/JOURNAL.md as "the DOM
// is unreachable", which was wrong, and cost an afternoon of designing around a
// problem that did not exist.)
//
// Second, what `get_root` returns is a document node that holds the doctype, not the
// `html` element. Every consumer here wants the document element, so this picks it once.

/// parse turns HTML source into the document element.
///
/// A parse error is not reported: `net/html` recovers from malformed markup the way a
/// browser does, because a browser does, and a document that renders slightly wrong is
/// more useful to this engine's user than a refusal. Malformed input is the common case
/// on the web, not the exceptional one.
pub fn parse(src string) &html.Tag {
	return document_element(html.parse(src).get_root())
}

/// parse_file reads a file and parses it. Unlike parse it can fail, because the file can
/// be absent.
pub fn parse_file(path string) !&html.Tag {
	return document_element(html.parse_file(path).get_root())
}

/// document_element returns the document element of a parsed document.
///
/// It walks past the nodes that are not elements, depth-first, and takes the first real
/// element it finds. `net/html` puts the doctype *and any text that precedes the first
/// tag* in a node above `html`, so `get_root` returns that wrapper rather than the
/// element the rest of the engine expects to root the box tree at.
///
/// The whitespace case is not a corner. A file written with a newline after the doctype
/// -- which is most files -- has a text node there, and skipping only `!`-prefixed names
/// returned that text node as the document. The symptom was a blank page and no error
/// anywhere: a text node as the root means no elements, means no boxes, means nothing to
/// paint.
///
/// It is depth-first rather than a walk down `children[0]` because the wrapper's first
/// child is not reliably the one to descend into, and because a document with no element
/// at all must still return the node it was given rather than walk off the end.
pub fn document_element(node &html.Tag) &html.Tag {
	found := first_element(node)
	if found == unsafe { nil } {
		return node
	}
	return found
}

fn first_element(node &html.Tag) &html.Tag {
	if node.name != 'text' && !node.name.starts_with('!') {
		return node
	}
	for child in node.children {
		found := first_element(child)
		if found != unsafe { nil } {
			return found
		}
	}
	return unsafe { nil }
}

/// elements returns every element in the subtree rooted at `el`, in document order.
///
/// It is here because walking the tree is the one thing every caller needs and getting
/// the order wrong is easy: the box tree composites parents before children, and a paint
/// order that does not is a page where a parent's background lands on its own text.
pub fn elements(el &html.Tag) []&html.Tag {
	mut out := []&html.Tag{}
	collect(el, mut out)
	return out
}

fn collect(el &html.Tag, mut out []&html.Tag) {
	if !el.name.starts_with('!') && el.name != 'text' {
		out << el
	}
	for child in el.children {
		collect(child, mut out)
	}
}

/// by_id returns the first element with the given id, or nil.
///
/// It is a convenience over `elements` rather than a new capability, and it is here
/// because a renderer resolves `#id` targets constantly and every caller writing that
/// loop by hand is a chance to get the first-match rule wrong.
pub fn by_id(el &html.Tag, id string) &html.Tag {
	for candidate in elements(el) {
		if candidate.attributes['id'] == id && id != '' {
			return candidate
		}
	}
	return unsafe { nil }
}

/// text_content returns an element's text, including that of its descendants.
///
/// The UA sheet's `list-style-type` has nothing to say without it, and it is also the
/// cheapest way for a caller to ask "what does this element say" without walking.
pub fn text_content(el &html.Tag) string {
	mut b := strings.new_builder(64)
	write_text(el, mut b)
	return b.str()
}

fn write_text(el &html.Tag, mut b strings.Builder) {
	if el.name == 'text' {
		b.write_string(el.content)
		return
	}
	for child in el.children {
		write_text(child, mut b)
	}
}
