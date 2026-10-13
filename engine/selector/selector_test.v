module selector

fn one(text string) ComplexSelector {
	list := parse(text) or { return ComplexSelector{} }
	return list[0]
}

fn must_parse(text string) SelectorList {
	return parse(text) or { panic('expected ' + text + ' to parse') }
}

fn test_a_type_selector() {
	s := one('p')
	assert s.parts.len == 1
	assert s.parts[0].tag == 'p'
	assert s.parts[0].id == ''
	assert s.parts[0].classes.len == 0
	assert !s.parts[0].universal
}

fn test_a_compound_selector_collects_every_simple_selector() {
	s := one('a#main.big.wide[href][data-x="1"]')
	c := s.parts[0]
	assert c.tag == 'a'
	assert c.id == 'main'
	assert c.classes == ['big', 'wide']
	assert c.attrs.len == 2
	assert c.attrs[0].op == .exists
	assert c.attrs[1].op == .equals && c.attrs[1].value == '1'
}

fn test_universal_is_distinguished_from_nothing() {
	assert one('*').parts[0].universal
	assert !one('p').parts[0].universal
	assert one('*.a').parts[0].universal && one('*.a').parts[0].classes == ['a']
}

fn test_a_type_selector_comes_first_and_only_once() {
	// `b.a` is an element with a class and is perfectly valid; `.a b` is two
	// compounds. What must not happen is a second type selector in one compound,
	// which would need `a` and `b` to be adjacent without a combinator.
	s := one('b.a')
	assert s.parts[0].tag == 'b'
	assert s.parts[0].classes == ['a']
	assert one('.ab').parts[0].classes == ['ab']
	assert one('.a b').parts.len == 2
}

fn test_combinators() {
	desc := one('a b')
	assert desc.parts.len == 2
	assert desc.combinators[1] == .descendant

	child := one('a > b')
	assert child.parts.len == 2
	assert child.combinators[1] == .child

	adj := one('a + b')
	assert adj.combinators[1] == .adjacent_sibling

	gen := one('a ~ b')
	assert gen.combinators[1] == .general_sibling
}

fn test_whitespace_around_a_combinator_is_allowed() {
	assert one('a>b').parts.len == 2
	assert one('a > b').parts.len == 2
	assert one('a  >  b').combinators[1] == .child
}

fn test_the_subject_is_the_last_compound() {
	// `div p` asks about a `p`; the `div` is the constraint. Getting this
	// backwards produces a tree that renders and a cascade that does nothing.
	s := one('div.main > p')
	assert s.parts[1].tag == 'p'
	assert s.parts[0].tag == 'div'
	assert s.parts[0].classes == ['main']
}

fn test_a_selector_list() {
	list := must_parse('a, b , c')
	assert list.len == 3
	assert list[0].parts[0].tag == 'a'
	assert list[2].parts[0].tag == 'c'
}

fn test_an_invalid_selector_invalidates_the_whole_list() {
	// Selectors 3 says one bad selector drops every rule in the list, and that is
	// what a browser does. Returning a partial list would be the alternative and it
	// is wrong: `a, b[` would then apply `a`.
	assert parse('a, b[') == none
	assert parse('a, >b') == none
	assert parse('a, b c d') != none
}

fn test_empty_input_is_not_a_selector() {
	assert parse('') == none
	assert parse('   ') == none
	assert parse(',') == none
}

struct AttrCase {
	src  string
	op   AttrOp
	want string
}

fn test_attribute_operators() {
	cases := [
		AttrCase{ src: '[a]', op: .exists, want: '' },
		AttrCase{ src: '[a=b]', op: .equals, want: 'b' },
		AttrCase{ src: '[a~=b]', op: .includes, want: 'b' },
		AttrCase{ src: '[a|=b]', op: .dash_match, want: 'b' },
		AttrCase{ src: '[a^=b]', op: .prefix, want: 'b' },
		AttrCase{ src: '[a$=b]', op: .suffix, want: 'b' },
		AttrCase{ src: '[a*=b]', op: .substring, want: 'b' },
	]
	for c in cases {
		s := one(c.src)
		assert s.parts[0].attrs.len == 1
		assert s.parts[0].attrs[0].op == c.op
		assert s.parts[0].attrs[0].value == c.want
	}
}

fn test_attribute_value_may_be_quoted_a_number_or_an_ident() {
	assert one('[a="1"]').parts[0].attrs[0].value == '1'
	assert one('[a=1]').parts[0].attrs[0].value == '1'
	assert one('[a=b]').parts[0].attrs[0].value == 'b'
	assert one("[a='b']").parts[0].attrs[0].value == 'b'
}

fn test_attribute_case_insensitive_flag() {
	assert !one('[a=b]').parts[0].attrs[0].case_insensitive
	assert one('[a=b i]').parts[0].attrs[0].case_insensitive
	assert one('[a=b I]').parts[0].attrs[0].case_insensitive
	assert !one('[a=b s]').parts[0].attrs[0].case_insensitive
	assert parse('[a=b x]') == none
}

fn test_an_attribute_without_a_closing_bracket_is_invalid() {
	assert parse('[a') == none
	assert parse('[a=b') == none
	assert parse('[=b]') == none
}

fn test_a_hash_that_is_not_an_ident_is_not_an_id_selector() {
	assert one('#main').parts[0].id == 'main'
	assert parse('#123') == none
}

fn test_pseudo_classes() {
	names := [
		':hover',
		':focus',
		':active',
		':link',
		':visited',
		':checked',
		':disabled',
		':enabled',
		':root',
		':empty',
		':first-child',
		':last-child',
		':only-child',
		':first-of-type',
		':last-of-type',
		':only-of-type',
	]
	for name in names {
		s := one('p' + name)
		assert s.parts[0].pseudo_classes.len == 1
		assert s.parts[0].tag == 'p'
	}
}

fn test_pseudo_class_names_are_case_insensitive() {
	assert one('p:FIRST-CHILD').parts[0].pseudo_classes[0].kind == .first_child
}

fn test_an_unknown_pseudo_class_invalidates_the_selector() {
	// `:has` and `:is` are Selectors Level 4 and are Phase 3 work. Rejecting them
	// drops the rule, which is what a browser does for a pseudo-class it does not
	// know, and it is better than matching them unconditionally.
	assert parse('p:has(a)') == none
	assert parse('p:is(a)') == none
	assert parse('p::before') != none
	assert parse('p:before') != none
}

fn test_pseudo_elements_are_kept_and_end_the_compound() {
	s := one('p::before')
	assert s.parts[0].pseudo_element == 'before'
	// `p::before span` is two compounds, so the pseudo-element must not swallow
	// what follows it.
	s2 := one('p::before span')
	assert s2.parts.len == 2
	assert s2.parts[0].pseudo_element == 'before'
	assert s2.parts[1].tag == 'span'
}

fn test_legacy_pseudo_elements_may_use_one_colon() {
	assert one('p:before').parts[0].pseudo_element == 'before'
	assert one('p::after').parts[0].pseudo_element == 'after'
	assert one('p:first-line').parts[0].pseudo_element == 'first-line'
	assert one('p:first-letter').parts[0].pseudo_element == 'first-letter'
}

fn test_not_parses_a_nested_selector_list() {
	s := one('p:not(.a)')
	assert s.parts[0].pseudo_classes[0].kind == .negation
	assert s.parts[0].pseudo_classes[0].inner.len == 1
	assert s.parts[0].pseudo_classes[0].inner[0].parts[0].classes == ['a']
	assert one('p:not(.a, #b)').parts[0].pseudo_classes[0].inner.len == 2
	assert one('p:not(div > a)').parts[0].pseudo_classes[0].inner[0].parts.len == 2
}

fn test_an_invalid_argument_to_not_invalidates_the_selector() {
	assert parse('p:not()') == none
	assert parse('p:not(.a') == none
	assert parse('p:not(>)') == none
}

struct NthCase {
	src  string
	want Nth
}

fn test_nth_child_forms() {
	cases := [
		NthCase{ src: 'odd', want: Nth{ a: 2, b: 1 } },
		NthCase{ src: 'even', want: Nth{ a: 2, b: 0 } },
		NthCase{ src: 'n', want: Nth{ a: 1, b: 0 } },
		NthCase{ src: '-n', want: Nth{ a: -1, b: 0 } },
		NthCase{ src: '+n', want: Nth{ a: 1, b: 0 } },
		NthCase{ src: '2n', want: Nth{ a: 2, b: 0 } },
		NthCase{ src: '-3n', want: Nth{ a: -3, b: 0 } },
		NthCase{ src: '2n+1', want: Nth{ a: 2, b: 1 } },
		NthCase{ src: '2n - 1', want: Nth{ a: 2, b: -1 } },
		NthCase{ src: '-n+3', want: Nth{ a: -1, b: 3 } },
		NthCase{ src: '3', want: Nth{ a: 0, b: 3 } },
		NthCase{ src: '-3', want: Nth{ a: 0, b: -3 } },
		NthCase{ src: '+3', want: Nth{ a: 0, b: 3 } },
	]
	for c in cases {
		s := one('li:nth-child(${c.src})')
		assert s.parts[0].pseudo_classes.len == 1
		assert s.parts[0].pseudo_classes[0].kind == .nth_child
		assert s.parts[0].pseudo_classes[0].nth == c.want
	}
}

fn test_nth_last_child_and_nth_of_type() {
	assert one('li:nth-last-child(2n)').parts[0].pseudo_classes[0].kind == .nth_last_child
	assert one('li:nth-of-type(2n)').parts[0].pseudo_classes[0].kind == .nth_of_type
	assert one('li:nth-of-type(odd)').parts[0].pseudo_classes[0].nth == Nth{2, 1}
}

fn test_an_invalid_nth_invalidates_the_selector() {
	assert parse('li:nth-child()') == none
	assert parse('li:nth-child(2x)') == none
	assert parse('li:nth-child(2n+)') == none
	assert parse('li:nth-child(2n+1') == none
}

fn test_lang() {
	assert one('p:lang(en)').parts[0].pseudo_classes[0].kind == .lang
	assert one('p:lang(en)').parts[0].pseudo_classes[0].word == 'en'
	assert parse('p:lang()') == none
}

fn test_specificity_of_the_simple_forms() {
	assert must_parse('p').specificity() == Specificity{0, 0, 1}
	assert must_parse('*').specificity() == Specificity{0, 0, 0}
	assert must_parse('.a').specificity() == Specificity{0, 1, 0}
	assert must_parse('#a').specificity() == Specificity{1, 0, 0}
	assert must_parse('[a]').specificity() == Specificity{0, 1, 0}
	assert must_parse('p.a#b[c]').specificity() == Specificity{1, 2, 1}
	assert must_parse('p::before').specificity() == Specificity{0, 0, 2}
	assert must_parse('div p').specificity() == Specificity{0, 0, 2}
}

fn test_specificity_of_not_includes_its_argument() {
	assert must_parse('p:not(.a)').specificity() == Specificity{0, 2, 1}
	// The negation is not free: `:not(#a)` is an id selector for cascade
	// purposes and must outrank `.b`.
	assert must_parse('p:not(#a)').specificity() == Specificity{1, 1, 1}
	notted := must_parse('p:not(#a)').specificity()
	plain := must_parse('.b').specificity()
	assert notted.cmp(plain) > 0
}

fn test_specificity_compares_lexicographically() {
	assert must_parse('#a').specificity().cmp(must_parse('.b.c').specificity()) > 0
	assert must_parse('.a.b.c').specificity().cmp(must_parse('p q r').specificity()) > 0
	assert must_parse('p').specificity().cmp(must_parse('p').specificity()) == 0
	assert must_parse('.a').specificity().cmp(must_parse('.b').specificity()) == 0
}

fn test_specificity_pack_distinguishes_triples() {
	mut seen := map[u64]bool{}
	triples := [
		Specificity{0, 0, 0},
		Specificity{0, 0, 1},
		Specificity{0, 1, 0},
		Specificity{1, 0, 0},
		Specificity{0, 0, 65535},
		Specificity{0, 65535, 65535},
		Specificity{65535, 65535, 65535},
	]
	for t in triples {
		assert !seen[t.pack()]
		seen[t.pack()] = true
	}
}

fn test_specificity_pack_caps_rather_than_wrapping() {
	// Without a cap, a rule with 65536 type selectors would pack to the same
	// number as one with none, and the cascade would merge them.
	assert Specificity{0, 0, 70000}.pack() == Specificity{0, 0, 65535}.pack()
	assert Specificity{70000, 0, 0}.pack() != Specificity{0, 0, 0}.pack()
}

fn test_escapes_in_a_selector_are_resolved() {
	// The CSS tokenizer resolves them, so a selector written with an escape
	// matches the same element as the plain one.
	assert one('#\\6d ain').parts[0].id == 'main'
	assert one('.\\63 lass').parts[0].classes == ['class']
}

fn test_persian_class_and_tag_names_parse() {
	// Non-ASCII code points in the CSS ident set are ordinary characters to the
	// tokenizer, and this project renders Persian pages.
	assert one('.کلاس').parts[0].classes == ['کلاس']
	assert one('بخش').parts[0].tag == 'بخش'
}

fn test_the_selectors_real_pages_use_all_parse() {
	for src in [
		'body > div.container#main.wide > ul.menu > li.item > a[href^="https"]:hover',
		'html body div p, html body div span',
		'a:not([href]), a[href=""]',
		'input[type=checkbox]:checked + label',
		'table tr:nth-child(2n+1) td',
		':root',
		'p:first-child',
		'* + *',
	] {
		assert parse(src) != none
	}
}

// The specificity of a selector *list* is its most specific alternative, not the sum.
//
// The sum is what this engine computed first, and it is wrong in a way that shows on
// every stylesheet: the user-agent sheet's `html, body, div, p, h1, h2, ... { display:
// block }` would arrive at a specificity of thirty type selectors and beat any
// single-selector rule that follows it. That is exactly how `li { display: list-item }`
// came to be overruled by the block list, and every list in the engine lost its marker.
fn test_specificity_of_a_list_is_its_most_specific_alternative() {
	assert must_parse('p, div').specificity() == Specificity{0, 0, 1}
	assert must_parse('p, div, a').specificity() == Specificity{0, 0, 1}
	// The most specific one wins, whichever position it is in: an id anywhere in the
	// list lifts the whole rule's specificity, and a type selector beside it does not
	// drag it down.
	assert must_parse('#a, p').specificity() == Specificity{1, 0, 0}
	assert must_parse('p, #a').specificity() == Specificity{1, 0, 0}
	assert must_parse('p, div .a, span').specificity() == Specificity{0, 1, 1}
}
