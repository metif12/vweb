module css

import strconv
import strings

// A tokenizer for CSS, following CSS Syntax Level 3.
//
// Bytes in, tokens out. Nothing here knows what a token *means*: `red` and `12px`
// are both just tokens, and deciding that one is a colour and the other a length
// belongs to engine/style. Keeping that line here means a stylesheet using a
// property this engine has never heard of still parses, which is the normal case
// on the real web.
//
// The tokenizer is total. Malformed input yields bad_string and bad_url tokens
// rather than an error, because CSS requires a bad declaration to be dropped
// while the rest of the stylesheet survives, and that is only possible if lexing
// a broken rule cannot fail.
//
// Code points, not bytes. CSS decides whether a character is a name character by
// looking at ranges of code points, and those ranges are not "everything
// non-ASCII": they exclude NBSP, the zero-width characters, and the bidi control
// codes. An RTL page is full of those, so a byte-level approximation would quietly
// swallow an RLM into the identifier next to it. Classification therefore decodes
// UTF-8 first, and only the ASCII fast path stays byte-wise.
//
// Not implemented: <unicode-range-token>, which exists only for @font-face's
// `unicode-range` descriptor and is Phase 3 work.

pub enum TokenKind {
	ident
	function
	at_keyword
	hash
	string
	bad_string
	url
	bad_url
	delim
	number
	percentage
	dimension
	whitespace
	cdo
	cdc
	colon
	semicolon
	comma
	lbracket
	rbracket
	lparen
	rparen
	lbrace
	rbrace
	eof
}

// Token is one CSS token.
//
// `value` is the token's semantic text with escapes already resolved: an ident's
// value, a string's contents, the URL inside url(), the single character of a
// delim, or the literal source text of a numeric token. Resolving escapes is the
// point -- `\75 rl` and `url` are the same ident, and a cascade comparing them as
// written would miss the match.
//
// A numeric token keeps its source text in `value` and its value in `num`, rather
// than being reformatted from the number. `1e3` therefore stays `1e3`, which keeps
// a stylesheet round-trippable and lets a test assert on what was written.
//
// `is_int` marks a number, percentage or dimension whose written form has neither
// a fraction nor an exponent, which is the spec's "integer" type flag. `is_id`
// marks a hash token whose value is a valid ident sequence, which is the spec's
// "id" flag and is what separates `#foo` the id selector from `#foo` the colour.
// Each flag is meaningful for exactly one kind and is false elsewhere.
pub struct Token {
pub:
	kind   TokenKind
	value  string
	num    f64
	unit   string
	is_int bool
	is_id  bool
}

pub fn tokenize(src string) []Token {
	mut lx := Lexer{ src: preprocess(src) }
	mut out := []Token{}
	for {
		t := lx.next()
		out << t
		if t.kind == .eof {
			return out
		}
	}
}

// Control bytes have no printable literal, so they are named. `nul` doubles as the
// end-of-input marker: see `Lexer.peek`.
const tab = u8(0x09)
const nl = u8(0x0a)
const nul = u8(0x00)
const bs = u8(0x5c)

struct Lexer {
mut:
	src []u8
	pos int
}

// preprocess applies the input-stream filters of CSS Syntax 3.3: CR, CRLF and FF
// all become LF, and NULL or a surrogate becomes U+FFFD. The first means the rest
// of the lexer only ever has to know one line terminator. The second is the only
// filter that can grow the input -- U+FFFD is three bytes and a NULL is one -- so
// the buffer is sized from a counted pass rather than from the input length.
fn preprocess(src string) []u8 {
	raw := src.bytes()
	mut extra := 0
	mut i := 0
	for i < raw.len {
		cp, n := decode_at(raw, i)
		if cp == 0 {
			extra += 2
		}
		i += n
	}
	mut out := []u8{len: raw.len + extra}
	mut o := 0
	i = 0
	for i < raw.len {
		cp, n := decode_at(raw, i)
		if cp == 0x0d {
			// CR, and CRLF, each become exactly one LF.
			out[o] = nl
			o++
			i += n
			if n == 1 && i < raw.len && raw[i] == nl {
				i++
			}
			continue
		}
		if cp == 0x0c {
			// FF becomes LF like CR does. It is a line terminator, not an error,
			// so it must not take the U+FFFD branch below.
			out[o] = nl
			o++
			i += n
			continue
		}
		if cp == 0x00 || is_surrogate(cp) {
			out[o] = 0xef
			out[o + 1] = 0xbf
			out[o + 2] = 0xbd
			o += 3
			i += n
			continue
		}
		for k in 0 .. n {
			out[o + k] = raw[i + k]
		}
		o += n
		i += n
	}
	return out[..o]
}

// peek returns the byte at pos + offset, or nul at end of input. Treating end of
// input as nul is safe because preprocess has replaced every real nul, so the two
// are indistinguishable -- which is what makes the lookahead rules below readable.
fn (lx &Lexer) peek(offset int) u8 {
	i := lx.pos + offset
	if i >= lx.src.len {
		return nul
	}
	return lx.src[i]
}

// text returns the source bytes consumed since start. The returned string shares
// memory with src rather than copying, which is safe because src outlives every
// token produced from it.
fn (lx &Lexer) text(start int) string {
	return unsafe { lx.src[start..lx.pos].bytestr() }
}

fn (lx &Lexer) starts_with(offset int, s string) bool {
	if lx.pos + offset + s.len > lx.src.len {
		return false
	}
	for k, ch in s {
		if lx.src[lx.pos + offset + k] != ch {
			return false
		}
	}
	return true
}

// is_valid_escape reports whether a backslash at the offset starts an escape. A
// backslash before a newline is not one; the spec recovers it as a delim.
fn (lx &Lexer) is_valid_escape(offset int) bool {
	if lx.peek(offset) != bs {
		return false
	}
	n := lx.peek(offset + 1)
	return n != nl && n != nul
}

// starts_ident_at reports whether an ident sequence begins at the offset. The
// three-code-point lookahead is what keeps `-` from becoming a delim when it is
// really the start of `-webkit-thing`, and what makes `--custom-property` an
// ident.
fn (lx &Lexer) starts_ident_at(offset int) bool {
	i := lx.pos + offset
	if name_start_at(lx.src, i) || lx.is_valid_escape(offset) {
		return true
	}
	if lx.peek(offset) != `-` {
		return false
	}
	if name_start_at(lx.src, i + 1) || lx.peek(offset + 1) == `-` {
		return true
	}
	return lx.is_valid_escape(offset + 1)
}

// starts_number_at reports whether a number begins at the offset. A `.` only
// starts one when a digit follows, because `.5em` is a dimension but `.foo` is
// two tokens.
fn (lx &Lexer) starts_number_at(offset int) bool {
	a := lx.peek(offset)
	if a == `+` || a == `-` {
		if is_digit(lx.peek(offset + 1)) {
			return true
		}
		return lx.peek(offset + 1) == `.` && is_digit(lx.peek(offset + 2))
	}
	if is_digit(a) {
		return true
	}
	return a == `.` && is_digit(lx.peek(offset + 1))
}

// next consumes one token, following CSS Syntax 4.3.1. Comments are consumed
// before the dispatch, which is why there is no case for `/`: the character is
// always a delim by the time the dispatch sees it.
fn (mut lx Lexer) next() Token {
	lx.skip_comments()
	c := lx.peek(0)
	match c {
		nul {
			return Token{ kind: .eof }
		}
		` `, tab, nl {
			for is_ws(lx.peek(0)) {
				lx.pos++
			}
			return Token{ kind: .whitespace }
		}
		`"` {
			return lx.consume_string(`"`)
		}
		`'` {
			return lx.consume_string(`'`)
		}
		`#` {
			if !ident_at(lx.src, lx.pos + 1) && !lx.is_valid_escape(1) {
				lx.pos++
				return Token{ kind: .delim, value: punct_str(c) }
			}
			is_id := lx.starts_ident_at(1)
			lx.pos++
			return Token{ kind: .hash, value: lx.consume_ident_sequence(), is_id: is_id }
		}
		`(`, `)`, `[`, `]`, `{`, `}`, `,`, `:`, `;` {
			lx.pos++
			return Token{ kind: punctuation_kind(c) }
		}
		`+`, `.` {
			if lx.starts_number_at(0) {
				return lx.consume_numeric()
			}
			lx.pos++
			return Token{ kind: .delim, value: punct_str(c) }
		}
		`-` {
			// The order matters: the CDC check comes before the ident check, which
			// is the only reason `-->` is a token at all rather than the ident `--`
			// followed by a delim.
			if lx.starts_number_at(0) {
				return lx.consume_numeric()
			}
			if lx.peek(1) == `-` && lx.peek(2) == `>` {
				lx.pos += 3
				return Token{ kind: .cdc }
			}
			if lx.starts_ident_at(0) {
				return lx.consume_ident_like()
			}
			lx.pos++
			return Token{ kind: .delim, value: punct_str(c) }
		}
		`<` {
			if lx.starts_with(1, '!--') {
				lx.pos += 4
				return Token{ kind: .cdo }
			}
			lx.pos++
			return Token{ kind: .delim, value: punct_str(c) }
		}
		`@` {
			if lx.starts_ident_at(1) {
				lx.pos++
				return Token{ kind: .at_keyword, value: lx.consume_ident_sequence() }
			}
			lx.pos++
			return Token{ kind: .delim, value: punct_str(c) }
		}
		bs {
			if lx.is_valid_escape(0) {
				return lx.consume_ident_like()
			}
			lx.pos++
			return Token{ kind: .delim, value: punct_str(c) }
		}
		else {
			if is_digit(c) {
				return lx.consume_numeric()
			}
			if lx.starts_ident_at(0) {
				return lx.consume_ident_like()
			}
			// A delim can be a whole non-ASCII code point -- NBSP and the
			// zero-width characters are all delims -- so it is sliced by code
			// point rather than built one byte at a time.
			_, n := decode_at(lx.src, lx.pos)
			start := lx.pos
			lx.pos += n
			return Token{ kind: .delim, value: lx.text(start) }
		}
	}
}

// punctuation_kind maps the single-character tokens that carry no text of their
// own. Anything not listed is a delim, which is why this is total.
fn punctuation_kind(c u8) TokenKind {
	return match c {
		`(` { .lparen }
		`)` { .rparen }
		`[` { .lbracket }
		`]` { .rbracket }
		`{` { .lbrace }
		`}` { .rbrace }
		`,` { .comma }
		`:` { .colon }
		`;` { .semicolon }
		else { .delim }
	}
}

// punct_str renders one ASCII byte as CSS text for a delim token. Only the arms
// with a single-byte delimiter use it; a delim that is a whole non-ASCII code
// point is sliced out of the source instead.
fn punct_str(c u8) string {
	mut b := strings.new_builder(1)
	b.write_byte(c)
	return b.str()
}

// skip_comments consumes every comment at the cursor. An unterminated one runs to
// end of input, which the spec also treats as a comment.
fn (mut lx Lexer) skip_comments() {
	for lx.peek(0) == `/` && lx.peek(1) == `*` {
		lx.pos += 2
		for lx.peek(0) != nul {
			if lx.peek(0) == `*` && lx.peek(1) == `/` {
				lx.pos += 2
				break
			}
			lx.pos++
		}
	}
}

// consume_ident_sequence reads an ident sequence with escapes resolved. The
// result is the ident's value rather than its source text, so an escaped spelling
// and a plain one compare equal.
fn (mut lx Lexer) consume_ident_sequence() string {
	mut b := strings.new_builder(16)
	for {
		i := lx.pos
		if i >= lx.src.len {
			return b.str()
		}
		if ident_at(lx.src, i) {
			_, n := decode_at(lx.src, i)
			for k in 0 .. n {
				b.write_byte(lx.src[i + k])
			}
			lx.pos += n
			continue
		}
		if lx.is_valid_escape(0) {
			b.write_rune(rune(lx.consume_escaped()))
			continue
		}
		return b.str()
	}
}

// consume_ident_like reads an ident, a function or a url, following CSS Syntax
// 4.3.4. The `(` is only consumed once the ident is already known, which is why
// `(` itself never produces a function token on its own.
fn (mut lx Lexer) consume_ident_like() Token {
	name := lx.consume_ident_sequence()
	if lx.peek(0) != `(` {
		return Token{ kind: .ident, value: name }
	}
	lx.pos++
	if name.to_lower() != 'url' {
		return Token{ kind: .function, value: name }
	}
	// Whitespace is consumed in pairs here, so an odd trailing space survives into
	// the check below and makes this look like a quoted url. The spec says so, and
	// consume_url skips the whitespace either way, so the difference is not
	// observable.
	for is_ws(lx.peek(0)) && is_ws(lx.peek(1)) {
		lx.pos++
	}
	first := lx.peek(0)
	if first == `"` || first == `'` || (is_ws(first) && (lx.peek(1) == `"` || lx.peek(1) == `'`)) {
		return Token{ kind: .function, value: name }
	}
	return lx.consume_url()
}

// consume_escaped returns the code point after a backslash, which the caller has
// already established is a valid escape. A hex escape takes up to six digits and
// then swallows one whitespace character, which is why `\75 rl` is `url` and not
// `u` followed by `rl`.
fn (mut lx Lexer) consume_escaped() u32 {
	lx.pos++
	c := lx.peek(0)
	if is_hex_digit(c) {
		mut cp := u32(0)
		mut n := 0
		for n < 6 && is_hex_digit(lx.peek(0)) {
			cp = cp * 16 + u32(hex_value(lx.peek(0)))
			lx.pos++
			n++
		}
		if is_ws(lx.peek(0)) {
			lx.pos++
		}
		// Zero, a surrogate, and out-of-range are all parse errors that the spec
		// resolves to U+FFFD. A surrogate is reachable here: `\D800` is a
		// well-formed escape that does not name a character.
		if cp == 0 || cp > 0x10ffff || is_surrogate(cp) {
			return 0xfffd
		}
		return cp
	}
	if c == nul {
		return 0xfffd
	}
	lx.pos++
	return u32(c)
}

// consume_string reads a quoted string. An unescaped newline or end of input ends
// it; the first makes it a bad_string, which the parser drops, and the second is
// merely an unterminated string at end of file. Either way the newline is left for
// the next token rather than consumed.
fn (mut lx Lexer) consume_string(quote u8) Token {
	lx.pos++
	mut b := strings.new_builder(16)
	for {
		c := lx.peek(0)
		if c == quote {
			lx.pos++
			return Token{ kind: .string, value: b.str() }
		}
		if c == nul {
			return Token{ kind: .string, value: b.str() }
		}
		if c == nl {
			return Token{ kind: .bad_string, value: b.str() }
		}
		if c == bs {
			if lx.peek(1) == nul {
				lx.pos++
				continue
			}
			if lx.peek(1) == nl {
				lx.pos += 2
				continue
			}
			b.write_rune(rune(lx.consume_escaped()))
			continue
		}
		b.write_byte(c)
		lx.pos++
	}
}

// consume_url reads the unquoted body of a url(). The `url(` has already been
// consumed. A quoted body is a function token plus a string and never reaches here.
fn (mut lx Lexer) consume_url() Token {
	mut b := strings.new_builder(32)
	for {
		c := lx.peek(0)
		if c == `)` {
			lx.pos++
			return Token{ kind: .url, value: b.str() }
		}
		if c == nul {
			return Token{ kind: .url, value: b.str() }
		}
		if is_ws(c) {
			b.write_byte(c)
			lx.pos++
			continue
		}
		if c == `"` || c == `'` || c == `(` || is_non_printable(c) {
			lx.consume_bad_url_remnant()
			return Token{ kind: .bad_url }
		}
		if c == bs {
			if lx.is_valid_escape(0) {
				b.write_rune(rune(lx.consume_escaped()))
				continue
			}
			lx.consume_bad_url_remnant()
			return Token{ kind: .bad_url }
		}
		b.write_byte(c)
		lx.pos++
	}
}

// consume_bad_url_remnant drops everything up to and including the closing paren,
// so the lexer resumes on the token after the broken url.
fn (mut lx Lexer) consume_bad_url_remnant() {
	for {
		c := lx.peek(0)
		if c == nul {
			return
		}
		lx.pos++
		if c == `)` {
			return
		}
	}
}

// consume_numeric reads a number and whatever unit follows it, producing a
// number, percentage or dimension token.
fn (mut lx Lexer) consume_numeric() Token {
	start := lx.pos
	mut is_int := true
	c := lx.peek(0)
	if c == `+` || c == `-` {
		lx.pos++
	}
	for is_digit(lx.peek(0)) {
		lx.pos++
	}
	if lx.peek(0) == `.` && is_digit(lx.peek(1)) {
		is_int = false
		lx.pos += 2
		for is_digit(lx.peek(0)) {
			lx.pos++
		}
	}
	e := lx.peek(0)
	if e == `e` || e == `E` {
		sign := lx.peek(1)
		if is_digit(sign) {
			is_int = false
			lx.pos += 2
		} else if (sign == `+` || sign == `-`) && is_digit(lx.peek(2)) {
			is_int = false
			lx.pos += 3
		}
		for is_digit(lx.peek(0)) {
			lx.pos++
		}
	}
	numtext := lx.text(start)
	number := strconv.atof64(numtext) or { 0.0 }
	if lx.peek(0) == `%` {
		lx.pos++
		return Token{ kind: .percentage, value: numtext, num: number, is_int: is_int }
	}
	if lx.starts_ident_at(0) {
		return Token{ kind: .dimension, value: numtext, num: number, unit: lx.consume_ident_sequence(), is_int: is_int }
	}
	return Token{ kind: .number, value: numtext, num: number, is_int: is_int }
}

// decode_at decodes the UTF-8 code point at i and returns it with the number of
// bytes it occupies. Malformed input decodes to U+FFFD one byte at a time, so the
// caller always makes progress and never reads past the end.
fn decode_at(b []u8, i int) (u32, int) {
	if i >= b.len {
		return 0, 0
	}
	lead := b[i]
	if lead < 0x80 {
		return u32(lead), 1
	}
	mut n := 0
	mut cp := u32(0)
	if lead >= 0xc2 && lead <= 0xdf {
		n, cp = 1, u32(lead & 0x1f)
	} else if lead >= 0xe0 && lead <= 0xef {
		n, cp = 2, u32(lead & 0x0f)
	} else if lead >= 0xf0 && lead <= 0xf4 {
		n, cp = 3, u32(lead & 0x07)
	} else {
		return 0xfffd, 1
	}
	if i + n >= b.len {
		return 0xfffd, 1
	}
	for k in 1 .. n + 1 {
		cont := b[i + k]
		if cont < 0x80 || cont > 0xbf {
			return 0xfffd, 1
		}
		cp = (cp << 6) | u32(cont & 0x3f)
	}
	return cp, n + 1
}

// name_start_at reports whether a name-start code point begins at i. CSS's
// non-ASCII set is a list of ranges, not everything above U+007F: it leaves out
// NBSP, the zero-width characters and the bidi controls, so treating every byte
// >= 0x80 as a name character would swallow an RLM into the identifier beside it.
fn name_start_at(b []u8, i int) bool {
	if i >= b.len {
		return false
	}
	c := b[i]
	if c < 0x80 {
		return is_name_start_byte(c)
	}
	cp, _ := decode_at(b, i)
	return is_non_ascii_ident(cp)
}

// ident_at reports whether an ident code point begins at i: a name-start, a
// digit, or a hyphen. Digits and the hyphen are ASCII, so the byte test is exact
// for those and only the non-ASCII case needs decoding.
fn ident_at(b []u8, i int) bool {
	if i >= b.len {
		return false
	}
	c := b[i]
	if c < 0x80 {
		return is_name_start_byte(c) || is_digit(c) || c == `-`
	}
	cp, _ := decode_at(b, i)
	return is_non_ascii_ident(cp)
}

fn is_name_start_byte(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
}

fn is_non_ascii_ident(cp u32) bool {
	return cp == 0xb7 || (cp >= 0xc0 && cp <= 0xd6) || (cp >= 0xd8 && cp <= 0xf6)
		|| (cp >= 0xf8 && cp <= 0x37d) || (cp >= 0x37f && cp <= 0x1fff) || cp == 0x200c
		|| cp == 0x200d || cp == 0x203f || cp == 0x2040 || (cp >= 0x2070 && cp <= 0x218f)
		|| (cp >= 0x2c00 && cp <= 0x2fef) || (cp >= 0x3001 && cp <= 0xd7ff)
		|| (cp >= 0xf900 && cp <= 0xfdcf) || (cp >= 0xfdf0 && cp <= 0xfffd) || cp >= 0x10000
}

fn is_surrogate(cp u32) bool {
	return cp >= 0xd800 && cp <= 0xdfff
}

fn is_digit(c u8) bool {
	return c >= `0` && c <= `9`
}

fn is_hex_digit(c u8) bool {
	return is_digit(c) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)
}

// is_ws covers the three whitespace code points CSS defines, which after
// preprocessing is all of them: U+00A0 and U+2000..U+200A are not whitespace here.
fn is_ws(c u8) bool {
	return c == ` ` || c == tab || c == nl
}

fn is_non_printable(c u8) bool {
	return c <= 0x08 || c == 0x0b || (c >= 0x0e && c <= 0x1f) || c == 0x7f
}

fn hex_value(c u8) int {
	if c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` {
		return int(c - `a`) + 10
	}
	return int(c - `A`) + 10
}
