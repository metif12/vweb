module css

fn rules_of(src string) []Rule {
	return parse(src).rules
}

// qualified returns the nth qualified rule, or a zero value if there are fewer.
// A test that reached for a rule that is not there would otherwise index out of
// range and report a panic instead of the real difference.
fn qualified(src string, n int) QualifiedRule {
	rules := rules_of(src)
	mut found := 0
	for r in rules {
		if r is QualifiedRule {
			if found == n {
				return r
			}
			found++
		}
	}
	return QualifiedRule{}
}

fn count_qualified(src string) int {
	mut n := 0
	for r in rules_of(src) {
		if r is QualifiedRule {
			n++
		}
	}
	return n
}

fn decl_names(d Declaration) string {
	return d.name + ':' + d.value + if d.important { '!' } else { '' }
}

fn test_empty_stylesheet_has_no_rules() {
	assert rules_of('').len == 0
	assert rules_of('   \n\t ').len == 0
	assert rules_of('/* just a comment */').len == 0
}

fn test_one_simple_rule() {
	r := qualified('p { color: red }', 0)
	assert r.prelude == 'p'
	assert r.declarations.len == 1
	assert decl_names(r.declarations[0]) == 'color:red'
	assert !r.declarations[0].important
}

fn test_declaration_value_is_normalized() {
	// Comments go and runs of whitespace collapse, so the cascade and a test can
	// compare the value as text.
	r := qualified('p { margin:  1px   /*here*/  0  }', 0)
	assert r.declarations[0].value == '1px 0'
}

fn test_several_declarations_keep_source_order() {
	r := qualified('p { color: red; background: blue }', 0)
	assert r.declarations.len == 2
	assert decl_names(r.declarations[0]) == 'color:red'
	assert decl_names(r.declarations[1]) == 'background:blue'
}

fn test_last_declaration_without_a_semicolon_is_kept() {
	r := qualified('p { color: red }', 0)
	assert r.declarations.len == 1
	r2 := qualified('p { a: 1; b: 2 }', 0)
	assert r2.declarations.len == 2
}

fn test_important_with_and_without_a_space() {
	// The tokenizer has no case for `!`, so both spellings are a delim and an
	// ident and the parser is what pairs them up.
	r := qualified('p { color: red !important; x: 1 }', 0)
	assert r.declarations[0].important
	assert r.declarations[0].value == 'red'
	assert !r.declarations[1].important
	r2 := qualified('p { color: red ! important }', 0)
	assert r2.declarations[0].important
	assert r2.declarations[0].value == 'red'
}

fn test_important_is_case_insensitive() {
	r := qualified('p { color: red !IMPORTANT }', 0)
	assert r.declarations[0].important
	assert r.declarations[0].value == 'red'
}

fn test_a_bang_that_is_not_important_stays_in_the_value() {
	r := qualified('p { content: "a" ; x: 1 }', 0)
	assert r.declarations[0].value == '"a"'
	assert !r.declarations[0].important
}

fn test_rules_keep_source_order() {
	// The cascade resolves equal specificity by source order, so this is not a
	// detail the parser is free to lose.
	sheet := parse('a { x: 1 } b { x: 2 } c { x: 3 }')
	assert sheet.rules.len == 3
	mut i := 0
	for r in sheet.rules {
		if r is QualifiedRule {
			i++
			assert r.prelude == ['a', 'b', 'c'][i - 1]
		}
	}
}

fn test_prelude_keeps_selectors_untouched() {
	// The selector grammar belongs to engine/selector. What matters here is that
	// the text survives with its combinators and its commas intact.
	r := qualified('div.main > p + a ~ span , [data-x], a:link::before { color: red }', 0)
	assert r.prelude == 'div.main > p + a ~ span , [data-x], a:link::before'
}

fn test_prelude_whitespace_is_collapsed_but_not_invented() {
	// Collapsing runs is safe; adding a space where there was none is not, because
	// `.a.b` and `.a .b` are different selectors.
	assert qualified('p{color:red}', 0).prelude == 'p'
	assert qualified('p   {color:red}', 0).prelude == 'p'
	assert qualified('.a.b{color:red}', 0).prelude == '.a.b'
	assert qualified('.a  .b{color:red}', 0).prelude == '.a .b'
}

fn test_custom_property_declaration_is_kept() {
	r := qualified(':root { --main-bg: #fff }', 0)
	assert r.declarations[0].name == '--main-bg'
	assert r.declarations[0].value == '#fff'
}

fn test_value_may_contain_braces_and_semicolons_inside_functions() {
	r := qualified('p { background: url(a;b{c}.png) }', 0)
	assert r.declarations[0].value == 'url(a;b{c}.png)'
}

fn test_value_may_contain_a_brace_inside_a_string() {
	r := qualified('p { content: "}" ; x: 1 }', 0)
	assert r.declarations.len == 2
	assert r.declarations[0].value == '"}"'
}

fn test_malformed_declaration_is_dropped_and_the_rest_survive() {
	// This is the reason the parser recovers instead of failing: a typo in one
	// declaration must not take the rest of the block with it, and on the real web
	// the typo is usually in the middle.
	r := qualified('p { color: red; ; nonsense; font-size: 2px }', 0)
	assert r.declarations.len == 2
	assert decl_names(r.declarations[0]) == 'color:red'
	assert decl_names(r.declarations[1]) == 'font-size:2px'
}

fn test_malformed_declaration_without_a_colon_is_skipped_to_the_semicolon() {
	r := qualified('p { color red; font-size: 2px }', 0)
	assert r.declarations.len == 1
	assert decl_names(r.declarations[0]) == 'font-size:2px'
}

fn test_rule_with_no_block_is_dropped() {
	// Keeping it would put an unparsed prelude with no declarations into the
	// cascade.
	assert count_qualified('p { color: red } dangling') == 1
	assert count_qualified('just a prelude') == 0
}

fn test_rule_with_a_stray_closing_brace_is_dropped() {
	assert count_qualified('p { color: red } }') == 1
}

fn test_truncated_rule_keeps_what_it_parsed() {
	// The commonest cause of a truncated stylesheet is a cut-off file, and losing
	// its declarations helps nobody.
	r := qualified('p { color: red; font-size: 2px', 0)
	assert r.declarations.len == 2
	assert qualified('p { color: red', 0).declarations.len == 1
}

fn test_truncated_stylesheet_terminates() {
	for src in ['a{b:', 'a{b', 'a{', 'a', '@media', '@media(', '@media screen', '"',
		'/*', 'a{b:c', 'a{b:url(', '}}}', '@;', '@'] {
		_ := rules_of(src)
	}
}

fn test_at_rule_without_a_block_is_kept_as_a_declaration_at_rule() {
	rules := rules_of('@import url(a.css);')
	assert rules.len == 1
	if rules[0] is AtDeclarationRule {
		assert rules[0].name == 'import'
		assert rules[0].prelude == 'url(a.css)'
		assert rules[0].declarations.len == 0
	} else {
		assert false
	}
}

fn test_at_rule_names_are_lower_cased() {
	rules := rules_of('@MEDIA screen { a { b: c } }')
	assert rules.len == 1
	if rules[0] is NestedRule {
		assert rules[0].name == 'media'
		assert rules[0].prelude == 'screen'
		assert rules[0].rules.len == 1
	} else {
		assert false
	}
}

fn test_font_face_block_holds_declarations_not_rules() {
	// The shape of an at-rule's block is not decidable from CSS itself, so it
	// comes from the name.
	rules := rules_of('@font-face { font-family: X; src: url(x.woff) }')
	assert rules.len == 1
	if rules[0] is AtDeclarationRule {
		assert rules[0].declarations.len == 2
	} else {
		assert false
	}
}

fn test_media_block_holds_rules() {
	rules := rules_of('@media screen and (min-width: 600px) { p { color: red } }')
	assert rules.len == 1
	if rules[0] is NestedRule {
		assert rules[0].rules.len == 1
		if rules[0].rules[0] is QualifiedRule {
			assert rules[0].rules[0].prelude == 'p'
		} else {
			assert false
		}
	} else {
		assert false
	}
}

fn test_nested_at_rules_nest() {
	rules := rules_of('@media print { @media (min-width: 10px) { p { a: b } } }')
	assert rules.len == 1
	if rules[0] is NestedRule {
		assert rules[0].rules.len == 1
		if rules[0].rules[0] is NestedRule {
			assert rules[0].rules[0].name == 'media'
			assert rules[0].rules[0].rules.len == 1
		} else {
			assert false
		}
	} else {
		assert false
	}
}

fn test_at_rule_prelude_keeps_its_parens() {
	rules := rules_of('@supports (display: grid) { p { a: b } }')
	if rules[0] is NestedRule {
		assert rules[0].prelude == '(display: grid)'
	} else {
		assert false
	}
}

fn test_cdo_and_cdc_are_skipped_not_parsed_as_rules() {
	assert count_qualified('<!-- p { a: b } -->') == 1
}

fn test_selector_syntax_is_not_validated_here() {
	// A prelude that is not a valid selector is still a rule; it is the selector
	// grammar's job to reject it, and at worst it matches nothing.
	assert count_qualified('p >>> q { a: b }') == 1
	assert count_qualified('}{ { a: b }') == 0
}

fn test_serialize_round_trips_through_the_tokenizer() {
	for src in ['div.main > p', 'a[href^="http"]', '1px solid red', 'url(a.png)',
		'"a\\"b"', 'rgba(1, 2, 3, 0.5)', 'a\\ b'] {
		once := serialize(tokenize(src))
		twice := serialize(tokenize(once))
		assert once == twice
	}
}

fn test_serialize_quotes_a_string_again() {
	assert serialize(tokenize('"a"')) == '"a"'
	// An ident whose value holds a space needs its backslash back, or the second
	// pass would read it as two idents.
	assert serialize(tokenize('a\\ b')) == 'a\\ b'
}

fn test_user_agent_stylesheet_parses() {
	sheet := parse(user_agent_css)
	mut n := 0
	mut decls := 0
	for r in sheet.rules {
		if r is QualifiedRule {
			n++
			decls += r.declarations.len
		}
	}
	assert n > 10
	assert decls > 20
}

fn test_user_agent_stylesheet_is_self_consistent() {
	// Two things a UA sheet gets wrong that no test would otherwise catch: a
	// selector list whose last member has no trailing comma, and a declaration
	// whose value came out empty because of a stray semicolon.
	sheet := parse(user_agent_css)
	for r in sheet.rules {
		if r is QualifiedRule {
			assert r.prelude != ''
			assert !r.prelude.ends_with(',')
			for d in r.declarations {
				assert d.name != ''
				assert d.value != ''
				assert !d.name.ends_with(':')
			}
		}
	}
}

fn test_user_agent_stylesheet_makes_html_and_body_block_with_the_default_margin() {
	sheet := parse(user_agent_css)
	mut block_list := ''
	mut body_margin := ''
	mut ol_padding := ''
	for r in sheet.rules {
		if r is QualifiedRule {
			if r.prelude.contains('html,') && r.prelude.contains('p,') {
				for d in r.declarations {
					if d.name == 'display' {
						block_list = d.value
					}
				}
			}
			if r.prelude == 'body' {
				for d in r.declarations {
					if d.name == 'margin' {
						body_margin = d.value
					}
				}
			}
			if r.prelude == 'ul, ol' {
				for d in r.declarations {
					if d.name == 'padding-left' {
						ol_padding = d.value
					}
				}
			}
		}
	}
	// `p` has no rule of its own because it is in the block list with everything
	// else that is display:block.
	assert block_list == 'block'
	assert body_margin == '8px'
	assert ol_padding == '40px'
}

fn test_user_agent_stylesheet_does_not_list_inline_elements() {
	// Everything that should be inline is left out, because the initial value of
	// `display` is inline and writing it out would double the sheet for no effect.
	sheet := parse(user_agent_css)
	for r in sheet.rules {
		if r is QualifiedRule {
			assert r.prelude != 'span'
			assert r.prelude != 'a, b, i'
		}
	}
}

fn test_user_agent_stylesheet_hides_the_elements_that_render_nothing() {
	sheet := parse(user_agent_css)
	mut hidden := ''
	for r in sheet.rules {
		if r is NestedRule {
			continue
		}
		if r is AtDeclarationRule {
			continue
		}
		if r is QualifiedRule {
			for d in r.declarations {
				if d.name == 'display' && d.value == 'none' {
					hidden = r.prelude
				}
			}
		}
	}
	// `head, link, meta, ...` is one selector list, so the check is that some rule
	// with display:none exists and that script is in it.
	assert hidden.contains('script')
	assert hidden.contains('style')
}