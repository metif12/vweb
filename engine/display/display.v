module display

import engine.raster
import math
import engine.selector
import engine.style
import engine.tree
import net.html
import strings
import text

// Block layout: a styled element tree becomes boxes with rectangles.
//
// Phase 1 lays out block-level boxes only. An inline element's content becomes one
// anonymous block holding its text, which renders a page made of paragraphs and
// headings correctly and is *wrong* in exactly one way that Phase 2 fixes: there is
// no line breaking, so a long paragraph is one long run. That is stated here rather
// than discovered on a page later.
//
// Two decisions shape everything else.
//
// Collapsing margins. This is not an optimisation, it is what `1em` margins on
// paragraphs are *for*: two paragraphs one em apart want one em between them, not
// two. Getting it wrong doubles every vertical gap on the page, which is why it is
// here rather than deferred.
//
// Integer rectangles. ARCHITECTURE.md 3 requires integer arithmetic, and this is
// where the one rounding step happens: a CSS length is a float until the box is
// given its position, and then it is an int forever. A box that accumulated
// fractions down a tree would have a golden image that depends on its depth.

pub struct Rect {
pub mut:
	x      int
	y      int
	width  int
	height int
}

// InlineRun is a stretch of a block's inline text in one style.
//
// A block's inline content is a *sequence* of these, not one string. That is the whole
// difference between Phase 2 stage A and stage B: stage A concatenated every run into one
// string and so lost `<b>bold</b>` and `font-size:28px` inside a paragraph, while stage B
// keeps each stretch's own style so the line breaker can break *between* runs and shape
// each one with the font it asked for.
pub struct InlineRun {
pub mut:
	text      string
	style     style.Style
	font_size f64
}

// Box is annotated @[heap] because boxes are allocated with `&Box{}` and then
// written through that pointer after the frame that made them has returned. Without
// it V may place them on the stack, and the first write through the stale pointer is
// a corruption that shows up somewhere else entirely.
@[heap]
pub struct Box {
pub mut:
	style style.Style
	// rect is the border box: everything inside the margin.
	rect Rect
	// content is the area inside the border and the padding, which is where text and
	// child boxes go.
	content Rect
	// border_px is the *used* border width of each side in pixels, in CSS order, after
	// the none/hidden rule above has been applied. Paint reads it instead of resolving
	// the lengths again: two resolutions of the same `em` against two different font
	// sizes is a border that does not line up with the box it is drawn on.
	border_px [4]int
	// font_size is the box's own font size in pixels, resolved once here. Layout needs
	// it for every `em` in the box's own box-model values, and re-deriving it from the
	// style would need the parent's size threaded through the tree.
	font_size f64
	// text is the content this box lays out itself. A box with element children has
	// none.
	//
	// It is the concatenation of `runs`, kept so that a caller asking "what does this box
	// say" gets one answer. Layout uses `runs`, because it is the only one of the two that
	// can tell a bold stretch from the plain text around it.
	text string
	// runs is the inline content in order, each stretch in its own style.
	runs []InlineRun
	// glyphs are text's positioned output, kept on the box so paint does not reshape
	// the same run twice.
	glyphs []text.PositionedGlyph
	// line_count is how many lines the text broke into. The height follows from it and
	// the line height, so it is not stored: a second number that has to agree with the
	// first is a second thing to get wrong.
	line_count int
	children   []&Box
	element    &html.Tag = unsafe { nil }
	// is_anonymous marks a box with no element of its own -- the block an inline
	// element's text was collected into. Paint needs to know, because an anonymous box
	// has no background of its own to draw.
	is_anonymous bool
}

// Layouter holds everything a layout pass needs. One per pass: it is cheap to build,
// and holding one across a resize is how a stale box tree survives.
pub struct Layouter {
pub mut:
	engine          &style.Engine
	state           &selector.State
	fonts           &text.FontLibrary
	viewport_width  int
	viewport_height int
	root_font_size  f64 = 16.0
}

// layout builds the box tree for a document and returns the root box.
//
// The root box is the viewport's content box: a block that fills the width given
// here. `body`'s own margin then sits inside it, which is what puts a page's default
// 8px margin 8px from the edge rather than 8px from nothing.
pub fn (mut l Layouter) layout(root &html.Tag) &Box {
	base := style.initial()
	mut ctx := l.context(l.root_font_size)
	root_style := l.engine.compute(root, &base, &ctx, l.state)
	// A root element's own font-size defines the rem basis, because a page that sets
	// `html { font-size: 120% }` means it.
	l.root_font_size = resolve(root_style.font_size, &ctx, f64(l.viewport_width))

	mut b := l.build(root, root_style, &ctx)
	b.style.margin = style.Edges{}
	l.place(mut b, l.viewport_width, 0, 0, false)
	return b
}

fn (mut l Layouter) context(font_size f64) style.Context {
	return style.Context{
		font_size:       font_size
		root_font_size:  l.root_font_size
		viewport_width:  f64(l.viewport_width)
		viewport_height: f64(l.viewport_height)
	}
}

// build makes a box and its children from an element.
fn (mut l Layouter) build(el &html.Tag, s style.Style, ctx &style.Context) &Box {
	// Children inherit this box's font size, not the viewport's, so an `em` inside a
	// heading is the heading's size.
	mut child_ctx := l.context(resolve(s.font_size, ctx, f64(l.viewport_width)))
	mut b := &Box{
		style:     s
		element:   el
		font_size: child_ctx.font_size
	}
	// Inline-level children accumulate into one anonymous box rather than one each.
	//
	// One each was Phase 1's stand-in for inline layout and it was wrong in a way that
	// showed on every page with a single `<b>` in it:
	//
	//	<p>plain then <b>bold</b> then plain</p>
	//
	// built three anonymous boxes, so it rendered as three lines, one per run, with the
	// text in the right order but stacked down the page instead of running across it. A
	// block's inline content is one continuous stream of text that line boxes break; making
	// each run its own block made every run its own line.
	//
	// What this cost, and what later fixed: the accumulated runs all took the block's font,
	// so `<span style="font-size:28px">` in a paragraph rendered at 16px. Stage B gave each
	// run its own style and its own resolved font size, and this comment is the record of
	// which half of that was obvious. Colour, weight and italic needed nothing at all --
	// they travel in `style`, and `style` was always the element's own. Only `font-size`
	// was wrong, because it was the one property travelling as a number alongside the style
	// rather than inside it.
	mut pending := []InlineRun{}
	for child in el.children {
		if tree.is_text(child) {
			// Whitespace is kept rather than dropped. Dropping a whitespace-only node
			// between two inline elements glues them together: `<b>a</b> <i>b</i>` would
			// become "ab". Collapsing happens once, in `inline_box`.
			pending << InlineRun{
				text:      child.content
				style:     s
				font_size: child_ctx.font_size
			}
			continue
		}
		if !tree.is_element(child) {
			continue
		}
		cs := l.engine.compute(child, &s, &child_ctx, l.state)
		if cs.display == .none {
			continue
		}
		if !cs.display.is_block_level() {
			if child.name == 'br' {
				// A forced break ends the line, so what has accumulated becomes its own box
				// and the text after it starts another. This is also the only reason `<br>`
				// worked at all: with one box per run, the runs either side of it landed on
				// separate lines by accident. Merging without handling `br` here would have
				// quietly removed the only line break the engine had.
				//
				// The text that follows is *inside* the `br` node as far as `net/html` is
				// concerned -- `collect_text` on a `<br>` is what returns "two" out of
				// `<p>one<br>two</p>` -- so it is read from there and starts the next box.
				// Without this the text after a `<br>` vanished, which is what happened the
				// first time round.
				if box := inline_box(pending, s, child_ctx.font_size) {
					b.children << box
				}
				pending = [
					InlineRun{
						text:      collect_text(child)
						style:     cs
						font_size: child_ctx.font_size
					},
				]
				continue
			}
			// An inline element's text is collected into one run in *its* style, not the
			// block's. This is the line stage A could not draw.
			//
			// The font size is resolved from the element's own `font-size` against the
			// *block's* context rather than copied from that context. `child_ctx` holds the
			// block's font size, so a `<span style="font-size:28px">` in a 16px paragraph was
			// being given 16px -- and it drew at 16px too, in every size.
			//
			// Colour, weight and italic came through correctly, because they travel in the
			// style and the style *is* the element's own. That is what made this so easy to
			// miss: every other per-run property worked, and the one that did not is the
			// one a reader notices first.
			pending << InlineRun{
				text:      collect_text(child)
				style:     cs
				font_size: resolve(cs.font_size, &child_ctx, f64(l.viewport_width))
			}
			continue
		}
		if box := inline_box(pending, s, child_ctx.font_size) {
			b.children << box
		}
		pending = []
		b.children << l.build(child, cs, &child_ctx)
	}
	if box := inline_box(pending, s, child_ctx.font_size) {
		b.children << box
	}
	return b
}

// inline_box turns accumulated inline runs into an anonymous box, or into nothing when
// every run in them is empty.
//
// `text_style_of` is applied per run rather than once to the box. It clears the
// properties that belong to an element's own box -- background, borders, margin and
// padding -- and an inline element's background *is* its own, so this is what stops
// `<span style="background:yellow">` painting behind the whole block.
fn inline_box(in_runs []InlineRun, s style.Style, font_size f64) ?&Box {
	if in_runs.len == 0 {
		return none
	}
	mut runs := []InlineRun{cap: in_runs.len}
	for r in in_runs {
		t := collapse_inline_space(r.text, s.white_space)
		if t == '' {
			continue
		}
		runs << InlineRun{
			text:      t
			style:     text_style_of(r.style)
			font_size: r.font_size
		}
	}
	if runs.len == 0 {
		return none
	}
	// The block's own leading and trailing whitespace goes, but not a run in the middle:
	// the space between `<b>a</b>` and `<i>b</i>` is inside the block and has to survive,
	// which is the whole reason runs are collapsed individually rather than joined first.
	trim_leading(mut runs)
	trim_trailing(mut runs)
	if runs.len == 0 {
		return none
	}
	// Built after the trims, not before. It was not, and `text` came out as
	// " spaced out here " for the one block whose leading and trailing whitespace is
	// supposed to go.
	mut flat := strings.new_builder(64)
	for r in runs {
		flat.write_string(r.text)
	}
	return &Box{
		style:        text_style_of(s)
		text:         flat.str()
		runs:         runs
		font_size:    font_size
		is_anonymous: true
	}
}

fn trim_leading(mut runs []InlineRun) {
	for i in 0 .. runs.len {
		runs[i].text = runs[i].text.trim_left(' \n\t\r')
		if runs[i].text != '' {
			return
		}
	}
}

fn trim_trailing(mut runs []InlineRun) {
	mut i := runs.len - 1
	for i >= 0 {
		runs[i].text = runs[i].text.trim_right(' \n\t\r')
		if runs[i].text != '' {
			return
		}
		i--
	}
}

// collapse_inline_space applies CSS whitespace collapsing to a block's inline text: a run
// of whitespace is one space, and leading and trailing whitespace goes.
//
// Only for `normal`. `pre` and `pre-wrap` keep their newlines and their runs, and
// `nowrap` still collapses -- it is about line *breaking*, not about whitespace -- so
// collapsing on `nowrap` is right and leaving it alone would double every space in it.
//
// The block's own `white-space` decides for the whole run. A `<pre>` inside a normal
// paragraph would need its own rule per run, which arrives with per-run styling; doing it
// per block now would be a second approximation of the same thing.
fn collapse_inline_space(content string, ws style.WhiteSpace) string {
	if ws == .pre || ws == .pre_wrap || ws == .pre_line {
		// No collapsing. The edges are still trimmed by the caller.
		return content
	}
	mut b := strings.new_builder(content.len)
	mut in_space := false
	for c in content {
		if c == ` ` || c == `\n` || c == `\t` || c == `\r` {
			if !in_space {
				b.write_byte(` `)
			}
			in_space = true
			continue
		}
		in_space = false
		b.write_u8(c)
	}
	return b.str()
}

// text_style_of is a style for a box that only holds text, with the properties that
// belong to an element rather than to its text cleared.
//
// Copying the parent's whole style is what inheritance means, and it is right for
// colour, font and line height. It is wrong for `background-color` and the borders,
// which CSS does not inherit: they belong to the element's own box. Carrying them
// onto an anonymous text box makes paint draw the parent's background once per text
// node inside it, which is invisible for an opaque colour and exactly double-dark for
// a translucent one.
//
// The same applies to an inline element's own background. Phase 1 gives an inline
// element one anonymous block rather than one per line, so painting its background
// would cover the whole containing block rather than the text; a highlighted span is
// Phase 2's job, when there are line boxes to attach fragments to.
// The same applies to margin and padding. A text run sits *inside* its parent element's
// content box, so carrying the parent's margin onto it counts that margin twice: once on
// the parent where `place` adds its own top margin, and again on the child where the
// child's is added before placement. The box then ends up taller than its own content by
// exactly one margin.
//
// The numbers, from one page: an `h1` with `border-bottom: 2px` and a 21px margin laid
// out 57 tall around a 34 tall line box. 34 + 2 + 21 = 57, the 21 being the margin again.
// So `border-bottom` painted at y=134 while the text ran to y=155, and the border struck
// through the heading. Every box with a margin was wrong by the same amount: a `p` with
// `margin: 1em 0` placed its text 32px below its own top edge instead of 16. The control
// is the one box on the page with no margin set, `div.wide`, which showed no doubling at
// all.
fn text_style_of(parent style.Style) style.Style {
	mut s := parent
	s.background_color = raster.transparent
	s.border_width = style.Edges{}
	mut no_border := [4]style.BorderStyle{}
	s.border_style = no_border
	s.margin = style.Edges{}
	s.padding = style.Edges{}
	return s
}

// place lays a box out at a position, in place, and returns its border-box height.
//
// `y` is the top of this box's *margin box*: the caller has already advanced past the
// collapsed top margin, because a collapsed margin is the caller's arithmetic to do and
// two places doing it is how it got counted twice. `bottom_escapes` says whether this
// box's bottom margin may collapse with the one below it, which decides whether the
// caller subtracts it from the height it gets back.
fn (mut l Layouter) place(mut b &Box, containing_width int, x int, y int, bottom_escapes bool) int {
	s := b.style
	ctx := l.context(b.font_size)
	margin := edges_of(s.margin, &ctx, f64(containing_width))
	border := zero_width_sides(mut edges_of(s.border_width, &ctx, f64(containing_width)),
		s.border_style)
	padding := edges_of(s.padding, &ctx, f64(containing_width))

	frame := border.left + border.right + padding.left + padding.right
	available := containing_width - margin.left - margin.right - frame
	// Under `border-box` a specified width covers padding and border, so the content box is
	// what remains after subtracting them. Only a *specified* width is adjusted: `auto`
	// already received the space left over after margins, border and padding in
	// `available`, and subtracting again would shrink it twice.
	bs := s.box_sizing == .border_box
	content_width := box_width(s.width, s.min_width, s.max_width, available, containing_width,
		&ctx, bs, frame)

	// The margin box starts at `y`: the caller has already advanced past this box's
	// collapsed top margin, so the border box does too, and adding `margin.top` here as
	// well counted it twice.
	//
	// The numbers, from the page this was found on. An `h1` with `margin: 0.67em` and one
	// line of text: the caller advanced 21px for the margin, this added 21px more, and
	// the content landed at y=92 inside a border box starting at y=71. The box was 36 tall
	// and correct on paper -- 34 line plus 2 border -- but the text ran past its bottom,
	// so `border-bottom` drew through the middle of the heading. Every box with a margin
	// was short by one margin, and every one of them painted its background and borders
	// over its predecessor: `.card`'s text overflowed its own background by 3px.
	//
	// Horizontally this is the opposite: margins do not collapse, the caller passes the
	// same x to every child, and each box offsets itself by its own left margin. So
	// `margin.left` is applied here and not there.
	border_x := x + margin.left
	content_x := border_x + border.left + padding.left
	mut cursor := y + border.top + padding.top
	content_y := cursor

	mut previous_bottom := 0
	mut first := true
	// Indexed rather than ranged: `for child_ref in b.children { mut child := child_ref }`
	// makes a mutable reference to an immutable loop variable, which V reports as a
	// notice and which is one copy away from writing to the wrong box.
	mut i := 0
	for i < b.children.len {
		mut child := b.children[i]
		cs := child.style
		child_ctx := l.context(child.font_size)
		cm := edges_of(cs.margin, &child_ctx, f64(content_width))
		// Adjacent siblings' margins collapse to the larger of the two. This is the
		// whole reason `p { margin: 1em 0 }` looks right.
		mut top := cm.top
		if !first {
			top = max_of(previous_bottom, cm.top)
		}
		cursor += top
		// Only an only-child box can collapse through to its parent's edge.
		is_last := b.children.len == 1
		cursor += l.place(mut child, content_width, content_x, cursor, is_last)
		previous_bottom = cm.bottom
		first = false
		i++
	}

	if b.text != '' {
		lines := l.layout_runs(mut b, &ctx, content_x, content_y, content_width)
		b.line_count = lines.len
		// One flat list rather than a list per line: paint draws glyphs, not lines, and
		// a caller asking "where is the text of this box" wants every glyph in one
		// place. Each glyph already carries the baseline it was shaped for.
		mut glyphs := []text.PositionedGlyph{}
		mut height := 0
		for ln in lines {
			glyphs << ln.glyphs
			height += ln.height
		}
		b.glyphs = glyphs
		b.content = Rect{ x: content_x, y: content_y, width: content_width, height: height }
		cursor += height
		previous_bottom = 0
	} else if b.children.len == 0 {
		// An empty block is still one line tall. A page of them collapsing to nothing
		// makes `height: 100%` on a parent a percentage of zero.
		fs := font_style_of(s, b.font_size, &ctx)
		line_height := px(l.fonts.line_metrics(&fs).line_height)
		b.content = Rect{ x: content_x, y: content_y, width: content_width, height: line_height }
		cursor += line_height
		previous_bottom = 0
	} else {
		b.content = Rect{ x: content_x, y: content_y, width: content_width }
	}

	mut content_height := max_of(cursor - content_y, 0)
	// A box with no content at all -- `display: block` on an empty div with a set
	// height aside -- would otherwise be zero tall.
	if b.children.len == 0 && b.text == '' && content_height == 0 {
		fs := font_style_of(s, b.font_size, &ctx)
		content_height = px(l.fonts.line_metrics(&fs).line_height)
	}

	// `min-height` and `max-height` bound the *content* box here, which is what CSS 2.1
	// 10.7 says and is the same box `min-width`/`max-width` bound in `box_width`.
	content_height = height_clamp(content_height, s.min_height, s.max_height, &ctx,
		f64(containing_width))

	mut border_height := content_height + padding.top + padding.bottom + border.top +
		border.bottom

	if s.height.unit != .auto && s.height.unit != .none {
		// An explicit height overrides the content's, which is what `height: 200px` on a
		// short paragraph means. The content is not clipped: overflow is Phase 3.
		border_height = px(resolve(s.height, &ctx, f64(containing_width)))
		// Clamped here as well, on the specified height rather than on the content.
		// That is the one place the two disagree about which box they bound: the
		// content-box rule applies above, but an explicit `height` is treated as the
		// whole border box, so min/max are applied to it directly. Fixing that is
		// `box-sizing`, which is the next item and which will make the two agree.
		border_height = height_clamp(border_height, s.min_height, s.max_height, &ctx,
			f64(containing_width))
		b.content.height = max_of(content_height, 0)
	} else if b.children.len > 0 && previous_bottom > 0 && (bottom_escapes
		|| b.children.len == 1) {
		// The last child's bottom margin collapses with this box's when nothing
		// separates them, so it is not counted twice.
		border_height -= previous_bottom
	}

	b.rect = Rect{ x: border_x, y: y, width: content_width + frame, height: border_height }
	// Assigned one side at a time because a braced array initializer with positional
	// elements is a parse error in V 0.5.2 (see notes/V-GOTCHAS.md).
	mut bw := [4]int{}
	bw[0] = border.top
	bw[1] = border.right
	bw[2] = border.bottom
	bw[3] = border.left
	b.border_px = bw
	b.content.height = max_of(content_height, 0)
	return border_height
}

// zero_width_sides applies the used border-width rule of CSS 2.1 10.3.3: a side whose
// style is `none` or `hidden` has a used width of zero, whatever `border-width` says.
//
// This is here rather than in paint because it changes where the box *ends*. A
// `border-width: 3px` with no `border-style` is six pixels of nothing, and if only
// paint knew that rule then layout and paint would disagree about the content box --
// which shows up as text sitting three pixels too far left with nothing drawn there.
fn zero_width_sides(mut px Px4, styles [4]style.BorderStyle) Px4 {
	if draws_no_border(styles[0]) {
		px.top = 0
	}
	if draws_no_border(styles[1]) {
		px.right = 0
	}
	if draws_no_border(styles[2]) {
		px.bottom = 0
	}
	if draws_no_border(styles[3]) {
		px.left = 0
	}
	return px
}

fn draws_no_border(s style.BorderStyle) bool {
	return s == .none || s == .hidden
}

// box_width implements the width part of the box model.
//
// `auto` takes what is left after margins, borders and padding. A percentage is that
// fraction of the containing block's *content* width, and a length is itself -- and
// neither is clamped to what is left, because CSS 2.1 10.4 says a box wider than its
// containing block overflows it. That is the whole reason `width: 100%` plus padding
// hangs over the edge: the padding is added to the 100%, not taken out of it.
// box_width resolves `width` and then clamps it, which is three separate rules that
// have to happen in this order (CSS 2.1 10.4):
//
//	1. resolve `width` against the containing block,
//	2. let `min-width` beat `max-width` when the two conflict,
//	3. clamp `width` into `[min-width, max-width]`.
//
// Step 2 is not optional and not cosmetic. With `min-width: 200px; max-width: 100px`
// the two rules applied in the other order give 100, which is *below* the floor the
// author asked for, and a box can then be smaller than its own min-content. Applying
// the max first and raising it to the min is what makes the result unable to invert,
// which is what the eighth acceptance case in `docs/PHASES.md` asks for.
//
// `min-width: auto` and an unset `max-width` are both "no bound", and `auto` is
// additionally "no bound" rather than "0", so it is not folded into the zero case.
// height_clamp applies `min-height` and `max-height` to a content height.
//
// It is deliberately the same shape as the clamp inside `box_width` rather than a
// shared helper, because the two clamp at different points: width is resolved before
// any padding is added, and height is clamped to the content box before padding is
// added to it. Folding them together would need a callback for where in the arithmetic
// the bound applies, which is more machinery than two short functions justify.
fn height_clamp(content_height int, min_h style.Length, max_h style.Length, ctx &style.Context,
	basis f64) int {
	mut lo := 0
	if min_h.unit != .auto {
		lo = px(resolve(min_h, ctx, basis))
		if lo < 0 {
			lo = 0
		}
	}
	mut hi := -1
	if max_h.unit != .none {
		hi = px(resolve(max_h, ctx, basis))
		if hi < 0 {
			hi = -1
		}
	}
	if hi >= 0 && hi < lo {
		hi = lo
	}
	mut v := content_height
	if v < lo {
		v = lo
	}
	if hi >= 0 && v > hi {
		v = hi
	}
	return max_of(v, 0)
}

// `border_box` and `frame` are what `box-sizing: border-box` needs: the specified value
// and both bounds are border-box sizes, so padding and border come off each of them. The
// bounds are converted as well as `width`, because `min-width` is interpreted in the same
// box as `width` -- clamping a content-box min against a border-box width is how a
// `border-box` box ends up smaller than its own floor.
fn box_width(w style.Length, min_w style.Length, max_w style.Length, available int,
	containing_width int, ctx &style.Context, border_box bool, frame int) int {
	mut v := match w.unit {
		.auto, .none {
			if available < 0 {
				0
			} else {
				available
			}
		}
		.percent { px(w.value * f64(containing_width) / 100.0) }
		else { px(resolve(w, ctx, f64(containing_width))) }
	}
	// A negative length is not a width. `max-width: -20px` must not become a floor
	// above `min-width` either, so both are floored before they are compared.
	mut lo := 0
	if min_w.unit != .auto {
		lo = px(resolve(min_w, ctx, f64(containing_width)))
		if border_box {
			lo -= frame
		}
		if lo < 0 {
			lo = 0
		}
	}
	mut hi := -1
	if max_w.unit != .none {
		hi = px(resolve(max_w, ctx, f64(containing_width)))
		if border_box && hi >= 0 {
			hi -= frame
		}
		if hi < 0 {
			hi = -1
		}
	}
	if hi >= 0 && hi < lo {
		hi = lo
	}
	// A specified width under `border-box` loses the frame; `auto` must not, because
	// `available` was already reduced by margins, border and padding above.
	if border_box && w.unit != .auto && w.unit != .none {
		v -= frame
		if v < 0 {
			v = 0
		}
	}
	if v < lo {
		v = lo
	}
	if hi >= 0 && v > hi {
		v = hi
	}
	if v < 0 {
		v = 0
	}
	return v
}

// wrap_width is the width to break text at, which is the content width except for the
// two `white-space` values that forbid breaking.
//
// The value used to mean "never break" is larger than any viewport rather than a
// sentinel, because vtext then returns exactly one line for ordinary text and the
// right number for text with newlines in it -- which is what `pre` asks for. `pre-wrap`
// and `pre-line` both wrap here; the difference between them is that `pre-line`
// collapses runs of spaces, which is Phase 2's problem and is stated here rather than
// silently ignored.
fn wrap_width(ws style.WhiteSpace, content_width int) f64 {
	if ws == .nowrap || ws == .pre {
		return 1.0e9
	}
	return f64(content_width)
}

// baseline_of is the y of a line's baseline, from the top of its line box.
//
// CSS 2.1 10.8.1: the space a line box leaves for text is split evenly above and below
// it, so the baseline sits at half the leading plus the ascent. Putting the baseline at
// the ascent instead -- the obvious thing -- leaves all the leading below the text, so
// every line sits high in its box and consecutive lines look like they are drifting
// apart. With a line height smaller than the font's own, the leading is negative and the
// text is centred on the line, which is also what this produces.
fn baseline_of(top int, ascent f64, descent f64, line_height f64) int {
	leading := line_height - (ascent + descent)
	return px(f64(top) + leading / 2.0 + ascent)
}

fn resolve(l style.Length, ctx &style.Context, basis f64) f64 {
	return l.to_px_or(ctx, basis)
}

// Px4 is the resolved box model in pixels. It is not style.Edges, which holds
// unresolved lengths: resolving here is where ARCHITECTURE.md 3's single rounding step
// happens.
struct Px4 {
pub mut:
	top    int
	right  int
	bottom int
	left   int
}

fn edges_of(e style.Edges, ctx &style.Context, basis f64) Px4 {
	return Px4{
		top:    px(resolve(e.top, ctx, basis))
		right:  px(resolve(e.right, ctx, basis))
		bottom: px(resolve(e.bottom, ctx, basis))
		left:   px(resolve(e.left, ctx, basis))
	}
}

// px rounds to nearest. Truncating instead biases every box a little toward zero and
// the error accumulates down a tree.
fn px(v f64) int {
	return int(math.round(v))
}

fn max_of(a int, b int) int {
	return if a > b {
		a
	} else {
		b
	}
}

// font_style_of builds the text layer's narrower style from the computed style. Only
// the fields that can change shaping or measurement are carried across, because that
// narrowness is what makes the glyph cache key valid.
fn font_style_of(s style.Style, font_size f64, ctx &style.Context) text.FontStyle {
	weight := if s.font_weight == .bold {
		700
	} else {
		400
	}
	mut fs := text.FontStyle{
		family: s.font_family
		weight: weight
		italic: s.font_style == .italic || s.font_style == .oblique
		size:   font_size
	}
	// A unitless line-height is a multiple of the font size, a length is a length, and
	// zero means the font's own natural line height.
	if s.line_height.unit == .none && s.line_height.value > 0.0 {
		fs.line_height = s.line_height.value * font_size
	} else if s.line_height.unit != .none && s.line_height.unit != .auto {
		fs.line_height = resolve(s.line_height, ctx, font_size)
	}
	return fs
}

// collect_text returns an element's own text, including that of its inline
// descendants.
fn collect_text(el &html.Tag) string {
	if tree.is_text(el) {
		return el.content
	}
	if !tree.is_element(el) {
		return ''
	}
	mut out := strings.new_builder(64)
	for child in el.children {
		out.write_string(collect_text(child))
	}
	return out.str()
}

// boxes returns every box in the tree, parents before children, which is the order
// paint composites in for source-over.
pub fn boxes(root &Box) []&Box {
	mut out := []&Box{}
	mut stack := []&Box{}
	stack << root
	for stack.len > 0 {
		cur := stack.pop()
		out << cur
		mut i := cur.children.len
		for i > 0 {
			i--
			stack << cur.children[i]
		}
	}
	return out
}

pub fn (b &Box) background() raster.Color {
	return b.style.background_color
}

// LaidLine is one line of a box's inline content, after breaking and shaping.
struct LaidLine {
	glyphs []text.PositionedGlyph
	// width is the line's advance. Nothing outside the tests reads it yet; bidi will want
	// it for alignment.
	width  f64
	height int
}

// Atom is one measurable piece of a line: a word, or a space, within one run's style.
//
// The alternative -- measuring whole runs and breaking between them -- cannot break
// inside a long stretch of ordinary text, and a paragraph with one `<b>` in it is one
// stretch of ordinary text either side of that `<b>`.
struct Atom {
	run     int
	content string
	width   f64
	space   bool
}

// layout_runs breaks a box's inline content into lines and shapes each one where it will
// be drawn.
//
// `text.FontLibrary.wrap` cannot do this job: it takes one string and one style and hands
// them to `vtext.wrap_paragraph`, so it cannot express `<b>bold</b>` in a paragraph at all.
// That is why this exists rather than a parameter being added down there.
//
// Lines advance by the *box's* line height, not by the tallest font on the line. That is a
// simplification: a `<span style="font-size:28px">` in a 16px paragraph overlaps its
// neighbours rather than pushing them apart. Half-leading to the tallest item is the
// correct rule and is recorded in PHASES.md as part of this step.
// `content_y` rather than a baseline passed in: each line's height now depends on the fonts
// on that line, so `place` cannot say where the first baseline goes without first knowing
// how tall the first line is. It used to pass one computed from the *box's* metrics, and
// that is why a 28px run in a 16px paragraph overlapped its neighbours.
fn (mut l Layouter) layout_runs(mut b &Box, ctx &style.Context, content_x int, content_y int,
	content_width int) []LaidLine {
	max_w := wrap_width(b.style.white_space, content_width)

	// Atoms first, across every run, so a break can land on a run boundary as easily as on
	// a space inside one.
	mut atoms := []Atom{}
	for ri, r in b.runs {
		run_style := font_style_of(r.style, r.font_size, ctx)
		for tok in tokenize_inline(r.text, b.style.white_space) {
			atoms << Atom{
				run:     ri
				content: tok
				width:   l.fonts.advance(&run_style, tok)
				space:   tok.len > 0 && (tok[0] == ` ` || tok[0] == `\t` || tok[0] == `\n`)
			}
		}
	}
	if atoms.len == 0 {
		return []LaidLine{}
	}

	// Greedy fill. A space never starts a line and never causes one, so the break is taken
	// before the word that would not fit rather than after the space before it.
	mut lines := [][]Atom{}
	mut cur := []Atom{}
	mut w := 0.0
	for a in atoms {
		if a.space && cur.len == 0 {
			continue
		}
		if !a.space && cur.len > 0 && w + a.width > max_w {
			lines << cur
			cur = []
			w = 0.0
		}
		cur << a
		w += a.width
	}
	if cur.len > 0 {
		lines << cur
	}

	// Shape each line. Consecutive atoms of the same run are shaped as one string, so a
	// word spanning two atoms still joins and shapes as a word.
	// Half-leading, CSS 2.1 10.8.1: each item's leading is split half above and half below
	// its own text, so a line box is as tall as the tallest item on it plus that item's
	// half-leading. `line_has_run` keeps a 28px run on the second line from inflating the
	// first.
	mut out := []LaidLine{cap: lines.len}
	mut y := content_y
	for line_atoms in lines {
		mut above := 0.0
		mut below := 0.0
		for ri in 0 .. b.runs.len {
			if !line_has_run(line_atoms, ri) {
				continue
			}
			rs := font_style_of(b.runs[ri].style, b.runs[ri].font_size, ctx)
			m := l.fonts.line_metrics(&rs)
			half := (m.line_height - (m.ascent + m.descent)) / 2.0
			above = fmax(above, m.ascent + half)
			below = fmax(below, m.descent + half)
		}
		line_height := px(above + below)
		baseline := f64(y) + above
		mut x := f64(content_x)
		mut glyphs := []text.PositionedGlyph{}
		mut i := 0
		for i < line_atoms.len {
			mut j := i
			mut seg := strings.new_builder(32)
			for j < line_atoms.len && line_atoms[j].run == line_atoms[i].run {
				seg.write_string(line_atoms[j].content)
				j++
			}
			r := b.runs[line_atoms[i].run]
			run_style := font_style_of(r.style, r.font_size, ctx)
			glyphs << l.fonts.shape(seg.str(), &run_style, x, baseline)
			mut seg_w := 0.0
			for k in i .. j {
				seg_w += line_atoms[k].width
			}
			x += seg_w
			i = j
		}
		out << LaidLine{
			glyphs: glyphs
			width:  x - f64(content_x)
			height: line_height
		}
		y += line_height
	}
	return out
}

// line_has_run reports whether any atom on the line came from run `ri`. A line's height
// depends on the fonts that actually appear on it, not on every font in the box: a 28px run
// on the second line must not make the first one tall.

fn line_has_run(atoms []Atom, ri int) bool {
	for a in atoms {
		if a.run == ri {
			return true
		}
	}
	return false
}

fn fmax(a f64, b f64) f64 {
	return if a > b {
		a
	} else {
		b
	}
}

// tokenize_inline splits a run's text into words and runs of spaces.
//
// This is the smallest piece of Phase 2 stage B and it is separated out first because
// everything above it is arithmetic on what this returns: a token becomes an `Atom`, an
// atom's width decides where a line breaks, and the atoms on a line are joined and
// shaped. When a box holding the text "ab" laid out with **four** glyphs in it, this was
// the first place worth looking, because a word that tokenized per character would
// account for exactly that doubling.
//
// `pre` keeps its newlines as tokens of their own, which is what makes them break lines.
// A leading space is dropped rather than tokenized: a line cannot start with one, and
// `layout_runs` skips leading spaces anyway -- it is dropped here so that a box's first
// token is a word and the arithmetic downstream never sees a space it has to special-case.
// A trailing space *is* kept, so that a line ending in one is measured honestly.
fn tokenize_inline(content string, ws style.WhiteSpace) []string {
	pre := ws == .pre || ws == .pre_wrap || ws == .pre_line
	mut out := []string{}
	mut cur := ''
	// A whitespace run has been seen and not yet emitted as a token. Deferring it is what
	// collapses a run of them: `a  b` emits one space, not two, and a leading one is
	// dropped rather than emitted, because out.len is still zero.
	mut pending := false
	for c in content {
		if c == ` ` || c == `\t` || c == `\r` {
			if cur != '' {
				out << cur
				cur = ''
			}
			// `pre` keeps its whitespace, so each one is emitted where it stands. For
			// everything else it is deferred and collapsed, and doing both is how "a  b"
			// produced three spaces in `pre` and one in `normal`.
			if pre {
				out << ' '
			} else {
				pending = true
			}
			continue
		}
		if c == `\n` && !pre {
			// A newline is whitespace like any other for `normal`.
			if cur != '' {
				out << cur
				cur = ''
			}
			pending = true
			continue
		}
		if c == `\n` && pre {
			// A newline in `pre` breaks a line, so it is a token in its own right rather
			// than a space that happens to be wide.
			if cur != '' {
				out << cur
				cur = ''
			}
			out << '\n'
			pending = false
			continue
		}
		if pending {
			// No `out.len > 0` guard here. A run is not a line: the space at the start of
			// a middle run sits between two words, and dropping it turned
			// "plain then " + "bold" + " then plain" into "plain then boldthen plain".
			// `layout_runs` is where a line refuses to *start* with a space.
			out << ' '
			pending = false
		}
		// `rune(c).str()`, not `c.str()`. On a `u8`, `str()` produces the *number* as
		// text: 'a' becomes "97" and 'b' becomes "98", so "ab" tokenized to "9798" and a
		// whole page rendered as its own ASCII codes. The cast is the whole difference
		// between a character and its index.
		cur += rune(c).str()
	}
	if cur != '' {
		out << cur
	}
	// A trailing space is kept so a line that ends in one is measured honestly.
	if pending {
		out << ' '
	}
	return out
}
