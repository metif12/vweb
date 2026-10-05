module selector

import engine.tree
import net.html

// Matching a selector against a document.
//
// The document tree is `vlib/net/html`'s, so this module consumes `html.Tag` and
// adds nothing of its own to it. That is the point of decision 6 in
// docs/ARCHITECTURE.md: a parallel DOM would be a second implementation of one
// concept, and only one of the two would improve. The few questions every pass
// asks about a node live in engine/tree.
//
// Every entry point takes the element being tested and answers whether it is the
// *subject* of the selector. `div p` asks about a `p`, so it starts at the `p` and
// walks up; nothing here ever walks down the tree from a candidate ancestor,
// which is both the fast direction and the one that gets the semantics right.
//
// A pseudo-class that depends on input -- `:hover`, `:focus`, `:active` -- is
// answered by `State`, which the caller fills in explicitly. That is what makes
// rendering deterministic: a golden image may depend on hover, but only because
// something said so.
//
// The sibling helpers in engine/tree scan the parent's `children` rather than
// following `prev` and `next`. Following the links is O(1) per step, but it would
// tie every answer here to a chain that a text-heavy document can leave
// inconsistent, and a wrong answer is a silently unmatched selector rather than a
// crash.

pub struct State {
pub:
	hovered &html.Tag = unsafe { nil }
	focused &html.Tag = unsafe { nil }
	active  &html.Tag = unsafe { nil }
	visited map[string]bool
}

pub fn (l SelectorList) matches(el &html.Tag, state &State) bool {
	for s in l {
		if s.matches(el, state) {
			return true
		}
	}
	return false
}

// matches reports whether el is the subject of this complex selector.
pub fn (s ComplexSelector) matches(el &html.Tag, state &State) bool {
	if !s.parts[s.parts.len - 1].matches(el, state) {
		return false
	}
	return s.matches_at(el, s.parts.len - 1, state)
}

// match_descendant walks ancestors looking for one that satisfies the part before
// the current index, which is what `a b c` means when asked about a `c`.
fn match_descendant(el &html.Tag, s ComplexSelector, i int, state &State) ?&html.Tag {
	mut p := tree.parent_element(el) or { return none }
	for {
		if s.matches_at(p, i - 1, state) {
			return p
		}
		p = tree.parent_element(p) or { return none }
	}
}

// match_sibling walks backwards over previous elements for the general sibling
// combinator.
fn match_sibling(el &html.Tag, s ComplexSelector, i int, state &State) ?&html.Tag {
	mut p := tree.previous_element(el) or { return none }
	for {
		if s.matches_at(p, i - 1, state) {
			return p
		}
		p = tree.previous_element(p) or { return none }
	}
}

// matches_at is matches with an explicit index into the parts, so the recursive
// steps do not restart the walk at the subject.
fn (s ComplexSelector) matches_at(el &html.Tag, i int, state &State) bool {
	if !s.parts[i].matches(el, state) {
		return false
	}
	if i == 0 {
		return true
	}
	next := match s.combinators[i] {
		.child { tree.parent_element(el) or { return false } }
		.descendant { match_descendant(el, s, i, state) or { return false } }
		.adjacent_sibling { tree.previous_element(el) or { return false } }
		.general_sibling { match_sibling(el, s, i, state) or { return false } }
	}
	return s.matches_at(next, i - 1, state)
}

// matches reports whether one element satisfies every simple selector in the
// compound.
pub fn (c CompoundSelector) matches(el &html.Tag, state &State) bool {
	if !tree.is_element(el) {
		return false
	}
	if c.tag != '' && el.name != c.tag {
		return false
	}
	if c.id != '' && el.attributes['id'] != c.id {
		return false
	}
	for cls in c.classes {
		if !el.class_set.exists(cls) {
			return false
		}
	}
	for a in c.attrs {
		if !a.matches(el) {
			return false
		}
	}
	for p in c.pseudo_classes {
		if !p.matches(el, state) {
			return false
		}
	}
	return true
}

pub fn (a AttrSelector) matches(el &html.Tag) bool {
	// Presence is tested with `in` and not by reading the value, because a
	// valueless attribute such as `disabled` is stored as an empty string and
	// `[disabled]` must match it.
	if a.name !in el.attributes {
		return false
	}
	if a.op == .exists {
		return true
	}
	mut want := a.value
	mut got := el.attributes[a.name]
	if a.case_insensitive {
		want = want.to_lower()
		got = got.to_lower()
	}
	return match a.op {
		.exists { true }
		.equals { got == want }
		// `~=` matches a whole word in a space-separated list, so it is not a
		// substring test: `class~="a"` must not match `class="ab"`.
		.includes { contains_word(got, want) }
		// `|=` matches the whole value or a value followed by a hyphen, which is
		// what makes it right for language subtags like `en-GB`.
		.dash_match {
			got == want || (got.len > want.len && got.starts_with(want) && got[want.len] == `-`)
		}
		.prefix { got.starts_with(want) }
		.suffix { got.ends_with(want) }
		.substring { want != '' && got.contains(want) }
	}
}

// contains_word reports whether want is one of the space-separated words in got.
// The separators CSS uses are space, tab and newline, and two of them in a row do
// not make an empty word.
fn contains_word(got string, want string) bool {
	if want == '' {
		return false
	}
	mut start := 0
	mut i := 0
	for i <= got.len {
		if i == got.len || got[i] == ` ` || got[i] == `\t` || got[i] == `\n` {
			if i > start && got[start..i] == want {
				return true
			}
			start = i + 1
		}
		i++
	}
	return false
}

pub fn (p PseudoClass) matches(el &html.Tag, state &State) bool {
	return match p.kind {
		.hover { el == state.hovered }
		.focus { el == state.focused }
		.active { el == state.active }
		// `:link` is a property of the element, not of input, so it needs no
		// state. `:visited` does, and with no history recorded nothing is visited.
		.link { el.attributes['href'] != '' }
		.visited { state.visited.len > 0 && el.attributes['href'] in state.visited }
		.checked { has_checked_state(el) }
		.disabled { has_disabled_state(el) }
		.enabled { !has_disabled_state(el) && is_form_control(el) }
		.root { tree.parent_element(el) == unsafe { nil } }
		// Selectors Level 4: an element with only whitespace inside counts as empty.
		// Level 3 said otherwise and browsers changed, so this follows the browsers.
		.empty { tree.element_child_count(el) == 0 && el.text().trim_space() == '' }
		.first_child { tree.index_among_siblings(el) == 0 }
		.last_child { tree.index_among_siblings(el) == tree.element_sibling_count(el) - 1 }
		.only_child { tree.element_sibling_count(el) == 1 }
		.first_of_type { tree.index_among_siblings_of_type(el) == 0 }
		.last_of_type {
			tree.index_among_siblings_of_type(el) == tree.sibling_count_of_type(el) - 1
		}
		.only_of_type { tree.sibling_count_of_type(el) == 1 }
		// The three positional forms are one-based, as CSS defines them: `:nth-child(1)`
		// is the first element, not the zeroth. Getting this wrong turns every
		// odd/even rule on the web into its complement.
		.nth_child { nth_matches(tree.index_among_siblings(el) + 1, p.nth) }
		.nth_last_child {
			nth_matches(tree.element_sibling_count(el) - tree.index_among_siblings(el), p.nth)
		}
		.nth_of_type { nth_matches(tree.index_among_siblings_of_type(el) + 1, p.nth) }
		.negation { !p.inner.matches(el, state) }
		.lang { element_lang(el).starts_with(p.word) }
	}
}

// nth_matches implements `an+b` against a one-based index. The spec says n is a
// *non-negative* integer, which is what makes `-n+2` mean the first two elements
// rather than the first two plus every element after them. That restriction is the
// whole reason the `li:nth-child(-n+3)` idiom for "the first three" works.
fn nth_matches(index int, n Nth) bool {
	if n.a == 0 {
		return index == n.b
	}
	// index must equal a*k + b for a non-negative integer k, so index - b must be
	// divisible by a and the quotient must not be below zero. The remainder test does
	// not care about the sign; the quotient's does.
	if (index - n.b) % n.a != 0 {
		return false
	}
	return (index - n.b) / n.a >= 0
}

fn is_form_control(el &html.Tag) bool {
	return match el.name {
		'button', 'input', 'select', 'textarea', 'option', 'optgroup', 'fieldset' { true }
		else { false }
	}
}

// has_checked_state reports whether the element is a checkbox or radio that
// carries the `checked` attribute. The engine has no form state, so nothing can
// be checked by interaction and a rule written for `:checked` only ever applies to
// markup that says so.
fn has_checked_state(el &html.Tag) bool {
	if el.name != 'input' {
		return false
	}
	typ := (el.attributes['type'] or { 'text' }).to_lower()
	if typ != 'checkbox' && typ != 'radio' {
		return false
	}
	return 'checked' in el.attributes
}

fn has_disabled_state(el &html.Tag) bool {
	if !is_form_control(el) {
		return false
	}
	if 'disabled' in el.attributes {
		return true
	}
	// A control inside a disabled fieldset is disabled without carrying the
	// attribute, and a stylesheet that says `button:disabled` expects it.
	return has_disabled_ancestor(el)
}

fn has_disabled_ancestor(el &html.Tag) bool {
	mut p := tree.parent_element(el) or { return false }
	for {
		if p.name == 'fieldset' {
			if 'disabled' in p.attributes {
				return true
			}
		}
		p = tree.parent_element(p) or { return false }
	}
}

// element_lang returns the element's language, from its own `lang` or the nearest
// ancestor that has one, as `:lang()` requires.
fn element_lang(el &html.Tag) string {
	if l := el.attributes['lang'] {
		return l.to_lower()
	}
	mut cur := tree.parent_element(el) or { return '' }
	for {
		if l := cur.attributes['lang'] {
			return l.to_lower()
		}
		cur = tree.parent_element(cur) or { return '' }
	}
}
