module css

// The tests are a table, in the sense that matters: every row is a query and an
// expected answer, and the rows were written from Media Queries 4's rules rather than
// from the implementation. A test written after the code agrees with it by
// construction.
//
// Three cases carry most of the weight, and they are the three ways this could be
// wrong in a way nobody would notice:
//
//   - An unknown feature is FALSE, and so is a query containing one. A stylesheet that
//     asks for `aspect-ratio` gets nothing rather than everything.
//   - A context with no viewport matches NO dimensioned query, in either direction.
//     Treating "not told" as "zero-sized" would silently apply every mobile branch.
//   - `print` is false here. A renderer that honours `@media print` paints a page for a
//     printer onto a screen, and that is the kind of bug that looks like a styling
//     mistake three layers away.

fn at(width int, height int) MediaContext {
	return screen_context(width, height)
}

fn desktop() MediaContext {
	return at(1024, 768)
}

fn phone() MediaContext {
	return at(375, 667)
}

fn unknown() MediaContext {
	return MediaContext{}
}

// --- the empty and trivial cases ---------------------------------------------

fn test_an_empty_query_list_is_true() {
	assert unknown().matches('')
	assert unknown().matches('   ')
}

fn test_all_and_screen_match_a_screen_renderer() {
	assert desktop().matches('all')
	assert desktop().matches('screen')
	assert desktop().matches('ALL')
	assert desktop().matches('Screen')
}

fn test_only_all_and_screen_are_honoured() {
	// `print` and `speech` are devices this renderer is not.
	assert !desktop().matches('print')
	assert !desktop().matches('speech')
}

fn test_an_unknown_media_type_is_false() {
	// Not true because it is not `print`: because this engine cannot claim to be a
	// television.
	assert !desktop().matches('tv')
}

fn test_only_is_a_no_op_for_a_query_this_engine_can_parse() {
	assert desktop().matches('only screen')
	assert phone().matches('only screen and (max-width: 400px)')
}

fn test_not_inverts_the_rest_of_the_query() {
	assert !desktop().matches('not screen')
	assert desktop().matches('not print')
	assert desktop().matches('NOT print')
}

// --- width and height --------------------------------------------------------

fn test_min_width_matches_at_and_above_the_value() {
	assert desktop().matches('(min-width: 1000px)')
	assert desktop().matches('(min-width: 1024px)')
	assert !desktop().matches('(min-width: 1025px)')
}

fn test_max_width_matches_at_and_below_the_value() {
	assert desktop().matches('(max-width: 1024px)')
	assert desktop().matches('(max-width: 2000px)')
	assert !desktop().matches('(max-width: 1023px)')
}

fn test_an_exact_width_matches_only_that_width() {
	assert desktop().matches('(width: 1024px)')
	assert !desktop().matches('(width: 1023px)')
}

fn test_height_features_use_the_height() {
	assert at(800, 600).matches('(max-height: 600px)')
	assert !at(800, 600).matches('(min-height: 601px)')
}

fn test_the_range_features_are_the_obvious_combination() {
	assert desktop().matches('(min-width: 400px) and (max-width: 1200px)')
	assert !desktop().matches('(min-width: 400px) and (max-width: 1000px)')
}

fn test_four_hundred_px_of_landscape_and_similar_spellings_parse_the_same() {
	// The whole reason the prelude goes back through the tokenizer.
	assert desktop().matches('(min-width:400px)')
	assert desktop().matches('( min-width : 400px )')
	assert desktop().matches('(MIN-WIDTH: 400PX)')
}

fn test_em_resolves_against_the_root_font_size() {
	mut c := desktop()
	c.root_font_size = 16.0
	assert c.matches('(min-width: 64em)')
	assert !c.matches('(min-width: 65em)')
}

fn test_rem_and_em_are_the_same_size_in_a_media_query() {
	// MQ4 resolves both against the initial font size, and this context has only one
	// font size in it.
	mut c := desktop()
	c.root_font_size = 10.0
	assert c.matches('(min-width: 100rem)')
	assert c.matches('(min-width: 100em)')
}

fn test_zero_is_a_length_and_a_bare_number_is_not() {
	assert desktop().matches('(min-width: 0)')
	// A bare 500 is a mistake in the stylesheet, and reading it as pixels would make
	// the mistake work.
	assert !desktop().matches('(min-width: 500)')
}

fn test_an_unknown_unit_is_false() {
	assert !desktop().matches('(min-width: 40pt)')
	assert !desktop().matches('(min-width: 50%)')
}

fn test_a_feature_with_no_value_is_false() {
	// MQ4 would say `(width)` is true; MQ3 says false and this follows MQ3 so a
	// stylesheet does not change meaning between the two readings.
	assert !desktop().matches('(width)')
}

// --- no viewport -------------------------------------------------------------

fn test_no_viewport_matches_no_dimensioned_query() {
	c := unknown()
	assert !c.matches('(min-width: 1px)')
	assert !c.matches('(max-width: 100000px)')
	assert !c.matches('(width: 0)')
}

fn test_no_viewport_still_matches_the_non_dimensioned_queries() {
	// `all` and `screen` are true whatever the size, so a stylesheet wrapped in
	// `@media screen` is not lost on a caller that has no window.
	c := unknown()
	assert c.matches('screen')
	assert c.matches('all')
}

fn test_a_known_viewport_of_zero_is_not_the_same_as_no_viewport() {
	// Zero-sized is a real viewport and it is narrower than any max-width, so the
	// mobile branch matches. "Not told" matches nothing.
	assert at(0, 0).matches('(max-width: 100px)')
	assert !unknown().matches('(max-width: 100px)')
}

// --- orientation and colour scheme -------------------------------------------

fn test_orientation_comes_from_the_numbers_rather_than_a_feature() {
	assert at(800, 600).matches('(orientation: landscape)')
	assert !at(800, 600).matches('(orientation: portrait)')
	assert at(375, 667).matches('(orientation: portrait)')
}

fn test_a_square_viewport_is_portrait() {
	// Equal is not greater, and this is the case a `<` would get wrong.
	assert at(500, 500).matches('(orientation: portrait)')
}

fn test_orientation_needs_a_viewport() {
	assert !unknown().matches('(orientation: landscape)')
}

fn test_prefers_color_scheme_follows_the_context() {
	mut light := desktop()
	assert light.matches('(prefers-color-scheme: light)')
	assert !light.matches('(prefers-color-scheme: dark)')
	light.prefers_dark = true
	assert light.matches('(prefers-color-scheme: dark)')
	assert !light.matches('(prefers-color-scheme: light)')
}

fn test_prefers_color_scheme_defaults_to_light() {
	assert unknown().matches('(prefers-color-scheme: light)')
}

// --- query lists -------------------------------------------------------------

fn test_a_comma_means_any_of_them() {
	q := '(min-width: 1000px), (max-width: 400px)'
	assert desktop().matches(q)
	assert phone().matches(q)
	// Neither branch: 375 is not over 1000, and it is not under 400... it is, so this
	// one does match. The point is the middle.
	assert !at(800, 600).matches(q)
}

fn test_a_trailing_comma_leaves_the_list_matching() {
	// Per the spec an empty query is true. `@media screen, { ... }` is what a
	// generator that emitted an empty condition produces.
	assert desktop().matches('screen, ')
	assert desktop().matches('screen,,print')
}

fn test_an_and_inside_parentheses_is_not_a_list_separator() {
	assert desktop().matches('screen and (min-width: 100px)')
}

// --- unknown features --------------------------------------------------------

fn test_an_unknown_feature_is_false() {
	assert !desktop().matches('(aspect-ratio: 16/9)')
	assert !desktop().matches('(resolution: 2dppx)')
	assert !desktop().matches('(hover)')
	assert !desktop().matches('(-webkit-touch-callout: none)')
}

fn test_one_unknown_feature_fails_the_whole_query() {
	// Not "the known ones still apply": a query is a conjunction and an unmeasurable
	// term makes it unanswerable.
	assert !desktop().matches('(min-width: 100px) and (aspect-ratio: 16/9)')
}

fn test_an_unknown_feature_does_not_fail_a_list_that_has_a_known_one() {
	assert desktop().matches('(aspect-ratio: 16/9), (min-width: 100px)')
}

fn test_a_range_form_is_false() {
	// MQ4's `(width >= 600px)`. Not implemented, and false rather than true.
	assert !desktop().matches('(width >= 600px)')
	assert !desktop().matches('(400px <= width <= 700px)')
}

fn test_boolean_logic_inside_parentheses_is_false() {
	assert !desktop().matches('(not all)')
	assert !desktop().matches('screen and (width > 100px or hover)')
}

// --- malformed input ---------------------------------------------------------

fn test_an_unclosed_group_is_false() {
	assert !desktop().matches('(min-width: 400px')
}

fn test_a_group_with_no_feature_is_false() {
	assert !desktop().matches('(: 400px)')
	assert !desktop().matches('()')
}

fn test_surrounding_whitespace_and_case_do_not_matter() {
	assert desktop().matches('  SCREEN  ')
	assert desktop().matches('\n(min-width: 100px)\n')
}

fn test_the_two_ends_of_a_phone_and_a_desktop_agree() {
	// A sanity check on the table as a whole: the queries a responsive stylesheet
	// actually contains, with the answers a reader would expect.
	queries := ['(max-width: 600px)', '(min-width: 601px)', '(min-width: 601px) and (max-width: 1200px)']
	assert phone().matches(queries[0])
	assert !phone().matches(queries[1])
	assert !phone().matches(queries[2])
	assert !desktop().matches(queries[0])
	assert desktop().matches(queries[1])
	assert desktop().matches(queries[2])
}
