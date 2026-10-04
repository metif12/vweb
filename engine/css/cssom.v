module css

import strings

// The CSS object model: what a stylesheet means, once it has been read.
//
// Everything here holds source text, not interpreted values. `color: red` is a
// Declaration whose value is the string `red`; deciding that `red` is a colour
// and turning it into premultiplied bytes belongs to engine/style. That line is
// what lets a stylesheet using a property this engine has never heard of parse
// and cascade, which on the real web is most of them.
//
// A selector stays text too. engine/selector owns that grammar, and keeping it
// out of here is what stops the two from drifting into disagreeing about what a
// comma means.

pub struct Stylesheet {
pub:
	rules []Rule
}

// Rule is one entry in a stylesheet. It is a sum type rather than one struct with
// a kind field because an at-rule has no selector: a struct would make every
// reader check which half of it was meaningful, and the compiler would not check
// that for them.
type Rule = QualifiedRule | AtDeclarationRule | NestedRule

// QualifiedRule is `prelude { declarations }` -- a selector and the declarations
// that apply to whatever it matches.
pub struct QualifiedRule {
pub:
	prelude string
	declarations []Declaration
}

// AtDeclarationRule is an at-rule whose block is a declaration list, such as
// @font-face. One with no block at all -- @import, @charset -- is also this
// shape, with no declarations.
pub struct AtDeclarationRule {
pub:
	name string
	prelude string
	declarations []Declaration
}

// NestedRule is an at-rule whose block is a rule list, such as @media.
pub struct NestedRule {
pub:
	name string
	prelude string
	rules []Rule
}

// Declaration is one `name: value` pair. `value` is normalized text: comments
// removed and runs of whitespace collapsed, so a cascade can compare it and a
// test can assert on it.
pub struct Declaration {
pub:
	name string
	value string
	important bool
}

// serialize renders a token run back to CSS text, with runs of whitespace
// collapsed to a single space and the ends trimmed. It is the normalizer the
// parser uses for preludes and values, and it round-trips: feeding its output
// back through the tokenizer yields the same tokens.
pub fn serialize(toks []Token) string {
	mut b := strings.new_builder(64)
	mut space := false
	for t in toks {
		if t.kind == .eof {
			continue
		}
		if t.kind == .whitespace {
			space = true
			continue
		}
		if space && b.len > 0 {
			b.write_byte(` `)
		}
		space = false
		s := token_text(t)
		if s != '' {
			b.write_string(s)
		}
	}
	return b.str()
}

// token_text renders one token as source text.
pub fn token_text(t Token) string {
	return match t.kind {
		.ident, .at_keyword { escape_ident(t.value) }
		.function { escape_ident(t.value) + '(' }
		.hash { '#' + escape_ident(t.value) }
		.string { quote_string(t.value) }
		.url { 'url(' + t.value + ')' }
		.number { t.value }
		.percentage { t.value + '%' }
		.dimension { t.value + escape_ident(t.unit) }
		.delim { t.value }
		.lparen { '(' }
		.rparen { ')' }
		.lbracket { '[' }
		.rbracket { ']' }
		.lbrace { '{' }
		.rbrace { '}' }
		.comma { ',' }
		.colon { ':' }
		.semicolon { ';' }
		.cdo { '<!--' }
		.cdc { '-->' }
		else { '' }
	}
}

// escape_ident writes an ident's value back as source. An ident value can hold
// characters that are not name characters when they arrived through an escape --
// `a\ b` is the ident `a b` -- so writing the value bare would silently change
// its meaning the second time round.
fn escape_ident(s string) string {
	raw := s.bytes()
	mut b := strings.new_builder(s.len)
	mut i := 0
	for i < raw.len {
		_, n := decode_at(raw, i)
		if ident_at(raw, i) {
			for k in 0 .. n {
				b.write_byte(raw[i + k])
			}
		} else {
			b.write_byte(bs)
			for k in 0 .. n {
				b.write_byte(raw[i + k])
			}
		}
		i += n
	}
	return b.str()
}

// quote_string re-quotes a string's contents. Only `"` and `\` need escaping; a
// literal newline cannot appear because the tokenizer ends a string at one, and
// what is left of a `\` followed by a newline is the backslash's own removal.
fn quote_string(s string) string {
	mut b := strings.new_builder(s.len + 2)
	b.write_byte(`"`)
	for c in s {
		if c == `"` || c == bs {
			b.write_byte(bs)
		}
		b.write_byte(c)
	}
	b.write_byte(`"`)
	return b.str()
}