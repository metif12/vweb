module tree

import net.html

// Predicates and navigation over `vlib/net/html`'s tree.
//
// This module holds no tree of its own. ARCHITECTURE.md 6 records that an
// `engine/dom` was written here once and deleted, because a second
// implementation of the document tree is a second thing that only one of the two
// ever improves. What is left is the handful of questions every pass asks about a
// node -- is this an element, what is its parent, what are its element children --
// in one place.
//
// `is_element` is duplicated from `net/html` on purpose, and it is the only thing
// in this project that is. The rewritten `net/html` has it as a method, but that
// rewrite lives only in C:\Users\MR\Projects\v, while `vtext` -- the text layer
// this engine is built on -- does not yet compile under that tree's compiler. So
// the two available V installations each supply half of what is needed, and the
// half that is missing is this one function. Delete it and call the method as soon
// as both halves come from the same tree; the body is identical either way.

// is_element reports whether the node is an element, as opposed to a text run or
// the document node. A text run has no attributes, no parent that can be asked for
// an ancestor chain and no children, so a pass that treats one as an element reads
// a tag name of `text` off it and keeps going.
pub fn is_element(el &html.Tag) bool {
	return el.name != 'text' && el.name != '!document'
}

// is_text reports whether the node is a run of text.
pub fn is_text(el &html.Tag) bool {
	return el.name == 'text'
}

// parent_element returns the nearest element ancestor. The document node is not an
// element and neither is a text run, so there is nothing above the root element.
pub fn parent_element(el &html.Tag) ?&html.Tag {
	p := el.parent
	if p == unsafe { nil } || !is_element(p) {
		return none
	}
	return p
}

// element_children returns the element children of a node, skipping text runs.
// Layout builds boxes from elements; including whitespace runs would give every gap
// between two inline boxes a box of its own.
pub fn element_children(el &html.Tag) []&html.Tag {
	mut out := []&html.Tag{}
	for c in el.children {
		if is_element(c) {
			out << c
		}
	}
	return out
}

// element_child_count counts the element children of a node.
pub fn element_child_count(el &html.Tag) int {
	mut n := 0
	for c in el.children {
		if is_element(c) {
			n++
		}
	}
	return n
}

// index_among_siblings returns the element's zero-based position among its element
// siblings, which is what `:first-child` and `:nth-child` are defined against.
pub fn index_among_siblings(el &html.Tag) int {
	p := parent_element(el) or { return 0 }
	mut i := 0
	for c in p.children {
		if !is_element(c) {
			continue
		}
		if c == el {
			return i
		}
		i++
	}
	return i
}

// element_sibling_count returns how many elements share a parent with this one,
// counting itself.
pub fn element_sibling_count(el &html.Tag) int {
	p := parent_element(el) or { return 1 }
	mut n := 0
	for c in p.children {
		if is_element(c) {
			n++
		}
	}
	return n
}

// previous_element returns the element before el among its siblings. Whitespace
// text runs are not elements, so `:first-child` on the first element of a document
// is true even though a text run precedes it.
pub fn previous_element(el &html.Tag) ?&html.Tag {
	p := parent_element(el) or { return none }
	mut prev := unsafe { nil }
	for c in p.children {
		if c == el {
			break
		}
		if is_element(c) {
			prev = c
		}
	}
	if prev == unsafe { nil } {
		return none
	}
	return prev
}

// next_element returns the element after el among its siblings.
pub fn next_element(el &html.Tag) ?&html.Tag {
	p := parent_element(el) or { return none }
	mut seen := false
	for c in p.children {
		if c == el {
			seen = true
			continue
		}
		if seen && is_element(c) {
			return c
		}
	}
	return none
}

// index_among_siblings_of_type returns the element's zero-based position among
// siblings that have the same tag name, which is what `:nth-of-type` counts.
pub fn index_among_siblings_of_type(el &html.Tag) int {
	p := parent_element(el) or { return 0 }
	mut i := 0
	for c in p.children {
		if !is_element(c) || c.name != el.name {
			continue
		}
		if c == el {
			return i
		}
		i++
	}
	return i
}

// sibling_count_of_type returns how many siblings share this element's tag name.
pub fn sibling_count_of_type(el &html.Tag) int {
	p := parent_element(el) or { return 1 }
	mut n := 0
	for c in p.children {
		if is_element(c) && c.name == el.name {
			n++
		}
	}
	return n
}
