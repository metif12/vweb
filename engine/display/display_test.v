module display

import engine.css
import engine.raster
import engine.selector
import engine.style
import math
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

fn test_a_long_word_is_not_broken_to_fit_a_narrow_box() {
	// Acceptance case 1, on the glyphs rather than only on the box. The test above
	// asserts the box kept its 40px; what this adds is the word itself: every glyph is
	// on one baseline, so it was not broken, and the glyphs are still 16px, so it was
	// not scaled down to fit. A narrower box, a mid-word break and a shrunken font are
	// the three ways this case can be got wrong, and each is caught here on its own.
	b := word_box('div { width: 40px }', 'incomprehensibilities', 800)
	assert b.rect.width == 40
	glyphs := b.children[0].glyphs
	assert glyphs.len > 0
	for g in glyphs {
		assert g.y == glyphs[0].y
		assert g.size == 16.0
	}
	// The word is still reported as wider than the box that holds it, which is what
	// says the box was not quietly narrowed to the space it was given.
	assert b.min_content_width > b.rect.width
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

// --- intrinsic sizes (docs/PHASES.md, min-content / max-content) ------------

fn test_max_content_is_the_text_on_one_line() {
	// `max-content` is the width with nothing wrapping, which for text is every word
	// laid end to end. Asserted as an inequality rather than a number, because the exact
	// width follows the font and the point is the *relation* to the other sizes.
	b := word_box('div { width: 400px }', 'aa bb cc', 800)
	one := word_box('div { width: 400px }', 'aa bb cc dd', 800)
	assert one.max_content_width > b.max_content_width
	// The box is laid out at its specified 400, not at its max-content: the two are
	// independent measurements and conflating them is the mistake this test exists to catch.
	assert b.rect.width == 400
	assert b.min_content_width < b.max_content_width
}

fn test_min_content_is_the_widest_single_word() {
	// A line may break between words but never inside one, so min-content is the width of
	// the longest word -- not the sum, and not the width of the longest *line* after
	// breaking. A one-word box is the degenerate case where the two must agree.
	many := word_box('div { width: 400px }', 'aa bbbbbbbbbb cc', 800)
	one := word_box('div { width: 400px }', 'bbbbbbbbbb', 800)
	assert many.min_content_width == one.min_content_width
	assert many.min_content_width < many.max_content_width
}

fn test_min_content_can_exceed_the_width_a_box_asked_for() {
	// Acceptance case 8 is about the clamp, and `test_min_width_beats_a_smaller_max_width`
	// covers it. What is worth asserting on the measurements is the case that produces it:
	// an unbreakable word whose min-content is larger than the width the box was given.
	//
	// Note that min-content and max-content are equal here, and correctly so: a box holding
	// a single unbreakable word has nothing to break, so both measurements are that word's
	// width. An earlier version of this test asserted `min > max` and was wrong -- a
	// measurement clamped into its opposite number would be the actual defect.
	b := word_box('div { width: 60px }', 'supercalifragilistic', 800)
	assert b.min_content_width > 0
	assert b.max_content_width > 0
	assert b.min_content_width <= b.max_content_width
	// The word does not fit in 60, so min-content says so, and the box still stays at the
	// 60 it was asked for rather than collapsing or going negative.
	assert b.min_content_width > b.rect.width
	assert b.rect.width == 60
}

fn test_a_parent_is_as_wide_as_its_widest_child() {
	// Intrinsic sizes propagate, which is what makes them usable for stretch-to-fit and
	// for an atomic inline-level box later. A parent containing one child inherits that
	// child's measurements plus its own frame.
	mut body := el('body', '', '')
	mut outer := el('div', 'outer', '')
	mut inner := el('div', 'inner', '')
	attach(mut inner, text_el('aa bbbbbbbb cc'))
	attach(mut outer, inner)
	attach(mut body, outer)
	mut l := layouter('', 800)
	root := l.layout(body)
	o := box_for(root, 'outer')
	i := box_for(root, 'inner')
	assert o.min_content_width == i.min_content_width
	assert o.max_content_width == i.max_content_width
}

fn test_a_box_with_padding_is_wider_intrinsically_than_one_without() {
	// The frame is part of the intrinsic size, not something subtracted afterwards. A
	// parent sizing itself to its content has to reserve the padding too, or the content
	// overflows the moment it takes that size.
	padded := word_box('div { padding: 0 20px }', 'aa bb cc', 800)
	plain := word_box('div { width: 400px }', 'aa bb cc', 800)
	assert padded.max_content_width - plain.max_content_width == 40
	assert padded.min_content_width > plain.min_content_width
}

// --- acceptance cases 3 and 6 ----------------------------------------------

fn test_a_percentage_width_resolves_against_a_parent_that_is_itself_a_percentage() {
	// Case 3. A percentage is against the parent's *used* width, not against the viewport,
	// so 50% of 50% of 800 is 200 and not 400. Getting this wrong is invisible on any page
	// whose parents all have pixel widths.
	mut body := el('body', '', '')
	mut outer := el('div', 'outer', '')
	mut inner := el('div', 'inner', '')
	attach(mut inner, text_el('abc'))
	attach(mut outer, inner)
	attach(mut body, outer)
	mut l := layouter('div { width: 50% }', 800)
	root := l.layout(body)
	o := box_for(root, 'outer')
	i := box_for(root, 'inner')
	assert o.rect.width == 400
	assert i.rect.width == 200
}

fn test_a_word_that_exactly_fits_stays_and_one_pixel_wider_breaks() {
	// Case 6. The boundary is `>` and not `>=`: a word that exactly fills the space fits,
	// and one pixel more does not. The widths are measured rather than written as numbers,
	// so the test does not depend on the font it happens to run with.
	//
	// The second word is the one that has to move. A *single* unbreakable word wider than
	// its container does not split -- it overflows, which is correct -- so testing the
	// boundary on one word would have been testing the wrong thing.
	// The whole string is measured as one unit, space included. Measuring the words
	// separately and adding them up forgets the space between them, which is itself an
	// atom with a width -- and that is exactly the kind of off-by-one this case is about.
	both_text := 'aa incomprehensibilities'
	w := word_box('div { width: 400px }', both_text, 800).max_content_width
	both := word_box('div { width: ${w}px }', both_text, 800)
	assert both.children[0].line_count == 1
	short := word_box('div { width: ${w - 1}px }', both_text, 800)
	assert short.children[0].line_count == 2
}

// --- acceptance case 4 -------------------------------------------------------

fn test_an_auto_width_fills_the_space_available() {
	// Case 4. A block with no width takes the space its parent leaves. The distinction that
	// matters is against max-content: an auto block is as wide as the *space*, not as wide
	// as its text, and conflating the two is what makes a block shrink to its content.
	b := word_box('div { }', 'aa bb cc', 800)
	assert b.rect.width == 800
	assert b.rect.width > b.max_content_width
	// Margins reduce the space, so they reduce the auto width too.
	m := word_box('div { margin: 0 50px }', 'aa bb cc', 800)
	assert m.rect.width == 700
	// A percentage is not `auto` and must not be treated as filling the space.
	assert word_box('div { width: 50% }', 'aa bb cc', 800).rect.width == 400
}

// --- inline-block as an atomic box ------------------------------------------

fn inline_block_div(sheet string) &Box {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	mut span := el('span', 'ib', '')
	attach(mut span, text_el('X'))
	attach(mut div, text_el('a'), span, text_el('b'))
	attach(mut body, div)
	mut l := layouter(sheet, 800)
	return box_for(l.layout(body), 'd')
}

fn test_an_inline_block_shares_a_line_with_the_text_around_it() {
	d := inline_block_div('span { display: inline-block; width: 20px }')
	assert d.children.len == 1
	assert d.children[0].line_count == 1
	assert d.children[0].atomics.len == 1
	assert d.children[0].text == 'a b'
}

fn test_an_inline_block_is_never_broken() {
	d := inline_block_div('span { display: inline-block; width: 900px }')
	assert d.children[0].atomics.len == 1
	assert d.children[0].atomics[0].rect.width == 900
}

fn test_an_inline_block_is_laid_out_as_a_box() {
	d := inline_block_div('span { display: inline-block; width: 30px; height: 25px }')
	assert d.children[0].atomics[0].rect.width == 30
	assert d.children[0].atomics[0].rect.height == 25
}

// --- stretch-to-fit: an atomic inline-level box with width auto --------------

// An inline-block holding `inner` as its only content, inside a div of `width`, and
// returning that div. Its content box is the line the box has to fit into -- the div
// has no frame of its own here -- so the width is the space available before the box's
// own margins take their share.
//
// The width is a parameter rather than something inside `sheet` because every test here
// is the same box in a different amount of space: wider than the content, between the
// two intrinsic widths, and narrower than both.
fn atomic_div(sheet string, width int, inner string) &Box {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	mut span := el('span', 'ib', '')
	attach(mut span, text_el(inner))
	attach(mut div, text_el('a'), span, text_el('b'))
	attach(mut body, div)
	mut l := layouter('div { width: ${width}px } ' + sheet, width)
	return box_for(l.layout(body), 'd')
}

fn test_an_auto_inline_block_hugs_its_content() {
	d := atomic_div('span { display: inline-block }', 400, 'abc')
	ib := d.children[0].atomics[0]
	// Shrink-to-fit, CSS 2.1 10.3.9: the line is wider than the content, so the box
	// takes the content's width and not the line's. This is the whole bug the section
	// is here for -- `width: auto` inside `place` used to fill the line.
	assert ib.rect.width == ib.max_content_width
	assert ib.rect.width < d.content.width
	// The text around it stayed on the one line it belongs on: an inline-block taking
	// the whole line pushed the words after it onto the next one.
	assert d.children[0].line_count == 1
	assert ib.children[0].line_count == 1
}

fn test_an_auto_inline_block_takes_the_width_it_has() {
	// The middle of the clamp: the line is wider than the longest word and narrower
	// than the whole text, so the box takes exactly the width available and wraps its
	// own text to get into it.
	wide := atomic_div('span { display: inline-block }', 800, 'aa bb cc dd')
	ib := wide.children[0].atomics[0]
	min_w := ib.min_content_width
	max_w := ib.max_content_width
	assert max_w > min_w
	available := min_w + (max_w - min_w) / 2
	assert available > min_w
	assert available < max_w
	d := atomic_div('span { display: inline-block }', available, 'aa bb cc dd')
	fitted := d.children[0].atomics[0]
	assert fitted.rect.width == available
	// Wrapped rather than overflowed: the text did not fit, so it broke.
	assert fitted.children[0].line_count > 1
}

fn test_an_auto_inline_block_overflows_rather_than_breaking_its_longest_word() {
	// The floor of the same clamp, which is acceptance case 1 in the other direction:
	// the line is narrower than a word that cannot be broken, so the box runs past the
	// line instead of clipping, scaling or splitting the word.
	wide := atomic_div('span { display: inline-block }', 800, 'incomprehensibilities')
	min_w := wide.children[0].atomics[0].min_content_width
	assert min_w > 0
	d := atomic_div('span { display: inline-block }', 10, 'incomprehensibilities')
	ib := d.children[0].atomics[0]
	assert ib.rect.width == min_w
	assert ib.rect.width > d.content.width
	assert ib.children[0].line_count == 1
}

fn test_the_frame_is_inside_the_shrink_to_fit_width() {
	// Padding and border are part of the fitted width, not added to it. A box that
	// hugged its text and then took the frame on top would be wider than the content
	// by exactly the frame, which is the mistake this case separates out.
	d := atomic_div('span { display: inline-block; padding: 0 10px; border-width: 2px; border-style: solid }',
		800, 'abc')
	ib := d.children[0].atomics[0]
	assert ib.rect.width == ib.max_content_width
	frame := ib.rect.width - ib.content.width
	assert frame == 2 * (10 + 2)
	assert ib.children[0].line_count == 1
}

fn test_an_auto_inline_block_fits_the_width_its_margins_leave() {
	// The other half of what comes off the line before the clamp: the margins. The two
	// intrinsic widths are measured at a width where they are unambiguous, and the line
	// is then set to the width between them that the margins leave -- so the case is
	// the box taking 40px less than the line for its 20px margins, not a number that
	// happened to survive this font.
	wide := atomic_div('span { display: inline-block; margin: 0 20px }', 800, 'aa bb cc dd')
	ib := wide.children[0].atomics[0]
	assert ib.max_content_width > ib.min_content_width
	available := ib.min_content_width + (ib.max_content_width - ib.min_content_width) / 2
	d := atomic_div('span { display: inline-block; margin: 0 20px }', available + 2 * 20,
		'aa bb cc dd')
	fitted := d.children[0].atomics[0]
	assert fitted.rect.width == available
}

fn test_an_explicit_width_is_not_shrunk_to_fit() {
	// The other side of the rule: shrink-to-fit is what `width: auto` means. An
	// inline-block that asked for a width gets it, even in a line much narrower.
	d := atomic_div('span { display: inline-block; width: 300px }', 40, 'abc')
	ib := d.children[0].atomics[0]
	assert ib.rect.width == 300
	assert ib.children[0].line_count == 1
}

// --- acceptance case 5: margin auto ----------------------------------------

fn test_auto_margins_centre_a_box_with_a_definite_width() {
	b := word_box('div { width: 200px; margin: 0 auto }', 'abc', 800)
	assert b.rect.width == 200
	assert b.rect.x == 300
	m := word_box('div { width: 200px; margin: 0 50px 0 auto }', 'abc', 800)
	assert m.rect.x == 550
}

fn test_an_auto_width_is_not_centred() {
	b := word_box('div { margin: 0 auto }', 'abc', 800)
	assert b.rect.x == 0
	assert b.rect.width == 800
}

fn test_an_explicit_zero_margin_is_not_centred() {
	b := word_box('div { width: 300px; margin: 0 }', 'abc', 800)
	assert b.rect.x == 0
}

fn test_the_longhand_auto_margin_centres() {
	// The longhand form, to separate the shorthand expansion from the centring rule.
	b := word_box('div { width: 200px; margin-left: auto; margin-right: auto }', 'abc', 800)
	assert b.rect.x == 300
}

fn test_the_one_value_auto_shorthand_centres() {
	b := word_box('div { width: 200px; margin: auto }', 'abc', 800)
	assert b.rect.x == 300
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

fn test_a_persian_word_is_one_token_and_stays_persian() {
	// The tokenizer walks the string's *bytes* unless it is told otherwise, and a Persian
	// character is two of them. `rune(c).str()` on a byte is the Latin-1 character of that
	// value, so "سلام" came out as "Ø³Ù„Ø§Ù…" -- six Latin characters -- and was then
	// measured, shaped and drawn as Latin-1. A Persian page rendered as garbled Latin with
	// correct right-to-left *ordering* of the wrong letters, which is the kind of failure
	// that reads as a font problem and is a tokenizer problem.
	//
	// Asserted on the tokens rather than on the glyphs because the tokens are what the
	// shaper is given: if this passes, the bridge receives Persian.
	assert tokenize_inline('سلام', .normal) == ['سلام']
	assert tokenize_inline('سلام دنیا', .normal) == ['سلام', ' ', 'دنیا']
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

// --- acceptance case 7: RTL text in a box with `direction: rtl` ------------
//
// The glyph forms were already right before this section, and that is the part worth
// being precise about: the bridge shapes Persian through the Arabic fallback chain and
// hands the glyphs back in *visual* order with x increasing from the origin, so for a
// Persian run the last character written is the leftmost glyph and the first is the
// rightmost. What was missing is where a line starts. `layout_runs` always put the pen
// at the content box's left edge, so a Persian paragraph in an RTL box drew flush left,
// with the letters in the right order on the wrong side.
//
// Two things these tests need the sheets to say, both of them measured rather than
// assumed. `font-family: sans-serif`, because that is what the Persian example uses and
// because the fallback chain does not rescue a face that has no Arabic: the default
// family resolves to a serif face whose Arabic coverage is empty, and a per-script
// font set asks its own two slots before its chain, so Persian drawn in it comes out as
// .notdef with the em for an advance. And `direction: rtl` on a *block*, because that is
// the property the case is about.
//
// Mixed Persian and Latin runs are deliberately not tested here. A line is laid out in
// one direction, its box's, and reordering the runs *inside* a line is the bidi work
// Phase 3 inherits; a test for it now would be a test of behaviour that does not exist.

// The font the tests below ask for, spelled once. See the note above.
const rtl_font = 'font-family: sans-serif; '

const rtl_words = 'سلام دنیا'

fn min_x_of(glyphs []text.PositionedGlyph) f64 {
	mut m := glyphs[0].x
	for g in glyphs {
		if g.x < m {
			m = g.x
		}
	}
	return m
}

fn max_x_of(glyphs []text.PositionedGlyph) f64 {
	mut m := glyphs[0].x
	for g in glyphs {
		if g.x > m {
			m = g.x
		}
	}
	return m
}

// furthest_x_of_cluster is the largest x among the glyphs drawn from one character, or
// -1 when the character drew none. It is how these tests ask "which character is at the
// right end of the line" without depending on where the pen happened to put it: several
// glyphs can share an x, because a mark sits on its letter rather than after it.
//
// `cluster` is an index into the string that was shaped, and for these strings a rune
// index, so cluster 0 is the first character of a one-segment line.
fn furthest_x_of_cluster(glyphs []text.PositionedGlyph, cluster int) f64 {
	mut m := -1.0
	for g in glyphs {
		if g.cluster == cluster && g.x > m {
			m = g.x
		}
	}
	return m
}

// laid_lines lays a box's inline content out a second time, because `place` folds the
// lines into one flat glyph list and keeps only the height: a line's advance width lives
// in `LaidLine` and nowhere else, and the assertions below are about where a line's left
// edge is relative to that width.
//
// It is the shaped width, not the sum of the box's atoms, and the difference is measured
// rather than assumed: each atom is one word measured on its own, and Arabic joining
// makes a word a different width when it is shaped with its neighbours. `max_content_width`
// is the atom sum, so it is not the width of the line as drawn and using it here would
// assert a number the ink does not have.
fn laid_lines(mut b &Box) []LaidLine {
	mut l := layouter('', b.content.width)
	ctx := l.context(b.font_size)
	// No floats: this re-lays the box's own runs out on their own, which is what the
	// assertions about a line's width want, and none of them has a float in it.
	mut empty := []&Box{}
	return l.layout_runs(mut b, &ctx, b.content.x, b.content.y, b.content.width, empty)
}

fn test_rtl_text_in_an_rtl_box_is_flush_right() {
	// Case 7. The ink starts one line width in from the content box's right edge, so
	// the first character written is the rightmost glyph.
	mut b := plain_box('div { ' + rtl_font + 'direction: rtl }', 800, rtl_words, true)
	assert b.style.direction == .rtl
	assert b.content.width == 800
	assert b.line_count == 1
	// Every glyph is inside the content box. A line anchored at the wrong edge puts
	// its first character outside the box it was laid out in, and that is the visible
	// symptom this case is about.
	for g in b.glyphs {
		assert g.x >= f64(b.content.x)
		assert g.x <= f64(b.content.x + b.content.width)
	}
	// The first character of the string is at the right end of the line: no glyph drawn
	// from a later character reaches further right than the ones drawn from it.
	assert math.abs(furthest_x_of_cluster(b.glyphs, 0) - max_x_of(b.glyphs)) < 0.001
	// Flush right: the ink's left edge plus the line's own advance is the content box's
	// right edge. The pen starts one line width in from that edge, so a line shorter
	// than the box is held against it.
	lines := laid_lines(mut b)
	assert lines.len == 1
	right := f64(b.content.x + b.content.width)
	assert math.abs(min_x_of(b.glyphs) + lines[0].width - right) < 0.001
}

fn test_an_ltr_box_is_unchanged_and_the_rtl_one_mirrors_it() {
	// The regression guard, and the measurement the case is really about: the same
	// text in an LTR box is flush left, in an RTL box flush right, and the ink occupies
	// exactly the same shape either way. Direction moves a line; it does not reshape it.
	ltr := plain_box('div { ' + rtl_font + '}', 800, rtl_words, true)
	mut rtl := plain_box('div { ' + rtl_font + 'direction: rtl }', 800, rtl_words, true)
	assert ltr.style.direction == .ltr
	assert ltr.max_content_width == rtl.max_content_width
	assert ltr.glyphs.len == rtl.glyphs.len
	// Glyph for glyph the RTL line is the LTR line moved right: the same shaping in the
	// same order, one origin. The relative positions are the two pens' own arithmetic,
	// grouped differently, hence the thousandth of a pixel.
	mut i := 0
	for i < ltr.glyphs.len {
		assert rtl.glyphs[i].gid == ltr.glyphs[i].gid
		assert math.abs((rtl.glyphs[i].x - min_x_of(rtl.glyphs)) - (ltr.glyphs[i].x - min_x_of(ltr.glyphs))) < 0.001
		i++
	}
	// Flush left, exactly: the leftmost glyph's pen is the content box's left edge.
	assert min_x_of(ltr.glyphs) == f64(ltr.content.x)
	// And the RTL line sits the leftover space further right, where the leftover space is
	// what its own ink does not fill. Before the fix the shift is zero, which is the
	// whole of the bug this case is about.
	rtl_lines := laid_lines(mut rtl)
	assert rtl_lines.len == 1
	shift := min_x_of(rtl.glyphs) - min_x_of(ltr.glyphs)
	leftover := f64(rtl.content.width) - rtl_lines[0].width
	assert math.abs(shift - leftover) < 0.001
}

fn test_an_ltr_box_of_latin_text_is_untouched() {
	// The regression guard in its plainest form: Latin text in a box with no direction
	// set is laid out exactly as it was before `direction` was read at all -- flush left,
	// and the first character the leftmost glyph.
	b := plain_box('', 800, 'abc def', true)
	assert b.style.direction == .ltr
	assert b.glyphs.len > 0
	// The bridge returns visual order, so for Latin that is the order the text was
	// written in and the first glyph of the list is the first character.
	assert b.glyphs[0].cluster == 0
	assert b.glyphs[0].x == f64(b.content.x)
	assert min_x_of(b.glyphs) == f64(b.content.x)
}

fn test_two_lines_of_rtl_text_are_both_flush_right() {
	// Both lines are anchored to the right edge, not just the first: a line that
	// broke short starts further in from the left edge than a full one, and both end
	// at the same right edge.
	sentence := 'این متن فارسی است و باید نوشته شود'
	mut b := plain_box('div { ' + rtl_font + 'direction: rtl; width: 160px }', 800, sentence, true)
	assert b.line_count > 1
	lines := laid_lines(mut b)
	assert lines.len == b.line_count
	// The glyphs of one line share the baseline they were shaped at, so the split
	// between lines is where y stops agreeing. A pixel is the margin on both sides: a
	// mark lifts its glyph by more than that and a line's baseline moves by the line
	// height, so the tolerance separates the two and nothing else.
	right := f64(b.content.x + b.content.width)
	mut at := 0
	for ln in lines {
		mut to := at
		for to < b.glyphs.len && math.abs(b.glyphs[to].y - b.glyphs[at].y) < 1.0 {
			to++
		}
		// Cloned rather than sliced: a slice of `b.glyphs` copies anyway and says so with
		// a notice, and this module's test output is read for notices.
		ln_glyphs := b.glyphs[at..to].clone()
		at = to
		assert ln_glyphs.len > 0
		for g in ln_glyphs {
			assert g.x >= f64(b.content.x)
			assert g.x <= right
		}
		// The left edge plus the line's own advance is the right edge.
		assert math.abs(min_x_of(ln_glyphs) + ln.width - right) < 0.001
	}
	assert at == b.glyphs.len
}

fn test_direction_rtl_on_an_ancestor_reaches_a_nested_block() {
	// Inheritance, which is how a Persian page works: `body` carries the direction
	// and every block inside it inherits it, so the nested block's text is laid out
	// from the right edge too.
	mut body := el('body', '', '')
	mut outer := el('div', 'outer', '')
	mut inner := el('div', 'inner', '')
	attach(mut inner, text_el(rtl_words))
	attach(mut outer, inner)
	attach(mut body, outer)
	root := layouter('div { ' + rtl_font + 'direction: rtl }', 800).layout(body)
	assert box_for(root, 'outer').style.direction == .rtl
	assert box_for(root, 'inner').style.direction == .rtl
	mut anon := box_for(root, 'inner').children[0]
	assert anon.style.direction == .rtl
	lines := laid_lines(mut anon)
	assert lines.len == 1
	right := f64(anon.content.x + anon.content.width)
	assert math.abs(min_x_of(anon.glyphs) + lines[0].width - right) < 0.001
}

fn test_a_rtl_line_reports_its_true_width() {
	// `LaidLine.width` used to be the pen's distance from the content box's left edge,
	// which for a right-to-left line is the *box*: the pen is shifted to the right edge
	// and then walks back left by the line's width, so it ends where it started plus the
	// box. This is the assertion that catches shifting the pen without correcting the
	// width, which is exactly the mistake the shift invites.
	mut b := plain_box('div { ' + rtl_font + 'direction: rtl }', 800, rtl_words, true)
	lines := laid_lines(mut b)
	assert lines.len == 1
	assert lines[0].width > 0.0
	assert lines[0].width < f64(b.content.width)
	// And the width it reports is the line's own advance: the ink's left edge plus it
	// is the content box's right edge, which is the same statement as flush right.
	assert math.abs(min_x_of(b.glyphs) + lines[0].width - f64(b.content.x + b.content.width)) < 0.001
}

fn test_text_align_center_places_a_short_line_mid_gap() {
	// The pen starts half the leftover space in from the left edge, so the ink sits
	// in the middle of the gap rather than against either side.
	mut b := plain_box('div { text-align: center }', 800, 'abc def', true)
	lines := laid_lines(mut b)
	assert lines.len == 1
	mid := f64(b.content.x) + f64(b.content.width) / 2.0
	assert math.abs(min_x_of(b.glyphs) + lines[0].width / 2.0 - mid) < 0.001
}

fn test_text_align_right_flushes_an_ltr_line_to_the_right_edge() {
	// Physical, not directional: an LTR line asked for `right` ends at the right
	// edge exactly the way an RTL line does by default.
	mut b := plain_box('div { text-align: right }', 800, 'abc def', true)
	lines := laid_lines(mut b)
	assert lines.len == 1
	right := f64(b.content.x + b.content.width)
	assert math.abs(min_x_of(b.glyphs) + lines[0].width - right) < 0.001
}

fn test_text_align_left_overrides_an_rtl_box_to_flush_left() {
	// `left` ignores direction where `start` follows it: the same RTL box that is
	// flush right by default puts its ink against the left edge when asked.
	mut b := plain_box('div { ' + rtl_font + 'direction: rtl; text-align: left }', 800, rtl_words, true)
	lines := laid_lines(mut b)
	assert lines.len == 1
	assert math.abs(min_x_of(b.glyphs) - f64(b.content.x)) < 0.01
}

fn test_text_align_start_and_end_follow_direction() {
	// `start` is the default both tests above assume: right for RTL, left for LTR.
	// `end` is its mirror, so `end` on an RTL box is flush left and on an LTR box
	// flush right.
	mut rtl := plain_box('div { ' + rtl_font + 'direction: rtl; text-align: end }', 800, rtl_words, true)
	assert math.abs(min_x_of(rtl.glyphs) - f64(rtl.content.x)) < 0.01
	mut ltr := plain_box('div { text-align: end }', 800, 'abc def', true)
	lines := laid_lines(mut ltr)
	assert lines.len == 1
	right := f64(ltr.content.x + ltr.content.width)
	assert math.abs(min_x_of(ltr.glyphs) + lines[0].width - right) < 0.001
}

fn test_text_align_justify_fills_every_line_but_the_last() {
	// Every line but the last shares its leftover space between its words, so each
	// of them is exactly as wide as the gap; the last line keeps the block's start
	// alignment and stays short.
	mut b := plain_box('div { text-align: justify; width: 110px }', 800, 'aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk', true)
	assert b.line_count >= 3
	lines := laid_lines(mut b)
	assert lines.len == b.line_count
	for i in 0 .. lines.len - 1 {
		assert math.abs(lines[i].width - f64(b.content.width)) < 0.01
	}
	// The last line starts at the left edge: same split-by-baseline as the two-line
	// RTL test, because `place` keeps one flat glyph list.
	mut at := 0
	for _ in 0 .. lines.len - 1 {
		mut to := at
		for to < b.glyphs.len && math.abs(b.glyphs[to].y - b.glyphs[at].y) < 1.0 {
			to++
		}
		at = to
	}
	assert at < b.glyphs.len
	assert math.abs(b.glyphs[at].x - f64(b.content.x)) < 0.01
}

fn gids_of(b &Box) []int {
	mut out := []int{}
	for g in b.glyphs {
		out << g.gid
	}
	return out
}

fn test_text_transform_uppercase_shapes_the_uppercase_text() {
	// The run is measured, broken and shaped as its transformed self: `abc` under
	// `uppercase` draws exactly the glyphs a literal `ABC` draws, and not the ones
	// the source text would have drawn. Glyph identity, not width, is the assertion
	// -- two different strings can be equally wide.
	upper := plain_box('div { text-transform: uppercase }', 800, 'abc', true)
	plain_upper := plain_box('', 800, 'ABC', true)
	plain_lower := plain_box('', 800, 'abc', true)
	assert gids_of(upper) == gids_of(plain_upper)
	assert gids_of(upper) != gids_of(plain_lower)
}

fn test_text_transform_lowercase_and_capitalize() {
	lower := plain_box('div { text-transform: lowercase }', 800, 'ABC', true)
	assert gids_of(lower) == gids_of(plain_box('', 800, 'abc', true))
	// `capitalize` touches the first letter of each word and nothing else: the rest
	// keeps its case, so this is not `uppercase` wearing a hat.
	cap := plain_box('div { text-transform: capitalize }', 800, 'aaa bBB', true)
	assert gids_of(cap) == gids_of(plain_box('', 800, 'Aaa BBB', true))
}

fn test_vertical_align_super_raises_its_run() {
	// Glyph order is placement order, so the first glyph belongs to `base` and the
	// last to the `super` span after it: the span's ink sits higher (smaller y) than
	// the baseline text, and the line grew to hold the raised run.
	mixed := span_box('span { vertical-align: super }', 800, 'base', 'X', true)
	plain := span_box('', 800, 'base', 'X', true)
	assert mixed.glyphs[0].y - mixed.glyphs.last().y > 1.0
	assert mixed.content.height > plain.content.height
}

fn test_vertical_align_sub_lowers_its_run() {
	// The mirror: a `sub` span's ink sits lower (larger y) than the baseline text,
	// and the line grew downward to hold it.
	mixed := span_box('span { vertical-align: sub }', 800, 'base', 'X', true)
	plain := span_box('', 800, 'base', 'X', true)
	assert mixed.glyphs.last().y - mixed.glyphs[0].y > 1.0
	assert mixed.content.height > plain.content.height
}

fn test_vertical_align_on_a_block_does_not_lift_its_text() {
	// `vertical-align` applies to inline-level boxes (CSS 2.1 10.8): on a block it
	// is ignored, so the block's own text stays on the baseline and the line keeps
	// the height it would have had without the declaration.
	raised := plain_box('div { vertical-align: super }', 800, 'abc', true)
	plain := plain_box('', 800, 'abc', true)
	assert gids_of(raised) == gids_of(plain)
	for i in 0 .. raised.glyphs.len {
		assert raised.glyphs[i].y == plain.glyphs[i].y
	}
	assert raised.content.height == plain.content.height
}

fn atomic_line(sheet string) &Box {
	mut body := el('body', '', '')
	mut div := el('div', 'd', '')
	mut span := el('span', 'ib', '')
	attach(mut span, text_el('X'))
	attach(mut div, span, text_el(rtl_words))
	attach(mut body, div)
	return box_for(layouter(sheet, 800).layout(body), 'd').children[0]
}

fn test_an_atomic_inline_box_is_placed_by_the_rtl_pen() {
	// The line breaker places atomic boxes with the same pen it lays the text out
	// with, so in an RTL box the first item on the line -- the atomic, here -- is the
	// rightmost one and the text that follows it runs left from its left edge.
	ltr := atomic_line('span { display: inline-block; width: 40px; height: 20px }')
	mut rtl := atomic_line('div { ' + rtl_font + 'direction: rtl } span { display: inline-block; width: 40px; height: 20px }')
	assert ltr.atomics.len == 1
	assert rtl.atomics.len == 1
	lines := laid_lines(mut rtl)
	assert lines.len == 1
	right := f64(rtl.content.x + rtl.content.width)
	// The atomic is the first item on the line, so the line's left edge is its left edge
	// and the line's width reaches from there to the right edge. `rect.x` is an int and
	// the pen is truncated into it, hence the pixel.
	assert math.abs(f64(rtl.atomics[0].rect.x) + lines[0].width - right) <= 1.0
	// The text starts where the atomic ends, which is the same pen one item further on.
	assert math.abs(min_x_of(rtl.glyphs) - f64(rtl.atomics[0].rect.x + rtl.atomics[0].rect.width)) <= 1.0
	// The LTR twin is untouched: the atomic at the left edge and the text after it.
	assert ltr.atomics[0].rect.x == ltr.content.x
	assert min_x_of(ltr.glyphs) == f64(ltr.content.x + ltr.atomics[0].rect.width)
}

// --- the relayout protocol: a percentage inside a shrink-to-fit box ------------

// percentage_in_atomic builds a 400px div holding an inline-block whose only content
// is another inline-block with a percentage width, and returns both.
//
// This is ARCHITECTURE.md section 5's case in one tree: the outer box's width is
// *measured* rather than known, so the inner percentage is resolved against whatever
// base the measurement happens to use.
fn percentage_in_atomic(viewport int, pct string) (&Box, &Box) {
	mut body := el('body', '', '')
	mut d := el('div', 'd', '')
	mut p := el('span', 'p', '')
	mut q := el('span', 'q', '')
	attach(mut q, text_el('hi'))
	attach(mut p, q)
	attach(mut d, p)
	attach(mut body, d)
	root := layouter('div { width: ${viewport}px } #p { display: inline-block } #q { display: inline-block; width: ${pct} }',
		viewport).layout(body)
	db := box_for(root, 'd')
	pbox := db.children[0].atomics[0]
	qbox := pbox.children[0].atomics[0]
	return pbox, qbox
}

fn test_a_percentage_inside_a_shrink_to_fit_box_is_not_measured_against_the_probe_width() {
	// Before the fix the outer box came out 500,000 px wide in a 400 px viewport: the
	// measure pass lays the box out at `unbreakable_width`, the inner `width: 50%`
	// resolved against it to 250,000, and that provisional number was folded into the
	// outer box's intrinsic width -- so the shrink-to-fit clamp returned the absurdity
	// instead of the space available.
	p, q := percentage_in_atomic(400, '50%')
	// It hugs its own content, which is the inner box's content width, because that is
	// narrower than the line.
	assert p.rect.width == p.max_content_width
	// And the percentage resolved against the width it *finally got*, not the probe.
	assert q.rect.width == p.rect.width / 2
}

fn test_a_wider_percentage_still_cannot_push_the_box_past_the_line() {
	// The same shape at 80%, and against a viewport narrower than the content: the box
	// may overflow, but it may not be measured as a fraction of the probe width.
	p, _ := percentage_in_atomic(60, '80%')
	assert p.rect.width == p.max_content_width
	assert p.min_content_width > 0
}

fn test_an_explicit_width_inside_a_shrink_to_fit_box_is_untouched() {
	// The rule is about a *percentage*, not about atomic boxes in general. An atomic
	// with a definite width still contributes that width, and the outer box still hugs
	// the content it is given.
	mut body := el('body', '', '')
	mut d := el('div', 'd', '')
	mut p := el('span', 'p', '')
	mut q := el('span', 'q', '')
	attach(mut q, text_el('hi'))
	attach(mut p, text_el('a'), q, text_el('b'))
	attach(mut d, p)
	attach(mut body, d)
	root := layouter('div { width: 400px } #p { display: inline-block } #q { display: inline-block; width: 30px }',
		400).layout(body)
	pbox := box_for(root, 'd').children[0].atomics[0]
	qbox := pbox.children[0].atomics[0]
	assert qbox.rect.width == 30
	assert pbox.rect.width == pbox.max_content_width
}

fn test_the_relayout_of_a_percentage_is_deterministic() {
	// The architecture forbids nondeterminism, and a protocol that re-asks a layout
	// is exactly where a machine-dependent answer would creep in.
	first_p, first_q := percentage_in_atomic(400, '50%')
	second_p, second_q := percentage_in_atomic(400, '50%')
	assert first_p.rect.width == second_p.rect.width
	assert first_q.rect.width == second_q.rect.width
	assert first_p.max_content_width == second_p.max_content_width
}

// --- float and clear (CSS 2.1 section 9.5) -----------------------------------
//
// A floated box is taken out of the flow, positioned against the part of its line
// that its own side has free at the current vertical position; every line box it
// overlaps is shortened to avoid it; and `clear` is the one property that pushes a
// box *below* a float. What is asserted here is where boxes and glyphs end up,
// because a float is painted like any other box in tree order and geometry is the
// part that can be wrong.
//
// Deliberately not tested, because it is not implemented: float shapes, the effect
// of a float on the shrink-to-fit width of an atomic inline-level box, and negative
// margins on a float. PHASES.md records each of them.

// float_para is long enough to break into several lines at every width used below, so
// that one paragraph holds a line beside a float and a line below it. Line boxes are
// 20px under `layouter`, and the floats are 40 or 60 tall, so three lines of float is
// three lines to look at -- the shortest viewport used below is 150, which is narrower
// than most of the words put end to end.
const float_para = 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twothree fourfive sixseven eightnine'

// float_page builds a body of `width` from `which`, in the order given: `f` and `g`
// are floated elements, `x` is an ordinary block, and `p` is the paragraph whose lines
// have to shorten. The order is a parameter because which side of the text the float
// appears on is part of what is being tested.
fn float_page(sheet string, width int, which string) &Box {
	mut body := el('body', '', '')
	for c in which {
		if c == `f` {
			mut f := el('div', 'f', '')
			attach(mut f, text_el('F'))
			attach(mut body, f)
		} else if c == `g` {
			mut g := el('div', 'g', '')
			attach(mut g, text_el('G'))
			attach(mut body, g)
		} else if c == `x` {
			mut x := el('div', 'x', '')
			attach(mut x, text_el('between'))
			attach(mut body, x)
		} else if c == `p` {
			mut p := el('div', 'p', '')
			attach(mut p, text_el(float_para))
			attach(mut body, p)
		}
	}
	return layouter(sheet, width).layout(body)
}

// glyph_lines splits a box's flat glyph list into its lines by the baseline they were
// shaped at. `place` folds the lines into one list, and a test asking where the third
// line starts has nothing else to ask.
fn glyph_lines(b &Box) [][]text.PositionedGlyph {
	mut out := [][]text.PositionedGlyph{}
	mut cur := []text.PositionedGlyph{}
	for g in b.glyphs {
		if cur.len > 0 && g.y != cur[0].y {
			out << cur
			cur = []text.PositionedGlyph{}
		}
		cur << g
	}
	if cur.len > 0 {
		out << cur
	}
	return out
}

fn rects_overlap(a Rect, b Rect) bool {
	return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height
		&& b.y < a.y + a.height
}

fn test_a_left_float_shortens_the_lines_it_overlaps() {
	// The rule this section exists for, in the form that is easy to get wrong in the
	// wrong direction: a float does not narrow the *block* after it -- that still
	// fills its containing block -- it shortens the *line boxes* that overlap it.
	root := float_page('#f { float: left; width: 100px; height: 60px }', 400, 'fp')
	f := box_for(root, 'f')
	p := box_for(root, 'p')
	assert f.rect.x == 0
	assert f.rect.y == 0
	assert f.rect.width == 100
	// The paragraph is beside the float, not under it: it starts at the same y and it
	// is still as wide as its containing block.
	assert p.rect.y == f.rect.y
	assert p.rect.width == 400
	lines := glyph_lines(p.children[0])
	assert lines.len > 3
	// 60px of float covers three 20px lines, and each of those starts exactly at the
	// float's right edge: that is the pen's left limit, so this is an equality and not
	// an inequality.
	for i in 0 .. 3 {
		assert min_x_of(lines[i]) == f64(f.rect.x + f.rect.width)
	}
	// And the line below the float is a full line again, starting at the block's own
	// left edge. Without this the test would still pass if every line were shortened
	// by every float, which is the other way to be wrong about the same rule.
	assert min_x_of(lines[3]) == f64(p.content.x)
}

fn test_a_right_float_mirrors_the_left_one() {
	// The mirror, asserted as a mirror: the float is against the right edge of the
	// line, the lines it covers start at the block's left edge and end at its left
	// edge, and the line below it is full again.
	root := float_page('#f { float: right; width: 100px; height: 60px }', 400, 'fp')
	f := box_for(root, 'f')
	p := box_for(root, 'p')
	assert f.rect.x == 400 - f.rect.width
	assert p.rect.y == f.rect.y
	assert p.rect.width == 400
	lines := glyph_lines(p.children[0])
	assert lines.len > 3
	for i in 0 .. 3 {
		// A line is ragged, so the gap is asserted on the right as an inequality: no
		// line beside the float reaches past its left edge.
		assert min_x_of(lines[i]) == f64(p.content.x)
		assert max_x_of(lines[i]) <= f64(f.rect.x)
	}
	// Below the float the line has the whole block again, so it is wider than the
	// shortened lines above it. Measured as an ink span rather than as a right edge,
	// because a ragged line's right edge is not a fixed number.
	assert max_x_of(lines[3]) - min_x_of(lines[3]) > max_x_of(lines[0]) - min_x_of(lines[0])
}

fn test_two_left_floats_fit_beside_each_other_while_the_line_has_room() {
	// Which of the two CSS 2.1 9.5.1 rule 2 allows a renderer to choose, and where the
	// browsers agree with each other and with the intent of the rule: either "to the
	// right of the earlier float" or "lower than it", and a float takes the earliest y
	// it can and is then as far to its own side as that allows -- so side by side is
	// what it gets when the line is wide enough.
	root := float_page('#f { float: left; width: 100px; height: 40px } #g { float: left; width: 100px; height: 40px }',
		400, 'fgp')
	f := box_for(root, 'f')
	g := box_for(root, 'g')
	assert g.rect.y == f.rect.y
	assert g.rect.x == f.rect.x + f.rect.width
	// The paragraph's first line starts past both of them.
	p := box_for(root, 'p')
	assert min_x_of(glyph_lines(p.children[0])[0]) == f64(g.rect.x + g.rect.width)
}

fn test_a_float_that_does_not_fit_drops_below_the_earlier_one() {
	// The same two floats in a line only one of them fits: the second goes below the
	// first rather than beside it, and neither overlaps the other.
	root := float_page('#f { float: left; width: 100px; height: 40px } #g { float: left; width: 100px; height: 40px }',
		150, 'fgp')
	f := box_for(root, 'f')
	g := box_for(root, 'g')
	assert g.rect.x == f.rect.x
	assert g.rect.y == f.rect.y + f.rect.height
	assert !rects_overlap(f.rect, g.rect)
	// And the paragraph is laid out against both: its first lines are beside the first
	// float, the next ones are beside the second, and the ones below it are full.
	p := box_for(root, 'p')
	lines := glyph_lines(p.children[0])
	assert lines.len > 4
	assert min_x_of(lines[0]) == f64(f.rect.x + f.rect.width)
	assert min_x_of(lines[4]) == f64(p.content.x)
}

fn test_a_float_does_not_push_the_block_that_follows_it_down() {
	// The classic, and the control that says it is the float and not the height: with
	// the float out of flow the paragraph starts where the float starts, and the same
	// page with the float left in the normal flow starts it 40px lower.
	root := float_page('#f { float: left; width: 100px; height: 40px }', 400, 'fp')
	f := box_for(root, 'f')
	p := box_for(root, 'p')
	assert p.rect.y == f.rect.y
	assert min_x_of(glyph_lines(p.children[0])[0]) == f64(f.rect.x + f.rect.width)
	inflow := float_page('#f { width: 100px; height: 40px }', 400, 'fp')
	assert box_for(inflow, 'f').style.float == .none
	assert box_for(inflow, 'p').rect.y == 40
	// Out of flow also means out of the parent's height: the body is as tall as the
	// paragraph and the float is not counted in it. That is the clearfix case, and it
	// is the behaviour CSS specifies.
	assert root.rect.height == p.rect.height
}

fn test_clear_left_pushes_a_block_below_a_left_float() {
	// `clear` is measured against a float that does not move the cursor, and the block
	// doing the clearing is not the one that follows the float directly: an ordinary
	// block sits between them, so a float that failed to be out of flow would put the
	// cleared block 20px lower than it should be.
	root := float_page('#f { float: left; width: 100px; height: 40px } #p { clear: left }',
		400, 'fxp')
	f := box_for(root, 'f')
	p := box_for(root, 'p')
	assert p.rect.y == f.rect.y + f.rect.height
	// The cleared block starts below the float, so its first line is a full line again.
	assert min_x_of(glyph_lines(p.children[0])[0]) == f64(p.content.x)
}

fn test_clear_on_one_side_ignores_a_float_on_the_other() {
	// `clear: left` is named for the side the float is on, not for the side the box
	// moves to: a right float does not push a box that clears only the left.
	root := float_page('#f { float: right; width: 100px; height: 40px } #p { clear: left }',
		400, 'fxp')
	f := box_for(root, 'f')
	p := box_for(root, 'p')
	assert p.rect.y == box_for(root, 'x').rect.y + 20
	assert p.rect.y < f.rect.y + f.rect.height
}

fn test_clear_both_pushes_below_a_float_on_either_side() {
	root := float_page('#f { float: right; width: 100px; height: 40px } #p { clear: both }',
		400, 'fxp')
	f := box_for(root, 'f')
	p := box_for(root, 'p')
	assert p.rect.y == f.rect.y + f.rect.height
	// And the twin on the left, so the value is not reading as `left`.
	left := float_page('#f { float: left; width: 100px; height: 40px } #p { clear: both }',
		400, 'fxp')
	assert box_for(left, 'p').rect.y == box_for(left, 'f').rect.y + box_for(left, 'f').rect.height
}

fn test_a_float_keeps_its_margin_out_of_the_line_beside_it() {
	// CSS 2.1 9.5 says a line avoids a float's *margin* box, and a margin on a floated
	// image is the ordinary case -- not the exotic one. So a 100px float with
	// `margin-right: 8px` shortens the line to 108 from the left edge, not to 100, and
	// the ink starts one own margin further right than the border box ends.
	root := float_page('#f { float: left; width: 100px; height: 40px; margin-right: 8px }',
		400, 'fp')
	f := box_for(root, 'f')
	p := box_for(root, 'p')
	assert min_x_of(glyph_lines(p.children[0])[0]) == f64(f.rect.x + f.rect.width + 8)
	// And on the other side, mirror: a right float's left margin moves the line's right
	// edge as well.
	right := float_page('#f { float: right; width: 100px; height: 40px; margin-left: 6px }',
		400, 'fp')
	rf := box_for(right, 'f')
	rp := box_for(right, 'p')
	assert max_x_of(glyph_lines(rp.children[0])[0]) <= f64(rf.rect.x - 6)
}

fn test_a_float_with_an_auto_width_hugs_its_content() { // A float's `width: auto` is shrink-to-fit (CSS 2.1 10.3.8), not the fill the same
	// `auto` gives a block: a pull-quote box 45px wide must not take the whole page
	// and shorten every line in it. This is the same clamp `place_atomic` implements
	// for an atomic inline-level box, and reading the block rule here is the mistake.
	root := float_page('#f { float: left; height: 40px }', 400, 'fp')
	f := box_for(root, 'f')
	assert f.rect.width == f.max_content_width
	assert f.rect.width < 400
	assert min_x_of(glyph_lines(box_for(root, 'p').children[0])[0]) == f64(f.rect.x + f.rect.width)
}

fn test_a_float_inside_a_nested_block_shortens_the_lines_after_it() {
	// CSS 2.1 9.5 shortens every line box a float overlaps, and a nested block is not
	// a formatting context of its own -- so a float inside the nested div shortens the
	// text after that div as well. This is the case whose list threading is easy to get
	// wrong: a float kept in a per-box list would only shorten its own siblings.
	mut body := el('body', '', '')
	mut outer := el('div', 'o', '')
	mut nested := el('div', 'n', '')
	mut f := el('div', 'f', '')
	attach(mut f, text_el('F'))
	attach(mut nested, f, text_el('inner'))
	attach(mut outer, nested, text_el('outer'))
	attach(mut body, outer)
	root := layouter('#f { float: left; width: 100px; height: 60px }', 400).layout(body)
	fb := box_for(root, 'f')
	assert fb.rect.x == 0
	// Inside the nested block, and after it, both lines start past the float.
	assert min_x_of(box_for(root, 'n').children[1].glyphs) == f64(fb.rect.x + fb.rect.width)
	assert min_x_of(box_for(root, 'o').children[1].glyphs) == f64(fb.rect.x + fb.rect.width)
}

fn test_a_flow_root_does_not_let_its_floats_escape() {
	// `display: flow-root` is a new block formatting context (CSS 2.1 9.4.1), which is
	// the whole of what the keyword is for: the float shortens the lines inside it and
	// nothing outside it. The same page without it is the test above.
	mut body := el('body', '', '')
	mut outer := el('div', 'o', '')
	mut fr := el('div', 'r', '')
	mut f := el('div', 'f', '')
	attach(mut f, text_el('F'))
	attach(mut fr, f, text_el('inside'))
	attach(mut outer, fr, text_el('outside'))
	attach(mut body, outer)
	root := layouter('#r { display: flow-root } #f { float: left; width: 100px; height: 60px }',
		400).layout(body)
	fb := box_for(root, 'f')
	inside := box_for(root, 'r').children[1]
	outside := box_for(root, 'o').children[1]
	assert min_x_of(inside.glyphs) == f64(fb.rect.x + fb.rect.width)
	assert min_x_of(outside.glyphs) == f64(outside.content.x)
}

fn test_no_float_leaves_every_line_unshortened() {
	// The control for the whole section, and the reason the shortening cannot be
	// unconditional: the same page with `float: none` lays out exactly as it did
	// before any of this existed.
	root := float_page('#f { float: none; width: 100px; height: 40px }', 400, 'fp')
	f := box_for(root, 'f')
	p := box_for(root, 'p')
	assert f.style.float == .none
	assert p.rect.y == 40
	assert min_x_of(glyph_lines(p.children[0])[0]) == f64(p.content.x)
	// A block that asked for nothing still fills the space it has.
	assert word_box('', 'aa bb cc', 800).rect.width == 800
}

// --- position (CSS 2.1 9.3.2, 9.4.3, 9.6) ------------------------------------
//
// `position` does one of three things: does nothing (`static`), moves a box that
// keeps its place in the flow (`relative`), or takes the box out of the flow
// altogether (`absolute` and `fixed`). The two rules that carry all the weight are
// 9.4.3 -- a relative box moves and nothing else does -- and 10.1: the containing
// block an out-of-flow box is placed against is the *padding box* of the nearest
// ancestor that is not `static`, or the initial containing block when there is no
// such ancestor. `fixed` always uses the viewport.
//
// Everything asserted below is a rectangle, because a box drawn in the right order
// at the wrong place is still wrong, and `tools/boxes.v` is what makes that visible
// on a rendered page.

// position_page builds body > a, holder > (x, o), b. `holder` is the ancestor under
// test, `o` is the box being positioned, and `x` is the in-flow sibling that says what
// the flow still has. `a` and `b` are in-flow blocks either side of the holder so the
// tests can see that an out-of-flow `o` moved nothing at all.
//
// The viewport is 400 so that every number below is small enough to read: `a` is 20
// tall, the holder starts at y=20, and its 10px of padding pushes its content to y=30.
fn position_page(sheet string, width int) &Box {
	mut body := el('body', '', '')
	mut a := el('div', 'a', '')
	attach(mut a, text_el('a'))
	mut holder := el('div', 'holder', '')
	mut x := el('div', 'x', '')
	attach(mut x, text_el('x'))
	mut o := el('div', 'o', '')
	attach(mut o, text_el('overlay'))
	attach(mut holder, x, o)
	mut b := el('div', 'b', '')
	attach(mut b, text_el('b'))
	attach(mut body, a, holder, b)
	return layouter(sheet, width).layout(body)
}

// The sheet every test below starts from: the holder is the positioned ancestor and
// `o` is the absolutely positioned box.
const holder_positioned = '#holder { position: relative; padding: 10px } '

fn test_a_static_box_is_exactly_where_it_was() {
	// The control for the whole section. `position: static` -- which is the initial
	// value, so this is the page with no `position` declaration at all -- lays out
	// exactly as it did before `position` existed, and every number here is the
	// block layout of Phase 1: one 20px line each, stacked in document order with
	// nothing taken out of the flow.
	root := position_page('', 400)
	assert box_for(root, 'o').rect.x == 0
	assert box_for(root, 'o').rect.y == 40
	assert box_for(root, 'x').rect.y == 20
	assert box_for(root, 'holder').rect.height == 40
	assert box_for(root, 'b').rect.y == 60
}

fn test_a_relative_box_keeps_its_place_and_moves() {
	// CSS 2.1 9.4.3: the box is offset *after* it is laid out, so it keeps the space
	// it took and its siblings do not move. This is the whole difference between
	// `relative` and a margin, and the assertion on the sibling is the half that is
	// easy to drop.
	root := position_page(holder_positioned + '#x { position: relative; top: 10px; left: 20px }',
		400)
	moved := box_for(root, 'x')
	// The static place is the holder's content box, which the 10px of left padding puts
	// at x=10, and `left: 20px` moves it 20 further right from there.
	assert moved.rect.x == 30
	assert moved.rect.y == 40
	// The box that follows it is where it would have been anyway: the moved box left
	// its place behind it.
	assert box_for(root, 'b').rect.y == 80
	assert box_for(root, 'holder').rect.height == 60
}

fn test_a_relative_box_only_moves_by_the_insets_it_names() {
	// `right` and `bottom` move a box the other way, and only the sides that were
	// written move it: a box with `left` alone does not also shift vertically. The
	// content box starts at x=10 under the holder's 10px of left padding, which is
	// where both boxes below start from.
	root := position_page(holder_positioned + '#x { position: relative; left: 15px }', 400)
	moved := box_for(root, 'x')
	assert moved.rect.x == 25
	assert moved.rect.y == 30
	// The other pair: 15 to the left is 5 to the left of the holder's own edge, and 5
	// up is 5 above the static y=30.
	up := position_page(holder_positioned + '#x { position: relative; right: 15px; bottom: 5px }',
		400)
	u := box_for(up, 'x')
	assert u.rect.x == -5
	assert u.rect.y == 25
}

fn test_an_absolute_box_is_placed_against_its_positioned_ancestor() {
	// CSS 2.1 10.1: the containing block is the *padding box* of the nearest
	// positioned ancestor. The holder is at (0,20) with 10px of padding, so its
	// padding box starts at (0,20) and its content box at (0,30) -- and an absolute
	// child with `top: 5px; left: 7px` lands 5 from the top of the *padding* box and
	// 7 from its left edge, not from the content box.
	root := position_page(holder_positioned + '#o { position: absolute; top: 5px; left: 7px; width: 40px; height: 30px }',
		400)
	o := box_for(root, 'o')
	assert o.rect.x == 7
	assert o.rect.y == 25
	assert o.rect.width == 40
	assert o.rect.height == 30
}

fn test_an_absolute_box_leaves_the_flow_alone() {
	// Both halves of "out of flow", and the second is the one a page notices: the
	// box does not advance the cursor, so the in-flow sibling after it keeps its
	// place and the holder is no taller than the sibling it still has.
	root := position_page(holder_positioned + '#o { position: absolute; top: 5px; left: 7px; width: 40px; height: 30px }',
		400)
	assert box_for(root, 'x').rect.y == 30
	assert box_for(root, 'holder').rect.height == 40
	assert box_for(root, 'b').rect.y == 60
	// And the viewport-wide control: without `position` the same box is in the flow
	// after `x` and pushes everything below it down by its own height.
	inflow := position_page('', 400)
	assert box_for(inflow, 'o').rect.y == 40
	assert box_for(inflow, 'b').rect.y == 60
}

fn test_an_absolute_box_with_no_positioned_ancestor_uses_the_initial_containing_block() {
	// The same box, in the same tree, with no positioned ancestor anywhere. The
	// containing block is then the initial containing block -- the viewport itself --
	// so the insets count from the top-left of the page and not from the holder.
	root := position_page('#o { position: absolute; top: 5px; left: 7px; width: 40px; height: 30px }',
		400)
	o := box_for(root, 'o')
	assert o.rect.x == 7
	assert o.rect.y == 5
	// The initial containing block is the viewport, so the same box measured against
	// the *right* inset lands against the right edge of the page.
	right := position_page('#o { position: absolute; right: 7px; bottom: 5px; width: 40px; height: 30px }',
		400)
	r := box_for(right, 'o')
	assert r.rect.x == 400 - 7 - 40
	// 400 wide and the layouter's 800 tall viewport, measured from its bottom edge.
	assert r.rect.y == 800 - 5 - 30
}

fn test_position_fixed_uses_the_viewport_even_under_a_positioned_ancestor() {
	// `fixed` is `absolute` with one rule changed: the containing block is the
	// viewport, so a positioned ancestor above it does not apply. The holder here is
	// 20px down the page with 10px of padding, which is what separates the two.
	root := position_page(holder_positioned + '#o { position: fixed; top: 5px; left: 7px; width: 40px; height: 30px }',
		400)
	o := box_for(root, 'o')
	assert o.rect.x == 7
	assert o.rect.y == 5
	// And it is still out of the flow: the sibling keeps its place.
	assert box_for(root, 'x').rect.y == 30
	assert box_for(root, 'b').rect.y == 60
}

fn test_an_absolute_box_with_auto_insets_sits_at_its_static_position() {
	// CSS 2.1 10.3.7: when no inset says where the box goes, it goes where it would
	// have gone in the flow. This is the part everyone forgets, and the page it
	// breaks is one where an overlay is positioned only by `top` and inherits its
	// horizontal place from the flow.
	root := position_page(holder_positioned + '#o { position: absolute }', 400)
	o := box_for(root, 'o')
	// The static position is the holder's content box at the point the box occurs:
	// 10 in from the left for the padding, and 20 below the top of the content box
	// for the sibling ahead of it.
	assert o.rect.x == 10
	assert o.rect.y == 50
	// Out of flow, so the holder is only as tall as the sibling it still has.
	assert box_for(root, 'holder').rect.height == 40
	// And with `top` written, only the horizontal place is still the static one.
	shifted := position_page(holder_positioned + '#o { position: absolute; top: 40px }',
		400)
	s := box_for(shifted, 'o')
	assert s.rect.x == 10
	assert s.rect.y == 60
}

fn test_an_absolute_box_is_sized_by_two_opposite_insets() {
	// CSS 2.1 10.3.7 rule 1: with `width: auto` and both `left` and `right` given,
	// the box takes the space between them. The other side of the same rule, and the
	// reason a `top:0; bottom:0` overlay fills its container.
	root := position_page(holder_positioned + '#o { position: absolute; left: 10px; right: 20px; top: 0; bottom: 0 }',
		400)
	o := box_for(root, 'o')
	holder := box_for(root, 'holder')
	// 400 wide, less the two insets, less the box's own zero margins.
	assert o.rect.x == 10
	assert o.rect.width == 400 - 10 - 20
	// The holder's padding box is 40 tall (one 20px line plus 10px of padding each
	// side) and the box fills it exactly, because the insets are both zero.
	assert o.rect.y == 20
	assert o.rect.height == holder.rect.height
}

fn test_an_absolute_box_with_no_width_hugs_its_content() {
	// The third case of the same rule, and the reason `place_atomic` exists: with no
	// inset and no width the box is shrink-to-fit, so it is as wide as its own
	// content and not as wide as the containing block it was placed against.
	root := position_page(holder_positioned + '#o { position: absolute; top: 0; left: 0 }',
		400)
	o := box_for(root, 'o')
	assert o.rect.x == 0
	assert o.rect.y == 20
	assert o.rect.width == o.max_content_width
	assert o.rect.width < 400
}

fn test_a_percentage_inset_resolves_against_the_containing_block() {
	// An inset that is a percentage is a fraction of the containing block's own
	// padding box, which is the same class of assumption the relayout protocol of
	// ARCHITECTURE.md section 5 exists for: the base has to be known before the
	// fraction means anything. The layouter's viewport is 800 tall, so 25% of the
	// holder's 40px padding box is 10.
	root := position_page(holder_positioned + '#o { position: absolute; top: 25%; left: 12.5%; width: 40px; height: 30px }',
		400)
	o := box_for(root, 'o')
	assert o.rect.y == 20 + 10
	assert o.rect.x == 400 / 8
}

fn test_an_absolute_box_inside_another_absolute_box_uses_it_as_the_containing_block() {
	// The containing block is the nearest positioned ancestor, so nesting two
	// out-of-flow boxes re-anchors the inner one against the outer one's padding box.
	mut body := el('body', '', '')
	mut outer := el('div', 'outer', '')
	mut inner := el('div', 'inner', '')
	attach(mut outer, text_el('outer'))
	attach(mut inner, text_el('inner'))
	attach(mut outer, inner)
	attach(mut body, outer)
	root := layouter('#outer { position: absolute; top: 10px; left: 10px; width: 200px; padding: 12px } #inner { position: absolute; top: 4px; left: 5px; width: 30px; height: 30px }',
		400).layout(body)
	o := box_for(root, 'outer')
	i := box_for(root, 'inner')
	assert o.rect.x == 10
	assert o.rect.y == 10
	// The inner box counts from the outer one's *padding* box, which is the outer one's
	// border box: the 12px of padding sits inside it rather than offsetting it. Reading
	// the content box here would put the inner box 12 too far in.
	assert i.rect.x == 10 + 5
	assert i.rect.y == 10 + 4
}

fn test_a_percentage_inside_a_shrink_to_fit_absolute_box_is_not_measured_against_the_probe() {
	// An absolute box with no width and no inset pairing is shrink-to-fit, so its width
	// is *measured* -- and a percentage inside it is then a fraction of the very width
	// being measured. This is the trap `place_atomic` fell into (measured: 500,000 in a
	// 400px viewport for a 50% child) reached by another route: the probe lays the box
	// out a million pixels wide, and the final width is the clamp, not the probe.
	mut body := el('body', '', '')
	mut holder := el('div', 'holder', '')
	mut p := el('div', 'p', '')
	mut q := el('div', 'q', '')
	attach(mut q, text_el('hi'))
	attach(mut p, q)
	attach(mut holder, p)
	attach(mut body, holder)
	root := layouter(holder_positioned + '#p { position: absolute; top: 0; left: 0 } #q { width: 50% }',
		400).layout(body)
	pbox := box_for(root, 'p')
	qbox := box_for(root, 'q')
	// It hugs its own content, and the percentage resolved against the width it
	// *finally got* rather than against the probe.
	assert pbox.rect.width == pbox.max_content_width
	assert qbox.rect.width == pbox.rect.width / 2
}

fn test_an_absolute_box_of_a_static_ancestor_still_finds_the_positioned_one() {
	// The chain walk: the containing block is not the direct parent. Here the box is
	// two levels down from the positioned holder, so it is placed against the holder
	// even though a static div sits between them.
	mut body := el('body', '', '')
	mut holder := el('div', 'holder', '')
	mut middle := el('div', 'middle', '')
	mut o := el('div', 'o', '')
	attach(mut middle, text_el('middle'))
	attach(mut o, text_el('deep'))
	attach(mut middle, o)
	attach(mut holder, middle)
	attach(mut body, holder)
	root := layouter(holder_positioned + '#o { position: absolute; top: 3px; left: 4px; width: 30px; height: 30px }',
		400).layout(body)
	// The containing block is the holder's padding box, which starts where the holder's
	// border box does -- the holder is the body's first child, so that is y=0, and the
	// nearest *static* ancestor in the chain is not a candidate at all. The padding is
	// inside the box the insets are measured against, not an offset from it.
	assert box_for(root, 'o').rect.x == 4
	assert box_for(root, 'o').rect.y == 3
}

// --- display: table -----------------------------------------------------------

// table_page builds body > table#t > tr#r1 > td#c1, td#c2 with the words given, laid
// out at 800. The `tr` is a direct child of the table on purpose: that is the form
// real pages write, and it is the form CSS 2.1 17.2.1 requires to be wrapped.
fn table_page(sheet string, first string, second string) &Box {
	mut body := el('body', '', '')
	mut table := el('table', 't', '')
	mut tr := el('tr', 'r1', '')
	mut c1 := el('td', 'c1', '')
	mut c2 := el('td', 'c2', '')
	attach(mut c1, text_el(first))
	attach(mut c2, text_el(second))
	attach(mut tr, c1, c2)
	attach(mut table, tr)
	attach(mut body, table)
	return layouter(sheet, 800).layout(body)
}

fn test_a_table_that_is_narrower_than_the_line_does_not_overlap_what_follows_it() {
	// The row heights are read *after* the cells are laid out at the widths their
	// columns came out as, and not from the measuring pass: a cell placed at a column
	// narrower than the line wraps its text to more lines and grows. Reading the height
	// first is why a table's next block used to sit on top of its last row.
	mut body := el('body', '', '')
	mut table := el('table', 't', '')
	mut tr := el('tr', 'r1', '')
	mut c1 := el('td', 'c1', '')
	mut c2 := el('td', 'c2', '')
	mut after := el('div', 'after', '')
	attach(mut c1, text_el('a very long description that will not fit in a narrow column at all'))
	attach(mut c2, text_el('bb'))
	attach(mut tr, c1, c2)
	attach(mut table, tr)
	attach(mut after, text_el('after'))
	attach(mut body, table, after)
	root := layouter('', 200).layout(body)
	t := box_for(root, 't')
	a := box_for(root, 'after')
	// The block after the table starts below the table's bottom edge.
	assert a.rect.y >= t.rect.y + t.rect.height
	// And the table is as tall as the wrapped cell needed, not as tall as it was when it
	// was measured across the full line.
	cell := box_for(root, 'c1')
	assert cell.rect.height > a.rect.y - t.rect.y - 40
}

fn test_a_table_that_asks_for_a_width_fills_it() {
	// `width: 100%` is what most stylesheets give a table, and a grid that ignores it
	// runs the border to the full width while the columns stop short of it -- a blank
	// strip on the right with a border through the middle of it.
	mut body := el('body', '', '')
	mut table := el('table', 't', '')
	mut tr := el('tr', 'r1', '')
	mut c1 := el('td', 'c1', '')
	mut c2 := el('td', 'c2', '')
	attach(mut c1, text_el('aa'))
	attach(mut c2, text_el('bb'))
	attach(mut tr, c1, c2)
	attach(mut table, tr)
	attach(mut body, table)
	root := layouter('table { width: 100% }', 400).layout(body)
	t := box_for(root, 't')
	one := box_for(root, 'c1')
	two := box_for(root, 'c2')
	assert t.content.width == 400
	// The first column is *wider than its content*: the surplus over what the cells needed
	// was shared out, which is what makes a full-width table fill the page instead of
	// stopping where the content did.
	assert one.rect.width > one.max_content_width
	assert two.rect.x == one.rect.width
	assert one.rect.width + two.rect.width >= 400
}

fn test_a_rows_inside_a_tbody_are_kept_as_rows() {
	// The form every real page writes: `<table><thead><tr>…<tbody><tr>…`. The row groups
	// are already there, so nothing needs wrapping *except* the rows' own children, and
	// wrapping a row into anything else leaves the table with no rows at all -- which
	// renders as a table-sized blank and was caught by rendering a page, not by the
	// bare-row test above.
	mut body := el('body', '', '')
	mut table := el('table', 't', '')
	mut head := el('thead', 'h', '')
	mut hrow := el('tr', 'hr', '')
	mut hc := el('th', 'hc', '')
	mut tbody := el('tbody', 'b', '')
	mut brow := el('tr', 'br', '')
	mut bc := el('td', 'bc', '')
	attach(mut hc, text_el('name'))
	attach(mut hrow, hc)
	attach(mut head, hrow)
	attach(mut bc, text_el('aa'))
	attach(mut brow, bc)
	attach(mut tbody, brow)
	attach(mut table, head, tbody)
	attach(mut body, table)
	root := layouter('', 800).layout(body)
	t := box_for(root, 't')
	assert t.children.len == 2
	assert t.children[0].style.display == style.Display.table_header_group
	assert t.children[1].style.display == style.Display.table_row_group
	hr := t.children[0].children[0]
	br := t.children[1].children[0]
	assert hr.style.display == style.Display.table_row
	assert br.style.display == style.Display.table_row
	assert hr.children.len == 1
	assert hr.children[0].style.display == style.Display.table_cell
	assert br.children[0].style.display == style.Display.table_cell
	// And the rows are laid out one under the other, not stacked inside one cell.
	assert box_for(root, 'bc').rect.y > box_for(root, 'hc').rect.y
}

fn test_a_bare_row_under_a_table_is_wrapped_in_an_anonymous_row_group() {
	// Without the wrapper the row is laid out by block layout, which is how a table
	// becomes two empty divs: the cells would be positioned by the row's own block
	// path rather than by the column grid, and the table would have no columns at all.
	root := table_page('', 'aa', 'bbbb')
	t := box_for(root, 't')
	assert t.children.len == 1
	group := t.children[0]
	assert group.style.display == style.Display.table_row_group
	assert group.is_anonymous
	assert group.children.len == 1
	assert group.children[0].style.display == style.Display.table_row
	assert group.children[0].children.len == 2
	assert group.children[0].children[0].style.display == style.Display.table_cell
}

fn test_columns_take_their_cells_max_content() {
	// The widths are a relationship rather than a pixel constant, because the numbers
	// come from the font on this machine and a layout test must not be a font test.
	root := table_page('', 'aa', 'bbbbbbbbbb')
	c1 := box_for(root, 'c1')
	c2 := box_for(root, 'c2')
	assert c2.rect.width > c1.rect.width
	// Each column is its own cell's max-content, which is what "the table is as wide as
	// its content" means.
	assert c1.rect.width == c1.max_content_width
	assert c2.rect.width == c2.max_content_width
}

fn test_a_table_wider_than_its_line_is_reduced_to_fit() {
	// The Phase 3 gate is "no horizontal overflow", and this is the case that breaks it:
	// a table whose columns' content is wider than the viewport must come down to the
	// width available rather than run off the page.
	mut body := el('body', '', '')
	mut table := el('table', 't', '')
	mut tr := el('tr', 'r1', '')
	mut c1 := el('td', 'c1', '')
	mut c2 := el('td', 'c2', '')
	attach(mut c1, text_el('aaaaaaaaaaaaaa'))
	attach(mut c2, text_el('bbbbbbbbbbbbbb'))
	attach(mut tr, c1, c2)
	attach(mut table, tr)
	attach(mut body, table)
	root := layouter('', 200).layout(body)
	t := box_for(root, 't')
	assert t.content.width <= 200
	// Every column starts inside the table's own width: with two columns the second one
	// begins after the first, and neither can be pushed past the right edge by the
	// reduction -- which is what a table running off the page looks like.
	first := box_for(root, 'c1')
	second := box_for(root, 'c2')
	assert first.rect.x >= t.content.x
	assert second.rect.x >= t.content.x
	assert second.rect.x > first.rect.x
}

fn test_a_row_is_as_tall_as_its_tallest_cell() {
	// A short cell next to a tall one still takes the row's height, so its background
	// and border run the full row rather than stopping at its own text.
	root := table_page('td { height: 60px }', 'aa', 'bb')
	c1 := box_for(root, 'c1')
	c2 := box_for(root, 'c2')
	assert c1.rect.height >= 60
	assert c2.rect.height >= 60
}

fn test_two_rows_stack() {
	mut body := el('body', '', '')
	mut table := el('table', 't', '')
	mut r1 := el('tr', 'r1', '')
	mut r2 := el('tr', 'r2', '')
	mut a := el('td', 'a', '')
	mut b := el('td', 'b', '')
	mut c := el('td', 'c', '')
	mut d := el('td', 'd', '')
	attach(mut a, text_el('aa'))
	attach(mut b, text_el('bb'))
	attach(mut c, text_el('cc'))
	attach(mut d, text_el('dd'))
	attach(mut r1, a, b)
	attach(mut r2, c, d)
	attach(mut table, r1, r2)
	attach(mut body, table)
	root := layouter('', 800).layout(body)
	top := box_for(root, 'a').rect.y
	bottom := box_for(root, 'c').rect.y
	assert bottom > top
	// The second row starts where the first one ends, so the table is as tall as both.
	assert bottom - top == box_for(root, 'a').rect.height
}

fn test_stray_text_inside_a_table_is_wrapped_in_a_cell() {
	// Illegal in CSS and common in the wild. Wrapping it means it is laid out inside
	// the table; leaving it as a direct child would lay it out by block layout and put
	// it between the rows.
	mut body := el('body', '', '')
	mut table := el('table', 't', '')
	mut tr := el('tr', 'r1', '')
	mut c1 := el('td', 'c1', '')
	attach(mut c1, text_el('aa'))
	attach(mut tr, c1)
	attach(mut table, tr, text_el('stray'))
	attach(mut body, table)
	root := layouter('', 800).layout(body)
	t := box_for(root, 't')
	// One row group holding the row, and a second anonymous one holding the stray text.
	assert t.children.len == 2
	assert t.children[1].style.display == style.Display.table_row_group
	cell := t.children[1].children[0].children[0]
	assert cell.style.display == style.Display.table_cell
	assert cell.is_anonymous
}

fn test_a_table_does_not_upset_the_boxes_around_it() {
	// The regression guard for the hook in `place`: a table is a block, so the block
	// after it starts below the table and not on top of it.
	mut body := el('body', '', '')
	mut table := el('table', 't', '')
	mut tr := el('tr', 'r1', '')
	mut c1 := el('td', 'c1', '')
	mut after := el('div', 'after', '')
	attach(mut c1, text_el('aa'))
	attach(mut tr, c1)
	attach(mut table, tr)
	attach(mut after, text_el('after'))
	attach(mut body, table, after)
	root := layouter('', 800).layout(body)
	t := box_for(root, 't')
	a := box_for(root, 'after')
	assert a.rect.y >= t.rect.y + t.rect.height
}

// --- list markers -------------------------------------------------------------

fn list_page(sheet string, items ...string) &Box {
	// An `ol`, because the numbering rules are the ones that turn an index into text:
	// a `ul` inherits `disc` and never reaches them.
	mut body := el('body', '', '')
	mut list := el('ol', 'l', '')
	mut i := 0
	for it in items {
		mut li := el('li', 'li' + i.str(), '')
		attach(mut li, text_el(it))
		attach(mut list, li)
		i++
	}
	attach(mut body, list)
	return layouter(sheet, 400).layout(body)
}

fn test_a_list_item_gets_a_marker_box_of_its_own() {
	// The marker is a box outside the principal one, and a `decimal` marker is text --
	// so a list of three items carries three markers, and the second one says "2.".
	root := list_page('ol { list-style-type: decimal }', 'one', 'two', 'three')
	first := box_for(root, 'li0')
	second := box_for(root, 'li1')
	third := box_for(root, 'li2')
	assert first.marker_glyphs.len > 0
	assert second.marker_glyphs.len > 0
	assert third.marker_glyphs.len > 0
	// The marker is left of the item's own content and does not overlap it: the UA
	// sheet's `padding-left` on the list is what makes room for it.
	assert first.marker_rect.width == 0
	mut marker_right := first.marker_glyphs[0].x
	for g in first.marker_glyphs {
		if g.x + 8 > marker_right {
			marker_right = g.x + 8
		}
	}
	assert marker_right <= f64(first.content.x)
}

fn test_the_marker_numbers_follow_the_item_index() {
	// The index is counted by the *parent*, because a box cannot count itself: it does
	// not know which of its siblings it is.
	root := list_page('', 'a', 'b', 'c', 'd')
	first := box_for(root, 'li0')
	fourth := box_for(root, 'li3')
	// "1." and "4." are both right-aligned against the item's content edge, so the
	// wider marker starts further left: the numeral is wider and the marker grew.
	assert fourth.marker_glyphs.len > 0
	assert first.marker_glyphs.len > 0
	assert fourth.marker_glyphs[0].x < first.marker_glyphs[0].x
}

fn test_a_disc_marker_is_a_shape_not_text() {
	root := list_page('ol { list-style-type: disc }', 'one', 'two')
	first := box_for(root, 'li0')
	assert first.marker_kind == style.ListStyleType.disc
	assert first.marker_glyphs.len == 0
	assert first.marker_rect.width > 0
	assert first.marker_rect.x + first.marker_rect.width <= first.content.x
}

fn test_no_marker_without_a_list_style_type() {
	root := list_page('li { list-style-type: none }', 'one')
	first := box_for(root, 'li0')
	// Nothing is built, so both marker fields stay at their zero value -- a marker box
	// that does not exist is not a box of size zero, it is an absent one.
	assert first.marker_glyphs.len == 0
	assert first.marker_rect.width == 0
	assert first.marker_rect.height == 0
}

fn test_a_grouped_rule_no_longer_beats_a_single_one() {
	// The bug the specificity fix settled, from the page that found it. The UA sheet's
	// block list groups `li` with thirty other selectors, and summing gave it a
	// specificity no single `li` rule could beat -- so every list lost its marker.
	root := list_page('', 'one')
	first := box_for(root, 'li0')
	assert first.style.display == style.Display.list_item
	assert first.marker_glyphs.len > 0 || first.marker_kind == .disc
}

fn test_a_cell_can_span_several_columns() {
	// A spanning cell is laid out across the sum of the columns it covers, and the
	// columns under it are sized against its content rather than each on their own.
	//
	// The attributes are set by hand because `el` builds a bare Tag: a colspan exists to
	// be read off the element, not off the cascade.
	mut body := el('body', '', '')
	mut table := el('table', 't', '')
	mut tr := el('tr', 'r1', '')
	mut wide := el('td', 'wide', '')
	wide.attributes['colspan'] = '2'
	mut a := el('td', 'a', '')
	mut b := el('td', 'b', '')
	mut tr2 := el('tr', 'r2', '')
	mut c := el('td', 'c', '')
	mut d := el('td', 'd', '')
	attach(mut wide, text_el('a header that spans two columns'))
	attach(mut a, text_el('aa'))
	attach(mut b, text_el('bb'))
	attach(mut tr, wide, a)
	attach(mut c, text_el('cc'))
	attach(mut d, text_el('dd'))
	attach(mut tr2, c, d)
	attach(mut table, tr, tr2)
	attach(mut body, table)
	root := layouter('', 500).layout(body)
	w := box_for(root, 'wide')
	third := box_for(root, 'a')
	first := box_for(root, 'c')
	second := box_for(root, 'd')
	// `wide` spans columns 0 and 1, so it starts where the first column does and covers
	// both: it is as wide as the two columns under it together.
	assert w.rect.x == first.rect.x
	assert w.rect.width >= first.rect.width + second.rect.width
	// `a` is the third cell of the first row and comes after the two columns the
	// spanning cell took, so it starts where the spanning cell ends.
	assert third.rect.x == w.rect.x + w.rect.width
	// The second row's cells are inside the spanning cell's own width.
	assert first.rect.x < second.rect.x
	assert second.rect.x + second.rect.width <= w.rect.x + w.rect.width
}

fn test_a_fixed_table_takes_its_columns_from_the_cells() {
	// A fixed table's columns come from what its cells declare, not from what the content
	// measures -- so a long word in a short cell does not widen its column.
	mut body := el('body', '', '')
	mut table := el('table', 't', '')
	mut tr := el('tr', 'r1', '')
	mut a := el('td', 'a', '')
	mut b := el('td', 'b', '')
	attach(mut a, text_el('aa'))
	attach(mut b, text_el('bb'))
	attach(mut tr, a, b)
	attach(mut table, tr)
	attach(mut body, table)
	root := layouter('table { table-layout: fixed; width: 200px } td { width: 50px }',
		400).layout(body)
	one := box_for(root, 'a')
	two := box_for(root, 'b')
	assert one.rect.x == 0
	assert one.rect.width == 50
	assert two.rect.x == 50
	assert two.rect.width == 50
	// The declared widths take 100 of the 200 the table asked for, and the rest is left
	// with the columns that declared nothing -- of which there are none, because both
	// cells declared.
}

fn test_a_fixed_table_gives_the_rest_to_the_undeclared_columns() {
	// One cell declares a width and the other declares nothing, so the second takes what
	// is left of the table's width rather than its own content.
	mut body := el('body', '', '')
	mut table := el('table', 't', '')
	mut tr := el('tr', 'r1', '')
	mut a := el('td', 'a', '')
	mut b := el('td', 'b', '')
	attach(mut a, text_el('aa'))
	attach(mut b, text_el('bb'))
	attach(mut tr, a, b)
	attach(mut table, tr)
	attach(mut body, table)
	root := layouter('table { table-layout: fixed; width: 200px } td:first-child { width: 60px }',
		400).layout(body)
	one := box_for(root, 'a')
	two := box_for(root, 'b')
	assert one.rect.width == 60
	assert two.rect.x == 60
	assert two.rect.width == 140
}
