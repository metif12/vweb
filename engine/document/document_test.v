module document

import net.html as nhtml

// These tests use the real parser on real markup rather than building trees by hand.
//
// That is the opposite of what engine/display and engine/selector do, and it is
// deliberate: those tests hand-build trees so that a bug in another module cannot become
// this module's failing test. Here the parser *is* the thing under test, so a
// hand-built tree would test nothing. It also means a regression in `vlib/net/html`
// shows up here, which is the earliest place it can be seen.

fn names(root &nhtml.Tag) string {
	mut out := []string{}
	for el in elements(root) {
		out << el.name
	}
	return out.join(' ')
}

// --- the document element ----------------------------------------------------

fn test_the_document_element_is_html_and_not_the_doctype() {
	// `get_root` returns whatever sits above `html`, which is a document node holding
	// the doctype. Every consumer here wants the element the box tree is rooted at.
	doc := parse('<!DOCTYPE html><html><body><p>x</p></body></html>')
	assert doc.name == 'html'
}

fn test_a_document_with_no_doctype_still_finds_html() {
	doc := parse('<html><body><p>x</p></body></html>')
	assert doc.name == 'html'
}

fn test_a_fragment_with_no_html_element_yields_something_rather_than_nothing() {
	// Input that is only a doctype has no document element. Returning the node we were
	// given beats walking off the end of the tree.
	doc := parse('<!DOCTYPE html>')
	assert doc.name != ''
}

fn test_lowercase_and_uppercase_tags_are_normalised() {
	// `net/html` lowercases tag names. A selector written `DIV` has to match, and that
	// only works if the tree and the stylesheet agree on case.
	doc := parse('<HTML><BODY><P>x</P></BODY></HTML>')
	assert doc.name == 'html'
	assert names(doc) == 'html body p'
}

// --- text nodes --------------------------------------------------------------

fn test_text_inside_an_element_is_kept() {
	// This is the test that says which `net/html` this project builds against. The older
	// tree drops the leading text run of every element, which loses most of a document.
	doc := parse('<body><p>hello world</p></body>')
	p := first(doc, 'p')
	assert text_content(p) == 'hello world'
}

fn test_text_around_an_inline_element_is_all_kept() {
	// Three runs, and the ones on either side of the element are the ones a naive
	// implementation loses.
	doc := parse('<body><p>a<b>bold</b>c</p></body>')
	p := first(doc, 'p')
	assert text_content(p) == 'aboldc'
}

fn test_text_before_and_after_a_void_element_are_kept() {
	doc := parse('<body><p>one<br>two</p></body>')
	p := first(doc, 'p')
	assert text_content(p) == 'onetwo'
}

// --- structure ---------------------------------------------------------------

fn test_nested_elements_nest() {
	doc := parse('<body><div id="a"><p>one</p><div id="b"><span>two</span></div></div></body>')
	assert by_id(doc, 'b') != unsafe { nil }
	outer := by_id(doc, 'a')
	assert outer != unsafe { nil }
	// `b` is a descendant of `a`, at depth two below it.
	assert by_id(outer, 'b') != unsafe { nil }
}

fn test_siblings_are_siblings() {
	doc := parse('<body><p>one</p><p>two</p><p>three</p></body>')
	assert text_content(first(doc, 'p')) == 'one'
	mut ps := []&nhtml.Tag{}
	for el in elements(doc) {
		if el.name == 'p' {
			ps << el
		}
	}
	assert ps.len == 3
	assert text_content(ps[1]) == 'two'
	assert text_content(ps[2]) == 'three'
}

fn test_an_implicitly_closed_list_item_is_a_sibling() {
	// `<li>a<li>b` has no end tags and must still give two siblings rather than nesting.
	doc := parse('<body><ul><li>a<li>b</ul></body>')
	mut items := 0
	for el in elements(doc) {
		if el.name == 'li' {
			items++
		}
	}
	assert items == 2
}

// --- traversal ---------------------------------------------------------------

fn test_elements_is_in_document_order_with_parents_first() {
	doc := parse('<body><div><p>x</p></div></body>')
	assert names(doc) == 'body div p'
}

fn test_a_document_without_an_html_element_is_rooted_at_what_it_has() {
	// No `html` is synthesised. Inventing one would be parsing, which is the thing this
	// module exists not to do, and the layout does not need it: `Layouter.layout` treats
	// whatever it is given as the root and the UA sheet's `body` margin still applies.
	doc := parse('<div><p>x</p></div>')
	assert doc.name == 'div'
	assert names(doc) == 'div p'
}

fn test_elements_excludes_text_nodes() {
	// A text node is not an element and has no box of its own; including it would make
	// every traversal in the engine visit nodes it cannot lay out.
	doc := parse('<body><p>text here</p></body>')
	for el in elements(doc) {
		assert el.name != 'text'
	}
}

fn test_by_id_returns_the_first_match() {
	doc := parse('<body><div id="x">one</div><div id="x">two</div></body>')
	found := by_id(doc, 'x')
	assert found != unsafe { nil }
	assert text_content(found) == 'one'
}

fn test_by_id_returns_nothing_for_an_absent_id() {
	doc := parse('<body><p>x</p></body>')
	assert by_id(doc, 'nope') == unsafe { nil }
}

fn test_an_empty_id_does_not_match_everything() {
	// `attributes['id']` is '' for an element with no id, so a check without an emptiness
	// guard returns the first element of the document for a lookup of "".
	doc := parse('<body><p>x</p></body>')
	assert by_id(doc, '') == unsafe { nil }
}

fn test_an_unquoted_attribute_value_is_readable() {
	doc := parse('<body><div class=box>x</div></body>')
	div := first(doc, 'div')
	assert div.attributes['class'] == 'box'
}

// --- recovery ----------------------------------------------------------------

fn test_unclosed_tags_do_not_lose_the_document() {
	// A browser recovers and renders; refusing would make this engine useless on real
	// pages, which are full of unclosed `<p>` and `<li>`.
	doc := parse('<body><p>one<p>two<p>three</body>')
	assert text_content(doc).replace(' ', '').contains('onetwothree')
}

fn test_a_stray_end_tag_does_not_lose_the_document() {
	doc := parse('<body></span><p>after</p></body>')
	assert text_content(doc).contains('after')
}

fn test_an_empty_document_does_not_crash() {
	doc := parse('')
	assert doc != unsafe { nil }
	_ := elements(doc)
}

fn first(root &nhtml.Tag, name string) &nhtml.Tag {
	for el in elements(root) {
		if el.name == name {
			return el
		}
	}
	return unsafe { nil }
}
fn test_a_newline_after_the_doctype_still_finds_the_document_element() {
	// The bug this pins. `net/html` puts a text node above `html` when the source has
	// anything but a tag there, and a file with a newline after the doctype -- which is
	// nearly every file -- has exactly that. Returning the text node gives a document
	// with no elements in it, and the page comes out blank with nothing logged.
	doc := parse('<!DOCTYPE html>' + '\n' + '<html><body><p>x</p></body></html>')
	assert doc.name == 'html'
	assert elements(doc).len >= 3
}

fn test_leading_whitespace_before_the_doctype_is_skipped_too() {
	doc := parse('\n\n  <!DOCTYPE html>\n<html><body><p>x</p></body></html>')
	assert doc.name == 'html'
}

fn test_a_document_that_is_only_whitespace_yields_the_node_it_was_given() {
	// Nothing to find, so the caller gets what it passed in rather than nil. Every
	// consumer here would otherwise have to handle a nil document for input that is
	// merely empty.
	doc := parse('   ')
	assert doc != unsafe { nil }
}