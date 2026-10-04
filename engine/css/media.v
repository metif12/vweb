module css

// Media query evaluation.
//
// A media prelude is CSS text, so this module tokenizes it rather than scanning
// characters: every number, dimension and ident comes from the same lexer the rest of
// the engine uses, which means `(min-width:60em)` and `(min-width: 60em)` cannot
// disagree about what they mean.
//
// The rule that shapes everything else is CSS Media Queries 4's: **an unknown feature
// evaluates to false, and so does any query containing one.** That is not a
// simplification. A stylesheet asking for a feature the engine cannot measure is asking
// for something the engine would otherwise have to invent, and an invented answer paints
// a page the author never asked for. Refusing the whole query is the visible, recoverable
// failure.
//
// Three things are supported: the width and height features in px, em and rem; the media
// types; and `orientation` and `prefers-color-scheme`. Everything else -- `aspect-ratio`,
// `resolution`, the range forms of MQ4, boolean `or` inside a parenthesis -- evaluates
// to false. Those are decisions, not oversights, and they are listed here so that a
// stylesheet which stops working says why.
//
// The parser is a set of functions over a token slice and an index, and deliberately not
// a struct with a cursor. A `mut` receiver on a struct does not propagate its
// increments back to the caller's variable in this V unless the call site also says
// `mut`, so a cursor in a receiver silently re-reads the first token forever -- and the
// symptom is not an error, it is every query with an expression in it answering false.
// Passing the index in and returning it out has no such failure mode.

pub struct MediaContext {
pub mut:
	// width and height are in CSS pixels.
	width  f64
	height f64
	// known reports whether the caller supplied a viewport at all. A caller that has
	// not -- a unit test, a batch renderer -- is running a stylesheet outside a window,
	// and no dimensioned query can be answered for it, so none of them matches.
	//
	// This is deliberately not "a zero-sized viewport". A zero viewport would make
	// every `(max-width: 600px)` query match, which is the mobile branch of a
	// responsive stylesheet applied to a caller that never asked for a size.
	known bool
	// root_font_size resolves `em` and `rem`. It is a field rather than a constant
	// because `html { font-size: 120% }` changes what `12rem` means, and answering with
	// a hardcoded 16 would make the query match the wrong thing.
	root_font_size f64 = 16.0
	// prefers_dark is the reader's setting. Light is the default because that is what a
	// browser reports when nothing has been set.
	prefers_dark bool
}

// screen_context is the context for a renderer on a display, with a real viewport.
pub fn screen_context(width int, height int) MediaContext {
	return MediaContext{
		width:  f64(width)
		height: f64(height)
		known:  true
	}
}

// matches evaluates a media query list -- the prelude of an `@media` rule.
//
// The list is a comma-separated set of queries and any one of them matching is enough,
// which is what the comma means. An empty list is true, per the spec, and not as a
// convenience: `@media { ... }` is emitted by tools that build the list dynamically and
// dropping its rules would be surprising.
pub fn (ctx &MediaContext) matches(query_list string) bool {
	q := query_list.trim_space()
	if q == '' {
		return true
	}
	for one in split_queries(q) {
		if ctx.matches_query(one) {
			return true
		}
	}
	return false
}

fn (ctx &MediaContext) matches_query(query string) bool {
	q := query.trim_space()
	if q == '' {
		// A trailing comma leaves an empty entry. The spec makes an empty query true,
		// so `@media screen, { ... }` behaves like `@media screen` rather than
		// cancelling the whole list.
		return true
	}
	toks := significant(tokenize(q))
	mut i := 0
	mut negate := false
	if i < toks.len && toks[i].kind == .ident && toks[i].value.to_lower() == 'not' {
		negate = true
		i++
	} else if i < toks.len && toks[i].kind == .ident && toks[i].value.to_lower() == 'only' {
		// `only` is a hint to legacy UAs that cannot parse the rest of the query. A
		// parser that got here is not one, so it is a no-op.
		i++
	}
	result := ctx.eval_query(toks, i)
	if negate {
		return !result
	}
	return result
}

// eval_query evaluates one query from index `from`: an optional media type, then
// `and`-joined expressions, or a bare expression list.
fn (ctx &MediaContext) eval_query(toks []Token, from int) bool {
	mut i := from
	if i < toks.len && toks[i].kind == .ident && !is_word(toks[i].value, 'and')
		&& !is_word(toks[i].value, 'or') && !is_word(toks[i].value, 'not') {
		// A leading ident is the media type. A query that starts with `(` has none and
		// is implicitly `all`.
		typ := toks[i].value.to_lower()
		// A screen renderer honours `all` and `screen` and refuses everything else. An
		// unrecognised type is refused too: this engine cannot claim to be a television.
		if typ != 'all' && typ != 'screen' {
			return false
		}
		i++
	}
	// The rest is a sequence of `and`-joined expressions. `and` is a separator and not a
	// term, so it is skipped wherever it appears: `screen and (a)` and `(a) and (b)` are
	// the same shape once the type has been taken off the front, and handling them as two
	// cases is how `(min-width: 400px) and (max-width: 1200px)` came to answer false.
	for i < toks.len {
		if toks[i].kind == .ident && toks[i].value.to_lower() == 'and' {
			i++
			continue
		}
		end := ctx.eval_expression(toks, i) or { return false }
		i = end
	}
	// Anything left over is a shape this grammar does not cover, and a query it does not
	// cover is false rather than true.
	return i == toks.len
}

// eval_expression evaluates one `(feature: value)` group and returns the index after it.
fn (ctx &MediaContext) eval_expression(toks []Token, from int) ?int {
	mut i := from
	i = step(toks, i, .lparen) or { return none }
	mut feature := ''
	if i < toks.len && toks[i].kind == .ident {
		feature = toks[i].value
		i++
	}
	mut value := ''
	mut has_value := false
	if n := step(toks, i, .colon) {
		end := value_end(toks, n)
		value = serialize(toks[n..end])
		i = end
		has_value = true
	}
	i = step(toks, i, .rparen) or { return none }
	if !ctx.matches_feature(feature.to_lower(), value, has_value) {
		return none
	}
	return i
}

// matches_feature evaluates one `feature: value` pair. An unrecognised feature is false,
// and so is every query containing one.
fn (ctx &MediaContext) matches_feature(feature string, value string, has_value bool) bool {
	if feature == '' {
		return false
	}
	// Boolean logic inside the parentheses is MQ4 and is not implemented.
	if feature == 'not' || feature == 'or' {
		return false
	}
	// A range form such as `(width >= 600px)` tokenizes with no feature name, because
	// the comparison swallowed it. False.
	if has_value && !is_length_value(value) && !is_keyword(value) {
		return false
	}
	match feature {
		'all' { return !has_value || value == '' || value.to_lower() == 'all' }
		'width', 'min-width', 'max-width' {
			return ctx.matches_length(value, has_value, ctx.width, feature == 'min-width',
				feature == 'max-width')
		}
		'height', 'min-height', 'max-height' {
			return ctx.matches_length(value, has_value, ctx.height, feature == 'min-height',
				feature == 'max-height')
		}
		'orientation' {
			if !has_value || !ctx.known {
				return false
			}
			want := value.to_lower()
			if ctx.width > ctx.height {
				return want == 'landscape'
			}
			return want == 'portrait'
		}
		'prefers-color-scheme' {
			if !has_value {
				return false
			}
			// Both branches are asked, not just the dark one. Returning `want == 'light'`
			// for everything that is not `dark` answers `light` with true even when the
			// reader has asked for dark -- which is what this test caught.
			want := value.to_lower()
			if want == 'dark' {
				return ctx.prefers_dark
			}
			if want == 'light' {
				return !ctx.prefers_dark
			}
			// `no-preference` and anything else are not values this feature takes.
			return false
		}
		else { return false }
	}
}

// matches_length compares a viewport dimension against a length feature.
//
// Three ways to get this wrong are handled here rather than at the call site: a feature
// with no value, which MQ3 treats as false; a context with no viewport, where no
// dimensioned query can be answered; and a value in a unit that is not a length at all.
fn (ctx &MediaContext) matches_length(value string, has_value bool, actual f64, at_least bool, at_most bool) bool {
	if !has_value || value == '' {
		return false
	}
	if !ctx.known {
		return false
	}
	want := ctx.length_px(value) or { return false }
	if at_least {
		return actual >= want
	}
	if at_most {
		return actual <= want
	}
	return actual == want
}

// length_px resolves a length to pixels.
//
// `em` resolves against the root font size, not against an element's: there is no element
// in a media query, and MQ4 says the initial value for exactly that reason. `0` is a
// length in CSS and any other bare number is not, so a unitless number is accepted only
// when it is zero -- a bare `600` in `(min-width: 600)` is a mistake in the stylesheet and
// is refused rather than read as pixels.
fn (ctx &MediaContext) length_px(value string) ?f64 {
	t := significant(tokenize(value))
	if t.len == 0 {
		return none
	}
	head := t[0]
	match head.kind {
		.dimension {
			match head.unit.to_lower() {
				'px' { return head.num }
				'em' { return head.num * ctx.root_font_size }
				'rem' { return head.num * ctx.root_font_size }
				else { return none }
			}
		}
		.number {
			if head.num == 0.0 {
				return 0.0
			}
			return none
		}
		else { return none }
	}
}

// is_length_value and is_keyword split the two shapes a feature value can take, so that
// matches_feature can tell `600px` from `landscape` without evaluating both.
fn is_length_value(value string) bool {
	t := significant(tokenize(value))
	return t.len > 0 && (t[0].kind == .dimension || t[0].kind == .number)
}

fn is_keyword(value string) bool {
	t := significant(tokenize(value))
	return t.len > 0 && t[0].kind == .ident
}

fn is_word(value string, word string) bool {
	return value.to_lower() == word
}

// split_queries splits a query list on commas that are not inside parentheses.
//
// It goes through the tokenizer like everything else here: the delimiters are already
// tokens, so reading them as tokens is both shorter and the same answer the parser gives.
// An earlier version indexed the string directly, and `s[i]` does not have a stable type
// in this V -- a `u8` in one loop and a `string` in another -- so neither comparison
// against a character literal compiled.
//
// The whitespace tokens are kept on purpose. Each piece is handed on as
// `serialize(tokens)`, and serialize emits a space only where a whitespace token says
// there was one; dropping them first turned `only screen` into `onlyscreen`, which then
// failed to parse as two tokens and every query using `only` or `not` quietly became
// false. Nothing said so -- the answers were simply wrong.
fn split_queries(s string) []string {
	mut out := []string{}
	mut cur := []Token{}
	mut depth := 0
	for t in tokenize(s) {
		if t.kind == .eof {
			continue
		}
		if t.kind == .lparen {
			depth++
		} else if t.kind == .rparen {
			if depth > 0 {
				depth--
			}
		} else if t.kind == .comma && depth == 0 {
			out << serialize(cur)
			cur = []
			continue
		}
		cur << t
	}
	out << serialize(cur)
	return out
}

// step returns the index after the token at i when that token has the given kind, and
// none when it does not or when i is past the end.
fn step(toks []Token, i int, kind TokenKind) ?int {
	if i >= toks.len || toks[i].kind != kind {
		return none
	}
	return i + 1
}

// value_end returns the index just past a feature's value, stopping at the closing
// parenthesis of its group. That is what keeps `(min-width: 30em)` from swallowing the
// `)` and the rest of the query with it.
fn value_end(toks []Token, from int) int {
	mut i := from
	mut depth := 0
	for i < toks.len {
		if toks[i].kind == .lparen {
			depth++
		} else if toks[i].kind == .rparen {
			if depth == 0 {
				return i
			}
			depth--
		}
		i++
	}
	return toks.len
}

// significant drops whitespace and the end marker, which is what every walk above
// assumes it is walking.
fn significant(toks []Token) []Token {
	mut out := []Token{cap: toks.len}
	for t in toks {
		if t.kind == .whitespace || t.kind == .eof {
			continue
		}
		out << t
	}
	return out
}
