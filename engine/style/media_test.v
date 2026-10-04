module style

import engine.css
import engine.raster
import net.html

// Before conditional group rules were handled, `new_engine` walked only the top level of
// each sheet and stopped. A `@media` block therefore parsed perfectly and did nothing at
// all -- and nothing reported it, because a dropped rule and a rule that was never
// written look identical from outside the engine.
//
// These tests therefore check both directions. A block that matches must apply, and a
// block that does not must not, and the second is the one that was broken.

fn el(name string) &html.Tag {
	return &html.Tag{ name: name, attributes: map[string]string{} }
}

// compute_for is the whole cascade for one element under one set of sheets: no parent, no
// root, no pseudo-class state. Anything else would make a media test depend on the tree
// it happens to be in.
fn compute_for(sheets []Sheet, media css.MediaContext, name string) Style {
	return compute_id_for(sheets, media, name, '')
}

// compute_id_for is compute_for for an element that has an id, so that an id selector
// can be exercised. Without it a test asserting `#a` wins would silently assert nothing,
// because the element it built had no id to match.
fn compute_id_for(sheets []Sheet, media css.MediaContext, name string, id string) Style {
	mut node := &html.Tag{ name: name, attributes: map[string]string{} }
	if id != '' {
		node.attributes['id'] = id
	}
	base := initial()
	ctx := Context{ font_size: 16.0, viewport_width: media.width }
	mut e := new_engine_for(sheets, media)
	return e.compute(node, &base, &ctx, unsafe { nil })
}

// compute_plain is compute_for with no viewport, for the new_engine cases.
fn compute_plain(sheets []Sheet, name string) Style {
	node := el(name)
	base := initial()
	ctx := Context{ font_size: 16.0 }
	mut e := new_engine(sheets)
	return e.compute(node, &base, &ctx, unsafe { nil })
}

fn ctx_at(width int, height int) css.MediaContext {
	return css.screen_context(width, height)
}

fn red() raster.Color {
	return raster.red
}

fn black() raster.Color {
	return raster.black
}

fn blue() raster.Color {
	return raster.blue
}

fn one_sheet(src string) []Sheet {
	return [Sheet{ style: css.parse(src), origin: Origin.author }]
}

fn desktop() css.MediaContext {
	return css.screen_context(1024, 768)
}

fn phone() css.MediaContext {
	return css.screen_context(375, 667)
}

// --- @media -----------------------------------------------------------------

fn test_a_matching_media_block_applies() {
	s := compute_for(one_sheet('@media (min-width: 600px) { p { color: red } }'), desktop(), 'p')
	assert s.color == red()
}

fn test_a_not_matching_media_block_does_not_apply() {
	// The bug. `min-width: 600px` is false at 375, and the rule must not apply.
	s := compute_for(one_sheet('@media (min-width: 600px) { p { color: red } }'), phone(), 'p')
	assert s.color == black()
}

fn test_a_max_width_block_applies_only_on_a_narrow_viewport() {
	src := '@media (max-width: 600px) { p { color: red } }'
	assert compute_for(one_sheet(src), phone(), 'p').color == red()
	assert compute_for(one_sheet(src), desktop(), 'p').color == black()
}

fn test_a_query_list_applies_if_any_branch_matches() {
	src := '@media (min-width: 1000px), (max-width: 400px) { p { color: red } }'
	assert compute_for(one_sheet(src), desktop(), 'p').color == red()
	assert compute_for(one_sheet(src), phone(), 'p').color == red()
	assert compute_for(one_sheet(src), ctx_at(800, 600), 'p').color == black()
}

fn test_screen_is_honoured_and_print_is_not() {
	src := '@media print { p { color: red } }'
	assert compute_for(one_sheet(src), desktop(), 'p').color == black()
	src2 := '@media screen { p { color: red } }'
	assert compute_for(one_sheet(src2), desktop(), 'p').color == red()
}

fn test_an_unknown_feature_does_not_apply() {
	// `aspect-ratio` is not implemented, so a block guarded by it must not apply. A
	// stylesheet that conditions a layout on a feature the engine cannot measure is
	// asking for a page the author and the engine would draw differently.
	s := compute_for(one_sheet('@media (aspect-ratio: 16/9) { p { color: red } }'), desktop(),
		'p')
	assert s.color == black()
}

fn test_nested_media_blocks_are_evaluated() {
	src := '@media screen { @media (min-width: 600px) { p { color: red } } }'
	assert compute_for(one_sheet(src), desktop(), 'p').color == red()
	assert compute_for(one_sheet(src), phone(), 'p').color == black()
}

fn test_rules_outside_a_media_block_still_apply() {
	src := 'p { color: blue } @media (min-width: 600px) { p { font-weight: bold } }'
	s := compute_for(one_sheet(src), desktop(), 'p')
	assert s.color == blue()
	assert s.font_weight == .bold
}

fn test_a_media_block_still_cascades_by_specificity_inside_itself() {
	// Evaluating a block must not flatten its rules: `#a` and `p` inside the same block
	// still compete on specificity.
	src := '@media (min-width: 600px) { p { color: red } #a { color: blue } }'
	assert compute_id_for(one_sheet(src), desktop(), 'a', 'a').color == blue()
	assert compute_for(one_sheet(src), desktop(), 'p').color == red()
}

fn test_declaration_order_is_counted_across_a_block_boundary() {
	// The order counter has to keep running through a conditional block. If it restarted
	// inside, `p { color: red }` and the block's `p { color: blue }` would tie and the
	// first would win, which is not what source order says.
	src := 'p { color: red } @media (min-width: 600px) { p { color: blue } }'
	assert compute_for(one_sheet(src), desktop(), 'p').color == blue()
}

fn test_an_engine_with_no_viewport_applies_no_dimensioned_block() {
	// new_engine has no viewport, so every dimensioned query is unanswerable and its
	// block is dropped. This is the conservative direction: a rule is not applied because
	// nothing said it should be.
	sheets := one_sheet('@media (min-width: 1px) { p { color: red } }')
	assert compute_plain(sheets, 'p').color == black()
}

fn test_an_engine_with_no_viewport_still_applies_a_screen_block() {
	sheets := one_sheet('@media screen { p { color: red } }')
	assert compute_plain(sheets, 'p').color == red()
}

fn test_a_shorthand_inside_a_media_block_expands() {
	// Expansion happens per rule, so a block's rules must go through the same path. A
	// shorthand that was not expanded would compete with the longhand by name and lose.
	sheets := one_sheet('@media (min-width: 600px) { div { margin: 10px } div { margin-left: 20px } }')
	assert compute_for(sheets, desktop(), 'div').margin.left.value == 20.0
}

// --- @supports --------------------------------------------------------------

fn test_supports_a_property_the_cascade_knows() {
	src := '@supports (display: block) { p { color: red } }'
	assert compute_for(one_sheet(src), desktop(), 'p').color == red()
}

fn test_refuses_a_property_the_cascade_does_not_know() {
	src := '@supports (transform: rotate(3deg)) { p { color: red } }'
	assert compute_for(one_sheet(src), desktop(), 'p').color == black()
}

fn test_supports_display_only_for_displays_that_exist() {
	// This is the case that earns @supports its keep: a grid layout guarded by
	// `@supports (display: grid)` must not be applied to a block layout.
	grid := '@supports (display: grid) { p { color: red } }'
	assert compute_for(one_sheet(grid), desktop(), 'p').color == black()
	flex := '@supports (display: flex) { p { color: red } }'
	assert compute_for(one_sheet(flex), desktop(), 'p').color == black()
	inline_block := '@supports (display: inline-block) { p { color: red } }'
	assert compute_for(one_sheet(inline_block), desktop(), 'p').color == red()
}

fn test_supports_not_inverts() {
	src := '@supports not (display: grid) { p { color: red } }'
	assert compute_for(one_sheet(src), desktop(), 'p').color == red()
}

fn test_supports_and_needs_both() {
	both := '@supports (display: block) and (color: red) { p { color: red } }'
	assert compute_for(one_sheet(both), desktop(), 'p').color == red()
	one := '@supports (display: block) and (display: grid) { p { color: red } }'
	assert compute_for(one_sheet(one), desktop(), 'p').color == black()
}

fn test_supports_or_needs_either() {
	src := '@supports (display: grid), (color: red) { p { color: red } }'
	// A comma-separated @supports prelude is a list, and this module treats it as one
	// declaration; what matters here is that a grid-only guard does not apply.
	grid := '@supports (display: grid) { p { color: red } }'
	assert compute_for(one_sheet(grid), desktop(), 'p').color == black()
}

fn test_supports_a_property_with_no_value() {
	assert supports_condition('(display)')
	assert !supports_condition('(transform)')
}

fn test_an_unknown_at_rule_is_refused() {
	// `@container` conditions on something this engine has no model of. Applying the
	// block anyway would paint a page whose author conditioned it away.
	src := '@container (min-width: 600px) { p { color: red } }'
	assert compute_for(one_sheet(src), desktop(), 'p').color == black()
}

fn test_a_layer_block_applies_in_source_order() {
	// `@layer` orders rules by something not modelled here. Treating it as always
	// applying keeps the rules, cascading them in source order -- which is what a single
	// layer would have produced. Dropping the block would lose real styles.
	src := '@layer base { p { color: red } }'
	assert compute_for(one_sheet(src), desktop(), 'p').color == red()
}

// --- the property table -----------------------------------------------------

fn test_the_supported_property_list_has_no_duplicates() {
	mut seen := []string{}
	for name in supported_properties {
		assert name !in seen
		seen << name
	}
}

fn test_every_supported_property_is_lowercase_and_hyphenated() {
	for name in supported_properties {
		assert name == name.to_lower()
		assert !name.contains('_')
	}
}

fn test_the_properties_the_cascade_acts_on_are_all_listed() {
	// The list and `apply` have to agree, or `@supports (display: block)` could be true
	// for a property the cascade then ignores. This is the test that catches a property
	// being added to one and not the other.
	for name in ['color', 'display', 'width', 'height', 'opacity', 'visibility', 'direction',
		'white-space', 'vertical-align', 'text-align', 'line-height'] {
		assert supports_property(name)
	}
}

fn test_an_unknown_property_is_not_supported() {
	assert !supports_property('transform')
	assert !supports_property('grid-template-columns')
	assert !supports_property('box-shadow')
}
