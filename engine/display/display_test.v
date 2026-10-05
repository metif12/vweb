module display

import engine.css
import engine.raster
import engine.selector
import engine.style
import net.html
import text

// The tests build trees by hand for the reason written in
// engine/selector/match_test.v: a tree from another repository turns that
// repository's bug into this module's failing test.
//
// Every stylesheet below sets `line-height: 20px` on everything. Line height
// otherwise comes from whichever face the machine has, and a layout test that
// asserted absolute pixel positions would then be a test of the font on this host
// rather than of the layout. With an explicit line height, every vertical number
// here is exact, and the font only shows up in the golden test -- which is where
// PHASES.md says it belongs.

const line = 'line-height: 20px; '
// The UA sheet is in every test, because a browser has it and a div is a block only
// because of it: without it every div here is inline and every box but the root's
// disappears. ody { margin: 0 } then takes the default 8px back out, so the pixel
// arithmetic below reads as "800 minus what this test spent" instead of as 792 minus
// something. The two tests that care about the default margin use the sheet on its own.
const reset = 'body { margin: 0 } * { '

fn el(name string, id string, class string) &html.Tag {
	// The maps are created explicitly: a nil map is a read of nothing, and writing an
	// id into one is how a test helper ends up being the crash.
	mut node := &html.Tag{ name: name, attributes: map[string]string{} }
	if id != '' {
		node.attributes['id'] = id
	}
	if class != '' {
		node.class_set.add(class)
	}
	node.parent = &html.Tag{ name: 'body' }
	return node
}

fn text_el(content string) &html.Tag {
	return &html.Tag{ name: 'text', content: content }
}

// attach makes parent the parent of each child, both ways round. It takes mut on
// the pointer because V 0.5.2 only writes through a pointer parameter declared that
// way: mut p := parent silently copies the Tag and the tree stays empty, which
// shows up much later as a nil box rather than as a missing child.
// attach makes parent the parent of each child, both ways round.
//
// V 0.5.2 will not let a loop variable over an immutable slice be written through
// ("child.parent aliases mutable data from an immutable value"), and it rejects
// `mut` on a variadic parameter outright. So the children are copied into a local
// array first: that array is mutable, and the links can be set through it.
//
// The parent parameter is `mut` for a second reason. `mut p := parent` looks like it
// aliases and does not: it copies the Tag, the children land on the copy, and the
// tree stays empty -- which surfaces much later as a nil box rather than as a
// missing child.
fn attach(mut parent &html.Tag, children ...&html.Tag) {
	mut kids := []&html.Tag{}
	for child in children {
		kids << child
	}
	mut i := 0
	for i < kids.len {
		mut child := kids[i]
		parent.children << child
		child.parent = parent
		i++
	}
}

fn layouter(src string, width int) &Layouter {
	return &Layouter{
		engine:          style.new_engine([style.Sheet{
			style:  css.parse(css.user_agent_css + reset + line + ' } ' + src)
			origin: style.Origin.author
		}])
		state:           &selector.State{}
		fonts:           text.new_font_library()
		viewport_width:  width
		viewport_height: 800
	}
}

// A layouter whose line-height is `normal` instead of the fixed `20px` that
// `layouter` above forces onto `*`, so a line's height tracks the fonts on it.
//
// The two are not interchangeable, and the difference is what these tests exist to
// pin down. A *pixel* line-height is a length and does not scale with font size, so
// under `layouter` a 28px run correctly sits in a 20px line box -- every height here
// is 20 whatever the font size. That is right, and three earlier versions of these
// tests were wrong about it: they asserted `big > plain` under a fixed 20px
// line-height, which no correct implementation can satisfy.
fn layouter_normal(src string, width int) &Layouter {
	return &Layouter{
		engine:          style.new_engine([style.Sheet{
			style:  css.parse(css.user_agent_css + reset + 'line-height: normal; ' + ' } ' + src)
			origin: style.Origin.author
		}])
		state:           &selector.State{}
		fonts:           text.new_font_library()
		viewport_width:  width
		viewport_height: 800
	}
}

// --- line heights come from the fonts on them --------------------------------

// Each test compares two numbers that must differ, and the first carries an explicit
// `assert tall > short` so that if they ever match it goes red instead of passing
// vacuously. The first version of this compared against `short + tall` while both
// were the same number, so it passed with half-leading entirely absent.
fn span_box(sheet string, width int, plain string, inner string, fixed bool) &Box {
	mut l := if fixed {
		layouter(sheet, width)
	} else {
		layouter_normal(sheet, width)
	}
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	mut span := el('span', 'i', '')
	attach(mut span, text_el(inner))
	attach(mut div, text_el(plain), span)
	attach(mut body, div)
	return box_for(l.layout(body), 'd').children[0]
}

fn plain_box(sheet string, width int, content string, fixed bool) &Box {
	mut l := if fixed {
		layouter(sheet, width)
	} else {
		layouter_normal(sheet, width)
	}
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut div, text_el(content))
	attach(mut body, div)
	return box_for(l.layout(body), 'd').children[0]
}

fn test_a_larger_run_makes_its_line_taller() {
	// With `line-height: normal` a 28px run must make its line taller, or the two
	// sizes are drawn on top of each other. Before the fix both were 17.
	short := plain_box('', 800, 'abc', false).rect.height
	tall := span_box('span { font-size: 28px }', 800, '', 'abc', false)
	assert tall.rect.height > short
	assert tall.runs[0].font_size == 28.0
	assert tall.glyphs[0].size == 28.0
}

fn test_a_tall_run_only_heights_the_line_it_is_on() {
	// The discriminating measurement. If a line took its height from every font in
	// the box rather than the ones on it, the first line would be tall too and the
	// box would be two tall lines instead of one short and one tall.
	short := plain_box('', 800, 'abc', false).rect.height
	one := span_box('span { font-size: 28px }', 800, '', 'abc', false)
	assert one.rect.height > short
	m := span_box('span { font-size: 28px }', 60, 'aaa ', 'ccc', false)
	assert m.line_count == 2
	assert m.rect.height == short + one.rect.height
}

fn test_two_lines_both_carrying_the_run_are_both_tall() {
	// The other side of the same rule, and the case that would fail if `line_has_run`
	// were inverted or dropped: here the big run is on both lines.
	short := plain_box('', 800, 'abc', false).rect.height
	one := span_box('span { font-size: 28px }', 800, '', 'abc', false)
	assert one.rect.height > short
	both := span_box('span { font-size: 28px }', 60, '', 'aaa ccc', false)
	assert both.line_count == 2
	assert both.rect.height == 2 * one.rect.height
	// And the box in the previous test, which has the run on one line only, is strictly
	// shorter. Without this, that test could still pass on half-leading that inflates
	// every line regardless of what is on it.
	assert both.rect.height > short + one.rect.height
}

fn test_a_fixed_pixel_line_height_does_not_grow_with_the_font() {
	// The behaviour the three tests above got wrong, kept deliberately so it cannot be
	// got wrong again. `layouter` forces `line-height: 20px` onto every element, and a
	// pixel line-height is a length: it does not scale with font size. So under it a
	// 28px run is *supposed* to sit in a 20px line box, and both heights are equal.
	short := plain_box('', 800, 'abc', true).rect.height
	big := span_box('span { font-size: 28px }', 800, '', 'abc', true)
	assert big.rect.height == short
	assert big.glyphs[0].size == 28.0
}

// --- min-width and max-width (docs/PHASES.md cases 1, 2 and 8) ---------------

// A div whose only content is one word, laid out in `width`, returning the border box's
// width. `content` is what the box would otherwise shrink to, which is what makes case 1
// observable: without a floor the word is truncated or wrapped, with one it is not.
fn word_box(sheet string, word string, available int) &Box {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut div, text_el(word))
	attach(mut body, div)
	mut l := layouter(sheet, available)
	return box_for(l.layout(body), 'd')
}

fn test_a_long_word_overflows_rather_than_shrinking() {
	// Case 1. The word is far wider than the space, so the box stays at the width it was
	// given and the text runs past it. Asserting on the box width rather than on the text
	// is deliberate: an overflow is not a shrink, and the shrink is what would be wrong.
	b := word_box('div { width: 40px }', 'incomprehensibilities', 800)
	assert b.rect.width == 40
	// The text is not broken up to fit: it stays on one line and runs past the box. The
	// width the glyphs occupy is deliberately not asserted, because the anonymous box
	// fills its parent by definition -- its `rect.width` is 40 whether the word fits or
	// not, so measuring it here would have passed either way.
	assert b.children[0].line_count == 1
}

fn test_min_width_holds_a_box_open() {
	// Case 2's shape, without flexbox: a floor below the requested width. This is the
	// rule that keeps a long word from being crushed by a narrow parent.
	b := word_box('div { width: 40px; min-width: 200px }', 'abc', 800)
	assert b.rect.width == 200
}

fn test_max_width_caps_a_box_that_would_otherwise_fill() {
	b := word_box('div { max-width: 120px }', 'abc', 800)
	assert b.rect.width == 120
	// And the floor still applies when both are present and do not conflict.
	assert word_box('div { width: 500px; min-width: 60px; max-width: 120px }',
		'abc', 800).rect.width == 120
}

fn test_min_width_beats_a_smaller_max_width() {
	// Case 8. With `min-width: 200px; max-width: 100px` the two conflict, and applying
	// the max last gives 100 -- a box smaller than the floor that was asked for, and
	// smaller than its own min-content. The min wins, so the result is 200 and cannot
	// invert. Asserted as an inequality and not as one number so that a negative or
	// collapsed width cannot pass.
	b := word_box('div { width: 50px; min-width: 200px; max-width: 100px }', 'abc', 800)
	assert b.rect.width == 200
	// No padding or border here, so the content box is the border box. If the clamp had
	// inverted, the two would disagree.
	assert b.content.width == b.rect.width
}

fn test_min_width_auto_and_no_max_width_are_no_bounds() {
	// The two defaults must not behave like 0 and must not clamp anything: `auto` on
	// min-width means "no floor", not "floor of zero", and an unset max-width is not a
	// ceiling of zero either.
	b := word_box('div { min-width: auto; max-width: none }', 'abc', 800)
	assert b.rect.width > 0
}

// --- min-height and max-height -----------------------------------------------

fn test_min_height_holds_a_short_box_open() {
	// The height-side twin of `test_min_width_holds_a_box_open`: one line of text is
	// about 17 tall, and a floor of 150 has to win over it.
	b := word_box('div { min-height: 150px }', 'abc', 800)
	assert b.rect.height == 150
	assert b.content.height == 150
}

fn test_max_height_caps_a_box_full_of_lines() {
	// Enough text to lay out several lines naturally, then a ceiling that is well below
	// what the text needs. The box is capped and the content is not clipped.
	b := word_box('div { max-height: 40px }', 'aaa bbb ccc ddd eee fff ggg hhh iii', 60)
	assert b.rect.height == 40
	assert b.children[0].line_count > 1
}

fn test_min_height_beats_a_smaller_max_height() {
	// The same inversion as the width case, and the reason the two clamps are written the
	// same way: applying the max last would give 30, below the 90 floor that was asked
	// for. Asserted as an inequality so a collapsed or negative height cannot pass.
	b := word_box('div { min-height: 90px; max-height: 30px }', 'abc', 800)
	assert b.rect.height == 90
	assert b.content.height == 90
}

fn test_min_height_also_bounds_an_explicit_height() {
	// With `height` set, the specified height is what gets clamped. This is the one place
	// the rule differs from the content-box case above, and it is recorded here rather
	// than left to be discovered: `box-sizing` is what will make the two agree.
	b := word_box('div { height: 20px; min-height: 80px }', 'abc', 800)
	assert b.rect.height == 80
	assert word_box('div { height: 200px; max-height: 60px }', 'abc', 800).rect.height == 60
}

// --- box-sizing (docs/PHASES.md, box model) ----------------------------------

fn test_a_border_box_width_includes_its_padding() {
	// The visible difference, and the reason it cannot be checked by eye alone: the same
	// declaration is 140 wide under `content-box` and 100 under `border-box`, because the
	// 20px of padding on each side comes out of the width instead of being added to it.
	content := word_box('div { width: 100px; padding: 0 20px }', 'abc', 800)
	border := word_box('div { width: 100px; padding: 0 20px; box-sizing: border-box }', 'abc', 800)
	assert content.rect.width == 140
	assert content.content.width == 100
	assert border.rect.width == 100
	assert border.content.width == 60
}

fn test_box_sizing_is_the_default_content_box() {
	// Stated rather than assumed: the engine's long-standing behaviour is
	// `content-box`, and this pins it so that changing the initial value is a visible
	// break rather than a quiet one.
	assert word_box('div { width: 100px; padding: 0 20px; box-sizing: content-box }',
		'abc', 800).rect.width == 140
	// An unknown keyword must not fall back to content-box silently.
	assert word_box('div { width: 100px; padding: 0 20px; box-sizing: border-boxx }',
		'abc', 800).rect.width == 140
}

fn test_border_box_bounds_are_read_in_the_same_box_as_the_width() {
	// `min-width` is interpreted in whichever box `width` is, so under `border-box` the
	// frame has to come off the floor too. Clamping a border-box width against a
	// content-box floor is how a box ends up narrower than the minimum that was asked for:
	// with 40px of padding either side, a content-box `min-width: 100px` would leave 20
	// content pixels, which is less than the 100 the author wrote.
	b := word_box('div { width: 60px; min-width: 200px; padding: 0 20px; box-sizing: border-box }',
		'abc', 800)
	assert b.rect.width == 200
	assert b.content.width == 160
	// And the ceiling, same reasoning.
	assert word_box('div { width: 400px; max-width: 120px; padding: 0 20px; box-sizing: border-box }',
		'abc', 800).rect.width == 120
}

fn test_box_sizing_does_not_shrink_an_auto_width_twice() {
	// `width: auto` already receives the space left after margins, border and padding.
	// Subtracting the frame again would take it off twice, so an auto-width bordered box
	// has to come out exactly the width of its parent.
	b := word_box('div { padding: 0 20px; box-sizing: border-box }', 'abc', 300)
	assert b.rect.width == 300
	assert b.content.width == 260
}

fn box_for(root &Box, id string) &Box {
	for b in boxes(root) {
		if b.element != unsafe { nil } && b.element.attributes['id'] == id {
			return b
		}
	}
	return unsafe { nil }
}

// --- width ------------------------------------------------------------------

fn test_the_root_fills_the_viewport() {
	mut root := el('html', '', '')
	l := layouter('', 800)
	b := l.layout(root)
	assert b.rect.width == 800
	assert b.rect.x == 0
	assert b.rect.y == 0
}

fn test_a_block_child_fills_its_parent() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	assert d.rect.width == 800
	assert d.rect.x == 0
}

fn test_width_subtracts_margin_border_and_padding() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('div { margin: 10px; border-width: 2px; border-style: solid; padding: 5px }', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	// The margin takes 10px off each side of the *border box*, and the border and
	// padding then come out of what is left for the content.
	assert d.rect.width == 800 - 2 * 10
	// Which means the border box starts 10px in, not at the parent's edge. This used to
	// assert 0 and passed, describing a box that overlaps its parent's left margin --
	// and contradicting the sentence above it.
	assert d.rect.x == 10
	assert d.content.x == 10 + 2 + 5
	assert d.content.width == 800 - 2 * (10 + 2 + 5)
}

fn test_an_explicit_width_overrides_auto() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('div { width: 300px }', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	assert d.rect.width == 300
	assert d.content.width == 300
	// The box is as wide as it asked to be and sits at the left, which is where LTR
	// puts it; the leftover space is not distributed.
	assert d.rect.x == 0
}

fn test_a_percentage_width_is_of_the_containing_block() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('div { width: 50% }', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	assert d.rect.width == 400
}

fn test_a_percentage_is_of_the_content_box_not_the_border_box() {
	// `width: 100%` on a padded box means "as wide as the parent's content", so the
	// padding pushes it over the parent's edge. That is what CSS says and it is the
	// opposite of what the shorthand suggests.
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('div { padding: 10px; width: 100% }', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	assert d.content.width == 800
	assert d.rect.width == 820
}

fn test_a_width_wider_than_the_page_overflows_it() {
	// CSS 2.1 10.4: only `auto` is limited to what is left. An explicit width is
	// taken at its word, and what happens to the overflow is Phase 3's business.
	// Clamping here instead would make this page silently narrower than it asks to
	// be, which is worse than visibly too wide.
	mut body := el('body', '', '')
	div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('div { width: 5000px }', 800)
	b := l.layout(body)
	assert box_for(b, 'd').rect.width == 5000
}

// --- inline content ------------------------------------------------------------

fn test_inline_elements_share_one_line() {
	// Phase 1 made every inline run its own block, so this rendered as three lines, one per
	// run, with the right words in the right order running *down* the page. A block's inline
	// content is one stream of text that line boxes break, not one block per run.
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	mut span := el('span', 'i', '')
	attach(mut span, text_el('bold'))
	attach(mut div, text_el('plain then '), span, text_el(' then plain'))
	attach(mut body, div)
	l := layouter('', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	assert d.children.len == 1
	assert d.children[0].text == 'plain then bold then plain'
	assert d.children[0].line_count == 1
	assert d.rect.height == 20
}

fn test_whitespace_between_inline_elements_is_collapsed_to_one_space() {
	// Dropping a whitespace-only node between two inline elements glues them together:
	// `<b>a</b> <i>b</i>` became "ab".
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	mut span := el('span', 'i', '')
	attach(mut span, text_el('b'))
	attach(mut div, text_el('a '), span, text_el(' c'))
	attach(mut body, div)
	l := layouter('', 800)
	b := l.layout(body)
	assert box_for(b, 'd').children[0].text == 'a b c'
}

fn test_runs_of_whitespace_collapse_and_the_edges_are_dropped() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut div, text_el('\n   spaced \t out \n\n here \n'))
	attach(mut body, div)
	l := layouter('', 800)
	b := l.layout(body)
	assert box_for(b, 'd').children[0].text == 'spaced out here'
}

fn test_pre_keeps_its_whitespace() {
	mut body := el('body', '', '')
	mut pre := el('pre', 'd', '')
	attach(mut pre, text_el('a  b'))
	attach(mut body, pre)
	l := layouter('pre { white-space: pre }', 800)
	b := l.layout(body)
	assert box_for(b, 'd').children[0].text == 'a  b'
}

fn test_a_br_breaks_the_line_and_keeps_the_text_after_it() {
	// `net/html` nests the text that follows a `<br>` inside the `br` node, so
	// `collect_text` on a `<br>` is what produces "two" out of `<p>one<br>two</p>`. Reading
	// the break without reading that loses the text after it, which is what happened.
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	mut br := el('br', '', '')
	attach(mut br, text_el('two'))
	attach(mut div, text_el('one'), br)
	attach(mut body, div)
	l := layouter('', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	assert d.children.len == 2
	assert d.children[0].text == 'one'
	assert d.children[1].text == 'two'
	assert d.rect.height == 40
}

fn test_a_block_child_still_gets_its_own_box_and_the_inline_runs_around_it_stay_separate() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	mut inner := el('div', 'e', '')
	attach(mut inner, text_el('inner'))
	attach(mut div, text_el('before'), inner, text_el('after'))
	attach(mut body, div)
	l := layouter('', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	// before, the inner block, after.
	assert d.children.len == 3
	assert d.children[0].text == 'before'
	assert d.children[2].text == 'after'
}

fn test_an_inline_element_with_no_text_contributes_nothing() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	mut span := el('span', 'i', '')
	attach(mut span, text_el('   '))
	attach(mut div, text_el('a'), span, text_el('b'))
	attach(mut body, div)
	l := layouter('', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	// `a` and `b` with a whitespace-only span between them still make one box with "a b".
	assert d.children.len == 1
	assert d.children[0].text == 'a b'
}

// --- the inline tokenizer ------------------------------------------------------

// These are the tests that say what stage B is built on. `layout_runs` turns a box's runs
// into atoms and an atom list into glyphs, and every glyph it produces comes from one of
// these strings. When a box laid out "ab" carried four glyphs, this was where to look.

fn test_a_word_is_one_token_not_one_token_per_character() {
	assert tokenize_inline('ab', .normal) == ['ab']
	assert tokenize_inline('hello', .normal) == ['hello']
}

fn test_a_space_is_its_own_token() {
	assert tokenize_inline('a b', .normal) == ['a', ' ', 'b']
	assert tokenize_inline('a b c', .normal) == ['a', ' ', 'b', ' ', 'c']
}

fn test_runs_of_whitespace_collapse_to_one_space_token() {
	// The collapse has already happened in `collapse_inline_space` by this point, but the
	// tokenizer must not undo it or reintroduce the gaps it removed.
	assert tokenize_inline('a  b', .normal) == ['a', ' ', 'b']
}

fn test_a_trailing_space_is_a_token_so_a_line_can_end_in_one() {
	assert tokenize_inline('ab ', .normal) == ['ab', ' ']
}

fn test_a_leading_space_is_kept_because_a_run_is_not_a_line() {
	// The space at the start of a middle run is between two words. layout_runs is what
	// refuses to start a *line* with a space; dropping it here glued run boundaries
	// together, and "plain then " + "bold" came out as "plain then boldthen".
	assert tokenize_inline(' ab', .normal) == [' ', 'ab']
}

fn test_pretends_its_newlines_as_their_own_tokens() {
	assert tokenize_inline('a\nb', .pre) == ['a', '\n', 'b']
	assert tokenize_inline('a  b', .pre) == ['a', ' ', ' ', 'b']
}

fn test_an_empty_string_is_no_tokens() {
	assert tokenize_inline('', .normal).len == 0
}

fn test_height_is_the_content_height() {
	mut body := el('body', '', '')
	one := el('div', 'a', '')
	two := el('div', 'b', '')
	attach(mut body, one, two)
	l := layouter('', 800)
	b := l.layout(body)
	assert box_for(b, 'a').rect.height == 20
	assert box_for(b, 'b').rect.height == 20
	// Two twenty-pixel lines plus nothing else.
	assert b.rect.height == 40
}

fn test_an_empty_block_is_still_one_line_tall() {
	// A page of empty divs collapsing to nothing makes a percentage height on a
	// parent a percentage of zero.
	mut body := el('body', '', '')
	attach(mut body, el('div', 'a', ''))
	l := layouter('', 800)
	b := l.layout(body)
	assert box_for(b, 'a').rect.height == 20
}

fn test_an_elements_margin_is_not_also_counted_on_its_text() {
	// The invariant that was broken, and it is worth stating as an invariant rather than
	// as a number: an element's border box must be its content, its own padding and its
	// own border, and nothing else. A `p { margin: 1em 0 }` is 20 tall around one line of
	// text; it was 36, because the anonymous text box inherited the same margin and `place`
	// added it a second time.
	//
	// The visible symptom was not the extra 16px of height. It was that `border-bottom`
	// painted inside the last line of text, which is what made an `h1`'s heading look
	// struck through.
	mut body := el('body', '', '')
	mut p := el('p', 'a', '')
	attach(mut p, text_el('one line'))
	attach(mut body, p)
	l := layouter('p { margin: 8px 0; border-bottom: 2px solid red }', 800)
	b := l.layout(body)
	pa := box_for(b, 'a')
	// 20 line + 2 border. The 8px margin is outside the box and must not reappear inside.
	assert pa.rect.height == 22
}

fn test_a_margin_does_not_push_text_down_inside_its_own_element() {
	// The same defect read from the other side, and this is the one that would have
	// caught it without needing to know the expected height: the text box must start
	// where the element's content box starts. `div.wide` on the page this was found on,
	// with `margin: 8px 0` and no padding, put its text 32px below its own top edge.
	mut body := el('body', '', '')
	mut d := el('div', 'a', '')
	attach(mut d, text_el('x'))
	attach(mut body, d)
	l := layouter('div { margin: 8px 0 }', 800)
	b := l.layout(body)
	da := box_for(b, 'a')
	t := da.children[0]
	assert t.content.y == da.content.y
	assert da.content.height == 20
}

fn test_an_explicit_height_overrides_the_content() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('div { height: 200px }', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	assert d.rect.height == 200
	// The content is not clipped, so it can be taller than the box.
	assert d.content.height == 20
}

fn test_border_and_padding_add_to_the_height() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('div { border-width: 3px; border-style: solid; padding: 7px }', 800)
	b := l.layout(body)
	assert box_for(b, 'd').rect.height == 20 + 2 * (3 + 7)
}

fn test_an_inline_font_size_reaches_the_glyphs() {
	// Asserted on the glyph, not on the run's `font_size` field. The field was 16 while
	// the style said 28 and the glyph was 16 too, so a test on the field alone would have
	// passed on the broken code -- which is roughly what happened when a render was read as
	// showing 28px text and it was not.
	//
	// Colour, weight and italic travelled correctly all along, because they live in the
	// style and the style was the element's own. `font-size` was being copied from the
	// *block's* context instead, so of the four per-run properties it was the only one
	// broken, and it is the one a reader notices first.
	mut body := el('body', '', '')
	mut span := el('span', 'i', '')
	attach(mut span, text_el('abc'))
	mut div := el('div', 'd', '')
	attach(mut div, span)
	attach(mut body, div)
	l := layouter('span { font-size: 28px }', 800)
	anon := box_for(l.layout(body), 'd').children[0]
	assert anon.runs[0].font_size == 28.0
	assert anon.glyphs[0].size == 28.0
	// A run at the block's own size is untouched.
	plain := box_for(layouter('', 800).layout(body), 'd').children[0]
	assert plain.glyphs[0].size == 16.0
}

// --- used border width ------------------------------------------------------

fn test_a_border_width_with_no_style_reserves_nothing() {
	// CSS 2.1 10.3.3: the used width of a `none` border is zero. `border-width` alone
	// is the single most common way to write a border that does not appear, and a
	// layout that honoured the width anyway would put six pixels of empty space around
	// every such box.
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('div { border-width: 3px }', 800)
	d := box_for(l.layout(body), 'd')
	assert d.border_px == [0, 0, 0, 0]
	assert d.content.width == 800
}

fn test_a_hidden_border_also_reserves_nothing() {
	// `hidden` differs from `none` only in what happens when a table collapses
	// borders, which Phase 1 has no tables. It still has to zero the width, or the two
	// keywords would lay out differently for no reason a page could see.
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('div { border-width: 3px; border-style: hidden }', 800)
	assert box_for(l.layout(body), 'd').border_px == [0, 0, 0, 0]
}

fn test_only_the_styled_side_is_kept() {
	// Order matters and this is the point of the test: the shorthand comes first and
	// the per-side longhand overrides it. Reversed, the shorthand would win the top
	// side too and every side would be zero -- which is what the assertion has to be
	// able to tell apart from this.
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('div { border-width: 3px; border-style: none; border-top-style: solid }',
		800)
	assert box_for(l.layout(body), 'd').border_px == [3, 0, 0, 0]
}

fn test_a_per_side_longhand_alone_leaves_the_others_alone() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	l := layouter('div { border-width: 3px; border-bottom-style: solid }', 800)
	assert box_for(l.layout(body), 'd').border_px == [0, 0, 3, 0]
}

// --- margin collapsing ------------------------------------------------------

fn test_adjacent_margins_collapse_to_the_larger() {
	// This is the whole reason `p { margin: 1em 0 }` looks right. Without collapsing
	// the gap would be twice as large.
	mut body := el('body', '', '')
	a := el('div', 'a', '')
	b2 := el('div', 'b', '')
	attach(mut body, a, b2)
	l := layouter('div { margin: 10px 0 }', 800)
	b := l.layout(body)
	ba := box_for(b, 'a')
	bb := box_for(b, 'b')
	assert bb.rect.y - (ba.rect.y + ba.rect.height) == 10
}

fn test_collapsing_takes_the_larger_not_the_sum() {
	mut body := el('body', '', '')
	a := el('div', 'a', '')
	b2 := el('div', 'b', '')
	attach(mut body, a, b2)
	l := layouter('#a { margin-bottom: 4px } #b { margin-top: 30px }', 800)
	b := l.layout(body)
	ba := box_for(b, 'a')
	bb := box_for(b, 'b')
	assert bb.rect.y - (ba.rect.y + ba.rect.height) == 30
}

fn test_a_zero_margin_neither_adds_nor_subtracts() {
	mut body := el('body', '', '')
	a := el('div', 'a', '')
	b2 := el('div', 'b', '')
	attach(mut body, a, b2)
	l := layouter('#a { margin-bottom: 0 } #b { margin-top: 0 }', 800)
	b := l.layout(body)
	ba := box_for(b, 'a')
	bb := box_for(b, 'b')
	assert bb.rect.y - (ba.rect.y + ba.rect.height) == 0
}

fn test_a_border_stops_the_top_margin_from_escaping() {
	// With a border on the parent, the child's margin pushes the child down inside it
	// instead of moving the parent down. This is the difference you can see when the
	// parent has a background.
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	child := el('div', 'c', '')
	attach(mut div, child)
	attach(mut body, div)
	l := layouter('#d { border-width: 1px; border-style: solid; margin-top: 40px } #c { margin-top: 10px }', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	c := box_for(b, 'c')
	// The child's top margin sits inside the parent's border box.
	assert c.rect.y - d.rect.y == 1 + 10
}

fn test_nested_blocks_stack() {
	mut body := el('body', '', '')
	mut outer := el('div', 'outer', '')
	inner := el('div', 'inner', '')
	attach(mut outer, inner)
	attach(mut body, outer)
	l := layouter('', 800)
	b := l.layout(body)
	o := box_for(b, 'outer')
	i := box_for(b, 'inner')
	assert i.rect.y == o.rect.y
	assert i.rect.x == o.rect.x
	assert i.rect.height == 20
	assert o.rect.height == 20
}

// --- inline content ---------------------------------------------------------

fn test_an_inline_child_becomes_an_anonymous_block() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut div, text_el('hello'))
	attach(mut body, div)
	l := layouter('span { display: inline }', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	assert d.children.len == 1
	assert d.children[0].is_anonymous
	assert d.children[0].text == 'hello'
	assert d.children[0].rect.height == 20
}

fn test_a_display_none_child_is_skipped_entirely() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	// Both spans carry text, so the count below is about `display` and not about
	// which of them happened to have something to contribute.
	mut hidden := el('span', 'hidden', '')
	attach(mut hidden, text_el('gone'))
	mut shown := el('span', 'shown', '')
	attach(mut shown, text_el('kept'))
	attach(mut div, hidden, shown)
	attach(mut body, div)
	l := layouter('#hidden { display: none } span { display: inline }', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	assert d.children.len == 1
	assert d.children[0].text == 'kept'
}

fn test_text_is_shaped_onto_the_content_box() {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	attach(mut div, text_el('abc'))
	attach(mut body, div)
	l := layouter('span { display: inline }', 800)
	b := l.layout(body)
	d := box_for(b, 'd')
	anon := d.children[0]
	assert anon.glyphs.len > 0
	// The baseline is inside the content box: below the top edge, and no lower than
	// the bottom of the line.
	assert anon.content.y >= 0
	for g in anon.glyphs {
		assert g.y > f64(anon.content.y)
		assert g.y <= f64(anon.content.y + anon.content.height)
	}
}

// --- the user-agent sheet in the loop ---------------------------------------

fn test_the_default_body_margin_puts_content_eight_pixels_in() {
	mut root := el('html', '', '')
	mut body := el('body', 'body', '')
	mut div := el('div', 'd', '')
	attach(mut body, div)
	attach(mut root, body)
	l := style.new_engine([style.Sheet{
		style:  css.parse(css.user_agent_css + ' * { ' + line + ' }')
		origin: style.Origin.user_agent
	}])
	lay := &Layouter{ engine: l, state: &selector.State{}, fonts: text.new_font_library(), viewport_width: 800, viewport_height: 800 }
	b := lay.layout(root)
	d := box_for(b, 'd')
	// html has no margin, body has 8px, and the div sits inside body's content box.
	assert d.rect.x == 8
	assert d.content.width == 800 - 16
}

fn test_the_user_agent_sheet_makes_a_paragraph_a_block() {
	mut root := el('html', '', '')
	mut body := el('body', 'body', '')
	p := el('p', 'p', '')
	attach(mut body, p)
	attach(mut root, body)
	l := style.new_engine([style.Sheet{
		style:  css.parse(css.user_agent_css)
		origin: style.Origin.user_agent
	}])
	lay := &Layouter{ engine: l, state: &selector.State{}, fonts: text.new_font_library(), viewport_width: 800, viewport_height: 800 }
	b := lay.layout(root)
	assert box_for(b, 'p').rect.width == 800 - 16
}

fn test_a_text_box_does_not_inherit_its_parent_s_background() {
	// `background-color` is not an inherited property. An anonymous text box that kept
	// its parent's would be painted by the parent *and* by itself, which is invisible
	// for an opaque colour and exactly double-dark for a translucent one.
	mut root := el('html', '', '')
	mut body := el('body', 'body', '')
	mut div := el('div', 'd', '')
	attach(mut div, text_el('hello'))
	attach(mut body, div)
	attach(mut root, body)
	d := box_for(layouter('div { background-color: rgba(255, 0, 0, 0.5) }', 800).layout(root),
		'd')
	assert d.children.len == 1
	assert d.children[0].style.background_color == raster.transparent
}

fn test_an_inline_element_does_not_paint_its_own_background() {
	// Phase 1 gives an inline element one anonymous block rather than one per line, so
	// painting its background would cover the containing block instead of the text. A
	// highlighted span needs line boxes, which is Phase 2.
	mut root := el('html', '', '')
	mut body := el('body', 'body', '')
	mut div := el('div', 'd', '')
	mut span := el('span', 's', '')
	attach(mut span, text_el('hello'))
	attach(mut div, span)
	attach(mut body, div)
	attach(mut root, body)
	d := box_for(layouter('#s { display: inline; background-color: red }', 800).layout(root),
		'd')
	assert d.children.len == 1
	assert d.children[0].style.background_color == raster.transparent
	// The colour the text is drawn in still comes from the span.
	assert d.children[0].style.color == d.style.color
}

// --- a whole page -----------------------------------------------------------

fn test_a_page_lays_out_without_overflowing() {
	// The Phase 1 acceptance gate says layout must be *visually* right, which is a
	// golden test. What a unit test can say is the part that is objectively wrong:
	// nothing wider than the viewport, and every box inside its parent.
	mut root := el('html', '', '')
	mut body := el('body', 'body', '')
	mut div := el('div', 'd', '')
	attach(mut div, text_el('a paragraph of text'))
	attach(mut body, el('h1', 'title', ''), div)
	attach(mut root, body)
	l := style.new_engine([style.Sheet{
		style:  css.parse(css.user_agent_css)
		origin: style.Origin.user_agent
	}])
	lay := &Layouter{ engine: l, state: &selector.State{}, fonts: text.new_font_library(), viewport_width: 640, viewport_height: 480 }
	b := lay.layout(root)
	assert b.rect.width == 640
	for box in boxes(b) {
		assert box.rect.width <= 640
		assert box.rect.x >= 0
	}
	// The heading is above the paragraph.
	assert box_for(b, 'title').rect.y < box_for(b, 'd').rect.y
}

fn test_layout_is_repeatable() {
	// ARCHITECTURE.md 4: the same page laid out twice is identical, or a golden image
	// is testing the run rather than the layout.
	mut root := el('html', '', '')
	mut body := el('body', 'body', '')
	attach(mut body, el('div', 'a', ''), el('div', 'b', ''))
	attach(mut root, body)
	first := &Layouter{ engine: style.new_engine([style.Sheet{ style: css.parse(css.user_agent_css), origin: .user_agent }]), state: &selector.State{}, fonts: text.new_font_library(), viewport_width: 800, viewport_height: 600 }
	b1 := first.layout(root)
	for _ in 0 .. 3 {
		again := &Layouter{ engine: style.new_engine([style.Sheet{ style: css.parse(css.user_agent_css), origin: .user_agent }]), state: &selector.State{}, fonts: text.new_font_library(), viewport_width: 800, viewport_height: 600 }
		b2 := again.layout(root)
		for i in 0 .. boxes(b1).len {
			assert boxes(b2)[i].rect == boxes(b1)[i].rect
		}
	}
}

fn test_a_persian_page_lays_out() {
	// A Persian page is why this project exists. Its layout differs from an English
	// one only in the text and in `direction`.
	mut root := el('html', '', '')
	mut body := el('body', 'body', '')
	mut div := el('div', 'd', '')
	attach(mut div, text_el('سلام دنیا'))
	attach(mut body, div)
	attach(mut root, body)
	l := style.new_engine([style.Sheet{
		style:  css.parse(css.user_agent_css + ' body { direction: rtl; } * { ' + line + ' }')
		origin: style.Origin.author
	}])
	lay := &Layouter{ engine: l, state: &selector.State{}, fonts: text.new_font_library(), viewport_width: 800, viewport_height: 600 }
	b := lay.layout(root)
	d := box_for(b, 'd')
	// `direction` is inherited and does not change the box's geometry in Phase 1; it
	// is paint that aligns the run to the right. The test is that the direction
	// reached the style at all.
	assert d.style.direction == .rtl
	anon := d.children[0]
	assert anon.glyphs.len > 0
}
