module css

// A parser for CSS, following CSS Syntax 5.
//
// Recovery is the whole design. CSS requires a malformed declaration to be
// dropped while the rules around it survive, so every rule reader appends to a
// list instead of returning an error, and a bad rule is skipped by advancing to
// the next `;` or `}` rather than aborting the stylesheet. A parser that stopped
// at the first typo would drop every rule after it, and on the real web the first
// typo is usually in the middle of the file.
//
// Nothing here interprets a property. A declaration is a name and normalized
// text, and which of the ~150 properties in the wild are understood is
// engine/style's problem.

pub fn parse(src string) Stylesheet {
	mut p := Parser{ toks: tokenize(src) }
	return Stylesheet{ rules: p.parse_rule_list() }
}

// Parser walks the token stream. `i` never moves past the final eof token, so
// `peek` needs no bounds check: tokenize always emits exactly one eof, last.
struct Parser {
mut:
	toks []Token
	i    int
}

fn (p &Parser) peek() Token {
	return p.toks[p.i]
}

fn (p &Parser) at(k TokenKind) bool {
	return p.toks[p.i].kind == k
}

fn (mut p Parser) skip_one() {
	if p.i + 1 < p.toks.len {
		p.i++
	}
}

fn (mut p Parser) skip_whitespace() {
	for p.at(.whitespace) {
		p.skip_one()
	}
}

// parse_rule_list reads rules until the input ends or the enclosing `}` is
// reached, which it leaves in place. It serves both the top level of a
// stylesheet and the body of a nested at-rule, because that is the same grammar.
fn (mut p Parser) parse_rule_list() []Rule {
	mut out := []Rule{}
	for {
		p.skip_whitespace()
		if p.at(.eof) || p.at(.rbrace) {
			return out
		}
		// `<!--` and `-->` are legal at the top level of a legacy stylesheet and
		// mean nothing here, so they are skipped rather than read as rules.
		if p.at(.cdo) || p.at(.cdc) {
			p.skip_one()
			continue
		}
		if p.at(.at_keyword) {
			p.parse_at_rule(mut out)
			continue
		}
		p.parse_qualified_rule(mut out)
	}
}

// parse_qualified_rule appends `prelude { declarations }` to out, and appends
// nothing if the rule is malformed. A rule with no block is dropped rather than
// kept: it would put an unparsed prelude with no declarations into the cascade.
//
// Every path out of here leaves the cursor at or past the first token of the
// attempt. Rewinding instead would let a caller that reads rules until the input
// ends spin on the same token forever, which is exactly what `@` alone does.
fn (mut p Parser) parse_qualified_rule(mut out []Rule) {
	start := p.i
	mut block := -1
	mut depth := 0
	for {
		t := p.peek()
		if t.kind == .eof {
			p.i = start + 1
			return
		}
		if t.kind == .lparen || t.kind == .lbracket || t.kind == .function {
			depth++
		} else if t.kind == .rparen || t.kind == .rbracket {
			if depth > 0 {
				depth--
			}
		} else if t.kind == .lbrace {
			// The block only ends the prelude at nesting depth zero, so a brace
			// inside a function does not start the declaration block early.
			if depth == 0 {
				block = p.i
				break
			}
			depth++
		} else if t.kind == .rbrace && depth == 0 {
			p.i = start + 1
			return
		}
		p.skip_one()
	}
	prelude := serialize(p.toks[start..block])
	p.skip_one() // the `{`
	out << QualifiedRule{ prelude: prelude, declarations: p.parse_declaration_block() }
}

// parse_at_rule appends `@name prelude;` or `@name prelude { ... }` to out.
//
// Whether the block holds declarations or nested rules is not decidable from CSS
// itself -- the grammar is identical for both -- so it comes from the at-rule's
// name. The spec describes guessing and rewinding; that is strictly more code for
// a strictly worse answer.
fn (mut p Parser) parse_at_rule(mut out []Rule) {
	p.skip_one() // the at-keyword
	name := p.toks[p.i - 1].value.to_lower()
	start := p.i
	mut block := -1
	mut depth := 0
	for {
		t := p.peek()
		if t.kind == .eof {
			break
		}
		if depth == 0 && (t.kind == .lbrace || t.kind == .semicolon) {
			block = p.i
			break
		}
		if t.kind == .lparen || t.kind == .lbracket || t.kind == .function {
			depth++
		} else if t.kind == .rparen || t.kind == .rbracket {
			if depth > 0 {
				depth--
			}
		}
		p.skip_one()
	}
	if block < 0 {
		// Neither a block nor a semicolon before the input ended. Drop the rule
		// and stop consuming, so a truncated stylesheet does not turn into one
		// enormous at-rule with no block.
		p.i = p.toks.len - 1
		return
	}
	prelude := serialize(p.toks[start..block])
	if p.at(.semicolon) {
		p.skip_one()
		out << AtDeclarationRule{ name: name, prelude: prelude }
		return
	}
	p.skip_one() // the `{`
	if at_rule_holds_declarations(name) {
		out << AtDeclarationRule{
			name:         name
			prelude:      prelude
			declarations: p.parse_declaration_block()
		}
		return
	}
	nested := p.parse_rule_list()
	if p.at(.rbrace) {
		p.skip_one()
	}
	out << NestedRule{ name: name, prelude: prelude, rules: nested }
}

// at_rule_holds_declarations names the at-rules whose block is a declaration list.
// Every other at-rule holds nested rules, which is the only other shape CSS has.
fn at_rule_holds_declarations(name string) bool {
	return match name {
		'font-face', 'page', 'viewport', 'counter-style', 'property', 'font-palette-values' {
			true
		}
		else { false }
	}
}

// parse_declaration_block reads declarations until the closing brace, dropping
// any that are malformed. The brace is consumed if it is there; running out of
// input instead just ends the block, because the commonest cause of that is a
// truncated file and losing its declarations helps nobody.
fn (mut p Parser) parse_declaration_block() []Declaration {
	mut out := []Declaration{}
	for {
		p.skip_whitespace()
		if p.at(.rbrace) {
			p.skip_one()
			return out
		}
		if p.at(.eof) {
			return out
		}
		if d := p.parse_declaration() {
			out << d
			continue
		}
		p.skip_bad_declaration()
	}
}

// parse_declaration reads `name: value` and the `!important` suffix.
fn (mut p Parser) parse_declaration() ?Declaration {
	if !p.at(.ident) {
		return none
	}
	name := p.peek().value
	p.skip_one()
	p.skip_whitespace()
	if !p.at(.colon) {
		return none
	}
	p.skip_one()
	toks := p.consume_value()
	// Trailing whitespace is not part of the value, and leaving it in place
	// would hide the `!` from the check below.
	mut end := toks.len
	for end > 0 && toks[end - 1].kind == .whitespace {
		end--
	}
	mut important := false
	// The tokenizer has no case for `!` at all, so `!important` arrives as a
	// delim followed by an ident with optional whitespace between them.
	if end >= 2 && toks[end - 1].kind == .ident && toks[end - 1].value.to_lower() == 'important' {
		mut bang := end - 2
		for bang >= 0 && toks[bang].kind == .whitespace {
			bang--
		}
		if bang >= 0 && toks[bang].kind == .delim && toks[bang].value == '!' {
			important = true
			end = bang
		}
	}
	return Declaration{ name: name, value: serialize(toks[..end]), important: important }
}

// consume_value collects a declaration's value, respecting nesting so that a `;`
// inside url() or a function does not end it. It stops before a top-level `;` or
// `}` and consumes neither.
fn (mut p Parser) consume_value() []Token {
	start := p.i
	mut depth := 0
	for {
		t := p.peek()
		if t.kind == .eof {
			return p.toks[start..p.i]
		}
		if depth == 0 && (t.kind == .semicolon || t.kind == .rbrace) {
			return p.toks[start..p.i]
		}
		if t.kind == .lparen || t.kind == .lbracket || t.kind == .lbrace || t.kind == .function {
			depth++
		} else if t.kind == .rparen || t.kind == .rbracket {
			if depth > 0 {
				depth--
			}
		} else if t.kind == .rbrace && depth > 0 {
			depth--
		}
		p.skip_one()
	}
}

// skip_bad_declaration advances past one malformed declaration, so a typo in a
// single declaration does not take the rest of the block with it.
fn (mut p Parser) skip_bad_declaration() {
	for {
		t := p.peek()
		if t.kind == .eof || t.kind == .rbrace {
			return
		}
		p.skip_one()
		if t.kind == .semicolon {
			return
		}
	}
}

// parse_declarations parses a bare declaration list: what is inside a rule block, or the
// whole of a `style` attribute.
//
// It is a separate entry point rather than a flag on parse because the two have nothing
// else in common -- one expects rules and the other must not be given them -- and a
// `style="p { color: red }"` attribute is exactly as wrong as it looks.
pub fn parse_declarations(src string) []Declaration {
	mut p := Parser{ toks: tokenize(src) }
	return p.parse_declaration_block()
}
