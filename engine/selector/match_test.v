module selector

import engine.tree
import net.html

// The documents here are built by hand rather than parsed from HTML.
//
// The point is not to avoid a dependency. It is that a matcher test should be
// about the matcher: when a test builds its tree out of markup, a bug in the tree
// builder shows up as a failure here, and the two live in different repositories
// with different owners. Measured on 2026-10-04: the `net/html` in the V tree
// this project currently builds against nests `<div id="a"></div><div id="b"> </div>`
// wrongly -- `div#a` came out with two element children and the text of `div#c` --
// which is exactly the class of bug the rewritten tree builder fixes. A hand-built
// tree says what the matcher was handed, so a failure names the matcher.
//
// The parser-to-matcher path is covered by the page golden tests, once the
// toolchain question in env.ps1 is settled.

fn el(name string, id string, classes ...string) &html.Tag {
	mut node := &html.Tag{ name: name }
	if id != '' {
		node.attributes['id'] = id
	}
	for c in classes {
		node.class_set.add(c)
	}
	return node
}

// attach makes parent own the given children, which is what sets the children list
// and each child's back-pointer.
//
// `mut parent` on the parameter, not `mut p := parent` inside the body. The second
// form copies the Tag: the children land on the copy, the caller's node keeps an
// empty list, and V reports it as "cannot have a mutable reference to an immutable
// object". That version passed every test in this file, because the matcher only ever
// reads `parent.children` and the copy had those too -- which is why this is a
// comment and not a test. The same shape in engine/display/display_test.v produced an
// empty tree and a nil box, which is what identified it.
//
// The children are copied into a local mutable array first because V will not write
// through a loop variable over an immutable slice, and rejects `mut` on a variadic
// parameter outright.
// wrap creates a parent element and attaches the children to it. Most tests here
// build a parent that exists only to be selected on, and giving them a local plus an
// ttach call each would be two lines of noise per test.
fn wrap(name string, children ...&html.Tag) &html.Tag {
	mut parent := el(name, '')
	attach(mut parent, ...children)
	return parent
}

fn attach(mut parent &html.Tag, children ...&html.Tag) {
	mut kids := []&html.Tag{}
	for child in children {
		kids << child
	}
	mut i := 0
	for i < kids.len {
		mut c := kids[i]
		parent.children << c
		c.parent = parent
		c.position_in_parent = i
		i++
	}
}

// nodes_of returns every element in a hand-built tree, parents before children.
fn nodes_of(root &html.Tag) []&html.Tag {
	mut out := []&html.Tag{}
	mut stack := []&html.Tag{}
	stack << root
	for stack.len > 0 {
		cur := stack.pop()
		if cur != root && !tree.is_element(cur) {
			continue
		}
		out << cur
		mut i := cur.children.len
		for i > 0 {
			i--
			stack << cur.children[i]
		}
	}
	return out
}

fn count(nodes []&html.Tag, sel_text string) int {
	mut list := parse(sel_text) or { return -1 }
	state := &State{}
	mut n := 0
	for node in nodes {
		if list.matches(node, state) {
			n++
		}
	}
	return n
}

fn first(nodes []&html.Tag, sel_text string) &html.Tag {
	mut list := parse(sel_text) or { return unsafe { nil } }
	state := &State{}
	for node in nodes {
		if list.matches(node, state) {
			return node
		}
	}
	return unsafe { nil }
}

fn text_el(content string) &html.Tag {
	return &html.Tag{ name: 'text', content: content }
}

// --- type selectors ---------------------------------------------------------

fn test_a_type_selector_matches_every_element_of_that_name() {
	mut body := el('body', '')
	attach(mut body, el('p', ''), el('p', ''), el('span', ''))
	nodes := nodes_of(body)
	assert count(nodes, 'p') == 2
	assert count(nodes, 'span') == 1
	assert count(nodes, 'div') == 0
}

fn test_the_subject_is_the_element_asked_about() {
	// `div p` asks about a `p` that has a `div` above it. Matching it the other way
	// round -- asking about the `div` -- is the classic selector bug: it produces a
	// tree that renders and a cascade that does nothing.
	mut p := el('p', '')
	wrap('div', p)
	nodes := nodes_of(p.parent)
	assert count(nodes, 'div p') == 1
	assert count(nodes, 'p div') == 0

	mut inner := el('p', '')
	mut section := el('section', '')
	attach(mut section, el('div', ''), el('span', ''), inner)
	assert count(nodes_of(section), 'section p') == 1
}

fn test_descendant_reaches_through_any_depth() {
	mut p := el('p', '')
	mut inner := el('span', '')
	attach(mut inner, p)
	mut middle := el('div', '')
	attach(mut middle, el('em', ''), inner)
	mut outer := el('section', '')
	attach(mut outer, middle)
	nodes := nodes_of(outer)
	assert count(nodes, 'section p') == 1
	assert count(nodes, 'div p') == 1
	assert count(nodes, 'span p') == 1
	assert count(nodes, 'em p') == 0
}

// --- combinators ------------------------------------------------------------

fn test_child_combinator_is_the_direct_parent_only() {
	mut shallow_div := el('div', '')
	attach(mut shallow_div, el('p', ''))
	mut inner := el('span', '')
	attach(mut inner, el('p', ''))
	mut deep_div := el('div', '')
	attach(mut deep_div, inner)
	mut body := el('body', '')
	attach(mut body, shallow_div, deep_div)
	nodes := nodes_of(body)
	assert count(nodes, 'div > p') == 1
	assert count(nodes, 'div p') == 2
	assert count(nodes, 'span > p') == 1
}

fn test_adjacent_sibling() {
	mut list := el('ul', '')
	mut a := el('li', '')
	mut b := el('li', '')
	mut c := el('li', '')
	attach(mut list, a, b, c)
	nodes := nodes_of(list)
	assert count(nodes, 'li + li') == 2
	assert count(nodes, 'li ~ li') == 2
	assert count(nodes, 'li:first-child + li') == 1
	assert count(nodes, 'li:last-child + li') == 0
}

fn test_general_sibling_skips_over_other_names() {
	mut div := el('div', '')
	attach(mut div, el('a', ''), el('b', ''), el('a', ''))
	nodes := nodes_of(div)
	assert count(nodes, 'a ~ a') == 1
	assert count(nodes, 'a ~ b') == 1
	assert count(nodes, 'b ~ a') == 1
	assert count(nodes, 'a + b') == 1
	assert count(nodes, 'a + a') == 0
}

fn test_whitespace_text_runs_are_not_siblings() {
	// This is why the sibling helpers skip non-elements: a text run between every
	// pair of elements must not change what `:first-child` means.
	mut list := el('ul', '')
	mut a := el('li', '')
	mut b := el('li', '')
	attach(mut list, text_el('\n  '), a, text_el('\n  '), b, text_el('\n'))
	nodes := nodes_of(list)
	assert count(nodes, 'li:first-child') == 1
	assert first(nodes, 'li:first-child') == a
	assert count(nodes, 'li:last-child') == 1
	assert first(nodes, 'li:last-child') == b
	assert count(nodes, 'li') == 2
}

fn test_text_runs_never_match() {
	mut list := el('ul', '')
	attach(mut list, text_el('  '), el('li', ''))
	assert count(nodes_of(list), '*') == 2
}

// --- id, class, attribute ---------------------------------------------------

fn test_id_class_and_attribute_selectors() {
	mut main := el('div', 'main', 'a', 'b')
	mut other := el('div', 'other', 'b')
	main.attributes['data-x'] = '1'
	wrap('body', main, other)
	nodes := nodes_of(main.parent)
	assert count(nodes, '#main') == 1
	assert count(nodes, '.a') == 1
	assert count(nodes, '.b') == 2
	assert count(nodes, '.a.b') == 1
	assert count(nodes, '[data-x]') == 1
	assert count(nodes, '[data-x="1"]') == 1
	assert count(nodes, '[data-x="2"]') == 0
	assert count(nodes, 'div#main.a[data-x]') == 1
}

fn test_a_valueless_attribute_is_present() {
	// net/html stores `<input disabled>` as an empty string, so testing presence by
	// reading the value would silently reject it.
	mut inp := el('input', '')
	inp.attributes['disabled'] = ''
	wrap('body', inp)
	assert count(nodes_of(inp.parent), '[disabled]') == 1
	assert count(nodes_of(inp.parent), '[disabled=""]') == 1
	assert count(nodes_of(inp.parent), '[missing]') == 0
}

fn test_the_universal_selector_matches_every_element() {
	mut body := el('body', '')
	mut div := el('div', '')
	attach(mut div, el('p', ''), el('span', ''))
	attach(mut body, div)
	nodes := nodes_of(body)
	// body, div, p, span
	assert count(nodes, '*') == 4
	assert count(nodes, 'div *') == 2
	assert count(nodes, '* p') == 1
	assert count(nodes, 'body > div') == 1
}

// --- attribute operators ----------------------------------------------------

fn test_attribute_operators_against_real_values() {
	mut a := el('a', '')
	a.attributes['href'] = 'https://example.com/x'
	a.attributes['rel'] = 'nofollow noopener'
	a.attributes['lang'] = 'en-GB'
	a.attributes['title'] = 'hello world'
	mut b := el('a', '')
	b.attributes['href'] = '/local'
	wrap('div', a, b)
	nodes := nodes_of(a.parent)
	assert count(nodes, '[href^="https"]') == 1
	assert count(nodes, '[href$="local"]') == 1
	assert count(nodes, '[href*="example"]') == 1
	// `~=` matches a whole word, so it must not match a prefix of one.
	assert count(nodes, '[rel~="nofollow"]') == 1
	assert count(nodes, '[rel~="noopener"]') == 1
	assert count(nodes, '[rel~="no"]') == 0
	// `|=` matches the value or the value followed by a hyphen, which is what makes
	// it right for language subtags.
	assert count(nodes, '[lang|="en"]') == 1
	assert count(nodes, '[lang|="e"]') == 0
	assert count(nodes, '[lang|="en-GB"]') == 1
	assert count(nodes, '[title~="hello"]') == 1
	assert count(nodes, '[title~="lo wo"]') == 0
	assert count(nodes, '[title*="hello"]') == 1
}

fn test_attribute_selector_case_insensitive_flag() {
	mut d := el('div', '')
	d.attributes['title'] = 'Hello'
	wrap('body', d)
	nodes := nodes_of(d.parent)
	assert count(nodes, '[title="hello"]') == 0
	assert count(nodes, '[title="hello" i]') == 1
	assert count(nodes, '[title="Hello"]') == 1
}

// --- pseudo-classes ---------------------------------------------------------

fn test_not() {
	mut a := el('div', '', 'a')
	mut b := el('div', '', 'b')
	wrap('body', a, b)
	nodes := nodes_of(a.parent)
	assert count(nodes, 'div:not(.a)') == 1
	assert count(nodes, 'div:not(.a, .b)') == 0
	assert count(nodes, 'div:not(#nope)') == 2
	assert count(nodes, 'div:not(span)') == 2
	assert count(nodes, 'div:not(.a):not(.b)') == 0
}

fn test_root_matches_only_the_root_element() {
	mut root := el('html', '')
	mut body := el('body', '')
	mut div := el('div', '')
	attach(mut body, div)
	attach(mut root, body)
	nodes := nodes_of(root)
	assert count(nodes, ':root') == 1
	assert first(nodes, ':root') == root
}

fn test_empty_follows_selectors_level_four() {
	// Level 4 made an element with only whitespace inside `:empty` and browsers
	// followed. Level 3 did not.
	mut a := el('div', 'a')
	mut b := el('div', 'b')
	b.children << text_el(' ')
	mut c := el('div', 'c')
	c.children << text_el('x')
	mut d := el('div', 'd')
	attach(mut d, el('span', ''))
	wrap('body', a, b, c, d)
	nodes := nodes_of(a.parent)
	assert count(nodes, 'div#a:empty') == 1
	assert count(nodes, 'div#b:empty') == 1
	assert count(nodes, 'div#c:empty') == 0
	assert count(nodes, 'div#d:empty') == 0
}

fn test_positional_pseudo_classes() {
	mut list := el('ul', '')
	mut items := []&html.Tag{}
	for _ in 0 .. 5 {
		items << el('li', '')
	}
	attach(mut list, ...items)
	nodes := nodes_of(list)
	// One-based: `:nth-child(1)` is the first element, not the zeroth. Getting this
	// wrong turns every odd/even rule on the web into its complement.
	assert count(nodes, 'li:first-child') == 1
	assert count(nodes, 'li:last-child') == 1
	assert count(nodes, 'li:only-child') == 0
	assert count(nodes, 'li:nth-child(1)') == 1
	assert count(nodes, 'li:nth-child(3)') == 1
	assert count(nodes, 'li:nth-child(odd)') == 3
	assert count(nodes, 'li:nth-child(even)') == 2
	assert count(nodes, 'li:nth-child(2n)') == 2
	assert count(nodes, 'li:nth-child(2n+1)') == 3
	// n is non-negative in `an+b`, which is what makes the `-n+3` idiom for "the
	// first three" work.
	assert count(nodes, 'li:nth-child(-n+2)') == 2
	assert count(nodes, 'li:nth-child(-n+3)') == 3
	assert count(nodes, 'li:nth-child(n)') == 5
	assert count(nodes, 'li:nth-child(n+10)') == 0
	assert count(nodes, 'li:nth-last-child(1)') == 1
	assert count(nodes, 'li:nth-last-child(2)') == 1
}

fn test_only_child() {
	mut one := el('div', '')
	attach(mut one, el('p', ''))
	mut two := el('div', '')
	attach(mut two, el('p', ''), el('b', ''))
	wrap('body', one, two)
	nodes := nodes_of(one.parent)
	assert count(nodes, 'div:only-child p:only-child') == 0
	assert count(nodes, 'div p:only-child') == 1
}

fn test_of_type_counts_only_the_same_name() {
	// Interleaved names: `nth-of-type` must ignore the other one, while
	// `nth-child` must not.
	mut p1 := el('p', '')
	mut p2 := el('p', '')
	mut p3 := el('p', '')
	mut div := el('div', '')
	attach(mut div, p1, el('span', ''), p2, el('span', ''), p3)
	nodes := nodes_of(div)
	assert count(nodes, 'p:first-of-type') == 1
	assert first(nodes, 'p:first-of-type') == p1
	assert count(nodes, 'p:last-of-type') == 1
	assert first(nodes, 'p:last-of-type') == p3
	assert count(nodes, 'p:only-of-type') == 0
	assert count(nodes, 'p:nth-of-type(1)') == 1
	assert count(nodes, 'p:nth-of-type(2)') == 1
	assert first(nodes, 'p:nth-of-type(2)') == p2
	assert count(nodes, 'p:nth-of-type(odd)') == 2
	assert count(nodes, 'p:nth-child(3)') == 1
	assert count(nodes, 'p:nth-child(2)') == 0
}

fn test_link() {
	mut linked := el('a', '')
	linked.attributes['href'] = '/x'
	mut plain := el('a', '')
	wrap('div', linked, plain)
	assert count(nodes_of(linked.parent), 'a:link') == 1
}

fn test_checked_needs_the_attribute() {
	// The engine has no form state, so nothing can be checked by interaction and a
	// rule written for `:checked` only applies to markup that says so.
	mut unchecked := el('input', '')
	unchecked.attributes['type'] = 'checkbox'
	mut checked := el('input', '')
	checked.attributes['type'] = 'checkbox'
	checked.attributes['checked'] = ''
	mut typed := el('input', '')
	typed.attributes['type'] = 'text'
	wrap('body', unchecked, checked, typed)
	nodes := nodes_of(unchecked.parent)
	assert count(nodes, 'input:checked') == 1
	assert first(nodes, 'input:checked') == checked
	assert count(nodes, 'input:enabled') == 3
}

fn test_disabled_includes_a_disabled_fieldset() {
	// A control inside a disabled fieldset is disabled without carrying the
	// attribute, and a stylesheet that says `button:disabled` expects it to match.
	mut off := el('fieldset', '')
	off.attributes['disabled'] = ''
	attach(mut off, el('button', ''))
	mut on := el('fieldset', '')
	attach(mut on, el('button', ''))
	mut form := el('form', '')
	attach(mut form, off, on)
	nodes := nodes_of(form)
	assert count(nodes, 'button:disabled') == 1
	assert count(nodes, 'fieldset:disabled') == 1
	assert count(nodes, 'button:enabled') == 1
}

fn test_lang_falls_back_to_an_ancestor() {
	mut en_root := el('html', '')
	en_root.attributes['lang'] = 'en'
	mut p_en := el('p', '')
	mut div := el('div', '')
	div.attributes['lang'] = 'fa'
	mut p_fa := el('p', '')
	attach(mut div, p_fa)
	wrap('body', p_en, div)
	attach(mut en_root, p_en.parent)
	nodes := nodes_of(en_root)
	// `p_fa` has its own `lang` on the div above it and overrides the html one.
	assert count(nodes, 'p:lang(en)') == 1
	assert first(nodes, 'p:lang(en)') == p_en
	assert count(nodes, 'p:lang(fa)') == 1
	assert first(nodes, 'p:lang(fa)') == p_fa
	assert count(nodes, 'p:lang(fr)') == 0
	assert count(nodes, 'html:lang(en)') == 1
}

fn test_a_selector_list_matches_if_any_member_does() {
	mut a := el('div', '', 'a')
	mut b := el('div', '', 'b')
	mut plain := el('div', '')
	wrap('body', a, b, plain)
	nodes := nodes_of(a.parent)
	assert count(nodes, '.a, .b') == 2
	assert count(nodes, 'span, .a') == 1
}

// --- state-dependent --------------------------------------------------------

fn test_state_dependent_pseudo_classes_need_explicit_input() {
	// ARCHITECTURE 4 requires rendering to depend only on explicit input, so `:hover`
	// is answered by a State the caller fills in -- not by anything the matcher can
	// discover. With no state, nothing is hovered.
	mut one := el('a', '')
	one.attributes['href'] = '/1'
	mut two := el('a', '')
	two.attributes['href'] = '/2'
	wrap('div', one, two)
	mut list := parse('a:hover') or { panic('parse') }

	assert !list.matches(one, &State{})
	hovered := &State{ hovered: two }
	assert list.matches(two, hovered)
	assert !list.matches(one, hovered)

	// Rendering the same page twice with the same state must give the same answer,
	// which is the determinism a golden image depends on.
	again := &State{ hovered: two }
	assert list.matches(two, again)
}

fn test_focus_and_active() {
	mut a := el('button', '')
	mut b := el('button', '')
	wrap('body', a, b)
	focus := parse('button:focus') or { panic('parse') }
	active := parse('button:active') or { panic('parse') }
	st := &State{ focused: a, active: b }
	assert focus.matches(a, st)
	assert !focus.matches(b, st)
	assert active.matches(b, st)
	assert !active.matches(a, st)
}

fn test_visited_needs_history() {
	mut one := el('a', '')
	one.attributes['href'] = '/1'
	mut two := el('a', '')
	two.attributes['href'] = '/2'
	wrap('div', one, two)
	mut list := parse('a:visited') or { panic('parse') }
	assert !list.matches(one, &State{})
	st := &State{
		visited: {
			'/1': true
		}
	}
	assert list.matches(one, st)
	assert !list.matches(two, st)
}

// --- whole-selector shapes --------------------------------------------------

fn test_the_selectors_real_pages_use_all_match() {
	mut body := el('body', '')
	mut div := el('div', 'main', 'container', 'wide')
	mut menu := el('ul', '', 'menu')
	mut li := el('li', '', 'item')
	mut link := el('a', '')
	link.attributes['href'] = 'https://example.com'
	attach(mut li, link)
	attach(mut menu, li)
	attach(mut div, menu)
	mut body2 := el('body', '')
	attach(mut body2, div)
	attach(mut body, body2)
	nodes := nodes_of(body)
	assert count(nodes, 'body > div.container#main.wide > ul.menu > li.item > a[href^="https"]') == 1
	assert count(nodes, 'a:not([href])') == 0
	assert count(nodes, 'html body div p, html body div span') == 0
}

fn test_matching_is_repeatable() {
	// Same tree, same selector, twice: the answer must be identical. This is cheap
	// to assert and it is the property the cascade and the golden tests rest on.
	mut div := el('div', '', 'a')
	mut p := el('p', 'x')
	attach(mut div, p)
	mut span := el('span', '')
	wrap('body', div, el('p', ''))
	nodes := nodes_of(div.parent)
	for _ in 0 .. 3 {
		assert count(nodes, '.a p') == 1
		assert count(nodes, 'p, span') == 2
		assert count(nodes, '#x') == 1
	}
}

fn test_a_deep_tree_does_not_overflow_the_stack() {
	// The matcher walks ancestors iteratively and the sibling helpers scan rather
	// than recurse, so depth is a cost question and not a correctness one.
	mut top := el('div', '')
	mut cursor := top
	for _ in 0 .. 300 {
		mut next := el('div', '')
		attach(mut cursor, next)
		cursor = next
	}
	mut p := el('p', '')
	attach(mut cursor, p)
	nodes := nodes_of(top)
	assert count(nodes, 'p') == 1
	assert count(nodes, 'div p') == 1
	assert count(nodes, 'div > p') == 1
	assert count(nodes, 'div > div > p') == 1
}

fn test_non_ascii_class_and_tag_names_match() {
	// A Persian page is full of non-ASCII text and RTL markup, and nothing in the
	// matcher should care.
	mut main := el('div', '', 'متن')
	attach(mut main, el('p', ''), el('p', '', 'دوم'))
	wrap('body', main)
	nodes := nodes_of(main.parent)
	assert count(nodes, '.متن') == 1
	assert count(nodes, '.متن p') == 2
	assert count(nodes, 'p.دوم') == 1
}
