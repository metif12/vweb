module document

import net.html as nhtml

// Character reference decoding.
//
// The rules that are worth testing are the ones that refuse to do something. A decoder
// that replaces every `&word;` with something is wrong in a way that only shows up on a
// page nobody was looking at, so most of what follows is about references that must be
// left alone.

fn test_the_four_names_every_page_uses_are_decoded() {
	assert decode_text('a &amp; b') == 'a & b'
	assert decode_text('&lt;tag&gt;') == '<tag>'
	assert decode_text('&quot;q&quot;') == '"q"'
	assert decode_text('it&apos;s') == "it's"
}

fn test_a_legacy_name_is_decoded_without_its_semicolon() {
	// HTML5 lets a fixed list of names appear without the `;`, and `&amp` really is an
	// ampersand in a browser.
	assert decode_text('a &amp b') == 'a & b'
	assert decode_text('&copy') == '\u00A9'
}

fn test_a_non_legacy_name_without_its_semicolon_is_left_alone() {
	// `hellip` is not one of the legacy names, so it is text.
	assert decode_text('&hellip') == '&hellip'
}

fn test_an_unknown_name_is_left_alone() {
	// This is the spec's behaviour and it is the right one: a wrong mapping is a silent
	// corruption, and a missing one is visible.
	assert decode_text('a &notarealentity; b') == 'a &notarealentity; b'
}

fn test_a_name_that_is_only_a_prefix_of_a_real_one_is_left_alone() {
	// `notit` contains the legacy name `not`. Decoding it would render "¬it;".
	assert decode_text('&notit;') == '&notit;'
	assert decode_text('&not') == '\u00AC'
}

fn test_numeric_references_are_decoded_in_both_notations() {
	assert decode_text('&#65;&#66;&#67;') == 'ABC'
	assert decode_text('&#x41;&#X42;&#x43;') == 'ABC'
	// Above the BMP, so this is a four-byte sequence and not a three-byte one.
	assert decode_text('&#x1F600;') == '\U0001F600'
}

fn test_a_reference_beyond_the_last_code_point_becomes_the_replacement_character() {
	assert decode_text('&#x110000;') == '\uFFFD'
	assert decode_text('&#0;') == '\uFFFD'
}

fn test_a_surrogate_becomes_the_replacement_character() {
	// Not a character. Encoding it would produce invalid UTF-8 rather than a visible mark.
	assert decode_text('&#xD800;') == '\uFFFD'
	assert decode_text('&#55296;') == '\uFFFD'
}

fn test_the_c1_range_is_read_as_windows_1252() {
	// `&#146;` is a right single quote, which is what an author writing it means.
	assert decode_text('&#146;') == '\u2019'
	assert decode_text('&#151;') == '\u2014'
}

fn test_a_bare_ampersand_is_text() {
	assert decode_text('a & b') == 'a & b'
	assert decode_text('&&') == '&&'
	assert decode_text('&') == '&'
}

fn test_a_truncated_reference_is_text() {
	assert decode_text('&') == '&'
	assert decode_text('&#') == '&#'
	assert decode_text('&#x') == '&#x'
	assert decode_text('&#xZZ;') == '&#xZZ;'
}

fn test_text_with_no_reference_is_returned_unchanged() {
	assert decode_text('nothing to do here') == 'nothing to do here'
	assert decode_text('') == ''
}

fn test_a_non_breaking_space_decodes_to_a_non_breaking_space() {
	// U+00A0, not a space. It has to survive as its own character or `one&nbsp;two`
	// becomes `onetwo` at whitespace collapsing time.
	assert decode_text('one&nbsp;two') == 'one\u00A0two'
}

fn test_an_attribute_decodes_a_reference() {
	assert decode_attribute('a &amp; b') == 'a & b'
}

fn test_an_attribute_does_not_decode_a_legacy_name_before_an_equals_sign() {
	// `?a=1&copy=2` is two parameters, not an ampersand followed by `copy=2`. Decoding it
	// corrupts a URL, which is the one place a wrong character is guaranteed to be noticed.
	assert decode_attribute('?a=1&copy=2') == '?a=1&copy=2'
	assert decode_attribute('?a=1&amp=2') == '?a=1&amp=2'
}

fn test_an_attribute_does_not_decode_a_legacy_name_before_a_letter() {
	// `a&amp;b` in an attribute stays as it is. This is not an oversight in the rule above:
	// HTML5 says a semicolon-less named reference in an attribute is left alone when the
	// next character is `=` or an alphanumeric, and the reason is historical. It does mean
	// `a&ampb` renders literally in a title, which is the correct answer.
	assert decode_attribute('a&ampb') == 'a&ampb'
	// With the semicolon it is decoded, in an attribute as anywhere else -- the rule is
	// about a *missing* semicolon followed by `=` or a letter, not about attributes.
	assert decode_attribute('x&amp;y') == 'x&y'
	assert decode_attribute('x&amp;') == 'x&'
}

// --- through a real parse ------------------------------------------------------

// element_named is local to this file because each `_test.v` compiles as its own binary
// against the module: a helper defined in `document_test.v` is not visible here.
fn element_named(root &nhtml.Tag, name string) &nhtml.Tag {
	for candidate in elements(root) {
		if candidate.name == name {
			return candidate
		}
	}
	return unsafe { nil }
}

fn test_text_in_a_parsed_document_is_decoded() {
	root := parse('<html><body><p>Tom &amp; Jerry</p></body></html>')
	assert text_content(element_named(root, 'p')) == 'Tom & Jerry'
}

fn test_an_attribute_in_a_parsed_document_is_decoded() {
	// A space after the reference, because a letter after it would hit the attribute rule
	// above and stay literal. That is not a quirk worked around here; the title is just
	// the attribute where the space is natural.
	root := parse('<html><body><a title="a&amp; b" id="x">link</a></body></html>')
	link := by_id(root, 'x')
	assert link.attributes['title'] == 'a& b'
}

fn test_style_content_is_not_decoded() {
	// `<style>` holds CSS. `&amp;` in there is not an ampersand, it is an unknown escape
	// that a browser leaves exactly as written, and decoding it would corrupt the sheet.
	//
	// Asserted through the whole document's text rather than through the style element's
	// children, because the shape of what `net/html` hands back for a raw-text element is
	// its business and not a contract this test should depend on.
	root := parse('<html><head><style>p::after{content:"&amp;"}</style></head><body></body></html>')
	assert text_content(root).contains('&amp;')
}

// A script body is removed before the parser sees it, so there is nothing in it to decode.
// Asserted through the whole document rather than through the script element, because the
// shape `net/html` hands back for a raw-text element is its business.
fn test_script_content_is_gone_before_it_can_be_decoded() {
	root := parse('<html><body><script>if (a &lt; b) {}</script><p>x</p></body></html>')
	assert !text_content(root).contains('&lt;')
}

fn test_body_text_is_still_decoded_when_a_script_is_present() {
	// The script removal has to be a removal and not a bail: one script must not stop the
	// walk and leave the rest of the page undecoded.
	src := '<html><body><script>var a = "&lt;";</script><p>Tom &amp; Jerry</p></body></html>'
	// Asserted on the intermediate step as well as the result, because a wrong blanking
	// would otherwise be indistinguishable from a parser bug -- and it was: the tree came
	// back with a nil child in it and `text_content` died on it.
	assert blank_script_bodies(src) ==
		'<html><body><script></script><p>Tom &amp; Jerry</p></body></html>'
	root := parse(src)
	assert text_content(root).contains('Tom & Jerry')
}

// --- the script workaround -----------------------------------------------------

fn test_a_script_does_not_swallow_the_rest_of_the_document() {
	// `net/html` drops every element after a `<script>`. This is the assertion that says so,
	// and it is here rather than in a comment because the workaround that satisfies it is in
	// our layer and could be dropped by anyone tidying up.
	root := parse('<html><body><script>var a = 1;</script><p>plain text here</p></body></html>')
	assert text_content(element_named(root, 'p')) == 'plain text here'
}

fn test_several_scripts_and_the_markup_between_them() {
	root := parse('<html><body><p>one</p><script>a()</script><p>two</p>' +
		'<script>b()</script><p>three</p></body></html>')
	assert text_content(element_named(root, 'p')) == 'one'
	all := text_content(root)
	assert all.contains('one') && all.contains('two') && all.contains('three')
}

fn test_a_script_with_attributes_still_ends_correctly() {
	root := parse('<html><body><script src="a.js" defer></script><p>after</p></body></html>')
	assert text_content(element_named(root, 'p')) == 'after'
}

fn test_a_greater_than_inside_a_script_attribute_does_not_end_the_tag() {
	// `<script src="a>b">` is a script with a source, not a script followed by a stray `>`.
	// The parser would end the tag at that `>` and lose everything after it.
	assert blank_script_bodies('<script src="a>b"></script><p>x</p>') ==
		'<script src="a>b"></script><p>x</p>'
}

fn test_blanking_removes_the_body_and_keeps_both_tags() {
	assert blank_script_bodies('<script>var a = 1 < 2;</script>') == '<script></script>'
}

fn test_blanking_leaves_a_page_with_no_script_byte_for_byte_identical() {
	src := '<html><body><p>hello &amp; goodbye</p></body></html>'
	assert blank_script_bodies(src) == src
}

fn test_a_tag_that_merely_starts_with_script_is_not_a_script() {
	// `<scripty>` is an unknown element, and blanking to the next `</scripty>` would eat
	// the rest of the document.
	src := '<scripty>keep me</scripty><p>and me</p>'
	assert blank_script_bodies(src) == src
}

fn test_a_script_with_no_closing_tag_swallows_only_what_is_script() {
	// With no close tag, everything after the open tag is script body, and nothing in it is
	// markup, so blanking it is right rather than merely safe.
	assert blank_script_bodies('<p>before</p><script>var a = 1;') == '<p>before</p><script>'
}
