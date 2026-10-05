module selector

// The selector grammar's data model, following Selectors Level 3.
//
// A complex selector is a list of compound selectors joined by combinators, and a
// selector list is a list of complex selectors joined by commas. Those two levels
// are the whole grammar; everything else is a detail of what a compound selector
// can contain.
//
// The subject is the rightmost compound. `div p` matches a `p` somewhere inside a
// `div`, and it is the `p` that is being asked about -- so the matcher walks
// right to left and the cascade asks each element whether it is the subject. This
// is worth stating because getting it backwards is the classic selector bug: it
// produces a tree that renders and a cascade that silently does nothing.

type SelectorList = []ComplexSelector

// Combinator is how a compound selector relates to the one before it.
pub enum Combinator {
	descendant
	child
	adjacent_sibling
	general_sibling
}

// ComplexSelector is `a b > c + d`. parts[0] is the subject. combinators[0] is
// always .descendant and never read, because there is nothing before the subject
// for it to relate; combinators[i] joins parts[i-1] to parts[i].
pub struct ComplexSelector {
pub:
	parts       []CompoundSelector
	combinators []Combinator
}

// CompoundSelector is a run of simple selectors with no combinator between them,
// such as `a.foo#bar[baz]`. Every one of them must match the same element.
pub struct CompoundSelector {
pub:
	// tag is the element name to match, empty for none. HTML element names are
	// matched case-insensitively and the document tree has already lower-cased
	// them, so the comparison is exact.
	tag            string
	id             string
	classes        []string
	attrs          []AttrSelector
	pseudo_classes []PseudoClass
	// pseudo_element is empty for none. Phase 1 accepts and records it so a
	// stylesheet parses; nothing generates one yet.
	pseudo_element string
	// universal records that the compound was written as `*`, which matches
	// anything but is not the same as an empty compound: `.a` and `*.a` are
	// different inputs even though they match the same elements.
	universal bool
}

// AttrSelector is one `[name op "value"]` test.
pub struct AttrSelector {
pub:
	name  string
	op    AttrOp
	value string
	// case_insensitive is the `i` flag. It is honoured for the value comparison
	// and ignored for `exists`, where there is no value to compare.
	case_insensitive bool
}

pub enum AttrOp {
	exists
	equals
	includes
	dash_match
	prefix
	suffix
	substring
}

// PseudoKind is which pseudo-class this is. It is a separate enum from PseudoClass
// rather than a sum type because V 0.5.2 cannot construct an enum variant with a
// payload (`Pseudo.nth_child(x)` is a compile error), and because three variants
// share the same payload type -- `nth_child`, `nth_last_child` and `nth_of_type`
// differ only in how they index, so a type-based sum type could not tell them
// apart at all.
pub enum PseudoKind {
	// The states an explicit input can put an element in. ARCHITECTURE 4 requires
	// that rendering depends only on explicit input, which is what makes these
	// testable at all: a golden image may depend on hover, but only because
	// something set it.
	hover
	focus
	active
	link
	visited
	checked
	disabled
	enabled
	root
	empty
	first_child
	last_child
	only_child
	first_of_type
	last_of_type
	only_of_type
	nth_child
	nth_last_child
	nth_of_type
	negation
	lang
}

// PseudoClass is one pseudo-class selector. `nth`, `inner` and `word` are read
// only by the matching PseudoKind, and a PseudoClass with the wrong one set is
// rejected at parse time rather than at match time.
pub struct PseudoClass {
pub:
	kind PseudoKind
	nth  Nth
	// inner is the argument of `:not()`, a selector list so that `:not(a, b)`
	// parses; it is a list in a struct rather than a slice payload in a sum type
	// for the same reason as PseudoKind above.
	inner SelectorList
	word  string
}

// Nth is an `an+b` step, as in `:nth-child(2n+1)`.
pub struct Nth {
pub:
	a int
	b int
}

// Specificity is the (a, b, c) triple of Selectors Level 3: a counts id
// selectors, b counts class, attribute and pseudo-class selectors, and c counts
// type selectors and pseudo-elements. Two are compared as a lexicographic triple,
// which is why this is a function and not a subtraction.
pub struct Specificity {
pub:
	ids     int
	classes int
	types   int
}

// cmp orders two specificities, returning a negative number, zero or a positive
// number in the usual way.
pub fn (s Specificity) cmp(o Specificity) int {
	if s.ids != o.ids {
		return if s.ids < o.ids { -1 } else { 1 }
	}
	if s.classes != o.classes {
		return if s.classes < o.classes { -1 } else { 1 }
	}
	if s.types != o.types {
		return if s.types < o.types { -1 } else { 1 }
	}
	return 0
}

// pack flattens a specificity into a single integer, for use as a map key. V's
// maps reject struct keys, and the cascade wants to group declarations by
// specificity. The fields are capped first so two different triples cannot pack to
// the same number -- an unbounded `classes` count would let a rule with 70 classes
// collide with one that has 0 types and 6 more classes.
pub fn (s Specificity) pack() u64 {
	return u64(clamp16(s.ids)) << 32 | u64(clamp16(s.classes)) << 16 | u64(clamp16(s.types))
}

fn clamp16(v int) int {
	return if v > 0xffff { 0xffff } else { v }
}

fn (s Specificity) add(other Specificity) Specificity {
	return Specificity{s.ids + other.ids, s.classes + other.classes, s.types + other.types}
}

// specificity adds up the specificity of every complex selector in the list, which
// is the specificity of the whole rule.
pub fn (l SelectorList) specificity() Specificity {
	mut ids := 0
	mut classes := 0
	mut types := 0
	for s in l {
		t := s.specificity()
		ids += t.ids
		classes += t.classes
		types += t.types
	}
	return Specificity{ ids: ids, classes: classes, types: types }
}

// specificity is the sum over the complex selector's compounds.
pub fn (s ComplexSelector) specificity() Specificity {
	mut ids := 0
	mut classes := 0
	mut types := 0
	for p in s.parts {
		t := p.specificity()
		ids += t.ids
		classes += t.classes
		types += t.types
	}
	return Specificity{ ids: ids, classes: classes, types: types }
}

pub fn (c CompoundSelector) specificity() Specificity {
	mut classes := c.classes.len + c.attrs.len
	mut ids := 0
	if c.id != '' {
		ids = 1
	}
	// A pseudo-class contributes itself plus whatever its argument carries, which
	// is why `:not(#a)` outranks `.b`.
	for p in c.pseudo_classes {
		t := p.specificity()
		ids += t.ids
		classes += t.classes
	}
	mut types := 0
	if c.tag != '' {
		types++
	}
	// A pseudo-element counts as a type selector, so `p::before` is two of them.
	if c.pseudo_element != '' {
		types++
	}
	return Specificity{ ids: ids, classes: classes, types: types }
}

// specificity of a pseudo-class is one for itself plus that of its argument. The
// negation is not free: `:not(#a)` is an id selector for cascade purposes.
pub fn (p PseudoClass) specificity() Specificity {
	if p.kind == .negation {
		inner := p.inner.specificity()
		return Specificity{ ids: inner.ids, classes: inner.classes + 1, types: 0 }
	}
	return Specificity{}
}
