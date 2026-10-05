module css

fn kinds(toks []Token) []TokenKind {
	mut out := []TokenKind{len: toks.len}
	for i in 0 .. toks.len {
		out[i] = toks[i].kind
	}
	return out
}

fn values(toks []Token) []string {
	mut out := []string{len: toks.len}
	for i in 0 .. toks.len {
		out[i] = toks[i].value
	}
	return out
}

fn test_empty_input_is_one_eof_token() {
	toks := tokenize('')
	assert toks.len == 1
	assert toks[0].kind == .eof
}

fn test_ident_and_whitespace() {
	toks := tokenize('color  red')
	assert kinds(toks) == [.ident, .whitespace, .ident, .eof]
	assert values(toks) == ['color', '', 'red', '']
}

fn test_whitespace_run_is_one_token() {
	// A run is collapsed by the tokenizer, not by serialize. That is why `a  b`
	// and `a b` cannot be told apart, which is correct: CSS says they are the
	// same token sequence.
	assert kinds(tokenize('a   \n\t b')) == [.ident, .whitespace, .ident, .eof]
}

fn test_comment_is_not_a_token() {
	toks := tokenize('a/* comment */b')
	assert kinds(toks) == [.ident, .ident, .eof]
	assert values(toks) == ['a', 'b', '']
}

fn test_a_comment_splits_a_whitespace_run() {
	// Comments are consumed before the dispatch, and "consume as much whitespace
	// as possible" happens inside it. So a comment between two spaces really does
	// produce three whitespace tokens, which is why `.a /*x*/ .b` is two compound
	// selectors and not one.
	toks := tokenize('a /*x*/ b')
	assert kinds(toks) == [.ident, .whitespace, .whitespace, .ident, .eof]
}

fn test_unterminated_comment_runs_to_end_of_input() {
	assert kinds(tokenize('a/* b')) == [.ident, .eof]
}

fn test_punctuation_tokens() {
	assert kinds(tokenize('{}[]():;')) == [
		.lbrace,
		.rbrace,
		.lbracket,
		.rbracket,
		.lparen,
		.rparen,
		.colon,
		.semicolon,
		.eof,
	]
}

fn test_function_token_carries_the_name() {
	// The `(` is consumed only once the ident is known, so a function token is
	// produced by the ident, never by the paren.
	toks := tokenize('rgb(1,2,3)')
	assert kinds(toks) == [.function, .number, .comma, .number, .comma, .number, .rparen, .eof]
	assert toks[0].value == 'rgb'
}

fn test_bare_paren_is_always_a_paren_token() {
	assert kinds(tokenize('()')) == [.lparen, .rparen, .eof]
	assert kinds(tokenize('(1)')) == [.lparen, .number, .rparen, .eof]
}

fn test_at_keyword_token() {
	toks := tokenize('@media screen')
	assert kinds(toks) == [.at_keyword, .whitespace, .ident, .eof]
	assert toks[0].value == 'media'
}

fn test_at_not_followed_by_ident_is_a_delim() {
	assert kinds(tokenize('@ 1')) == [.delim, .whitespace, .number, .eof]
}

fn test_hash_token_type_flag_separates_a_selector_from_a_colour() {
	// The same token shape is an id selector or a colour depending on this flag,
	// and the tokenizer is the only place that knows which it saw.
	sel := tokenize('#main')[0]
	assert sel.kind == .hash && sel.is_id && sel.value == 'main'
	// A digit cannot start an ident sequence, so this is a hash token but not an
	// id -- which is exactly why `#123` is a colour and not a selector.
	num := tokenize('#123')[0]
	assert num.kind == .hash && !num.is_id && num.value == '123'
	// An escaped ident is a valid id too.
	esc := tokenize('#\\31 23')[0]
	assert esc.kind == .hash && esc.is_id
}

fn test_hash_with_nothing_ident_like_after_it_is_a_delim() {
	assert kinds(tokenize('#!')) == [.delim, .delim, .eof]
}

fn test_string_tokens_resolve_escapes() {
	toks := tokenize('"a\\"b"')
	assert toks[0].kind == .string
	assert toks[0].value == 'a"b'
	single := tokenize("'it\\'s'")[0]
	assert single.kind == .string && single.value == "it's"
}

fn test_string_ends_at_newline_as_a_bad_string() {
	// The newline is left for the next token rather than consumed, so recovery
	// resumes with the text after it.
	toks := tokenize('"open\nrest"')
	assert toks[0].kind == .bad_string
	assert toks[1].kind == .whitespace
	assert toks[2].kind == .ident && toks[2].value == 'rest'
}

fn test_escaped_newline_inside_a_string_is_removed() {
	toks := tokenize('"a\\\nb"')
	assert toks[0].kind == .string
	assert toks[0].value == 'ab'
}

fn test_unterminated_string_at_eof_is_still_a_string() {
	toks := tokenize('"abc')
	assert toks[0].kind == .string
	assert toks[0].value == 'abc'
}

fn test_url_token_for_the_unquoted_form() {
	toks := tokenize('url(a.png)')
	assert kinds(toks) == [.url, .eof]
	assert toks[0].value == 'a.png'
}

fn test_quoted_url_is_a_function_plus_a_string() {
	// Both spellings occur on the web, and the spec resolves them differently.
	toks := tokenize('url("a.png")')
	assert kinds(toks) == [.function, .string, .rparen, .eof]
	assert toks[0].value == 'url'
	assert toks[1].value == 'a.png'
}

fn test_url_is_case_insensitive_but_its_body_is_not() {
	assert tokenize('URL(a.png)')[0].kind == .url
	assert tokenize('Url(A.PNG)')[0].value == 'A.PNG'
}

fn test_url_with_whitespace_before_the_body_is_still_a_url_token() {
	// Whitespace after `url(` is consumed in pairs, so with two spaces one of them
	// survives into the url's value. The spec says so, and the difference is not
	// observable to anything downstream.
	toks := tokenize('url(  a.png  )')
	assert toks[0].kind == .url
	assert toks[0].value == ' a.png  '
}

fn test_url_may_contain_escaped_characters() {
	toks := tokenize('url(a\\2e png)')
	assert toks[0].kind == .url
	assert toks[0].value == 'a.png'
}

fn test_bad_url_is_dropped_and_lexing_resumes_after_it() {
	// An unquoted body may not contain a quote or a paren; a quoted one is a
	// function token and never gets here.
	toks := tokenize('url(a"b) red')
	assert toks[0].kind == .bad_url
	// The bad-url remnant consumes the closing paren, so lexing resumes on the
	// space before `red`.
	assert toks[1].kind == .whitespace
	assert toks[2].kind == .ident && toks[2].value == 'red'
	toks2 := tokenize('url(a(b))')
	// The remnant stops at the first closing paren, so a second one survives.
	assert kinds(toks2) == [.bad_url, .rparen, .eof]
}

fn test_number_token() {
	toks := tokenize('42')
	assert toks[0].kind == .number
	assert toks[0].value == '42'
	assert toks[0].num == 42.0
	assert toks[0].is_int
}

fn test_number_keeps_the_text_it_was_written_with() {
	// The written form is kept so a stylesheet round-trips. `1e3` must not
	// quietly become `1000`.
	assert tokenize('1e3')[0].value == '1e3'
	assert tokenize('1e3')[0].num == 1000.0
	assert !tokenize('1e3')[0].is_int
}

fn test_fractional_and_signed_numbers() {
	assert tokenize('+.5')[0].num == 0.5
	assert tokenize('-0.25')[0].num == -0.25
	assert !tokenize('-0.25')[0].is_int
	assert tokenize('+5')[0].num == 5.0
	assert tokenize('+5')[0].is_int
}

fn test_dot_without_a_following_digit_is_a_delim() {
	// `.5em` is a dimension but `.foo` is a delim and an ident.
	assert kinds(tokenize('.foo')) == [.delim, .ident, .eof]
	assert kinds(tokenize('1.5em')) == [.dimension, .eof]
	// `1.` is the number 1 followed by a dot, not the number 1.0.
	assert kinds(tokenize('1.')) == [.number, .delim, .eof]
}

fn test_percentage_token() {
	toks := tokenize('100%')
	assert toks[0].kind == .percentage
	assert toks[0].num == 100.0
	// The percent sign is the kind's job, so it is not in the value.
	assert toks[0].value == '100'
}

fn test_dimension_token_carries_its_unit() {
	toks := tokenize('1.5em')
	assert toks[0].kind == .dimension
	assert toks[0].num == 1.5
	assert toks[0].unit == 'em'
}

fn test_ident_escape_is_resolved_so_escaped_and_plain_compare_equal() {
	// `\75 rl` is `url`. A cascade comparing source text would miss the match.
	assert tokenize('\\75 rl')[0].value == 'url'
	assert tokenize('\\75 rl')[0].kind == .ident
	assert tokenize('\\75 rl')[0].value == tokenize('url')[0].value
}

fn test_hex_escape_swallows_one_following_whitespace() {
	// `\61 \62` is `ab`, not `a` followed by `b`: the space after the first hex
	// escape is consumed as part of that escape.
	assert tokenize('\\61 \\62')[0].value == 'ab'
}

fn test_escape_can_produce_a_character_that_is_not_a_name_char() {
	// The escape is resolved on the way in, which means an ident's value may
	// contain a space. serialize has to put the backslash back.
	tok := tokenize('a\\ b')[0]
	assert tok.kind == .ident
	assert tok.value == 'a b'
	assert token_text(tok) == 'a\\ b'
}

fn test_surrogate_and_zero_escapes_become_the_replacement_character() {
	// A surrogate is reachable through a perfectly well-formed escape, and it
	// does not name a character.
	assert tokenize('\\D800')[0].value == '\uFFFD'
	assert tokenize('\\0')[0].value == '\uFFFD'
}

fn test_backslash_before_a_newline_is_a_delim() {
	assert kinds(tokenize('\\\nfoo')) == [.delim, .whitespace, .ident, .eof]
}

fn test_dash_prefixed_ident_is_not_two_delims() {
	toks := tokenize('-webkit-box')
	assert toks[0].kind == .ident
	assert toks[0].value == '-webkit-box'
}

fn test_custom_property_name_is_an_ident() {
	assert tokenize('--main-bg')[0].kind == .ident
	assert tokenize('--main-bg')[0].value == '--main-bg'
}

fn test_lone_dash_is_a_delim() {
	assert kinds(tokenize('-')) == [.delim, .eof]
}

fn test_cdo_and_cdc_tokens() {
	assert kinds(tokenize('<!-- a -->')) == [.cdo, .whitespace, .ident, .whitespace, .cdc, .eof]
	// The CDC check comes before the ident check, which is the only reason `-->`
	// is a token rather than the ident `--` followed by a delim.
	assert tokenize('-->')[0].kind == .cdc
}

fn test_cdc_needs_the_hyphen_first() {
	assert kinds(tokenize('->')) == [.delim, .delim, .eof]
}

fn test_bang_is_an_ordinary_delim() {
	// There is no case for `!` in the tokenizer at all: `!important` is a delim
	// followed by an ident, and a parser is what recognises the pair.
	assert kinds(tokenize('!important')) == [.delim, .ident, .eof]
	assert kinds(tokenize('! important')) == [.delim, .whitespace, .ident, .eof]
}

fn test_crlf_and_form_feed_are_normalized_to_newline() {
	// The whole tokenizer only has to know one line terminator because of this.
	assert kinds(tokenize('a\r\nb')) == [.ident, .whitespace, .ident, .eof]
	assert kinds(tokenize('a\fb')) == [.ident, .whitespace, .ident, .eof]
	assert kinds(tokenize('a\rb')) == [.ident, .whitespace, .ident, .eof]
}

fn test_null_byte_becomes_the_replacement_character() {
	toks := tokenize('a\x00b')
	// U+FFFD is a non-ASCII ident code point, so it stays inside the ident
	// rather than splitting it.
	assert toks[0].kind == .ident
	assert toks[0].value == 'a\uFFFDb'
}

fn test_non_ascii_ident_ranges_follow_the_spec_list_not_the_byte_range() {
	// CSS excludes NBSP, the zero-width characters and the bidi controls from
	// the non-ASCII ident set. An RTL page is full of those, so treating every
	// byte >= 0x80 as a name character would swallow an RLM into the identifier
	// beside it -- which is a silent, wrong render rather than a parse error.
	assert tokenize('متن')[0].kind == .ident
	assert tokenize('متن')[0].value == 'متن'
	assert kinds(tokenize('a\u00A0b')) == [.ident, .delim, .ident, .eof]
	assert kinds(tokenize('a\u200Fb')) == [.ident, .delim, .ident, .eof]
	assert kinds(tokenize('a\u202Eb')) == [.ident, .delim, .ident, .eof]
	// A zero-width joiner is in the set, so it does stay.
	assert tokenize('a\u200Db')[0].kind == .ident
}

fn test_a_non_ascii_delim_is_one_whole_code_point() {
	toks := tokenize('\u00A0')
	assert kinds(toks) == [.delim, .eof]
	// Slicing by byte would have produced three delims.
	assert toks[0].value == '\u00A0'
}

fn test_ident_case_is_preserved() {
	// Case is the cascade's business, not the tokenizer's.
	assert tokenize('RED')[0].value == 'RED'
	assert tokenize('RED')[0].value != tokenize('red')[0].value
}

fn test_tokenize_always_ends_with_exactly_one_eof() {
	for src in ['a', 'a{b:c}', '@media(x){a{b:c}}', '', '\x00\x00', 'url(', '"', '/*'] {
		toks := tokenize(src)
		assert toks.len > 0
		assert toks[toks.len - 1].kind == .eof
		mut n := 0
		for t in toks {
			if t.kind == .eof {
				n++
			}
		}
		assert n == 1
	}
}

fn test_tokenize_terminates_on_awkward_input() {
	// Every one of these would loop forever if a branch failed to advance.
	for src in ['(', ')', '"', "'", '\\', '#', 'url(', 'url("', '-', '--', '<!--', '-->', '1e',
		'1e+', '.', '+.', '@'] {
		toks := tokenize(src)
		assert toks[toks.len - 1].kind == .eof
	}
}

fn test_a_real_declaration_lexes_the_way_the_parser_expects() {
	toks := tokenize('margin: 1px 0 2px')
	assert kinds(toks) == [
		.ident,
		.colon,
		.whitespace,
		.dimension,
		.whitespace,
		.number,
		.whitespace,
		.dimension,
		.eof,
	]
	assert toks[3].num == 1.0 && toks[3].unit == 'px'
	assert toks[5].kind == .number && toks[5].num == 0.0
}
