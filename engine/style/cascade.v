module style

import engine.css
import engine.selector
import engine.tree
import net.html

// The cascade: which declarations win, and what they compute to.
//
// CSS resolves a property in two steps and this module keeps them apart, because
// conflating them is the source of most cascade bugs. First, for one element and
// one property, find the winning *declaration*: origin and importance first, then
// specificity, then source order. Second, compute that declaration's value, which
// needs the parent and the root and not the other rules.
//
// Origins are ranked, not sorted by name, because `!important` inverts the order of
// all but the author origin. A UA `!important` declaration beats a normal author
// declaration, and an author `!important` one beats everything except a user
// `!important` one -- which this engine has no way to express, so the chain stops
// at three links.

pub enum Origin {
	user_agent
	// user_supplied is CSS's user origin: styles the reader has asked for, which
	// there is no way to express yet. It is in the chain because a future reader
	// preference must not have to renumber the origins above it.
	user_supplied
	author
}

// Declaration is one declaration together with where it came from and what it must
// beat. The three numbers are the whole cascade: origin-and-importance folded into
// one rank, specificity, and source order.
//
// `decl` is a named field rather than an embedded `css.Declaration` so that reading
// a name off the wrapper cannot be confused with reading one off the CSSOM, and so
// that the two never grow into the same field name by accident.
pub struct Declaration {
pub:
	decl        css.Declaration
	origin      Origin
	specificity selector.Specificity
	order       int
}

// rank is the origin-and-importance pair as a single comparable number. Higher
// wins. Folding the two into one number is what makes the comparison a plain `>`
// instead of a nested conditional, and the values are spaced so a future origin can
// be inserted without renumbering.
pub fn (d Declaration) rank() int {
	base := match d.origin {
		.user_agent { 0 }
		.user_supplied { 1 }
		.author { 2 }
	}
	if d.decl.important {
		// Importance flips every origin except the author's, which is the rule the
		// spec states as an exception rather than as a general inversion.
		return match d.origin {
			.author { 5 }
			.user_supplied { 3 }
			.user_agent { 4 }
		}
	}
	return base
}

// beats reports whether d should replace other for the same property.
pub fn (d Declaration) beats(other Declaration) bool {
	if d.rank() != other.rank() {
		return d.rank() > other.rank()
	}
	c := d.specificity.cmp(other.specificity)
	if c != 0 {
		return c > 0
	}
	return d.order > other.order
}

// Sheet is one stylesheet plus the origin its rules come from. Keeping the origin
// on the sheet rather than on each declaration is what makes `!important` in a UA
// sheet different from `!important` in an author's, which is the case that is easy
// to get backwards.
pub struct Sheet {
pub:
	style  css.Stylesheet
	origin Origin
}

// Engine applies a set of sheets to elements. One engine per document, so the
// parsed selectors are compiled once rather than per element.
pub struct Engine {
pub mut:
	sheets []Sheet
	// rules is every qualified rule from every sheet, in sheet order, with its
	// selector already parsed. A rule whose selector does not parse is dropped here,
	// which is what Selectors 3 requires: one invalid selector invalidates its rule.
	rules []CompiledRule
	// order_counter hands out the source-order numbers.
	order_counter int
}

struct CompiledRule {
	selector     selector.SelectorList
	declarations []Declaration
}

// new_engine compiles the sheets. This is the expensive half of the cascade and it
// happens once per document.
// new_engine compiles the sheets with no viewport.
//
// Media queries are then answered against a context that was never told a viewport,
// which means no dimensioned query matches: a `@media (min-width: 600px)` block is
// dropped and a `@media (max-width: 600px)` block is too. That is the conservative
// direction -- a rule is not applied because nothing said it should be -- and it is why
// `new_engine` exists at all rather than forcing every caller to invent a viewport.
//
// A renderer uses new_engine_for.
pub fn new_engine(sheets []Sheet) &Engine {
	return new_engine_for(sheets, css.MediaContext{})
}

// new_engine_for compiles the sheets against a viewport, so that `@media` and
// `@supports` blocks are resolved rather than dropped.
//
// The conditions are evaluated *here*, once, rather than per element at match time.
// The viewport cannot change without a re-layout, and a re-layout is already a new
// engine's worth of work; evaluating per element would mean asking the same question
// once per node and getting a different answer the moment anything moved.
pub fn new_engine_for(sheets []Sheet, media css.MediaContext) &Engine {
	mut e := Engine{ sheets: sheets }
	for sheet in sheets {
		e.compile_rules(sheet.style.rules, sheet.origin, media)
	}
	return &e
}

// compile_rules adds the qualified rules of a rule list to the engine, descending
// through conditional group rules.
//
// Before this, a `@media` block was silently dropped: the loop only ever looked at
// top-level qualified rules, so a responsive stylesheet parsed perfectly and did
// nothing at all. Nothing reported it, because a dropped rule and an absent rule look
// identical from the outside.
fn (mut e Engine) compile_rules(rules []css.Rule, origin Origin, media css.MediaContext) {
	for rule in rules {
		match rule {
			css.QualifiedRule {
				e.compile_qualified(rule, origin)
			}
			css.NestedRule {
				if !group_applies(rule, media) {
					continue
				}
				e.compile_rules(rule.rules, origin, media)
			}
			css.AtDeclarationRule {
				// `@font-face`, `@page` and `@keyframes` describe things this engine does
				// not draw. Their rules are not qualified rules and there is nothing to add
				// them to; the at-rule itself is kept on the sheet so a caller can find it.
			}
		}
	}
}

fn (mut e Engine) compile_qualified(rule css.QualifiedRule, origin Origin) {
	list := selector.parse(rule.prelude) or { return }
	spec := list.specificity()
	mut decls := []Declaration{}
	for decl in rule.declarations {
		for one in expand(decl) {
			decls << Declaration{
				decl:        one
				origin:      origin
				specificity: spec
				// The order number counts *declarations*, not rules. Two declarations in
				// one rule still have to be ordered, because `margin: 10px; margin-left:
				// 20px` is decided by which came last, and a per-rule counter would call it
				// a tie and keep the shorthand's answer.
				order:       e.order_counter
			}
			e.order_counter++
		}
	}
	e.rules << CompiledRule{ selector: list, declarations: decls }
}

// group_applies decides whether a conditional group rule's contents are in force.
//
// Two at-rules are answered and everything else is refused. Refusing is not tidiness:
// an unknown at-rule's contents are unknown, and a stylesheet guarded by a condition
// this engine cannot evaluate is one where applying the block would paint a page the
// author conditioned away.
fn group_applies(rule css.NestedRule, media css.MediaContext) bool {
	match rule.name.to_lower() {
		'media' { return media.matches(rule.prelude) }
		'supports' { return supports_condition(rule.prelude) }
		// `@layer` and `@container` order or condition rules by something this engine has
		// no model of. `@layer` in particular is common enough that refusing it silently
		// would lose real styles, so it is treated as always applying: its rules then
		// cascade in source order, which is the ordering a single layer would have given.
		'layer' { return true }
		else { return false }
	}
}

// supports_condition evaluates an `@supports` condition.
//
// The grammar implemented is `(property)`, `(property: value)`, `not (...)`, and
// `and`/`or` between them -- which is what `@supports` is written with in practice. A
// condition in any other shape is false.
//
// The property test is exact and the value test is not: a supported property with a
// value this engine cannot parse is treated as supported. That is a deliberate gap. The
// alternative is a per-property value parser behind `supports`, which is a second
// implementation of everything `apply` already does and would drift from it.
pub fn supports_condition(condition string) bool {
	c := condition.trim_space()
	if c == '' {
		return false
	}
	lower := c.to_lower()
	if lower.starts_with('not ') {
		return !supports_condition(c[4..])
	}
	// `or` binds more loosely than `and`, so it is the first thing split on: `A and B or C`
	// is `(A and B) or C`, and splitting on `and` first would read it as `A and (B or C)`.
	if pair := split_supports_at(c, 'or') {
		return supports_condition(pair[0]) || supports_condition(pair[1])
	}
	if pair := split_supports_at(c, 'and') {
		return supports_condition(pair[0]) && supports_condition(pair[1])
	}
	if !c.starts_with('(') || !c.ends_with(')') {
		return false
	}
	inner := c[1..c.len - 1].trim_space()
	if inner == '' {
		return false
	}
	mut name := inner
	mut value := ''
	mut has_value := false
	if colon := inner.index(':') {
		name = inner[..colon].trim_space()
		value = inner[colon + 1..].trim_space()
		has_value = true
	}
	if name == '' {
		return false
	}
	if !supports_property(name) {
		return false
	}
	if has_value && name == 'display' {
		return supports_display(value)
	}
	return true
}

// split_supports_at splits a condition at its first top-level `op`, ignoring any `op`
// inside parentheses.
//
// It works from tokens rather than from string offsets because the tokens are what say
// where the parentheses are, and an earlier version indexed the string directly -- which
// in this V is a `u8` in one loop and a `string` in another, so the comparison against
// `(` did not compile either way.
fn split_supports_at(s string, op string) ?[2]string {
	mut toks := []css.Token{}
	for t in css.tokenize(s) {
		if t.kind == .whitespace || t.kind == .eof {
			continue
		}
		toks << t
	}
	mut depth := 0
	mut at := -1
	for i, t in toks {
		if t.kind == .lparen {
			depth++
			continue
		}
		if t.kind == .rparen {
			if depth > 0 {
				depth--
			}
			continue
		}
		if depth == 0 && t.kind == .ident && t.value.to_lower() == op {
			at = i
			break
		}
	}
	if at < 0 {
		return none
	}
	return [css.serialize(toks[..at]), css.serialize(toks[at + 1..])]
}

// supports_display reports whether a `display` value is one this engine has.
//
// This is the case that earns `@supports` its keep: `@supports (display: grid)` is how
// a stylesheet asks for something it can fall back from, and answering it true would
// apply a grid layout to a block layout.
fn supports_display(value string) bool {
	match value.to_lower() {
		'block', 'inline', 'none', 'list-item', 'inline-block', 'flow-root' { return true }
		else { return false }
	}
}

// supported_properties is every property name `apply` acts on, plus the shorthands it
// expands. It is a list rather than a switch because it is data, and a test asserts it
// against `apply` so the two cannot drift.
const supported_properties = ['background', 'background-color', 'background-image',
	'background-position', 'background-repeat', 'background-size', 'border', 'border-color',
	'border-style', 'border-width', 'border-top', 'border-right', 'border-bottom', 'border-left',
	'border-top-color', 'border-right-color', 'border-bottom-color', 'border-left-color',
	'border-top-style', 'border-right-style', 'border-bottom-style', 'border-left-style',
	'border-top-width', 'border-right-width', 'border-bottom-width', 'border-left-width', 'bottom',
	'box-sizing', 'clear', 'color', 'display', 'direction', 'float', 'font-family', 'font-size',
	'font-style', 'font-weight', 'height', 'left', 'line-height', 'list-style-position',
	'list-style-type', 'margin', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
	'max-height', 'max-width', 'min-height', 'min-width', 'opacity', 'padding', 'padding-top',
	'padding-right', 'padding-bottom', 'padding-left', 'position', 'right', 'text-align',
	'text-decoration', 'text-transform', 'top', 'vertical-align', 'visibility', 'white-space',
	'width', 'z-index']

// supports_property reports whether the cascade can act on a property at all.
pub fn supports_property(name string) bool {
	return name.to_lower() in supported_properties
}

// expand replaces a shorthand with the longhands it stands for, before the cascade
// sees either of them.
//
// This is not tidiness. CSS canonicalises declarations for exactly this reason: a
// shorthand and a longhand for the same side have to compete on specificity, and
// they cannot do that if the winner is decided per property *name* and then applied
// in whatever order the names happened to be written. `p { margin-left: 20px } .x
// { margin: 10px }` is the case: the author meant `.x`'s shorthand to win on the
// left, and a cascade that resolves `margin` and `margin-left` separately gets it
// backwards unless the shorthand is expanded first.
//
// A declaration whose value is not a valid shorthand is passed through unchanged and
// rejected later by `apply`, which is where the property is known. Expanding here
// would mean parsing every value of every property twice.
fn expand(d css.Declaration) []css.Declaration {
	// Custom properties are opaque token streams and must not be touched.
	if d.name.starts_with('--') {
		return [d]
	}
	match d.name {
		'margin', 'padding' {
			return expand_sides(d)
		}
		// The border longhands put the side before the property -- `border-top-width`,
		// not `border-width-top` -- which is why these cannot share expand_sides'
		// name template with margin and padding.
		'border-width', 'border-color', 'border-style' {
			return expand_border_sides(d)
		}
		'border' {
			return expand_border(d)
		}
		'border-top', 'border-right', 'border-bottom', 'border-left' {
			return expand_border_side(d)
		}
		else {
			return [d]
		}
	}
}

// expand_sides turns a one-to-four-value box shorthand into four longhands.
fn expand_sides(d css.Declaration) []css.Declaration {
	// `margin` becomes `margin-top`; the side goes after the property.
	return expand_sides_named(d, [d.name + '-top', d.name + '-right', d.name + '-bottom',
		d.name + '-left'])
}

// expand_border_sides is expand_sides for the border properties, whose longhands put
// the side *before* the property: `border-top-width`, not `border-width-top`.
//
// Writing the names out rather than composing them is what caught this the first
// time: the two templates differ by where a hyphen goes, and composing them from one
// template produced `margintop`, which matches no property and is silently dropped.
fn expand_border_sides(d css.Declaration) []css.Declaration {
	// `border-width` -> `width`
	part := d.name['border-'.len..]
	return expand_sides_named(d, ['border-top-' + part, 'border-right-' + part,
		'border-bottom-' + part, 'border-left-' + part])
}

// expand_sides_named emits four longhands from a one-to-four-value shorthand, with
// the longhand name for each side given explicitly.
fn expand_sides_named(d css.Declaration, names [4]string) []css.Declaration {
	parts := split_top_level(d.value)
	if parts.len == 0 || parts.len > 4 {
		return [d]
	}
	mut vals := ['', '', '', '']
	mut i := 0
	for p in parts {
		vals[i] = p
		i++
	}
	// The one-value form repeats; the two-value form is top/bottom then left/right, and
	// the three-value form is top, left/right, bottom.
	//
	// The two-value case set only the right side. Its bottom was never assigned, so
	// `margin-bottom` was emitted with an empty value, `parse_length('')` failed, and the
	// bottom margin was silently left at zero -- for the second most common shorthand form
	// there is. `margin: 10px 20px` gave a paragraph no bottom margin at all, which on a
	// page of paragraphs is collapsed vertical spacing everywhere.
	//
	// The unit test that used to cover this asserted the correct answer and passed, because
	// it tested `parse_edges` -- a private function that nothing but the test called, and
	// which got the two-value case right. The live expander got it wrong underneath it.
	// Deleting the dead function and writing the test against the cascade is what found it.
	if i == 1 {
		vals[1] = vals[0]
		vals[2] = vals[0]
		vals[3] = vals[0]
	} else if i == 2 {
		vals[2] = vals[0]
		vals[3] = vals[1]
	} else if i == 3 {
		vals[3] = vals[1]
	}
	mut out := []css.Declaration{}
	for k in 0 .. 4 {
		out << css.Declaration{
			name:      names[k]
			value:     vals[k]
			important: d.important
		}
	}
	return out
}

// expand_border splits `border: 1px solid red` into a width, a style and a colour,
// and then each of those into its four sides. A word that fits none of the three is
// kept as the width, which `apply` will reject -- the same outcome as rejecting it
// here, with less code.
fn expand_border(d css.Declaration) []css.Declaration {
	comps := split_border_components(d.value)
	mut out := []css.Declaration{}
	for part in [
		css.Declaration{ name: 'border-width', value: comps[0], important: d.important },
		css.Declaration{ name: 'border-style', value: comps[1], important: d.important },
		css.Declaration{ name: 'border-color', value: comps[2], important: d.important },
	] {
		if part.value == '' {
			continue
		}
		out << expand_border_sides(part)
	}
	return out
}

// expand_border_side handles `border-top: 1px solid red`, the single-side shorthands.
//
// These were in `supported_properties` from the start, so the name survived the cascade
// and `apply` was handed `border-bottom: 2px solid #12407a`. `apply` knows the longhands
// only, matched the declaration against no property it acts on, and did nothing. No
// error, no warning, no border: every page using `border-left` or `border-bottom`, which
// is most of them, lost that border *and* the layout space it should have reserved.
//
// The unit test for this was named `test_a_border_shorthand_with_one_side_does_not_touch_
// the_others` and used `border-top-width`, which is a longhand. It passed, and it covered
// none of these four names. A test whose name describes a shorthand and whose body uses
// the longhand is worse than no test, because it is read as coverage.
//
// Only the named side is emitted. `border-bottom` must leave the top, right and left
// exactly as they were, which is what makes it usable in a cascade against a `border`
// shorthand on a rule of higher specificity.
fn expand_border_side(d css.Declaration) []css.Declaration {
	comps := split_border_components(d.value)
	// `border-top` -> `top`, so the longhands read `border-top-width`.
	side := d.name['border-'.len..]
	mut out := []css.Declaration{}
	for k in 0 .. 3 {
		if comps[k] == '' {
			continue
		}
		out << css.Declaration{
			name:      'border-' + side + '-' + ['width', 'style', 'color'][k]
			value:     comps[k]
			important: d.important
		}
	}
	return out
}

// split_border_components pulls the width, the style and the colour out of a border
// shorthand value, in whatever order they were written and with any of them missing.
//
// `border: 2px` and `border-bottom: solid` are both valid, and a component that is
// absent stays empty so the caller can leave that longhand out entirely -- emitting
// `border-top-style: ''` would reset a style that a lower-specificity rule had set.
fn split_border_components(value string) [3]string {
	mut width := ''
	mut style := ''
	mut colour := ''
	for part in split_top_level(value) {
		if style == '' && parse_border_style(part) != none {
			style = part
			continue
		}
		if colour == '' && parse_color(part) != none {
			colour = part
			continue
		}
		if width == '' {
			width = part
		}
	}
	return [width, style, colour]
}

// user_agent_engine returns an engine holding the UA stylesheet alone, which is the
// right starting point for a document with no author CSS and also the baseline every
// other cascade is measured against.
pub fn user_agent_engine() &Engine {
	return new_engine([Sheet{ style: css.parse(css.user_agent_css), origin: .user_agent }])
}

// winning returns the declarations that apply to one element, already resolved: at
// most one per property name.
//
// The result is in the order the properties were first mentioned rather than in map
// order. That is not a cosmetic choice: ARCHITECTURE.md 4 makes rendering
// deterministic, and a map's iteration order is not something a golden image can
// rely on even when it happens to be stable.
pub fn (e &Engine) winning(el &html.Tag, state &selector.State) []Declaration {
	mut best := map[string]Declaration{}
	mut names := []string{}
	for rule in e.rules {
		if !rule.selector.matches(el, state) {
			continue
		}
		for cand in rule.declarations {
			// Presence is tested with `in`, not by reading the value: a declaration's
			// value is legitimately empty and would be indistinguishable from absent.
			if cand.decl.name in best {
				if !cand.beats(best[cand.decl.name]) {
					continue
				}
			} else {
				names << cand.decl.name
			}
			best[cand.decl.name] = cand
		}
	}
	mut out := []Declaration{}
	for name in names {
		out << best[name]
	}
	return out
}

// compute produces the element's style from its parent's and the declarations that
// apply to it. `ctx` carries the font sizes and viewport that relative lengths
// resolve against; the caller sets `ctx.font_size` to the parent's computed size
// before calling, because in CSS an `em` on `font-size` resolves against the
// parent's font size rather than its own.
//
// There is no `root` parameter. `rem` resolves through `ctx.root_font_size`, which
// is a number the caller already has, so a Style would add nothing.
pub fn (e &Engine) compute(el &html.Tag, parent &Style, ctx &Context, state &selector.State) Style {
	mut s := initial()
	s.inherit_from(parent)
	// The root element does not inherit: it starts from the initial value, so there
	// is no ancestor above it for it to inherit from, and this is the only place the
	// distinction shows.
	if tree.parent_element(el) == none {
		s = initial()
	}
	for decl in e.winning(el, state) {
		s.apply(decl, ctx)
	}
	for decl in inline_declarations(el) {
		s.apply(Declaration{ decl: decl, origin: .author }, ctx)
	}
	// CSS 2.1 9.7, the cheap half of it: the computed value of `display` is `block`
	// for a floated element. This is not cosmetic, it is what makes the layout work:
	// a float is not inline-level, so it does not sit inside a line and the text
	// around it is not one run with it. `display: none` wins, because an element that
	// generates no boxes at all is not made to generate them by being floated.
	//
	// The `position` half of 9.7 -- an absolutely positioned element also computes
	// `display` to `block` -- is the same rule for the same reason: an out-of-flow box
	// is not inline-level either, so it cannot be collected into a line of its parent's
	// text. Without it a `position: absolute` `<span>` would be laid out as an
	// anonymous box of its parent's inline content and then positioned against a
	// containing block it has already been placed inside.
	if s.float != .none && s.display != .none {
		s.display = .block
	}
	if (s.position == .absolute || s.position == .fixed) && s.display != .none {
		s.display = .block
	}
	return s
}

// inline_declarations reads a `style` attribute into declarations.
//
// Precedence comes from *when* these are applied, not from the fields on the wrapper:
// `compute` applies them after every winning author declaration, and `apply` is a
// last-write-wins, so the attribute beats the stylesheet. It loses only to `!important`,
// because an `!important` inline declaration is still an `!important` one and the rank
// that says so travels with it.
//
// The wrapper carries only a name and an origin because nothing reads the other two on
// this path. Filling them in with a made-up specificity would be a lie that the next
// reader would believe.
fn inline_declarations(el &html.Tag) []css.Declaration {
	attr := el.attributes['style']
	if attr == '' {
		return []css.Declaration{}
	}
	// `css.parse_declarations` is the same parser the cascade uses for a block, so an
	// inline list understands comments, `!important` and semicolons as a stylesheet does.
	mut out := []css.Declaration{}
	for decl in css.parse_declarations(attr) {
		for one in expand(decl) {
			out << one
		}
	}
	return out
}

// apply writes one declaration into a style. An unrecognised or invalid declaration
// is dropped, which is what CSS requires and what keeps a stylesheet using a
// property this engine does not implement from affecting anything else.
pub fn (mut s Style) apply(decl Declaration, ctx &Context) {
	v := decl.decl.value
	match decl.decl.name {
		'display' { s.display = parse_display(v) or { return } }
		'color' { s.color = parse_color(v) or { return } }
		'background-color' { s.background_color = parse_color(v) or { return } }
		'background-image' { s.background_image = parse_image_url(v) or { return } }
		'background-repeat' { s.background_repeat = parse_repeat(v) or { return } }
		'background-position' {
			s.background_position = parse_background_position(v) or { return }
		}
		'background-size' { s.background_size = parse_background_size(v) or { return } }
		'background' { apply_background(mut s, v) }
		'font-size' { s.font_size = parse_length(v) or { return } }
		'font-family' { s.font_family = first_family(v) }
		'font-weight' { s.font_weight = parse_font_weight(v) or { return } }
		'font-style' { s.font_style = parse_font_style(v) or { return } }
		'line-height' { s.line_height = parse_line_height(v) or { return } }
		'text-align' { s.text_align = parse_text_align(v) or { return } }
		'text-decoration' { s.text_decoration = parse_text_decoration(v) or { return } }
		'text-transform' { s.text_transform = parse_text_transform(v) or { return } }
		'white-space' { s.white_space = parse_white_space(v) or { return } }
		'direction' { s.direction = parse_direction(v) or { return } }
		'vertical-align' { s.vertical_align = parse_vertical_align(v) or { return } }
		'list-style-type' { s.list_style_type = parse_list_style_type(v) or { return } }
		'list-style-position' {
			s.list_style_position = parse_list_style_position(v) or { return }
		}
		'opacity' { s.opacity = parse_number(v) or { return } }
		'visibility' { s.visibility = parse_visibility(v) or { return } }
		'float' { s.float = parse_float(v) or { return } }
		'clear' { s.clear = parse_clear(v) or { return } }
		'position' { s.position = parse_position(v) or { return } }
		'z-index' { s.z_index = parse_z_index(v) or { return } }
		// The four insets share `set_edge` with the margin and the padding longhands
		// because they are the same shape of value -- a length, a percentage or `auto`
		// per side -- and `side_index` already names the side in both `top` and
		// `border-top-width` shapes.
		'top', 'right', 'bottom', 'left' {
			s.insets = set_edge(s.insets, v, side_index(decl.decl.name)) or { return }
		}
		'margin-top', 'margin-right', 'margin-bottom', 'margin-left' {
			s.margin = set_edge(s.margin, v, side_index(decl.decl.name)) or { return }
		}
		'padding-top', 'padding-right', 'padding-bottom', 'padding-left' {
			s.padding = set_edge(s.padding, v, side_index(decl.decl.name)) or { return }
		}
		'border-top-width', 'border-right-width', 'border-bottom-width',
		'border-left-width' {
			s.border_width = set_edge(s.border_width, v, side_index(decl.decl.name)) or {
				return
			}
		}
		'border-top-color', 'border-right-color', 'border-bottom-color',
		'border-left-color' {
			c := parse_color(v) or { return }
			mut side := side_index(decl.decl.name)
			s.border_color[side] = c
		}
		'border-top-style', 'border-right-style', 'border-bottom-style',
		'border-left-style' {
			st := parse_border_style(v) or { return }
			mut side := side_index(decl.decl.name)
			s.border_style[side] = st
		}
		// An unknown keyword is ignored rather than treated as `content-box`, so a typo
		// does not silently switch the sizing model of everything below it.
		'box-sizing' {
			match v.trim_space().to_lower() {
				'content-box' { s.box_sizing = .content_box }
				'border-box' { s.box_sizing = .border_box }
				else { return }
			}
		}
		'width' { s.width = parse_length(v) or { return } }
		'height' { s.height = parse_length(v) or { return } }
		'min-width' { s.min_width = parse_length(v) or { return } }
		'min-height' { s.min_height = parse_length(v) or { return } }
		'max-width' { s.max_width = parse_length(v) or { return } }
		'max-height' { s.max_height = parse_length(v) or { return } }
		else { return }
	}
	_ = ctx
}

// side_index names the side in a longhand, in CSS's top/right/bottom/left order.
//
// Both shapes are accepted because CSS uses both: `margin-top` puts the side at the
// end and `border-top-width` puts it in the middle. Matching only the first shape
// returns -1 for every border longhand, which is an out-of-range write rather than an
// error -- the kind that shows up much later as a wrong pixel.
//
// The insets are the bare side names, and they have to be matched before the two
// composed shapes or they match neither: `top` does not end with `-top` and does not
// contain `-top-`, so without the first four lines every inset would return -1,
// `set_edge` would refuse it, and the declaration would be dropped with no error at
// all. That is exactly what happened: the box lay out as if no inset had been written.
fn side_index(name string) int {
	if name == 'top' {
		return 0
	}
	if name == 'right' {
		return 1
	}
	if name == 'bottom' {
		return 2
	}
	if name == 'left' {
		return 3
	}
	if name.ends_with('-top') || name.contains('-top-') {
		return 0
	}
	if name.ends_with('-right') || name.contains('-right-') {
		return 1
	}
	if name.ends_with('-bottom') || name.contains('-bottom-') {
		return 2
	}
	if name.ends_with('-left') || name.contains('-left-') {
		return 3
	}
	return -1
}

fn set_edge(edges Edges, v string, side int) ?Edges {
	l := parse_length(v) or { return none }
	mut e := edges
	match side {
		0 { e.top = l }
		1 { e.right = l }
		2 { e.bottom = l }
		3 { e.left = l }
		else { return none }
	}
	return e
}
