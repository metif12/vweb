module document

import strings

// Blanking script bodies before parsing.
//
// `vlib/net/html` drops every element after a `<script>`. Measured, not inferred:
//
//	<html><body><script>var a = 1;</script><p>plain text here</p></body></html>
//
// builds `html > body` with no children at all. The same document without the script
// builds `html > body > p` with its text. It is not about character references: the probe
// that established this has no entities in it.
//
// The cause is in the parser's code-tag state machine. When it sees `<script>` it sets
// `open_code` and scans for the closing tag, and when it finds it the closing is recorded
// against `parser.lexical_attributes.current_tag` -- but `generate_tag()` has already run
// and moved `current_tag` on to the next tag, so the close is applied to the wrong node and
// the markup that follows is consumed as part of it. (`vlib/net/html/parser.v`, the
// `open_code` branch.)
//
// This is a real bug in a shared stdlib and the fix belongs there. It is not being made
// there because that tree has uncommitted work in `vlib/net/html` from another session,
// and editing another session's live files is how two changesets end up fighting over one
// parser.
//
// So the workaround, in our own layer, is that a renderer with no JavaScript engine has no
// use for a script body: `script` content is never displayed, never measured and never
// styled. Blanking it before the parse means the parser never enters the broken state, and
// every element after it survives.
//
// `<style>` is untouched, and deliberately so: a stylesheet *is* used. The bug does not
// affect it -- a page with a `<style>` and a paragraph after it parses correctly -- because
// `style` is handled by a different path. Losing the stylesheet of every real page to work
// around a script bug would have been an expensive trade.
//
// This must be revisited at Phase 7. When there is an engine, the body matters, and the
// right answer is the parser fix rather than this.
pub fn blank_script_bodies(src string) string {
	if !has_script_tag(src) {
		return src
	}
	mut b := strings.new_builder(src.len)
	mut i := 0
	for i < src.len {
		if !open_tag_starts_at(src, i, 'script') {
			b.write_byte(src[i])
			i++
			continue
		}
		open_end := end_of_open_tag(src, i)
		if open_end < 0 {
			// An unterminated `<script` with no `>`. Copy the rest and stop guessing.
			b.write_string(src[i..])
			break
		}
// The open tag is kept: the element must survive, only its body goes.
		b.write_string(src[i..open_end])
		close_at := close_tag_index(src, open_end, 'script')
		if close_at < 0 {
			// No closing tag. Everything after the open tag is script body as far as HTML
			// is concerned, so none of it is markup and blanking all of it is right.
			break
		}
		// The close tag is written and then *skipped*, not re-examined. An earlier version
		// left `i` on the `</script` and went round the loop, matched the closing tag as if
		// it were an opening one, found no close after it and stopped -- which truncated
		// every page at its first script. `<html><body><script>x</script><p>hi</p>` came
		// back as `<html><body><script></script>`.
		close_end := end_of_open_tag(src, close_at)
		if close_end < 0 {
			b.write_string(src[close_at..])
			break
		}
		b.write_string(src[close_at..close_end])
		i = close_end
	}
	return b.str()
}

// has_script_tag is the cheap check that keeps the common case free of any copying: a page
// with no script returns its own source untouched.
fn has_script_tag(src string) bool {
	return index_of_open_tag(src, 0, 'script') >= 0
}

fn index_of_open_tag(src string, from int, name string) int {
	mut i := from
	for i < src.len {
		if open_tag_starts_at(src, i, name) {
			return i
		}
		i++
	}
	return -1
}

// close_tag_index finds `</name` at or after `from` and returns the index of the `<`.
fn close_tag_index(src string, from int, name string) int {
	mut i := from
	for i < src.len {
		if close_tag_starts_at(src, i, name) {
			return i
		}
		i++
	}
	return -1
}

// open_tag_starts_at reports whether an *opening* `<name` tag begins at `at`.
//
// Only opening tags. Matching `</name` here as well is what made the truncation above
// possible, and the closing tag has to be recognisable in its own right for the body to
// have an end.
fn open_tag_starts_at(src string, at int, name string) bool {
	if at + 1 >= src.len || src[at] != `<` {
		return false
	}
	mut i := at + 1
	if i + name.len > src.len || !equals_ignore_case(src[i..i + name.len], name) {
		return false
	}
	i += name.len
	// `<scripty` is not `<script`, and `</script` is not an opening tag. Either way the
	// character after the name has to end it.
	return i >= src.len || !is_name_byte(src[i])
}

fn close_tag_starts_at(src string, at int, name string) bool {
	if at + 2 >= src.len || src[at] != `<` || src[at + 1] != `/` {
		return false
	}
	mut i := at + 2
	if i + name.len > src.len || !equals_ignore_case(src[i..i + name.len], name) {
		return false
	}
	i += name.len
	return i >= src.len || !is_name_byte(src[i])
}

// end_of_open_tag returns the index just past the `>` that ends the open tag, or -1.
//
// Quoted attribute values are respected, because `>` inside one does not end the tag:
// `<script src="a>b">` is a script with a source, not a script followed by a stray `>`.
// This is the one part of the scan that a regex would get wrong and a loop gets right.
fn end_of_open_tag(src string, at int) int {
	mut i := at + 1
	mut quote := u8(0)
	for i < src.len {
		c := src[i]
		if quote != 0 {
			if c == quote {
				quote = 0
			}
		} else if c == `"` || c == `'` {
			quote = c
		} else if c == `>` {
			return i + 1
		}
		i++
	}
	return -1
}

fn equals_ignore_case(a string, b string) bool {
	if a.len != b.len {
		return false
	}
	for i in 0 .. a.len {
		if to_lower_byte(a[i]) != to_lower_byte(b[i]) {
			return false
		}
	}
	return true
}

fn to_lower_byte(c u8) u8 {
	return if c >= `A` && c <= `Z` { c + 32 } else { c }
}