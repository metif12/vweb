module document

import strings

// Character reference decoding.
//
// `vlib/net/html` tokenizes `&amp;` correctly -- it hands back the text node with the
// reference still spelled out in it, which is what the tokenizer is supposed to do -- and
// then leaves it for a consumer. Nothing above it decoded them, so a page rendered with
// `a &amp; b` on it, in this project's words: "named amp: a &amp; b".
//
// This is here rather than in `vlib/net/html` for two reasons. It is the wrong module's
// problem to solve, because that tree has a tree builder in it that many projects depend
// on and a change there is a change for all of them. And a decoder that mutates the tree
// has to know which nodes are raw text, which is a decision `engine/document` already owns.
//
// The rules implemented, and the two that are easy to get wrong:
//
//   - An unknown name is left alone. `&notarealentity;` renders as itself, which is what
//     the spec says and what browsers do. Decoding an unknown reference to nothing, or to
//     a guess, is worse than the bug it was meant to fix.
//   - A name may be decoded without its semicolon, but only for the set HTML5 marks as
//     legacy. `&amp` is an ampersand; `&hellip` without a semicolon is not an ellipsis.
//     An unknown name without a semicolon is left alone, which is also what makes a
//     query string like `?a=1&copy=2` survive.
//
// Numeric references are complete, because they are arithmetic rather than a table:
// `&#65;` and `&#x41;` both give U+0041. Out-of-range values become U+FFFD, which is the
// spec's replacement character, and the C1 range is remapped to the Windows-1252
// characters authors mean when they write `&#146;`.

/// decode_text decodes the character references in a text context.
pub fn decode_text(s string) string {
	return decode(s, false)
}

/// decode_attribute decodes the character references in an attribute value.
///
/// The difference from a text context is one rule: inside an attribute, a legacy name
/// followed by `=` or by an alphanumeric is not a reference at all. `?a=1&copy=2` in a
/// `href` is two parameters, not an ampersand followed by `copy=2`, and decoding it would
/// corrupt the URL.
pub fn decode_attribute(s string) string {
	return decode(s, true)
}

fn decode(s string, in_attribute bool) string {
	// `index_` rather than `index`: this V returns a plain int from it and an Option from
	// the other, and the fast path for the overwhelmingly common "no `&` at all" case
	// does not need an unwrap.
	if s.index_('&') < 0 {
		return s
	}
	mut b := strings.new_builder(s.len + 16)
	mut i := 0
	for i < s.len {
		if s[i] != `&` {
			b.write_byte(s[i])
			i++
			continue
		}
		if r := reference_at(s[i..], in_attribute) {
			b.write_string(r.text)
			i += r.len
			continue
		}
		// Not a reference. The `&` is text, and the scan continues from the next byte, so
		// `a & b` and `&notarealentity;` both survive untouched.
		b.write_byte(`&`)
		i++
	}
	return b.str()
}

// reference is a decoded character reference: the text it stands for, and how many bytes
// of the source it occupied.
//
// Both halves come back together on purpose. An earlier version had the readers return
// the text and a separate `reference_len` measure the span, which is the same arithmetic
// done twice, and the copy read one byte past the end of the string on a reference at the
// very end. A reader that consumed 6 bytes while the measurer counted 5 would also have
// dropped a character into the middle of the text.
struct Reference {
	text string
	len  int
}

fn reference_at(rest string, in_attribute bool) ?Reference {
	if r := numeric(rest) {
		return r
	}
	return named(rest, in_attribute)
}

// There is no longest-match walk here, and there does not need to be. It was written as
// one -- to stop `&notit;` decoding as the legacy `&not` -- and it forgot the more basic
// question, which is whether the name is in the table at all. `&notit;` is not, so
// `replacements["notit"]` is the empty string and seven bytes of the page vanished.
//
// A name in the table is an exact match by definition, and a name not in the table fails
// membership whatever it happens to be a prefix of. So the walk was redundant work that
// hid the one test that mattered.

// A name has to be in the table, exactly. This used to also walk the table looking for a
	// longer name starting with this one, on the theory that `&notit;` should not decode as
	// `&not` -- and then it read `replacements[name]` without ever checking that `name`
	// was there. `&notit;` is not in the table, `replacements["notit"]` is the empty
	// string, and seven bytes of the page disappeared.
//
// The prefix rule turns out to be unnecessary: a name in the table is an exact match by
	// definition, and a name not in the table fails the membership test whatever it is a
	// prefix of.
fn named(rest string, in_attribute bool) ?Reference {
	// `rest` starts at the `&`, so the name begins at 1. Starting the scan at 0 reads the
	// `&` itself, which is not a name byte, and every named reference then comes back as
	// none -- which is invisible in a unit test that calls `decode_text` directly and fatal
	// in the walk, where the numeric form kept working and named ones did not.
	mut i := 1
	for i < rest.len && is_name_byte(rest[i]) {
		i++
	}
	if i == 1 {
		return none
	}
	name := rest[1..i]
	mut has_semicolon := false
	if i < rest.len && rest[i] == `;` {
		has_semicolon = true
		i++
	}
	legacy := name in legacy_names
	// Only when the semicolon is *missing*. `x&amp;y` in an attribute decodes to `x&y`; it
	// is `x&ampy` that has to stay literal, and applying the rule either way was leaving
	// every correctly-written `&amp;` in every attribute undecoded.
	if legacy && in_attribute && !has_semicolon {
		// The attribute rule: `&copy=2` is a parameter named `copy`, not a copyright sign.
		if i < rest.len && (rest[i] == `=` || is_alnum(rest[i])) {
			return none
		}
	}
	// A non-legacy name without its semicolon is not a reference, which is what makes
	// `&hellip` render as itself.
	if !legacy && !has_semicolon {
		return none
	}
	if name !in replacements {
		return none
	}
	return Reference{
		text: replacements[name]
		len:  i
	}
}

fn numeric(rest string) ?Reference {
	if rest.len < 3 || rest[1] != `#` {
		return none
	}
	mut i := 2
	mut hex := false
	if rest[i] == `x` || rest[i] == `X` {
		hex = true
		i++
	}
	start := i
	mut code := 0
	for i < rest.len {
		d := digit_value(rest[i])
		if d < 0 || (!hex && d > 9) || (hex && d > 15) {
			break
		}
		code = code * (if hex { 16 } else { 10 }) + d
		if code > 0x10FFFF {
			// Stop accumulating rather than overflowing, but keep consuming the digits so
			// the reference is recognised and the rest of the text is not misread.
			code = 0x110000
		}
		i++
	}
	if i == start {
		return none
	}
	if i < rest.len && rest[i] == `;` {
		i++
	}
	return Reference{
		text: encode_code_point(code)
		len:  i
	}
}

// encode_code_point applies the numeric fixes the HTML spec requires and encodes the
// result as UTF-8.
//
// Three ranges are wrong on their own and all three have to become U+FFFD: zero, which is
// how a truncated reference arrives, the surrogate range, which is not a character, and
// anything past U+10FFFF. The C1 range is different -- authors write `&#146;` meaning an
// apostrophe, so those are remapped rather than replaced.
fn encode_code_point(code int) string {
	if code == 0 || code >= 0x110000 || (code >= 0xD800 && code <= 0xDFFF) {
		return '\uFFFD'
	}
	// C1 is handled after the range checks, not before: `0x9D` is inside it and is also a
	// literal Windows-1252 quote.
	if code >= 0x80 && code <= 0x9F {
		return rune(c1_remap[code - 0x80]).str()
	}
	return rune(code).str()
}

// c1_remap is the Windows-1252 reading of C1, which is what a numeric reference in the
// 0x80-0x9F range actually means to the people writing it.
const c1_remap = [
	u32(0x20AC), 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160,
	0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013,
	0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
]

fn is_digit_or_hex(c u8) bool {
	return (c >= `0` && c <= `9`) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)
}

fn digit_value(c u8) int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	if c >= `A` && c <= `F` {
		return int(c - `A`) + 10
	}
	return -1
}

fn is_alnum(c u8) bool {
	return (c >= `0` && c <= `9`) || (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
}

// is_name_byte is the character set a reference name is spelled with: alphanumerics, and
// nothing else. A name cannot contain `;`, so the terminator ends the run.
fn is_name_byte(c u8) bool {
	return is_alnum(c)
}

// replacements is the named character reference table.
//
// It is not the full 2231 entries of HTML5. It is the set that appears in real documents
// plus everything a hand-written page is likely to use, and an unlisted name is left
// spelled out rather than guessed at -- which is both the spec's behaviour and the honest
// one, since a wrong mapping is a silent corruption and a missing one is visible.
const replacements = {
	'amp':    '&'
	'AMP':    '&'
	'lt':     '<'
	'LT':     '<'
	'gt':     '>'
	'GT':     '>'
	'quot':   '"'
	'QUOT':   '"'
	'apos':   '\''
	'nbsp':   '\u00A0'
	'copy':   '\u00A9'
	'reg':    '\u00AE'
	'trade':  '\u2122'
	'cent':   '\u00A2'
	'pound':  '\u00A3'
	'yen':    '\u00A5'
	'euro':   '\u20AC'
	'curren': '\u00A4'
	'iexcl':  '\u00A1'
	'iquest': '\u00BF'
	'brvbar': '\u00A6'
	'uml':    '\u00A8'
	'sect':   '\u00A7'
	'para':   '\u00B6'
	'middot': '\u00B7'
	'laquo':  '\u00AB'
	'raquo':  '\u00BB'
	'times':  '\u00D7'
	'divide': '\u00F7'
	'deg':    '\u00B0'
	'plusmn': '\u00B1'
	'frac12': '\u00BD'
	'frac14': '\u00BC'
	'frac34': '\u00BE'
	'micro':  '\u00B5'
	'not':    '\u00AC'
	'shy':    '\u00AD'
	'macr':   '\u00AF'
	'sup1':   '\u00B9'
	'sup2':   '\u00B2'
	'sup3':   '\u00B3'
	'acute':  '\u00B4'
	'cedil':  '\u00B8'
	'ordf':   '\u00AA'
	'ordm':   '\u00BA'
	'hellip': '\u2026'
	'mdash':  '\u2014'
	'ndash':  '\u2013'
	'lsquo':  '\u2018'
	'rsquo':  '\u2019'
	'ldquo':  '\u201C'
	'rdquo':  '\u201D'
	'sbquo':  '\u201A'
	'bdquo':  '\u201E'
	'bull':   '\u2022'
	'dagger': '\u2020'
	'Dagger': '\u2021'
	'permil': '\u2030'
	'prime':  '\u2032'
	'Prime':  '\u2033'
	'oline':  '\u203E'
	'frasl':  '\u2044'
	'ensp':   '\u2002'
	'emsp':   '\u2003'
	'thinsp': '\u2009'
	'zwnj':   '\u200C'
	'zwj':    '\u200D'
	'lrm':    '\u200E'
	'rlm':    '\u200F'
	'larr':   '\u2190'
	'uarr':   '\u2191'
	'rarr':   '\u2192'
	'darr':   '\u2193'
	'harr':   '\u2194'
	'infin':  '\u221E'
	'ne':     '\u2260'
	'le':     '\u2264'
	'ge':     '\u2265'
	'simi':   '\u223C'
	'alpha':  '\u03B1'
	'beta':   '\u03B2'
	'gamma':  '\u03B3'
	'delta':  '\u03B4'
	'theta':  '\u03B8'
	'lambda': '\u03BB'
	'mu':     '\u03BC'
	'pi':     '\u03C0'
	'sigma':  '\u03C3'
	'omega':  '\u03C9'
	'spades': '\u2660'
	'clubs':  '\u2663'
	'hearts': '\u2665'
	'diams':  '\u2666'
}

// legacy_names is the set HTML5 allows to appear without a trailing semicolon.
const legacy_names = {
	'amp'
	'AMP'
	'lt'
	'LT'
	'gt'
	'GT'
	'quot'
	'QUOT'
	'nbsp'
	'copy'
	'reg'
	'cent'
	'pound'
	'yen'
	'curren'
	'iexcl'
	'iquest'
	'brvbar'
	'uml'
	'sect'
	'para'
	'middot'
	'laquo'
	'raquo'
	'times'
	'divide'
	'deg'
	'plusmn'
	'frac12'
	'frac14'
	'frac34'
	'micro'
	'not'
	'shy'
	'macr'
	'sup1'
	'sup2'
	'sup3'
	'acute'
	'cedil'
	'ordf'
	'ordm'
}