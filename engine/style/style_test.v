module style

import engine.css
import engine.raster
import engine.selector
import net.html

// --- building blocks --------------------------------------------------------

// color unwraps parse_color for the assertions, so a colour that stopped parsing shows
// up as a panic naming the value rather than as a comparison that never compiles.
fn color(text string) raster.Color {
	return parse_color(text) or { panic('color: ' + text) }
}

// el builds one element with the id and class a test needs, in one call. It takes no
// `mut` parameter on purpose: V 0.5.2 then makes every call site write `mut` before
// the argument, which is noise that says nothing about the test.
fn el(name string, id string, class string) &html.Tag {
	mut node := &html.Tag{ name: name }
	if id != '' {
		node.attributes['id'] = id
	}
	if class != '' {
		node.class_set.add(class)
	}
	// Every element here gets a parent, because the cascade treats a node with no
	// parent as the root element and starts it from the initial value instead of
	// inheriting. Building the link here avoids every call site having to.
	node.parent = &html.Tag{ name: 'body' }
	return node
}

// The elements here are built by hand rather than parsed, for the reason written
// in engine/selector/match_test.v: a tree from another repository turns that
// repository's bug into this module's failing test.
// style_of runs a cascade over one hand-built element. The parent is taken by value so
// that a test can pass initial() without needing somewhere to put it.
fn style_of(e &Engine, el &html.Tag, parent Style, ctx &Context) Style {
	return e.compute(el, &parent, ctx, &selector.State{})
}


fn author_engine(sources ...string) &Engine {
	mut sheets := [Sheet{ style: css.parse(css.user_agent_css), origin: Origin.user_agent }]
	for src in sources {
		sheets << Sheet{ style: css.parse(src), origin: Origin.author }
	}
	return new_engine(sheets)
}

// --- lengths ----------------------------------------------------------------

fn test_a_length_is_kept_unresolved() {
	// A length in `em` needs the parent's font size, which does not exist until
	// layout. Resolving here would mean the cascade needed the whole tree.
	l := parse_length('2em') or { panic('parse') }
	assert l.value == 2.0
	assert l.unit == .em
}

struct UnitCase {
	text string
	px   f64
}

fn test_absolute_units_resolve() {
	ctx := Context{ font_size: 16.0, root_font_size: 16.0 }
	cases := [
		UnitCase{ text: '1px', px: 1.0 },
		UnitCase{ text: '1pt', px: 96.0 / 72.0 },
		UnitCase{ text: '1pc', px: 16.0 },
		UnitCase{ text: '1in', px: 96.0 },
		UnitCase{ text: '2.54cm', px: 96.0 },
		UnitCase{ text: '25.4mm', px: 96.0 },
		UnitCase{ text: '101.6q', px: 96.0 },
	]
	for c in cases {
		l := parse_length(c.text) or { panic('parse ' + c.text) }
		px := l.to_px(&ctx)
		assert px > c.px - 0.001 && px < c.px + 0.001
	}
}

fn test_font_relative_units_resolve_against_the_context() {
	// `em` against the parent's size and `rem` against the root's: an element inside
	// a large heading is bigger in `em` and the same in `rem`, which is the whole
	// point of having both.
	ctx := Context{ font_size: 32.0, root_font_size: 16.0 }
	em := parse_length('2em') or { panic('parse') }
	rem := parse_length('2rem') or { panic('parse') }
	assert em.to_px(&ctx) == 64.0
	assert rem.to_px(&ctx) == 32.0
}

fn test_viewport_units_resolve_against_the_viewport() {
	ctx := Context{ font_size: 16.0, root_font_size: 16.0, viewport_width: 1000.0, viewport_height: 500.0 }
	assert (parse_length('10vw') or { panic('parse') }).to_px(&ctx) == 100.0
	assert (parse_length('10vh') or { panic('parse') }).to_px(&ctx) == 50.0
	assert (parse_length('10vmin') or { panic('parse') }).to_px(&ctx) == 50.0
	assert (parse_length('10vmax') or { panic('parse') }).to_px(&ctx) == 100.0
}

fn test_a_percentage_needs_a_basis() {
	l := parse_length('50%') or { panic('parse') }
	assert l.is_percent()
	assert l.to_px_or(default_context(), 200.0) == 100.0
	// With no basis there is no answer, and guessing one is how a percentage margin
	// ends up measured against the viewport.
	assert l.to_px(default_context()) == 0.0
}

fn test_auto_is_not_zero() {
	auto := parse_length('auto') or { panic('parse') }
	zero := parse_length('0') or { panic('parse') }
	assert auto.is_auto()
	// `width: auto` fills the containing block and `width: 0` does not, so treating
	// one as the other is the bug Phase 2 exists to prevent.
	assert !zero.is_auto()
}

fn test_an_invalid_length_is_rejected() {
	for bad in ['', 'abc', 'px', '1 lightyear', '1e', '- px'] {
		assert parse_length(bad) == none
	}
}

fn test_keyword_lengths() {
	// `thin`, `medium` and `thick` are absolute, so they need no context.
	assert (parse_length('thin') or { panic('parse') }).to_px(default_context()) == 1.0
	assert (parse_length('medium') or { panic('parse') }).to_px(default_context()) == 3.0
	assert (parse_length('thick') or { panic('parse') }).to_px(default_context()) == 5.0
}

fn test_unit_case_is_ignored() {
	l := parse_length('10PX') or { panic('parse') }
	assert l.unit == .px && l.value == 10.0
}

// --- colours ----------------------------------------------------------------

fn test_hex_colours_in_every_length() {
	assert color('#fff') == raster.rgb(255, 255, 255)
	assert color('#000') == raster.rgb(0, 0, 0)
	assert color('#abc') == raster.rgb(0xaa, 0xbb, 0xcc)
	assert color('#ff0000') == raster.rgb(255, 0, 0)
	assert color('#0000ff') == raster.rgb(0, 0, 255)
}

fn test_hex_colour_case_and_surrounding_space() {
	assert color('  #FF0000 ') == raster.rgb(255, 0, 0)
}

fn test_hex_colour_with_alpha_is_premultiplied() {
	// `rgba(255,255,255,128)` is (128,128,128,128), not (255,255,255,128). The
	// invariant r <= a is what makes source-over correct for every blend.
	c := parse_color('#ffffff80') or { panic('parse') }
	assert c.a == 128
	assert c.r == c.a && c.g == c.a && c.b == c.a
}

fn test_transparent() {
	assert color('transparent') == raster.transparent
}

fn test_named_colours() {
	assert color('red') == raster.rgb(255, 0, 0)
	assert color('  Tomato ') == raster.rgb(255, 99, 71)
	assert color('rebeccapurple') == raster.rgb(0x66, 0x33, 0x99)
	// The grey/gray and cyan/magenta spellings are aliases and must agree.
	assert color('grey') == color('gray')
	assert color('darkgrey') == color('darkgray')
	assert color('cyan') == color('aqua')
	assert color('magenta') == color('fuchsia')
}

fn test_an_unknown_colour_is_rejected_not_defaulted() {
	// Defaulting to black would repaint the page. Dropping the declaration leaves
	// whatever the author meant everywhere else.
	assert parse_color('notacolor') == none
	assert parse_color('#12345') == none
	assert parse_color('#gg0000') == none
	assert parse_color('') == none
}

fn test_rgb_in_every_spelling() {
	want := raster.rgb(1, 2, 3)
	assert color('rgb(1, 2, 3)') == want
	assert color('rgb(1,2,3)') == want
	assert color('rgb( 1 2 3 )') == want
	assert color('RGB(1,2,3)') == want
}

fn test_rgb_with_percentages_and_alpha() {
	assert color('rgb(100%, 0%, 0%)') == raster.rgb(255, 0, 0)
	c := parse_color('rgba(0, 0, 0, 0.5)') or { panic('parse') }
	assert c.a == 128
	// The slash syntax: `rgb(0 0 0 / 50%)` is 50% of opaque, not 0.5 of it.
	c2 := parse_color('rgb(0 0 0 / 50%)') or { panic('parse') }
	assert c2.a == 128
	c3 := parse_color('rgb(0 0 0 / 1)') or { panic('parse') }
	assert c3.a == 255
}

fn test_rgb_channels_are_clamped() {
	assert color('rgb(300, -20, 0)') == raster.rgb(255, 0, 0)
	assert color('rgba(0, 0, 0, 5)') == raster.rgba(0, 0, 0, 255)
}
// --- cascade ----------------------------------------------------------------

fn test_the_author_sheet_beats_the_user_agent_sheet() {
	e := author_engine('p { margin: 40px }')
	p := el('p', '', '')
	s := style_of(e, p, initial(), default_context())
	// The UA sheet gives `p` 1em margins, which at the default font size is 16px.
	assert s.margin.top.to_px(default_context()) == 40.0
}

fn test_specificity_beats_source_order() {
	e := author_engine('p { color: red } .x { color: lime }')
	el := el('p', '', 'x')
	s := style_of(e, el, initial(), default_context())
	assert s.color == raster.rgb(0, 255, 0)
	// The reverse order must not change the answer, or the cascade is sorting on
	// something other than specificity.
	e2 := author_engine('.x { color: lime } p { color: red }')
	s2 := style_of(e2, el, initial(), default_context())
	assert s2.color == raster.rgb(0, 255, 0)
}

fn test_source_order_breaks_a_specificity_tie() {
	e := author_engine('p { color: red } p { color: lime }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.color == raster.rgb(0, 255, 0)
	e2 := author_engine('p { color: lime } p { color: red }')
	s2 := style_of(e2, el('p', '', ''), initial(), default_context())
	assert s2.color == raster.rgb(255, 0, 0)
}

fn test_important_beats_a_more_specific_normal_declaration() {
	e := author_engine('#main { color: red } p { color: lime !important }')
	s := style_of(e, el('p', 'main', ''), initial(), default_context())
	assert s.color == raster.rgb(0, 255, 0)
}

fn test_important_author_beats_important_user_agent() {
	// The one place importance does *not* invert the origin order.
	e := author_engine('p { margin: 40px !important }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.margin.top.to_px(default_context()) == 40.0
}

fn test_an_invalid_declaration_is_dropped_not_defaulted() {
	// `color: notacolor` must leave the cascade's answer alone, not paint it black.
	e := author_engine('p { color: notacolor }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.color == raster.black
}

fn test_an_unimplemented_property_changes_nothing() {
	e := author_engine('p { margin-top: 40px; --custom: x; unknown-prop: 1 }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.margin.top.to_px(default_context()) == 40.0
}

// --- inheritance ------------------------------------------------------------

fn test_inherited_properties_come_from_the_parent() {
	mut parent := initial()
	parent.color = raster.rgb(1, 2, 3)
	parent.font_size = Length{ value: 30.0, unit: .px }
	e := author_engine('')
	child := el('span', '', '')
	s := style_of(e, child, parent, default_context())
	assert s.color == raster.rgb(1, 2, 3)
	assert s.font_size.value == 30.0
}

fn test_non_inherited_properties_do_not() {
	// `margin` is not inherited, and a stylesheet that gives a parent a margin has
	// said nothing about its children.
	mut parent := initial()
	parent.margin.top = Length{ value: 40.0, unit: .px }
	parent.padding.top = Length{ value: 40.0, unit: .px }
	parent.border_width.top = Length{ value: 3.0, unit: .px }
	parent.background_color = raster.rgb(9, 9, 9)
	e := author_engine('')
	child := el('span', '', '')
	s := style_of(e, child, parent, default_context())
	assert s.margin.top.value == 0.0
	assert s.padding.top.value == 0.0
	assert s.border_width.top.value == 0.0
	assert s.background_color == raster.transparent
}

fn test_the_inheritance_table_is_the_documented_one() {
	// The table in `inherit_from` is the spec's; a property that should inherit and
	// does not is a page that renders wrong in a way nothing else notices.
	for name in inherited_properties() {
		value := sample_value(name)
		wrapped := Declaration{
			decl: css.Declaration{
				name: name
				value: value
			}
		}
		mut child := initial()
		child.apply(wrapped, default_context())
		mut from_parent := initial()
		from_parent.apply(wrapped, default_context())
		mut grandchild := initial()
		grandchild.inherit_from(&from_parent)
		// The property must differ from the initial value in the child -- otherwise
		// the loop below would pass for a property that does not inherit either --
		// and the grandchild must have inherited exactly the child's value.
		if child == initial() {
			assert false, name + ' did not change from its initial value'
		}
		assert grandchild == child
	}
}

// sample_value gives one value per inherited property that is *not* the initial
// value. A property whose sample equals its initial would make the test above pass
// for the wrong reason, which is why this panics rather than returning something
// plausible.
fn sample_value(name string) string {
	return match name {
		'color' { 'rgb(1, 2, 3)' }
		'font-size' { '30px' }
		'font-family' { 'monospace' }
		'font-weight' { 'bold' }
		'font-style' { 'italic' }
		'line-height' { '2' }
		'text-align' { 'center' }
		'text-decoration' { 'underline' }
		'white-space' { 'pre' }
		'direction' { 'rtl' }
		'list-style-type' { 'square' }
		'list-style-position' { 'inside' }
		'vertical-align' { 'middle' }
		'text-transform' { 'uppercase' }
		'visibility' { 'hidden' }
		else { panic(name + ' is in the inheritance table but has no sample value') }
	}
}

fn test_display_is_not_inherited() {
	mut parent := initial()
	parent.display = .block
	e := author_engine('')
	child := el('span', '', '')
	s := style_of(e, child, parent, default_context())
	assert s.display == .inline
}

// --- shorthands -------------------------------------------------------------

fn test_the_margin_shorthand_in_every_form() {
	assert (parse_edges('1px') or { panic('parse') }) == Edges{
		Length{ value: 1.0, unit: .px }
		Length{ value: 1.0, unit: .px }
		Length{ value: 1.0, unit: .px }
		Length{ value: 1.0, unit: .px }
	}
	assert (parse_edges('1px 2px') or { panic('parse') }) == Edges{
		Length{ value: 1.0, unit: .px }
		Length{ value: 2.0, unit: .px }
		Length{ value: 1.0, unit: .px }
		Length{ value: 2.0, unit: .px }
	}
	assert (parse_edges('1px 2px 3px') or { panic('parse') }) == Edges{
		Length{ value: 1.0, unit: .px }
		Length{ value: 2.0, unit: .px }
		Length{ value: 3.0, unit: .px }
		Length{ value: 2.0, unit: .px }
	}
	e := parse_edges('1px 2px 3px 4px') or { panic('parse') }
	assert e.top.value == 1.0 && e.right.value == 2.0 && e.bottom.value == 3.0 && e.left.value == 4.0
}

fn test_an_edges_shorthand_with_too_many_values_is_rejected() {
	assert parse_edges('1px 2px 3px 4px 5px') == none
	assert parse_edges('') == none
}

fn test_a_longhand_beats_the_shorthand_of_the_same_side() {
	// `margin` then `margin-left` is the common way a stylesheet adjusts one side,
	// and it must work regardless of which came first in the file, because the
	// cascade has already picked the winner for each property name.
	e := author_engine('p { margin: 10px; margin-left: 20px }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.margin.top.value == 10.0
	assert s.margin.left.value == 20.0
}

fn test_a_more_specific_shorthand_beats_a_less_specific_longhand() {
	e := author_engine('p { margin-left: 20px } .x { margin: 10px }')
	s := style_of(e, el('p', '', 'x'), initial(), default_context())
	// The shorthand wins on the left because `.x` is more specific, and the cascade
	// resolves per property name -- so the longhand loses.
	assert s.margin.left.value == 10.0
}

fn test_border_shorthands() {
	e := author_engine('p { border: 2px solid red }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.border_width.top.value == 2.0
	assert s.border_style[0] == .solid
	assert s.border_color[0] == raster.rgb(255, 0, 0)
	// The longhands alone must reach the same place, or the shorthand is doing
	// something the longhands cannot.
	e2 := author_engine('p { border-width: 2px; border-style: solid; border-color: red }')
	s2 := style_of(e2, el('p', '', ''), initial(), default_context())
	assert s2.border_width.top.value == 2.0
	assert s2.border_style[0] == .solid
	assert s2.border_color[0] == raster.rgb(255, 0, 0)
}

fn test_a_border_shorthand_with_one_side_does_not_touch_the_others() {
	// `border-bottom` must leave the top, right and left alone, so it can be cascaded
	// against a `border` shorthand on a rule of higher specificity.
	//
	// This test used to be written with `border-top-width`, a longhand, which is why it
	// passed for as long as the four single-side *shorthands* were dead.
	e := author_engine('p { border: 1px solid red } #i { border-bottom: 9px solid blue }')
	s := style_of(e, el('p', 'i', ''), initial(), default_context())
	assert s.border_width.bottom.value == 9.0
	assert s.border_color[2] == raster.rgb(0, 0, 255)
	assert s.border_width.top.value == 1.0
	assert s.border_width.right.value == 1.0
	assert s.border_width.left.value == 1.0
	assert s.border_color[0] == raster.rgb(255, 0, 0)
	assert s.border_color[1] == raster.rgb(255, 0, 0)
}

fn test_every_single_side_border_shorthand_expands() {
	// All four, because the bug was a missing match arm and a test of one arm cannot
	// see a missing arm in another. The value order is permuted on purpose: a border
	// shorthand accepts width, style and colour in any order.
	e := author_engine('p { border-top: solid 1px; border-right: 2px dotted; ' +
		'border-bottom: #0f0; border-left: thick double red }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.border_width.top.value == 1.0
	assert s.border_style[0] == .solid
	assert s.border_width.right.value == 2.0
	assert s.border_style[1] == .dotted
	assert s.border_color[2] == raster.rgb(0, 255, 0)
	assert s.border_color[3] == raster.rgb(255, 0, 0)
}

fn test_a_single_side_border_shorthand_may_omit_components() {
	// `border-bottom: solid` sets the style and nothing else. It must not blank the
	// width or the colour, because `apply` reading an empty longhand would reset a
	// value a lower-specificity rule had set.
	e := author_engine('p { border: 1px solid red } #i { border-bottom: solid }')
	s := style_of(e, el('p', 'i', ''), initial(), default_context())
	assert s.border_style[2] == .solid
	assert s.border_width.bottom.value == 1.0
	assert s.border_color[2] == raster.rgb(255, 0, 0)
}

fn test_background_shorthand_sets_the_colour_and_ignores_the_rest() {
	e := author_engine('p { background: #fff url(x.png) no-repeat }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.background_color == raster.white
}

fn test_background_colour_longhand() {
	e := author_engine('p { background-color: rgb(1 2 3) }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.background_color == raster.rgb(1, 2, 3)
}

// --- individual properties --------------------------------------------------

fn test_keyword_values() {
	e := author_engine('p { display: block; font-weight: bold; font-style: italic;' +
		' text-align: center; text-decoration: underline; white-space: pre;' +
		' direction: rtl; visibility: hidden; opacity: 0.5 }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.display == .block
	assert s.font_weight == .bold
	assert s.font_style == .italic
	assert s.text_align == .center
	assert s.text_decoration == .underline
	assert s.white_space == .pre
	assert s.direction == .rtl
	assert s.visibility == .hidden
	assert s.opacity == 0.5
}

fn test_text_decoration_modifiers_are_ignored_not_rejected() {
	// `underline dotted red` must still underline.
	e := author_engine('p { text-decoration: underline dotted red }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.text_decoration == .underline
}

fn test_font_family_takes_the_first_listed() {
	assert first_family('serif') == 'serif'
	assert first_family('"My Font", serif') == 'My Font'
	assert first_family('Arial, Helvetica, sans-serif') == 'Arial'
	assert first_family('  monospace  ') == 'monospace'
}

fn test_line_height_accepts_a_number_a_length_and_a_percentage() {
	// A number is kept unitless: it multiplies the font size, and layout is where
	// that multiplication happens.
	n := parse_line_height('1.5') or { panic('parse') }
	assert n.value == 1.5
	assert n.unit == .none
	l := parse_line_height('20px') or { panic('parse') }
	assert l.value == 20.0 && l.unit == .px
	p := parse_line_height('150%') or { panic('parse') }
	assert p.is_percent()
	assert parse_line_height('normal') != none
	assert parse_line_height('2em') == none
}

fn test_width_and_height_default_to_auto() {
	// `auto` for a block means fill the containing block and `0` means nothing. The
	// distinction is the whole of Phase 2.
	s := initial()
	assert s.width.is_auto() && s.height.is_auto()
	e := author_engine('p { width: 0; height: 50% }')
	s2 := style_of(e, el('p', '', ''), s, default_context())
	assert s2.width.value == 0.0 && !s2.width.is_auto()
	assert s2.height.is_percent()
}

fn test_min_and_max_width_are_stored_even_though_nothing_reads_them_yet() {
	e := author_engine('p { min-width: 10px; max-width: 20em }')
	s := style_of(e, el('p', '', ''), initial(), default_context())
	assert s.min_width.value == 10.0
	assert s.max_width.value == 20.0 && s.max_width.unit == .em
}

fn test_flex_and_grid_display_lay_out_as_block_rather_than_dropping_the_rule() {
	// A stylesheet written for flex or grid should still produce a box, not an
	// unstyled element.
	e := author_engine('p { display: flex } q { display: grid }')
	assert style_of(e, el('p', '', ''), initial(), default_context()).display == .block
	assert style_of(e, el('q', '', ''), initial(), default_context()).display == .block
}

fn test_display_none_produces_no_box() {
	e := author_engine('p { display: none }')
	assert !style_of(e, el('p', '', ''), initial(), default_context()).display.is_block_level()
}

fn test_display_inline_produces_no_box_but_is_not_none() {
	// Phase 1's block layout keys on this distinction.
	e := author_engine('span { display: inline }')
	s := style_of(e, el('span', '', ''), initial(), default_context())
	assert s.display.is_inline()
	assert !s.display.is_block_level()
	e2 := author_engine('span { display: block }')
	s2 := style_of(e2, el('span', '', ''), initial(), default_context())
	assert s2.display.is_block_level() && !s2.display.is_inline()
}

// --- determinism ------------------------------------------------------------

fn test_the_cascade_is_deterministic() {
	// ARCHITECTURE 4: rendering the same page twice must give the same answer, byte
	// for byte. The cascade is the first place a map iteration could break that.
	src := 'p { color: red; margin: 1px } .x { color: lime } #i { padding: 2px }'
	e := author_engine(src)
	node := el('p', 'i', 'x')
	first := style_of(e, node, initial(), default_context())
	for _ in 0 .. 5 {
		again := style_of(e, node, initial(), default_context())
		assert again == first
	}
}

fn test_a_persian_stylesheet_computes() {
	// A Persian page is the reason this project exists, and a stylesheet for one
	// differs from an English one only in its text.
	e := author_engine('.متن { direction: rtl; font-family: Vazirmatn; color: #333 }')
	el := el('div', '', 'متن')
	s := style_of(e, el, initial(), default_context())
	assert s.direction == .rtl
	assert s.font_family == 'Vazirmatn'
	assert s.color == raster.rgb(0x33, 0x33, 0x33)
}
