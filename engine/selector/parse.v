module selector

import engine.css
import strconv

// A parser for the selector grammar, following Selectors Level 3.
//
// It reuses the CSS tokenizer rather than writing a second one. A selector's
// characters are a subset of CSS's and `#main > p` tokenizes to the same tokens
// either way, so a second tokenizer would be a second set of answers about
// escapes and case for no gain.
//
// An invalid selector makes the whole list invalid, which is what Selectors 3
// says and what a browser does: one bad selector in `a, b[` drops both rules.
// Returning an Option rather than a partially-filled list is what keeps that rule
// from being forgotten at the call site.

pub fn parse(text string) ?SelectorList {
	mut p := Parser{ toks: css.tokenize(text) }
	return p.parse_selector_list()
}

struct Parser {
mut:
	toks []css.Token
	i int
}

fn (p &Parser) peek() css.Token {
	return p.toks[p.i]
}

fn (p &Parser) at(k css.TokenKind) bool {
	return p.toks[p.i].kind == k
}

fn (mut p Parser) skip_one() {
	if p.i + 1 < p.toks.len {
		p.i++
	}
}

fn (mut p Parser) skip_ws() {
	for p.at(.whitespace) {
		p.skip_one()
	}
}

// parse_selector_list reads comma-separated complex selectors. It stops at a
// closing paren as well as at end of input, because it is also the body of
// `:not(...)`.
fn (mut p Parser) parse_selector_list() ?SelectorList {
	mut out := SelectorList{}
	for {
		p.skip_ws()
		if p.at(.eof) || p.at(.comma) || p.at(.rparen) {
			if out.len == 0 {
				return none
			}
			return out
		}
		s := p.parse_complex() or { return none }
		out << s
		p.skip_ws()
		if p.at(.comma) {
			p.skip_one()
			continue
		}
		if p.at(.eof) || p.at(.rparen) {
			if out.len == 0 {
				return none
			}
			return out
		}
		// Anything left over is trailing junk, which invalidates the list.
		return none
	}
}

// parse_complex reads `a b > c`. The subject is the last compound, so the matcher
// can walk the tree backwards from the element being tested.
fn (mut p Parser) parse_complex() ?ComplexSelector {
	mut parts := []CompoundSelector{}
	mut combinators := []Combinator{}
	mut pending := Combinator.descendant
	mut after_combinator := false
	for {
		mut gap := false
		for p.at(.whitespace) {
			p.skip_one()
			gap = true
		}
		if p.at(.eof) || p.at(.comma) || p.at(.rparen) {
			// A combinator with nothing after it is incomplete.
			if after_combinator {
				return none
			}
			break
		}
		t := p.peek()
		if t.kind == .delim && (t.value == '>' || t.value == '+' || t.value == '~') {
			if parts.len == 0 {
				return none
			}
			pending = combinator_of(t.value)
			after_combinator = true
			p.skip_one()
			continue
		}
		if !after_combinator && parts.len > 0 && !gap {
			// Two compounds with nothing between them: `ab` is one ident, so this
			// is only reachable through input like `a.b` written as `a .b` gone
			// wrong, and it is invalid.
			return none
		}
		after_combinator = false
		compound := p.parse_compound() or { return none }
		parts << compound
		combinators << pending
		pending = .descendant
	}
	if parts.len == 0 {
		return none
	}
	return ComplexSelector{ parts: parts, combinators: combinators }
}

fn combinator_of(s string) Combinator {
	return match s {
		'>' { .child }
		'+' { .adjacent_sibling }
		'~' { .general_sibling }
		else { .descendant }
	}
}

// parse_compound reads a run of simple selectors with no combinator between them.
// A type selector may only come first; `a b` is two compounds, not one.
fn (mut p Parser) parse_compound() ?CompoundSelector {
	mut tag := ''
	mut id := ''
	mut classes := []string{}
	mut attrs := []AttrSelector{}
	mut pseudos := []PseudoClass{}
	mut pseudo_element := ''
	mut universal := false
	mut simple_count := 0
	mut type_used := false
	for {
		t := p.peek()
		if t.kind == .ident && !type_used {
			tag = t.value
			type_used = true
			p.skip_one()
			simple_count++
			continue
		}
		if t.kind == .hash {
			// A hash token whose value is not a valid ident is `#123`, which is a
			// colour and not an id selector.
			if !t.is_id || id != '' {
				return none
			}
			id = t.value
			p.skip_one()
			simple_count++
			continue
		}
		if t.kind == .delim && t.value == '.' {
			p.skip_one()
			name := p.expect_ident() or { return none }
			classes << name
			simple_count++
			continue
		}
		if t.kind == .delim && t.value == '*' && simple_count == 0 {
			universal = true
			p.skip_one()
			simple_count++
			continue
		}
		if t.kind == .lbracket {
			attrs << p.parse_attr() or { return none }
			simple_count++
			continue
		}
		if t.kind == .colon {
			p.skip_one()
			mut double := false
			if p.at(.colon) {
				p.skip_one()
				double = true
			}
			// A functional pseudo-class arrives as a *function* token, because the
			// CSS tokenizer turns `not(` into one token and has already eaten the
			// opening paren. The argument readers therefore only look for the closing
			// one.
			if p.at(.function) {
				if double {
					return none
				}
				fn_name := p.peek().value.to_lower()
				// The token is consumed first: it carries the opening paren, so the
				// argument parser must start looking at what follows it.
				p.skip_one()
				pseudos << p.parse_function_pseudo_class(fn_name) or { return none }
				simple_count++
				continue
			}
			name := p.expect_ident() or { return none }
			lower := name.to_lower()
			if double || is_legacy_pseudo_element(lower) {
				// A pseudo-element ends the compound: `p::before span` is two
				// compounds, not one.
				pseudo_element = name
				return CompoundSelector{
					tag: tag
					id: id
					classes: classes
					attrs: attrs
					pseudo_classes: pseudos
					pseudo_element: pseudo_element
					universal: universal
				}
			}
			kind := pseudo_kind_of(lower) or { return none }
			pseudos << PseudoClass{ kind: kind }
			simple_count++
			continue
		}
		break
	}
	if simple_count == 0 {
		return none
	}
	return CompoundSelector{
		tag: tag
		id: id
		classes: classes
		attrs: attrs
		pseudo_classes: pseudos
		pseudo_element: pseudo_element
		universal: universal
	}
}

// is_legacy_pseudo_element names the pseudo-elements that may be written with one
// colon. Browsers still accept them and real stylesheets still use them.
fn is_legacy_pseudo_element(lower string) bool {
	return match lower {
		'before', 'after', 'first-line', 'first-letter' { true }
		else { false }
	}
}

fn (mut p Parser) expect_ident() ?string {
	if !p.at(.ident) {
		return none
	}
	s := p.peek().value
	p.skip_one()
	return s
}

// parse_function_pseudo_class reads the argument of a pseudo-class that arrived as
// a function token. The opening paren is part of that token and is already gone.
fn (mut p Parser) parse_function_pseudo_class(lower string) ?PseudoClass {
	match lower {
		'not' {
			inner := p.parse_function_selector_list() or { return none }
			return PseudoClass{ kind: .negation, inner: inner }
		}
		'nth-child' {
			n := p.parse_nth_argument() or { return none }
			return PseudoClass{ kind: .nth_child, nth: n }
		}
		'nth-last-child' {
			n := p.parse_nth_argument() or { return none }
			return PseudoClass{ kind: .nth_last_child, nth: n }
		}
		'nth-of-type' {
			n := p.parse_nth_argument() or { return none }
			return PseudoClass{ kind: .nth_of_type, nth: n }
		}
		'lang' {
			p.skip_ws()
			tag := p.expect_ident() or { return none }
			p.expect_rparen() or { return none }
			return PseudoClass{ kind: .lang, word: tag }
		}
		else { return none }
	}
}

// pseudo_kind_of maps a pseudo-class name to its kind, rejecting the ones this
// engine does not implement. A selector using an unknown pseudo-class invalidates
// the rule, which is what a browser does, and it is better than matching it
// unconditionally.
fn pseudo_kind_of(lower string) ?PseudoKind {
	return match lower {
		'hover' { PseudoKind.hover }
		'focus' { PseudoKind.focus }
		'active' { PseudoKind.active }
		'link' { PseudoKind.link }
		'visited' { PseudoKind.visited }
		'checked' { PseudoKind.checked }
		'disabled' { PseudoKind.disabled }
		'enabled' { PseudoKind.enabled }
		'root' { PseudoKind.root }
		'empty' { PseudoKind.empty }
		'first-child' { PseudoKind.first_child }
		'last-child' { PseudoKind.last_child }
		'only-child' { PseudoKind.only_child }
		'first-of-type' { PseudoKind.first_of_type }
		'last-of-type' { PseudoKind.last_of_type }
		'only-of-type' { PseudoKind.only_of_type }
		else { return none }
	}
}

fn (mut p Parser) parse_function_selector_list() ?SelectorList {
	inner := p.parse_selector_list() or { return none }
	p.expect_rparen() or { return none }
	return inner
}

fn (mut p Parser) expect_rparen() ?bool {
	p.skip_ws()
	if !p.at(.rparen) {
		return none
	}
	p.skip_one()
	return true
}

// parse_nth_argument reads an `an+b` step.
//
// It serializes the tokens and reads the text, because the tokenizer does not
// have `an+b` in mind: `2n` arrives as a dimension token, `-n` arrives as the
// ident `-n`, `+n` as a delim and an ident, and only `3` arrives as a plain
// number. Four token shapes for one grammar is the signal that the grammar should
// be read as text, and the text is short.
fn (mut p Parser) parse_nth_argument() ?Nth {
	text := p.collect_until_rparen() or { return none }
	return parse_nth(text)
}

// parse_nth reads `odd`, `even`, `n`, `-n`, `2n`, `2n+1`, `-n+3`, `3` or `-3`.
// Whitespace around the sign is allowed and ignored.
fn parse_nth(src string) ?Nth {
	s := src.replace(' ', '').to_lower()
	if s == '' {
		return none
	}
	if s == 'odd' {
		return Nth{ a: 2, b: 1 }
	}
	if s == 'even' {
		return Nth{ a: 2, b: 0 }
	}
	mut sign := 1
	mut rest := s
	if rest[0] == `+` {
		rest = rest[1..]
	} else if rest[0] == `-` {
		sign = -1
		rest = rest[1..]
	}
	if rest == '' {
		return none
	}
	if rest == 'n' {
		return Nth{ a: sign, b: 0 }
	}
	// No `n` at all, so the whole thing is the offset. Anything that is not a
	// number here is not an `an+b` and the selector is invalid.
	idx := rest.index('n') or {
		plain := strconv.atoi(rest) or { return none }
		return Nth{ a: 0, b: sign * plain }
	}
	mut a := sign
	if idx > 0 {
		n := strconv.atoi(rest[..idx]) or { return none }
		a = sign * n
	}
	return Nth{ a: a, b: tail_value(rest[idx + 1..]) or { return none } }
}

// tail_value reads the `+ b` or `- b` that follows an `n` in an `an+b`.
fn tail_value(tail string) ?int {
	if tail == '' {
		return 0
	}
	mut s := 1
	mut digits := tail
	if digits[0] == `+` {
		digits = digits[1..]
	} else if digits[0] == `-` {
		s = -1
		digits = digits[1..]
	}
	if digits == '' {
		return none
	}
	return s * (strconv.atoi(digits) or { return none })
}

// collect_until_rparen gathers the tokens up to a closing paren at this nesting
// level and returns them as source text.
fn (mut p Parser) collect_until_rparen() ?string {
	mut toks := []css.Token{}
	mut depth := 0
	for {
		t := p.peek()
		if t.kind == .eof {
			return none
		}
		if t.kind == .rparen && depth == 0 {
			p.skip_one()
			return css.serialize(toks)
		}
		if t.kind == .lparen || t.kind == .function || t.kind == .lbracket {
			depth++
		} else if t.kind == .rparen || t.kind == .rbracket {
			depth--
		}
		toks << t
		p.skip_one()
	}
}

// parse_attr reads `[name]`, `[name=value]` and its operators, plus the `i` flag.
fn (mut p Parser) parse_attr() ?AttrSelector {
	p.skip_one() // '['
	p.skip_ws()
	name := p.expect_ident() or { return none }
	p.skip_ws()
	if p.at(.rbracket) {
		p.skip_one()
		return AttrSelector{ name: name, op: .exists }
	}
	mut op := AttrOp.equals
	if p.at(.delim) {
		// `=` is one token but `~=`, `|=`, `^=`, `$=` and `*=` are two: the
		// tokenizer has no case for any of them, so each arrives as a delim
		// followed by a delim.
		if p.peek().value == '=' {
			p.skip_one()
		} else {
			symbol := p.peek().value
			op = attr_op_of(symbol) or { return none }
			p.skip_one()
			if !p.at(.delim) || p.peek().value != '=' {
				return none
			}
			p.skip_one()
		}
	}
	p.skip_ws()
	mut value := ''
	if p.at(.string) {
		value = p.peek().value
	} else if p.at(.ident) {
		value = p.peek().value
	} else if p.at(.number) {
		value = p.peek().value
	} else {
		return none
	}
	p.skip_one()
	p.skip_ws()
	mut insensitive := false
	if p.at(.ident) {
		flag := p.peek().value.to_lower()
		if flag != 'i' && flag != 's' {
			return none
		}
		insensitive = flag == 'i'
		p.skip_one()
		p.skip_ws()
	}
	if !p.at(.rbracket) {
		return none
	}
	p.skip_one()
	return AttrSelector{ name: name, op: op, value: value, case_insensitive: insensitive }
}

fn attr_op_of(symbol string) ?AttrOp {
	return match symbol {
		'~' { AttrOp.includes }
		'|' { AttrOp.dash_match }
		'^' { AttrOp.prefix }
		'$' { AttrOp.suffix }
		'*' { AttrOp.substring }
		else { return none }
	}
}
