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
// InlineItem is one item of a block's inline content: either a stretch of text or an
// atomic inline-level box.
//
// A struct with a tag rather than a sum type, because V's parser does not accept `&Box`
// as a match arm -- `match it { &Box { ... } }` is a parse error. The two cases still
// have to be told apart while iterating the content in source order, and a boolean does
// that without a sum type.
pub struct InlineItem {
pub mut:
	is_box    bool
	text      string
	style     style.Style
	font_size f64
	box       &Box = unsafe { nil }
}

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
	// marker_* are the list item's marker box (CSS 2.1 12.5), which is a box of its own
	// outside the principal box. A `decimal` marker is text and lands in
	// `marker_glyphs`; a `disc`/`circle`/`square` marker is a shape and lands in
	// `marker_kind` with its size. Only a `list-item` box has either.
	marker_glyphs []text.PositionedGlyph
	marker_kind   style.ListStyleType
	marker_rect   Rect
	// list_index is this item's 1-based position among the list items of its parent,
	// which is what "3." in an ordered list is. The parent knows the order and the box
	// cannot count itself, so it is recorded by `place` when it walks the children.
	list_index int
	// line_count is how many lines the text broke into. The height follows from it and
	// the line height, so it is not stored: a second number that has to agree with the
	// first is a second thing to get wrong.
	line_count int
	// Intrinsic widths (CSS Sizing 3). `max_content_width` is how wide the content would
	// be with nothing wrapping it; `min_content_width` is how narrow it can get without
	// something overflowing, which for text is its widest single word.
	//
	// They are on the box rather than returned by a function because layout needs them
	// after placement -- a parent's intrinsic size is the widest child's, so the child has
	// to have measured itself first. A `width()` call would have to re-walk the subtree at
	// every level, once per level.
	max_content_width int
	min_content_width int
	// float_margin is the margin box of a *floated* box: the area it keeps for itself
	// around its border box, which is what a line beside it has to avoid -- CSS 2.1 9.5
	// says the margin box, not the border box. It is stored rather than computed on the
	// spot because `place_float` resolves the margins once against the containing width
	// it was given, and `line_gap` has no context to resolve them again.
	float_margin Rect
	children     []&Box
	// atomics are this block's atomic inline-level boxes (inline-block). They are not in
	// children, because their position comes from the line layout rather than from block
	// layout: they sit *inside* a line, at the point the line breaker put them.
	atomics []&Box
	// absolutes are the out-of-flow boxes of this block, in document order, filled in by
	// `place` while it walks the flow. They are the same boxes that are in `children` --
	// an absolutely positioned box has to stay there, because `place` records the
	// position it *would* have had from the order it appears in -- and the extra list is
	// what the placement pass at the end of `place` iterates.
	//
	// They are not laid out by the flow itself. CSS 2.1 9.6 takes them out of it: they do
	// not advance the cursor, their margins do not collapse with a sibling's, and they
	// contribute nothing to the intrinsic width of the box that holds them. Each of
	// those is a rule elsewhere in this file, and each of them is a place where an
	// out-of-flow box has to be recognised -- which is why the position, not the list
	// membership, is what the check is on.
	absolutes []&Box
	// inline_items is the inline content in source order, text and atomics interleaved.
	// 
	// 
	// `runs` and `atomics` are the same content split by type -- which is what shaping and
	inline_items []InlineItem
	element      &html.Tag = unsafe { nil }
	// static_x and static_y are where this box would have been in the normal flow,
	// which is what an inset of `auto` resolves to (CSS 2.1 10.3.7 rule 3: `left` is
	// the static position). It is recorded while the flow is walked rather than
	// recomputed, because the cursor that would produce it has moved on by the time
	// the out-of-flow box is placed.
	static_x int
	static_y int
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
	// The floats of the flow `b` is in, in the order they are laid out. `place` appends
	// to it as it walks the tree -- a float belongs to the flow of the block it is in,
	// and a nested block is not a flow of its own -- and reads it to know which lines
	// to shorten and which boxes to clear. It is threaded rather than kept on the
	// Layouter because Layouter is reused: a field holding floats from a previous
	// viewport would shorten lines on the next one by boxes that are no longer there.
	mut floats := []&Box{}
	// The initial containing block: a `position: absolute` box with no positioned
	// ancestor is placed against the viewport (CSS 2.1 10.1), which is also the
	// containing block every `top`/`left` percentage starts from resolving against.
	l.place(mut b, l.viewport_width, 0, 0, false, ContBlock{
		x:      0
		y:      0
		width:  l.viewport_width
		height: l.viewport_height
	}, mut floats)
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
	mut pending := []InlineItem{}
	for child in el.children {
		if tree.is_text(child) {
			// Whitespace is kept rather than dropped. Dropping a whitespace-only node
			// between two inline elements glues them together: `<b>a</b> <i>b</i>` would
			// become "ab". Collapsing happens once, in `inline_box`.
			pending << InlineItem{
				is_box:    false
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
		if cs.display == .inline_block {
			// An inline-block is inline-level but atomic: it becomes a child box that the
			// line breaker treats as one unbreakable unit, rather than text collected into
			// the surrounding run. Without this it would be laid out as a block and get a
			// line of its own, which is the one thing it must not do.
			pending << InlineItem{
				is_box: true
				box:    l.build(child, cs, &child_ctx)
			}
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
					InlineItem{
						is_box:    false
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
			pending << InlineItem{
				is_box:    false
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
	// A table's children are rows inside row groups, and a stylesheet is free to omit
	// the row group: `<table><tr>` is the common form. CSS 2.1 17.2.1 requires the
	// missing wrappers to be generated, and without them the rows are laid out by block
	// layout -- two empty divs, which is the most common way a table page silently
	// falls apart and says nothing.
	wrap_table_children(mut b)
	return b
}

// anonymous_table_box makes a box for one of the internal table structures CSS 2.1
// 17.2.1 requires. The style is the parent's *inherited* properties with the display
// set to `d`, because an anonymous box has no author properties of its own: copying
// the parent's whole Style would carry its border, padding and width into the wrapper,
// and a `width: 400px` table would then also be a 400px row group.
fn anonymous_table_box(parent style.Style, d style.Display) &Box {
	mut s := style.initial()
	s.inherit_from(&parent)
	s.display = d
	return &Box{
		style:        s
		is_anonymous: true
	}
}

// wrap_table_children applies the anonymous-box rules of CSS 2.1 17.2.1 to the
// children of a table wrapper or a row group.
//
// Two rules, both of which a real page depends on:
//
//   - a run of `table-row` children directly under a table becomes one anonymous row
//     group, because rows are laid out by the table and not by block layout;
//   - a child of a table wrapper that is not a row, a row group or a column -- a stray
//     text node, a `<div>` -- is wrapped in an anonymous row group, row and cell, so
//     that it is laid out inside the table instead of being dropped or misplaced.
//
// The second rule is why this is a separate pass and not a branch in the child loop:
// by the time the loop has finished, the stray content is already a box of its own.
fn wrap_table_children(mut b &Box) {
	d := b.style.display
	if !d.is_table() && !d.is_table_row_group() {
		return
	}
	mut out := []&Box{}
	mut i := 0
	for i < b.children.len {
		cd := b.children[i].style.display
		if d.is_table() && cd == .table_row {
			// One anonymous group per *run* of rows, not one per row: `<table><tr>…<tr>…`
			// is one group, and a `<tbody>` between them is its own.
			mut rows := []&Box{}
			for i < b.children.len && b.children[i].style.display == .table_row {
				mut r := b.children[i]
				wrap_row_children(mut r)
				rows << r
				i++
			}
			mut g := anonymous_table_box(b.style, .table_row_group)
			g.children = rows
			out << g
			continue
		}
		if cd.is_table_row_group() {
			mut g := b.children[i]
			wrap_table_children(mut g)
			out << g
			i++
			continue
		}
		// A row inside a row group is exactly what belongs there, so it is kept and only
		// its own children are wrapped. Missing this case wrapped the rows of a `<tbody>`
		// into anonymous cells, which left the table with no rows at all and made it
		// render as nothing -- the form every real page writes, and the one the first
		// version of this got wrong because only the bare-row form had a test.
		if d.is_table_row_group() && cd == .table_row {
			mut r := b.children[i]
			wrap_row_children(mut r)
			out << r
			i++
			continue
		}
		if cd == .table_caption {
			out << b.children[i]
			i++
			continue
		}
		// A column or column group generates no box this engine lays out: the column
		// widths come from the cells, which is where CSS 2.1's own table puts them when
		// there are no `<col>` elements.
		if cd == .table_column || cd == .table_column_group {
			i++
			continue
		}
		mut cell := anonymous_table_box(b.style, .table_cell)
		cell.children << b.children[i]
		mut row := anonymous_table_box(b.style, .table_row)
		row.children << cell
		mut group := anonymous_table_box(b.style, .table_row_group)
		group.children << row
		out << group
		i++
	}
	b.children = out
}

// wrap_row_children wraps anything inside a row that is not a cell in an anonymous
// cell, which is the same rule one level down: a row's children are cells.
fn wrap_row_children(mut b &Box) {
	if b.style.display != .table_row {
		return
	}
	mut out := []&Box{}
	for c in b.children {
		if c.style.display.is_table_cell() || c.style.display == .table_caption {
			out << c
			continue
		}
		mut cell := anonymous_table_box(b.style, .table_cell)
		cell.children << c
		out << cell
	}
	b.children = out
}

// inline_box turns accumulated inline runs into an anonymous box, or into nothing when
// every run in them is empty.
//
// `text_style_of` is applied per run rather than once to the box. It clears the
// properties that belong to an element's own box -- background, borders, margin and
// padding -- and an inline element's background *is* its own, so this is what stops
// `<span style="background:yellow">` painting behind the whole block.
fn inline_box(in_items []InlineItem, s style.Style, font_size f64) ?&Box {
	if in_items.len == 0 {
		return none
	}
	mut items := []InlineItem{cap: in_items.len}
	mut runs := []InlineRun{}
	mut atomics := []&Box{}
	for item in in_items {
		if item.is_box {
			atomics << item.box
			items << item
			continue
		}
		t := collapse_inline_space(item.text, s.white_space)
		if t == '' {
			continue
		}
		nr := InlineRun{
			text:      t
			style:     text_style_of(item.style)
			font_size: item.font_size
		}
		runs << nr
		items << InlineItem{
			is_box:    false
			text:      t
			style:     nr.style
			font_size: nr.font_size
		}
	}
	if items.len == 0 {
		return none
	}
	// The block's own leading and trailing whitespace goes, but not an item in the middle:
	// the space between `<b>a</b>` and `<i>b</i>` is inside the block and has to survive.
	// Atomic boxes are never dropped -- they are not whitespace.
	trim_items(mut items)
	if items.len == 0 {
		return none
	}
	// Rebuilt after the trim, since the trim can drop items from either end.
	runs = []InlineRun{}
	atomics = []&Box{}
	mut flat := strings.new_builder(64)
	for item in items {
		if item.is_box {
			atomics << item.box
			// A stand-in so `text` is non-empty and the box takes the text branch in
			// `place`. The box's own content is not text and is not measured here.
			flat.write_string(' ')
		} else {
			runs << InlineRun{
				text:      item.text
				style:     item.style
				font_size: item.font_size
			}
			flat.write_string(item.text)
		}
	}
	return &Box{
		style:        text_style_of(s)
		text:         flat.str()
		runs:         runs
		atomics:      atomics
		inline_items: items
		font_size:    font_size
		is_anonymous: true
	}
}

// trim_items drops leading and trailing items that are whitespace-only text, leaving
// anything in the middle alone. Atomic boxes are never dropped: they are not whitespace
// and have to stay exactly where they were.
fn trim_items(mut items []InlineItem) {
	mut start := 0
	for start < items.len && !items[start].is_box
		&& collapse_inline_space(items[start].text, .normal).trim_space() == '' {
		start++
	}
	mut end := items.len
	for end > start && !items[end - 1].is_box
		&& collapse_inline_space(items[end - 1].text, .normal).trim_space() == '' {
		end--
	}
	items = items[start..end]
	// Dropping a whitespace-only item is not the same as dropping the whitespace. A single
	// item holding " spaced out here " is not whitespace-only, so it survives the pass above
	// and still carries the block's own leading and trailing space. Those go here.
	if start < items.len && !items[start].is_box {
		items[start].text = items[start].text.trim_left(' \n\t\r')
	}
	if end > start && !items[end - 1].is_box {
		items[end - 1].text = items[end - 1].text.trim_right(' \n\t\r')
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
	// And `float` and `clear` go with them, for the same reason twice over. An
	// anonymous box has no element of its own, so it cannot be floated, and the copy is
	// of a style that *was* floated -- which is what happens inside a floated box, whose
	// text is collected into one anonymous box. Leaving the property on it made the
	// anonymous box a float inside its own parent's float, which recursed.
	s.float = .none
	s.clear = .none
	// And `position`, `z-index` and the insets, for the same reason a third time. A
	// `position: relative` block's inline content is one anonymous box, and that box is
	// laid out from the origin its parent was laid out at -- which is already the
	// shifted one. Carrying the parent's `position` onto it would shift the text a
	// second time, by the parent's own insets.
	s.position = .static
	s.z_index = style.ZIndex{ auto: true }
	s.insets = style.auto_edges()
	// `display` too, because the style is copied from whatever block the text sits in and
	// that is not what the anonymous box is: a flow root's own inline content is part of
	// the flow root's flow, so an anonymous box inside it that carried `flow-root` would
	// start a new formatting context of its own and hide the very lines the float has to
	// shorten. The box holds inline content and lays it out, which is what `block` says.
	s.display = .block
	return s
}

// ContBlock is the containing block an out-of-flow box is placed against: the
// padding box of the nearest ancestor that is not `static` (CSS 2.1 10.1), or the
// initial containing block when there is no such ancestor.
//
// `height` is -1 when it is not definite, and that is a real answer rather than a
// missing one. A percentage against a containing block whose height comes from its
// content is `auto`, and this engine cannot tell the two apart with a number: the
// containing block is a box that is still being laid out. A box's *own* out-of-flow
// children are the exception -- they are placed against a containing block whose
// height does exist, because by then this box has been laid out -- see `place`.
struct ContBlock {
pub mut:
	x      int
	y      int
	width  int
	height int
}

// out_of_flow reports whether this position takes a box out of the normal flow
// (CSS 2.1 9.6). `sticky` is not accepted by the cascade, so a page using it keeps
// the `static` initial value and its box stays in the flow.
fn out_of_flow(p style.Position) bool {
	return p == .absolute || p == .fixed
}

// inset_px resolves one inset to pixels, or -1 when the side names no position.
//
// A percentage is the second way to say `auto`: CSS 2.1 10.3.7 resolves a
// percentage against a dimension of the containing block, and when that dimension
// is not definite the percentage computes to `auto`. So `basis < 0` returns -1 for
// a percentage and leaves a real length alone -- a `top: 10px` under a containing
// block of unknown height is still 10.
fn inset_px(l style.Length, ctx &style.Context, basis int) int {
	if l.unit == .auto || l.unit == .none {
		return -1
	}
	if l.unit == .percent {
		if basis < 0 {
			return -1
		}
		return px(l.value * f64(basis) / 100.0)
	}
	return px(resolve(l, ctx, 0.0))
}

// relative_offset is how far a relatively positioned box moves (CSS 2.1 9.4.3).
//
// It is resolved at the *top* of a box's own layout rather than applied to a finished
// subtree, and that is not an optimisation: the shift then moves the box and everything
// it lays out, in one arithmetic step, and a second layout of the same box -- which the
// relayout protocol does -- starts from the unshifted origin again instead of shifting
// a box that was already shifted.
//
// LTR resolves an over-constrained pair by ignoring `right`, and only the sides that
// were written move the box: a box with `top` alone does not shift sideways because
// `left` was not given.
fn (mut l Layouter) relative_offset(b &Box, cb ContBlock) (int, int) {
	s := b.style
	ctx := l.context(b.font_size)
	left := inset_px(s.insets.left, &ctx, cb.width)
	right := inset_px(s.insets.right, &ctx, cb.width)
	top := inset_px(s.insets.top, &ctx, cb.height)
	bottom := inset_px(s.insets.bottom, &ctx, cb.height)
	mut dx := 0
	mut dy := 0
	if left >= 0 {
		dx = left
	} else if right >= 0 {
		dx = -right
	}
	if top >= 0 {
		dy = top
	} else if bottom >= 0 {
		dy = -bottom
	}
	return dx, dy
}

// place_absolute places one out-of-flow box against its containing block.
//
// The rules of CSS 2.1 10.3.7 in the order they resolve, because the order is what the
// answers depend on: the width first -- from the two opposite insets, or
// shrink-to-fit, or the specified one -- then the horizontal edge (from `left`, or
// from `right` measured against the width, or from the static position), then the
// vertical one.
//
// The width when there is none is the same clamp and the same protocol
// `place_atomic` implements for an atomic inline-level box (CSS 2.1 10.3.9), which is
// why the two share it rather than each inventing one. ARCHITECTURE.md section 5 is
// the reason there is a protocol at all: a box whose width is measured, holding a
// percentage, is a fraction of the very width being measured.
fn (mut l Layouter) place_absolute(mut ab &Box, cb ContBlock) {
	s := ab.style
	ctx := l.context(ab.font_size)
	mut block := cb
	if s.position == .fixed {
		// `fixed` is `absolute` with one rule replaced (CSS 2.1 10.1): the containing
		// block is the viewport, so a positioned ancestor above it does not apply.
		block = ContBlock{ x: 0, y: 0, width: l.viewport_width, height: l.viewport_height }
	}
	m := edges_of(s.margin, &ctx, f64(block.width))
	pad := edges_of(s.padding, &ctx, f64(block.width))
	edge := zero_width_sides(mut edges_of(s.border_width, &ctx, f64(block.width)), s.border_style)
	frame := edge.left + edge.right + pad.left + pad.right
	top := inset_px(s.insets.top, &ctx, block.height)
	right := inset_px(s.insets.right, &ctx, block.width)
	bottom := inset_px(s.insets.bottom, &ctx, block.height)
	left := inset_px(s.insets.left, &ctx, block.width)
	// The space the border box may occupy, before the box's own margins take their
	// share.
	space := block.width - m.left - m.right
	definite_width := s.width.unit != .auto && s.width.unit != .none
	mut used := block.width
	if !definite_width && left >= 0 && right >= 0 {
		// The two opposite insets size the box. The result is floored at zero rather
		// than allowed to go negative, which is what an over-constrained box would
		// otherwise produce.
		mut w := space - left - right
		if w < 0 {
			w = 0
		}
		used = w + m.left + m.right
	} else if !definite_width {
		// Neither inset and no width: shrink-to-fit, the clamp CSS 2.1 10.3.7 takes from
		// 10.3.9 and the protocol ARCHITECTURE.md section 5 says a measured width
		// needs. The probe is laid out at its static position; only the width it turns
		// out to need is kept, because the position is decided below.
		l.place_root(mut ab, unbreakable_width, ab.static_x, ab.static_y, block)
		mut assumed := atomic_fit(ab, space) + m.left + m.right
		for pass := 1; pass < max_relayout_passes; pass++ {
			l.place_root(mut ab, assumed, ab.static_x, ab.static_y, block)
			next := atomic_fit(ab, space) + m.left + m.right
			if next == assumed {
				break
			}
			assumed = next
		}
		used = assumed
	}
	// A pass at the provisional position, so that the box has a size before it is used:
	// `right` and `bottom` are distances from the far edge of the containing block to
	// this box's own far *margin* edge, and neither can be measured until the box has
	// been laid out at the width decided above. It is laid out again below, at the
	// position the insets actually ask for, because a first pass at the wrong place is
	// still what makes the second one right.
	l.place_root(mut ab, used, ab.static_x, ab.static_y, block)
	// Then the place. `left` and `top` are simple offsets from the near edges of the
	// containing block; `right` and `bottom` are measured from the far edges and so need
	// the size the pass above produced. An inset that is `auto` -- including one that was
	// a percentage of a base nobody knows -- leaves the box at its static position.
	mut bx := ab.static_x
	mut by := ab.static_y
	if left >= 0 {
		bx = block.x + left
	} else if right >= 0 {
		bx = block.x + block.width - right - ab.rect.width - m.left - m.right
	}
	if top >= 0 {
		by = block.y + top
	} else if bottom >= 0 {
		by = block.y + block.height - bottom - ab.rect.height - m.top - m.bottom
	}
	l.place_root(mut ab, used, bx, by, block)
	// CSS 2.1 10.6.5: with `top` and `bottom` both given and `height: auto`, the height
	// is what is left between them. This is the `top: 0; bottom: 0` overlay, which is
	// the commonest way a stylesheet asks for a full-height box, and without it the
	// box takes its content height and stops short of the bottom.
	if (s.height.unit == .auto || s.height.unit == .none) && top >= 0 && bottom >= 0 {
		mut h := block.height - top - bottom - m.top - m.bottom - frame
		if h < 0 {
			h = 0
		}
		ab.rect.height = h
		ab.content.height = max_of(h - edge.top - edge.bottom - pad.top - pad.bottom, 0)
	}
}

// place lays a box out at a position, in place, and returns its border-box height.
//
// `y` is the top of this box's *margin box*: the caller has already advanced past the
// collapsed top margin, because a collapsed margin is the caller's arithmetic to do and
// two places doing it is how it got counted twice. `bottom_escapes` says whether this
// box's bottom margin may collapse with the one below it, which decides whether the
// caller subtracts it from the height it gets back. `floats` are the floats generated
// so far in this flow, and `place` appends the ones it generates to it.
//
// `cb` is the containing block this box's own descendants are positioned against --
// the padding box of the nearest ancestor that is not `static`, or the viewport. It
// changes only when a positioned box is entered, which is why it is a parameter rather
// than a field: two boxes in the same flow can be in different containing blocks.
fn (mut l Layouter) place(mut b &Box, containing_width int, x int, y int, bottom_escapes bool,
	cb ContBlock, mut floats []&Box) int {
	s := b.style
	ctx := l.context(b.font_size)
	// CSS 2.1 9.4.3: a relatively positioned box is offset from its normal position,
	// and the offset is applied to the origin it is laid out at rather than to a
	// finished subtree. Everything this box lays out -- its border box, its content
	// box, its children, its glyphs -- then moves together, which is what the rule
	// says, and the height this function returns is the unshifted one, so the
	// following siblings are laid out exactly as if the box had not moved. That second
	// half is the whole difference between `relative` and a margin.
	mut ox := x
	mut oy := y
	if s.position == .relative {
		dx, dy := l.relative_offset(b, cb)
		ox += dx
		oy += dy
	}
	mut margin := edges_of(s.margin, &ctx, f64(containing_width))
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
	mut border_x := ox + margin.left
	// Horizontal auto margins, CSS 2.1 10.3.2. With both sides `auto` and a width that is
	// not itself `auto`, the space left over is split between them, which is what centres
	// `<div style="width:200px; margin:0 auto">`. With only one side `auto`, that side
	// absorbs all the leftover space.
	//
	// The width has to be *definite*: a `width: auto` block has already taken all the space
	// there is, so the leftover is zero. And only a positive leftover is split -- a negative
	// one would push the box off the left edge.
	//
	// An out-of-flow box is excluded, because CSS 2.1 10.3.7 makes every `auto` margin of
	// an absolutely positioned box zero: it has already been given its place by an inset
	// or by its static position, and splitting what is left over between its margins
	// would move a box that was told exactly where to go.
	if s.width.unit != .auto && s.width.unit != .none && !out_of_flow(s.position) {
		leftover := containing_width - content_width - frame - margin.left - margin.right
		if leftover > 0 {
			if s.margin.left.unit == .auto && s.margin.right.unit == .auto {
				border_x = ox + leftover / 2
			} else if s.margin.left.unit == .auto {
				border_x = ox + leftover
			} else if s.margin.right.unit == .auto {
				border_x = ox
			}
		}
	}
	content_x := border_x + border.left + padding.left
	mut cursor := oy + border.top + padding.top
	content_y := cursor

	// The containing block this box's descendants are positioned against (CSS 2.1
	// 10.1). A box that is not `static` becomes one, and the containing block is its own
	// *padding box*: the border box less the borders, padding included. The content box
	// would put every overlay one padding inside where it belongs.
	//
	// The height is -1: it is the one dimension that does not exist yet, because the
	// children are what decide it. That is not a compromise but the rule CSS gives --
	// a percentage against a containing block whose height is not definite computes to
	// `auto` -- and it applies to every descendant reached through a *static* box. This
	// box's own out-of-flow children are placed at the end of this function, where the
	// height does exist.
	mut child_cb := cb
	if b.style.position != .static {
		child_cb = ContBlock{
			x:      border_x + border.left
			y:      oy + border.top
			width:  content_width + padding.left + padding.right
			height: -1
		}
	}

	mut previous_bottom := 0
	mut first := true
	// The list-item index of the child about to be laid out. A parent counting its own
	// children is the only place the order exists -- a box cannot count itself, because
	// it does not know which of its siblings it is.
	mut li_index := 0
	// A table is the one box whose children are not laid out by block layout at all:
	// its rows are sized by the column grid and its cells by the row they are in. So
	// the child loop below is skipped for one, and `layout_table` does the work. The
	// table's own height is then the rows' sum, which is what `cursor` becomes, so the
	// rest of this function -- the content rect, the height clamps -- needs no special
	// case for it.
	if s.display.is_table() {
		th := l.layout_table(mut b, &ctx, content_x, content_y, content_width, cb)
		b.content = Rect{ x: content_x, y: content_y, width: content_width, height: th }
		cursor += th
	} else {
		// Indexed rather than ranged: `for child_ref in b.children { mut child := child_ref }`
		// makes a mutable reference to an immutable loop variable, which V reports as a
		// notice and which is one copy away from writing to the wrong box.
		mut i := 0
		for i < b.children.len {
			mut child := b.children[i]
			cs := child.style
			child_ctx := l.context(child.font_size)
			cm := edges_of(cs.margin, &child_ctx, f64(content_width))
			if cs.display == .list_item {
				li_index++
				child.list_index = li_index
			}
			// Adjacent siblings' margins collapse to the larger of the two. The
			// whole reason `p { margin: 1em 0 }` looks right.
			mut top := cm.top
			if !first {
				top = max_of(previous_bottom, cm.top)
			}
			if out_of_flow(cs.position) {
				// CSS 2.1 9.6, and both halves of it are rules rather than consequences of
				// where the box is stored. It does not advance the cursor, and it does not
				// collapse its margins with a sibling's, so the in-flow box after it keeps
				// the place it had. That is the same pair of rules a float follows, for the
				// same reason.
				//
				// What is recorded here is the place the box *would* have taken. `left:
				// auto` resolves to exactly that (CSS 2.1 10.3.7 rule 3), and it is the
				// static-position fallback that a box positioned by `top` alone still needs
				// for its horizontal coordinate. It has to be captured while the cursor is
				// here: by the time the box is placed, the cursor has moved past it.
				child.static_x = content_x
				child.static_y = cursor + top
				b.absolutes << child
				// The next sibling is no longer the first, but an out-of-flow box leaves no
				// bottom margin behind it either, so `previous_bottom` keeps whatever the
				// last in-flow box left.
				first = false
				i++
				continue
			}
			if cs.float != .none {
				// A floated box is out of the flow, and both halves of that are rules rather
				// than a consequence of the data structure. It does not collapse its margins
				// with a sibling's -- margins of floating boxes never collapse, CSS 2.1 9.5.1
				// -- and it does not advance the cursor, so the box that follows it is laid
				// out where it would have been anyway. That second half is the visible one:
				// it is the difference between text wrapping beside a float and text pushed
				// below it.
				at := cursor + cm.top
				l.place_float(mut child, content_width, content_x, at + clear_push(floats, cs.clear,
					at), child_cb, mut floats)
				// The next sibling is no longer the first, but a float leaves no bottom
				// margin behind it: it does not participate in collapsing, so `previous_bottom`
				// must keep whatever the last in-flow box left.
				first = false
				i++
				continue
			}
			cursor += top
			// `clear` is the one property that moves a box below a float, and it is applied
			// to the position the collapsing settled on: the clearance is how much further
			// the box must move for its border box top to be below the bottom of every
			// earlier float on the sides it names (CSS 2.1 9.5.2).
			cursor += clear_push(floats, cs.clear, cursor)
			// Only an only-child box can collapse through to its parent's edge.
			is_last := b.children.len == 1
			if cs.display == .flow_root {
				// A flow root is a new block formatting context (CSS 2.1 9.4.1), so the
				// floats generated inside it shorten the lines inside it and nothing outside
				// it. That is the whole of what `display: flow-root` is for, and it is the
				// one difference between it and a plain block.
				mut inner := []&Box{}
				cursor += l.place(mut child, content_width, content_x, cursor, is_last, child_cb,
					mut inner)
			} else {
				cursor += l.place(mut child, content_width, content_x, cursor, is_last, child_cb,
					mut floats)
			}
			previous_bottom = cm.bottom
			first = false
			i++
		}
	}

	// Atomic inline-level boxes have to be sized before the text is laid out, because the
	// line breaker needs their widths. They are placed at a temporary position here and
	// given their real one during shaping.
	for ai in 0 .. b.atomics.len {
		if b.atomics[ai] == nil {
			continue
		}
		mut bx := b.atomics[ai]
		l.place_atomic(mut bx, content_width, content_x, content_y, child_cb)
	}

	if b.text != '' {
		lines := l.layout_runs(mut b, &ctx, content_x, content_y, content_width, floats)
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
	} else if flow_empty(b) {
		// An empty block is still one line tall. A page of them collapsing to nothing
		// makes `height: 100%` on a parent a percentage of zero.
		//
		// `flow_empty` rather than `children.len == 0`, because a box whose only child is
		// absolutely positioned is empty: it has no flow content to give it a line, and
		// giving it one would make every `position: relative` div holding a single
		// overlay a phantom 20px taller than its content.
		fs := font_style_of(s, b.font_size, &ctx)
		line_height := px(l.fonts.line_metrics(&fs).line_height)
		b.content = Rect{ x: content_x, y: content_y, width: content_width, height: line_height }
		cursor += line_height
		previous_bottom = 0
	} else if s.display.is_table() {
		// A table's content rect was already set by `layout_table`, with the rows' sum
		// for its height. Overwriting it here -- which is what this branch does for
		// every other box that has children -- would leave a table reporting zero
		// height and make its parent's next sibling start at the same y.
	} else {
		b.content = Rect{ x: content_x, y: content_y, width: content_width }
	}
	// The marker box (CSS 2.1 12.5) is built here rather than in the text branch above,
	// because a list item's marker belongs to the *item*, and the item is this box --
	// the box holding the text is an anonymous one that `text_style_of` has already made
	// `block`, so asking it whether it is a list item would always answer no.
	l.place_marker(mut b, &ctx, content_x, content_width, content_y)

	// A box whose content is child boxes is as wide as its widest child, by intrinsic
	// size, plus that child's margins. Done here rather than inside the child loop above
	// because it needs each child's own measurement, which that child only has once it has
	// been placed.
	//
	// Collapsed margins are summed rather than collapsed, so a parent with two children
	// whose vertical margins collapse reports a slightly larger min-content than a browser
	// would. That is the safe direction: an over-estimate keeps a box wide, while an
	// under-estimate clips content.
	mut child_max := 0
	mut child_min := 0
	for c in b.children {
		// An out-of-flow box is not part of the flow, so it is not part of the intrinsic
		// width either: CSS Sizing 3 says an absolutely positioned box does not
		// contribute to its parent's intrinsic size, and a page whose only child is an
		// overlay would otherwise measure itself against it.
		if out_of_flow(c.style.position) {
			continue
		}
		cctx := l.context(c.font_size)
		ce := edges_of(c.style.margin, &cctx, f64(content_width))
		w := c.max_content_width + ce.left + ce.right
		if w > child_max {
			child_max = w
		}
		n := c.min_content_width + ce.left + ce.right
		if n > child_min {
			child_min = n
		}
	}
	if b.children.len > 0 && !s.display.is_table() {
		b.max_content_width = child_max + frame
		b.min_content_width = child_min + frame
	}

	mut content_height := max_of(cursor - content_y, 0)
	// A box with no content at all -- `display: block` on an empty div with a set
	// height aside -- would otherwise be zero tall.
	//
	// An out-of-flow child is not content. A box whose only child is absolutely
	// positioned is empty, and a stylesheet that puts one overlay inside a
	// `position: relative` div expects that div to be no taller than its other
	// content -- which is the same rule that makes a float not heighten its parent.
	if flow_empty(b) && content_height == 0 {
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

	b.rect = Rect{ x: border_x, y: oy, width: content_width + frame, height: border_height }
	// Assigned one side at a time because a braced array initializer with positional
	// elements is a parse error in V 0.5.2 (see notes/V-GOTCHAS.md).
	mut bw := [4]int{}
	bw[0] = border.top
	bw[1] = border.right
	bw[2] = border.bottom
	bw[3] = border.left
	b.border_px = bw
	b.content.height = max_of(content_height, 0)

	// Every out-of-flow box this box is the containing block for, placed now that
	// every dimension of it is final.
	//
	// This is the whole reason they are placed here rather than inside the child loop
	// above: the loop runs before this box's height exists, and a percentage inset
	// placed there would be a fraction of a height nobody has decided yet. The
	// containing block handed down to the descendants reached through a *static* child
	// still has `height: -1`, which is the answer CSS gives for that case.
	if b.absolutes.len > 0 {
		mut own := cb
		if b.style.position != .static {
			// The padding box, which CSS 2.1 10.1 names: the border box less the two
			// borders on each axis. The padding itself is *inside* it, so an absolute child
			// with no inset starts at the outer edge of the padding and not at the edge of
			// the content -- reading the content box here would put every overlay one
			// padding inside where it belongs.
			own = ContBlock{
				x:      b.rect.x + b.border_px[3]
				y:      b.rect.y + b.border_px[0]
				width:  b.rect.width - b.border_px[1] - b.border_px[3]
				height: b.rect.height - b.border_px[0] - b.border_px[2]
			}
		}
		for ai in 0 .. b.absolutes.len {
			mut ab := b.absolutes[ai]
			l.place_absolute(mut ab, own)
		}
	}
	return border_height
}

// flow_empty reports that a box has nothing in the normal flow inside it. An
// out-of-flow child is not flow content, so a box holding only one is empty -- which is
// the rule that keeps a `position: relative` div with one absolute child from growing a
// phantom line. It is a walk rather than a count because the out-of-flow boxes are kept
// in `children` for the document order they carry, and a length there says nothing
// about how many of them are in the flow.
fn flow_empty(b &Box) bool {
	if b.text != '' {
		return false
	}
	for c in b.children {
		if !out_of_flow(c.style.position) {
			return false
		}
	}
	return true
}

// unbreakable_width is a containing width wide enough that nothing laid out inside it
// wraps. It is what the measure pass of `place_atomic` gives a box that it is about to
// size. `wrap_width` already means this as 1.0e9 for `nowrap`; this one is an int a
// million wide because `place` takes a containing width rather than a wrap width, and
// a million is wider than any line a page can lay out.
const unbreakable_width = 1_000_000

// max_relayout_passes is the relayout ceiling of ARCHITECTURE.md section 5: how many
// times a box may be laid out again at a resolved width before the engine gives up and
// keeps what it has. Browsers manage about four, and the number is here so that the
// protocol is bounded rather than trusting every layout to stabilise.
//
// A ceiling is not decoration here. Relayout is a feedback loop: a percentage width
// inside a shrink-to-fit box is a fraction of the very width the box is trying to work
// out, so without something to stop it the sequence can keep moving for ever. With the
// rules this engine implements today the loop converges on its first pass -- because
// `intrinsic_atom_width` stops a percentage contributing a provisional width, so the
// clamp is a one-step function of the content -- and the ceiling is the guard for the
// rules that arrive later, where it will not be.
const max_relayout_passes = 4

// place_atomic lays out one atomic inline-level box that sits inside a line of this
// block, sized to fit the space that line has for it.
//
// `line_width` is the width of the line's content box: what is available before the
// box's own margins take their share. The position it is given here is temporary --
// the line layout places the box where it actually landed when it shapes the line.
//
// `cb` is the containing block the box's own out-of-flow descendants resolve against.
// It is threaded through rather than reset: an atomic is a formatting context of its
// own but not a containing block, so a `position: absolute` inside an inline-block is
// still placed against the positioned ancestor *outside* it.
fn (mut l Layouter) place_atomic(mut bx &Box, line_width int, x int, y int, cb ContBlock) {
	// CSS 2.1 10.3.9: `width: auto` on an inline-block is shrink-to-fit,
	// min(max(preferred minimum, available), preferred) -- and not "fill the line",
	// which is what the same `auto` means on a block. The two are one `display` value
	// apart, and reading the block rule onto the inline one is what made
	// `<span style="display:inline-block">text</span>` take the whole width of the
	// paragraph around it.
	//
	// An explicit width is left to `box_width`, where it was already right, and there is
	// nothing to relayout: the width is the fact.
	if bx.style.width.unit != .auto && bx.style.width.unit != .none {
		l.place_root(mut bx, line_width, x, y, cb)
		return
	}
	bx_ctx := l.context(bx.font_size)
	bx_margin := edges_of(bx.style.margin, &bx_ctx, f64(line_width))
	// What is left of the line for the box's *border box*. The intrinsic widths carry the
	// box's own padding and border -- a parent sizing itself to a child has to reserve
	// them, which is why a padded box's intrinsic widths are wider than an unpadded
	// one's by exactly its frame -- so the frame belongs inside the clamp rather than
	// coming off the space. Taking it off both sides would understate the space by the
	// frame and every padded inline-block would come out one frame too narrow.
	available := line_width - bx_margin.left - bx_margin.right
	// Probe. The intrinsic widths the clamp is against do not exist until the box has
	// been laid out, and they have to be the content's own: laid out at the width it is
	// really going to get, an atomic inside it would already have shrunk itself to that
	// width, and this box's max-content would be measured as the space it was given
	// rather than as the width of its content.
	l.place_root(mut bx, unbreakable_width, x, y, cb)
	// The margins are handed back as containing width so that `place`'s own `available`
	// comes out as `fitted` less the frame, and its rect as `fitted`.
	mut assumed := atomic_fit(bx, available) + bx_margin.left + bx_margin.right
	// The relayout protocol, ARCHITECTURE.md section 5: lay the box out at the width this
	// pass settled on, and if the content then resolves to a different width, lay it out
	// again there. What the next pass is laid out at *is* the protocol's `reflow_at` --
	// the width the pass just used was an assumption, and this is the fact that replaces
	// it. A pass whose own answer is the width it already used is the final layout.
	for pass := 1; pass < max_relayout_passes; pass++ {
		l.place_root(mut bx, assumed, x, y, cb)
		next := atomic_fit(bx, available) + bx_margin.left + bx_margin.right
		if next == assumed {
			return
		}
		assumed = next
	}
	// The ceiling. Every pass changed the answer, so stop with the width we settled on
	// rather than moving again: a resolution that has not stabilised in `max_relayout_passes`
	// passes is a cycle, and the last width is the deterministic one to keep.
	l.place_root(mut bx, assumed, x, y, cb)
}

// table_rows is the table's rows in document order: the rows of each row group, and a
// row that was a direct child, which `wrap_table_children` has already put inside a
// group. It returns the row boxes themselves, so a caller sizing a column writes
// through the same pointers the tree holds.
fn table_rows(b &Box) []&Box {
	mut out := []&Box{}
	for g in b.children {
		if g.style.display.is_table_row_group() {
			for r in g.children {
				if r.style.display == .table_row {
					out << r
				}
			}
			continue
		}
		if g.style.display == .table_row {
			out << g
		}
	}
	return out
}

// table_cells is a row's cells in document order, skipping the caption if one was
// wrapped into the row by mistake of the stylesheet.
fn table_cells(r &Box) []&Box {
	mut out := []&Box{}
	for c in r.children {
		if c.style.display == .table_row {
			for cc in c.children {
				out << cc
			}
			continue
		}
		if c.style.display == .table_caption || c.style.display == .table_column
			|| c.style.display == .table_column_group {
			continue
		}
		out << c
	}
	return out
}

// layout_table lays out a table's rows and cells and returns the height they used.
//
// Two passes, which is CSS 2.1 17.5.2's automatic table layout and the reason
// `min_content_width`/`max_content_width` were built in Phase 2:
//
//  1. every cell is laid out once at the width the line has, because a cell's
//     min-content and max-content do not exist until the cell has been laid out;
//  2. the columns are sized from those numbers, reduced if their total would overflow
//     the table, and every cell is laid out again at the width its column came out as.
//
// The second pass is the relayout protocol of ARCHITECTURE.md section 5 applied to a
// whole grid: the first pass's geometry is an assumption, the column width is the fact
// that replaces it, and `place` assigning rather than accumulating is what makes the
// re-layout a replacement instead of an adjustment.
fn (mut l Layouter) layout_table(mut b &Box, ctx &style.Context, content_x int, content_y int, content_width int, cb ContBlock) int {
	mut rows := table_rows(b)
	// A caption is a direct child of the table and is not a row, so it is laid out here
	// rather than by the table's rows. CSS renders it above the table by default.
	//
	// Indexed rather than ranged, for the reason the child loop in `place` is: a ranged
	// loop variable is immutable, and V notices the mutable reference taken through it.
	mut top := content_y
	mut cap_i := 0
	for cap_i < b.children.len {
		mut c := b.children[cap_i]
		cap_i++
		if c.style.display != .table_caption {
			continue
		}
		mut cf := []&Box{}
		cctx := l.context(c.font_size)
		ce := edges_of(c.style.margin, &cctx, f64(content_width))
		top += ce.top
		top += l.place(mut c, content_width, content_x, top, false, cb, mut cf)
		top += ce.bottom
	}
	if rows.len == 0 {
		return top - content_y
	}
	// The grid: which column each cell starts in, so a spanning cell can occupy several
	// and the columns it covers are the ones it is sized against.
	grid := table_grid(rows)
	mut cols := 0
	for r in grid {
		mut c := 0
		for g in r {
			if g.col + g.colspan > c {
				c = g.col + g.colspan
			}
		}
		if c > cols {
			cols = c
		}
	}
	if cols == 0 {
		return top - content_y
	}
	// A cell is laid out inside the table's content box, and with its own float list:
	// a float inside a cell does not reach the rows of the table any more than a float
	// inside an inline-block reaches the paragraph around it.
	mut cell_cb := cb
	cell_cb.y = top
	cell_cb.x = content_x
	cell_cb.width = content_width
	// Pass 1: measure every cell, and keep the tallest cell of each row.
	mut minc := []int{len: cols, init: 0}
	mut maxc := []int{len: cols, init: 0}
	mut row_h := []int{len: rows.len, init: 0}
	for ri in 0 .. rows.len {
		mut cells := table_cells(rows[ri])
		for ci in 0 .. cells.len {
			g := grid[ri][ci]
			mut cell := cells[ci]
			cctx := l.context(cell.font_size)
			ce := edges_of(cell.style.margin, &cctx, f64(content_width))
			mut cf := []&Box{}
			l.place(mut cell, content_width, content_x, content_y, false, cell_cb, mut cf)
			w := cell.max_content_width + ce.left + ce.right
			n := cell.min_content_width + ce.left + ce.right
			// A spanning cell's content has to fit the *sum* of the columns it covers, so
			// its requirement is shared out over them: each column carries an equal share
			// rather than the whole of it. That is an approximation -- CSS 2.1 leaves the
			// distribution to the implementation -- and it is the one that keeps a wide
			// header from being squeezed into its first column while its later columns
			// stay empty.
			if g.colspan > 1 {
				mut k := 0
				for k < g.colspan && g.col + k < cols {
					share := w / g.colspan
					if share > maxc[g.col + k] {
						maxc[g.col + k] = share
					}
					share_min := n / g.colspan
					if share_min > minc[g.col + k] {
						minc[g.col + k] = share_min
					}
					k++
				}
			} else {
				if w > maxc[g.col] {
					maxc[g.col] = w
				}
				if n > minc[g.col] {
					minc[g.col] = n
				}
			}
			// A rowspan cell is as tall as the rows it covers together, so its height is
			// shared out over them for the same reason.
			h := cell.rect.height + ce.top + ce.bottom
			mut k := 0
			for k < g.rowspan && ri + k < rows.len {
				share := h / g.rowspan
				if share > row_h[ri + k] {
					row_h[ri + k] = share
				}
				k++
			}
		}
	}
	// The table's own intrinsic widths are the columns' sums, which is the second
	// reason Phase 2 measures them: a table inside a shrink-to-fit context is sized by
	// its columns, not by its widest child.
	b.max_content_width = 0
	b.min_content_width = 0
	for ci in 0 .. cols {
		b.max_content_width += maxc[ci]
		b.min_content_width += minc[ci]
	}
	// Pass 2: size the columns against what the line has, then place every cell.
	//
	// The table's own width joins the sizing here, because a column grid that ignores
	// `width: 100%` leaves the right part of the table blank while its border still runs
	// to the full width -- which is what every stylesheet that sets a table width asks
	// for and not what it gets.
	mut widths := column_widths(minc, maxc, content_width, wanted_width(b.style, ctx, content_width))
	mut y := top
	for ri in 0 .. rows.len {
		mut cells := table_cells(rows[ri])
		// The row's height is measured *after* its cells are laid out at the widths their
		// columns came out as, and not from pass 1. A cell placed at a column narrower
		// than the line wraps its text to more lines and grows, so the height pass 1 read
		// at the full line width was too small -- and the row after it then overlapped
		// it, which is what a table whose next block sits on top of its last row looks
		// like when it goes wrong.
		mut rh := 0
		for ci in 0 .. cells.len {
			g := grid[ri][ci]
			mut cell := cells[ci]
			cctx := l.context(cell.font_size)
			ce := edges_of(cell.style.margin, &cctx, f64(content_width))
			want := columns_width(widths, g.col, g.colspan)
			// The cell takes the width of the columns it covers, whatever its own content
			// wanted. `box_width` would clamp an `auto` width down to the cell's
			// max-content, which is right for a block and wrong for a cell: a spanning
			// header would come out the width of its own text and leave the columns beside
			// it empty. Setting the width explicitly is what bypasses that clamp, and the
			// frame is taken off because `place` reads a specified width as the content box.
			cp := edges_of(cell.style.padding, &cctx, f64(content_width))
			frame := cell.border_px[1] + cell.border_px[3] + cp.left + cp.right
			cell.style.width = style.Length{ unit: .px, value: f64(want - frame) }
			cx := content_x + column_offset(widths, g.col) + ce.left
			cy := y + ce.top
			mut cf := []&Box{}
			l.place(mut cell, want, cx, cy, false, cell_cb, mut cf)
			h := cell.rect.height + ce.top + ce.bottom
			if h > rh {
				rh = h
			}
		}
		// A cell's height is the row's, not its own content's, so a short cell in a tall
		// row still paints its background down the whole row. A rowspan cell keeps the
		// height it laid out at, because it is already as tall as the rows it covers.
		for ci in 0 .. cells.len {
			g := grid[ri][ci]
			if g.rowspan > 1 {
				continue
			}
			mut cell := cells[ci]
			cctx := l.context(cell.font_size)
			ce := edges_of(cell.style.margin, &cctx, f64(content_width))
			tall := rh - ce.top - ce.bottom
			if cell.rect.height < tall {
				cell.rect.height = tall
			}
		}
		y += rh
	}
	return y - content_y
}

// CellSpan is one cell's position in the table's grid: the column it starts in and how
// many columns it covers from there, and the same for rows.
struct CellSpan {
mut:
	col     int
	colspan int
	rowspan int
}

// table_grid works out which column of the table each cell starts in, which is not its
// index in the row: a cell with `colspan="2"` takes two columns, so the cells after it
// start two further right. The grid is filled left to right and top to bottom, skipping
// the columns an earlier row's `rowspan` has already taken.
//
// This is the only place spans are read, and it reads them off the element's own
// attributes: `colspan` and `rowspan` are presentational HTML attributes, not CSS
// properties, so they never reach the cascade.
fn table_grid(rows []&Box) [][]CellSpan {
	mut out := [][]CellSpan{}
	mut taken := map[string]bool{}
	for ri in 0 .. rows.len {
		mut cells := table_cells(rows[ri])
		mut line := []CellSpan{}
		mut col := 0
		for ci in 0 .. cells.len {
			// Step over any column a cell in an earlier row still occupies.
			for '${ri},${col}' in taken {
				col++
			}
			sp_col, sp_row := cell_span(cells[ci])
			line << CellSpan{ col: col, colspan: sp_col, rowspan: sp_row }
			// Mark the columns and rows this cell covers, so the cells below start to
			// the right of it.
			mut r := 0
			for r < sp_row {
				mut c := 0
				for c < sp_col {
					taken['${ri + r},${col + c}'] = true
					c++
				}
				r++
			}
			col += sp_col
		}
		out << line
	}
	return out
}

// cell_span reads the spanning attributes off a cell, defaulting to one in each axis --
// which is what a cell without the attributes is.
fn cell_span(c &Box) (int, int) {
	mut cs := 1
	mut rs := 1
	if c.element == unsafe { nil } {
		return cs, rs
	}
	if v := c.element.attributes['colspan'] {
		if v.len > 0 {
			n := v.int()
			if n > 0 {
				cs = n
			}
		}
	}
	if v := c.element.attributes['rowspan'] {
		if v.len > 0 {
			n := v.int()
			if n > 0 {
				rs = n
			}
		}
	}
	if cs < 1 {
		cs = 1
	}
	if rs < 1 {
		rs = 1
	}
	if rs > 1000 {
		// A `rowspan` of 0 means "take the rest of the table" in HTML, which this engine
		// does not implement; treating it as one rather than as an unbounded span is the
		// safe reading, and it is recorded in PHASES.md.
		rs = 1
	}
	return cs, rs
}

// column_offset is the distance from the table's left edge to the start of column `col`.
fn column_offset(widths []int, col int) int {
	mut x := 0
	mut i := 0
	for i < col && i < widths.len {
		x += widths[i]
		i++
	}
	return x
}

// columns_width is the total width of `span` columns from `col`, which is what a
// spanning cell is laid out at.
fn columns_width(widths []int, col int, span int) int {
	mut w := 0
	mut i := col
	for i < col + span && i < widths.len {
		w += widths[i]
		i++
	}
	return w
}

// wanted_width is the width the table's own `width` asked for, capped at what the line
// has, or 0 when it asked for `auto` -- which is "the columns' content", not a width.
fn wanted_width(s style.Style, ctx &style.Context, available int) int {
	if s.width.unit == .auto || s.width.unit == .none {
		return 0
	}
	w := px(resolve(s.width, ctx, f64(available)))
	if w > available {
		return available
	}
	if w < 0 {
		return 0
	}
	return w
}

// column_widths is CSS 2.1 17.5.2's second pass for this engine.
//
// CSS 2.1 leaves the distribution of a table's width among its columns to the
// implementation, so this engine's rule is written down rather than borrowed:
//
//   - the columns take their max-content while that fits the width available;
//   - a table that asked for a width of its own (`width: 100%`, or a length) gets it:
//     the surplus over the columns' content is shared out in proportion to their
//     max-content, which is what makes a full-width table fill the page instead of
//     running its border past a blank strip on the right;
//   - when the content does not fit, the space comes off the columns that *have* slack
//     -- the difference between their max-content and their min-content -- before it
//     comes off the min-content itself, because a column narrower than its narrowest
//     word breaks that word out of its cell;
//   - and a column reduced to its min-content is reduced further rather than letting
//     the table overflow its containing block, because a table wider than its parent
//     is exactly the failure the Phase 3 gate exists to catch.
//
// The loop is bounded by the slack rather than by a counter: it stops when no column
// has any left, which is what makes it terminate for any input.
fn column_widths(minc []int, maxc []int, available int, wanted int) []int {
	mut w := maxc.clone()
	mut have := 0
	for x in w {
		have += x
	}
	// Surplus: the table asked for a width wider than its columns' content, so the
	// extra is shared out rather than left blank.
	if wanted > have {
		mut extra := wanted - have
		for extra > 0 {
			mut before := 0
			for x in w {
				before += x
			}
			for i in 0 .. w.len {
				mut take := w[i] * extra / max_of(have, 1)
				if take > extra {
					take = extra
				}
				w[i] += take
				extra -= take
			}
			// Rounding gave nothing out this round, so give the last pixels to the
			// widest column: progress beats symmetry for the last few.
			mut after := 0
			for x in w {
				after += x
			}
			if after == before {
				mut widest := 0
				for i in 0 .. w.len {
					if w[i] > w[widest] {
						widest = i
					}
				}
				w[widest] += extra
				extra = 0
			}
		}
		return w
	}
	mut need := have - available
	if need <= 0 {
		return w
	}
	for need > 0 {
		mut slack := 0
		for i in 0 .. w.len {
			if w[i] > minc[i] {
				slack += w[i] - minc[i]
			}
		}
		if slack == 0 {
			break
		}
		mut before := 0
		for x in w {
			before += x
		}
		for i in 0 .. w.len {
			if w[i] <= minc[i] {
				continue
			}
			d := w[i] - minc[i]
			mut take := d * need / slack
			if take > d {
				take = d
			}
			// A column with all the slack still has to give some of it up, or the loop
			// spins on a rounding that takes nothing.
			if take < d && d * need > slack * d {
				take = d
			}
			w[i] -= take
		}
		mut after := 0
		for x in w {
			after += x
		}
		if after >= before {
			// Rounding took nothing this round, so take whatever is still needed from
			// the widest column: progress beats symmetry for the last pixel.
			mut widest := 0
			for i in 0 .. w.len {
				if w[i] > w[widest] {
					widest = i
				}
			}
			if w[widest] > 0 {
				take := if need > w[widest] { w[widest] } else { need }
				w[widest] -= take
			}
		}
	}
	return w
}

// place_root lays out a box that starts a block formatting context of its own, which
// is what an atomic inline-level box is (CSS 2.1 9.4.1). The floats generated inside it
// do not reach the lines outside it, and the floats outside it do not shorten the lines
// inside it, so the empty list handed to `place` is that boundary made concrete.
//
// Without it a float inside an inline-block would shorten the paragraph around it, and
// a line inside an inline-block would wrap around a float in the paragraph that holds
// it -- neither of which is true, and both of which look like a bug in the float.
fn (mut l Layouter) place_root(mut b &Box, containing_width int, x int, y int, cb ContBlock) {
	mut inner := []&Box{}
	l.place(mut b, containing_width, x, y, false, cb, mut inner)
}

// place_float lays out one floated box and records it in `floats`.
//
// CSS 2.1 9.5.1 positions a float against the outer edge of its own side, either to the
// right of every earlier float on that side or below it. How much of the line is left
// depends on where the earlier floats are, and the float's own height is not known until
// it has been laid out, so this is a bounded iteration: at each attempt the gap is
// measured at the candidate top, the float is laid out in that gap, and if the result
// either does not fit in the gap or overlaps an earlier float, the candidate top drops
// below the float in the way and the gap is measured again.
//
// The height that is measured against at each attempt is one pixel -- see
// `placement_gap` -- because the floats that can block the new one are exactly the ones
// covering its top edge.
fn (mut l Layouter) place_float(mut f &Box, containing_width int, x int, y int, cb ContBlock, mut floats []&Box) {
	right_side := f.style.float == .right
	ctx := l.context(f.font_size)
	fm := edges_of(f.style.margin, &ctx, f64(containing_width))
	mut top := y
	// Every failed attempt drops the float below at least one earlier float, so
	// `floats.len + 1` attempts settle any cascade of them. The bound is derived from
	// what can happen rather than being a number chosen to look safe: a fixed ceiling
	// would be a guess about how many floats a page can have.
	for _ in 0 .. floats.len + 1 {
		// `containing_width` is the content box's width, and the gap it takes is the
		// interval from `x` to the right edge of that box.
		gap := placement_gap(floats, top, x, x + containing_width)
		mut space := gap.span() - fm.left - fm.right
		if space < 0 {
			space = 0
		}
		// Laid out through `place_atomic` because `width: auto` on a float is
		// shrink-to-fit (CSS 2.1 10.3.8) and not the fill the same `auto` gives a block:
		// a pull-quote box has to hug its text. The first call is at the gap's left edge,
		// because that is where the width is decided, and a right float is then placed at
		// its own edge -- the gap's right edge less the width it turned out to need -- with
		// a second call, because its own content has to be laid out where it will be
		// drawn and not where it was measured.
		l.place_atomic(mut f, space, gap.left, top, cb)
		mut fx := gap.left
		if right_side {
			// `place` offsets the border box by the box's own left margin, so the x it is
			// given is the *margin box's* left edge.
			fx = gap.right - f.rect.width - fm.left - fm.right
		}
		if fx != gap.left {
			l.place_atomic(mut f, space, fx, top, cb)
		}
		// The two things that make a position wrong: not fitting in the gap, and
		// overlapping an earlier float. Both are checked on the margin box against the
		// gap's span, because that is what the line beside it has to give up.
		if fm.left + f.rect.width + fm.right <= gap.span() && !float_conflicts(floats, f.rect) {
			record_float(mut floats, mut f, fm)
			return
		}
		top = drop_below(floats, top, right_side)
	}
	// The bound. Nothing settled, so the float keeps the last position it was laid out
	// at and is still recorded: a line after it shortens around it rather than running
	// under it, and that is the smaller of the two errors available here.
	record_float(mut floats, mut f, fm)
}

// record_float writes the margin box a float keeps, and adds it to the flow's list.
fn record_float(mut floats []&Box, mut f &Box, fm Px4) {
	f.float_margin = Rect{
		x:      f.rect.x - fm.left
		y:      f.rect.y - fm.top
		width:  f.rect.width + fm.left + fm.right
		height: f.rect.height + fm.top + fm.bottom
	}
	floats << f
}

// clear_push is how much further a box must move down for its border box top to be
// below the bottom of every earlier float on the sides `clear` names.
//
// It is measured from the position the box has already reached -- margins and collapsing
// included -- and not as an offset from the float's own top, which is why a box below a
// taller float is pushed by the difference and not by the float's whole height. What is
// not here is CSS 2.1 9.5.2's rule that a clearance can be negative and pull a box up:
// nothing in this layout produces one, and a negative clamp would be a guess about a
// case that cannot happen yet.
fn clear_push(floats []&Box, clear style.Clear, at int) int {
	if clear == .none {
		return 0
	}
	mut limit := at
	for f in floats {
		// `clear` is named for the side the float is on, not for the side the box moves
		// to: a float on the right pushes a box down and it is still laid out on the
		// left, so `clear: left` does not see it.
		if clear == .left && f.style.float != .left {
			continue
		}
		if clear == .right && f.style.float != .right {
			continue
		}
		bottom := f.rect.y + f.rect.height
		if bottom > limit {
			limit = bottom
		}
	}
	if limit <= at {
		return 0
	}
	return limit - at
}

// drop_below is the next top position to try: the bottom of the earliest float on
// `right_side`'s own side that covers `top`. It is that side and not any float, because
// a float on the opposite side only narrows the line from the other end and can still
// leave room beside it.
fn drop_below(floats []&Box, top int, right_side bool) int {
	mut to := top
	for f in floats {
		// A float on the opposite side only narrows the line from the other end and can
		// still leave room beside it, so it is not what a float on this side drops below.
		if (f.style.float == .left) == right_side {
			continue
		}
		if f.rect.y > top || f.rect.y + f.rect.height <= top {
			continue
		}
		if f.rect.y + f.rect.height > to {
			to = f.rect.y + f.rect.height
		}
	}
	return to
}

// float_conflicts reports whether `r` overlaps a float already laid out. CSS 2.1 9.5.1
// rule 2 forbids a floating box overlapping an earlier float in the same flow, on either
// side: a float that overlaps one is moved, never stacked on it.
fn float_conflicts(floats []&Box, r Rect) bool {
	for f in floats {
		if overlaps(r, f.rect) {
			return true
		}
	}
	return false
}

fn overlaps(a Rect, b Rect) bool {
	return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height
		&& b.y < a.y + a.height
}

// LineGap is the interval of a line that no earlier float covers, in absolute
// coordinates. CSS 2.1 9.5's "a line box beside a floating box is shortened to avoid it"
// is arithmetic once the floats have rectangles: the line fills what is left between the
// nearest float on each side, and a line with no float over it takes the whole width.
struct LineGap {
pub mut:
	left  int
	right int
}

fn (g LineGap) span() int {
	w := g.right - g.left
	if w < 0 {
		return 0
	}
	return w
}

// line_gap returns the interval of the line that starts at `top` and is `height` tall,
// with every float overlapping that vertical range pushed out of it.
//
// What is pushed out is the float's *margin* box, not its border box: a floated box with
// `margin-right: 8px` keeps that 8px, and a line beside it starts 8px to the right of the
// box's right edge rather than touching it. CSS 2.1 9.5 says the margin box, and a page
// that puts a margin on a floated image is an ordinary page.
//
// A float that ends exactly at the top of the line is not in the way, and one that
// starts exactly at its bottom is not either: the comparison is half-open, so a float
// adjacent to a line shares an edge with it rather than shortening it.
fn line_gap(floats []&Box, top int, height int, left int, right int) LineGap {
	mut g := LineGap{
		left:  left
		right: right
	}
	for f in floats {
		// `float_margin` is what the float keeps, and it is set by `place_float` before
		// the box is recorded -- so it is always the margin box of a laid-out float and
		// never the zero value of an unpositioned one.
		fr := f.float_margin
		if fr.y >= top + height || fr.y + fr.height <= top {
			continue
		}
		if f.style.float == .left {
			if fr.x + fr.width > g.left {
				g.left = fr.x + fr.width
			}
		} else {
			if fr.x < g.right {
				g.right = fr.x
			}
		}
	}
	return g
}

// placement_gap is the gap measured for a float about to be positioned, and the one
// pixel of line height is the whole trick. A float belongs to a line when the two
// overlap, and the float's own height is not known before it is laid out -- so the
// question asked here is "which floats cover this top edge", which is the question that
// needs answering: floats are laid out in source order and the vertical cursor only
// moves down, so every earlier float that could overlap the new one also covers its top
// edge.
fn placement_gap(floats []&Box, top int, left int, right int) LineGap {
	return line_gap(floats, top, 1, left, right)
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

fn min_of(a int, b int) int {
	return if a < b {
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
//
// Out-of-flow boxes are in `children`, in document order, so this walk is unchanged and
// a tool printing the tree reads an absolutely positioned box where the document put it.
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
	// width is the line's advance: how far the pen travelled putting it down. Alignment
	// is what will want it -- a right-to-left line reports the width it drew, not the
	// width of the box it was drawn in, so `text-align` can have a number to place.
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
	// is_box marks an atomic inline-level box rather than a stretch of text. Such an
	// atom is never broken and carries the box it stands for, so the shaper can place
	// it and the line breaker can treat it as one unbreakable unit.
	is_box bool
	box    &Box = unsafe { nil }
}

// Segment is one stretch of a line that is shaped in a single call: consecutive atoms
// of one run, or one atomic box, together with the width it is placed by.
//
// A line's segments are collected before any of them is placed, where the code used to
// shape as it walked, because a right-to-left line starts its pen at the right edge and
// so needs every segment's width before it can put the first one down.
struct Segment {
	is_box bool
	text   string
	style  text.FontStyle
	width  f64
	box    &Box = unsafe { nil }
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
	content_width int, floats []&Box) []LaidLine {
	// Right to left comes from the box's computed `direction`, which CSS inherits, so an
	// ancestor's `direction: rtl` reaches the text inside it.
	//
	// There is no bidi algorithm here and this is not where one would go: a line is laid
	// out in one direction, its box's, and reordering the runs *inside* a line -- a Latin
	// word in a Persian sentence -- is the work Phase 3 inherits. A mixed line is drawn in
	// the box's direction with each run's own order, which is what the bridge already
	// shapes.
	rtl := b.style.direction == .rtl

	// Atoms first, across every run, so a break can land on a run boundary as easily as on
	// a space inside one.
	mut atoms := []Atom{}
	mut ri := 0
	for item in b.inline_items {
		if item.is_box && item.box != nil {
			atoms << Atom{
				run:    -1
				width:  f64(item.box.rect.width)
				is_box: true
				box:    item.box
			}
			continue
		}
		run_style := font_style_of(item.style, item.font_size, ctx)
		for tok in tokenize_inline(item.text, b.style.white_space) {
			atoms << Atom{
				run:     ri
				content: tok
				width:   l.fonts.advance(&run_style, tok)
				space:   tok.len > 0 && (tok[0] == ` ` || tok[0] == `\t` || tok[0] == `\n`)
			}
		}
		ri++
	}
	if atoms.len == 0 {
		return []LaidLine{}
	}

	// Intrinsic widths, measured before anything breaks a line, because after breaking they
	// cannot be recovered: `lines` has already folded the atoms into the widths it needed.
	//
	// Max-content is every atom on one line. Min-content is the widest single unbreakable
	// word, because a line may break between words but never inside one -- so that word is
	// the narrowest a line can be without the text overflowing it. Spaces are excluded,
	// since a trailing space is dropped rather than allowed to set the minimum.
	mut mx := 0.0
	mut mn := 0.0
	for a in atoms {
		w := intrinsic_atom_width(a)
		mx += w
		if !a.space && w > mn {
			mn = w
		}
	}
	// Rounded *up*, not to nearest. These are upper bounds on what the content needs, and
	// rounding a sum of advances down loses up to half a pixel -- which is enough to make a
	// container one pixel narrower than the content it was measured to fit, and so to break a
	// line that should have stayed whole.
	b.max_content_width = int(math.ceil(mx))
	b.min_content_width = int(math.ceil(mn))

	// Greedy fill and shaping in one pass, where they used to be two passes over the same
	// atoms. They cannot be separate any more: the width a line may fill is not a
	// constant now that a line beside a float is shortened by it, so which atoms belong
	// to a line depends on the line's own y -- and a line's y is only known after the
	// lines above it have been shaped and reported their heights.
	//
	// The height the gap is measured against is the box's own line height, which is the
	// height every line has while all its runs are at the box's own size. A line
	// carrying a larger run is taller than that and could overlap a float it was not
	// measured against; the alternative is to shape the line, measure it and shape it
	// again, which is more machinery than that case is worth.
	own_style := font_style_of(b.style, b.font_size, ctx)
	own_line := px(l.fonts.line_metrics(&own_style).line_height)
	mut cur := []Atom{}
	mut w := 0.0
	mut line_top := content_y
	mut gap := line_gap(floats, line_top, own_line, content_x, content_width)
	mut out := []LaidLine{}
	for a in atoms {
		if a.space && cur.len == 0 {
			continue
		}
		// A space never starts a line and never causes one, so the break is taken before
		// the word that would not fit rather than after the space before it.
		if !a.space && cur.len > 0 && w + a.width > wrap_width(b.style.white_space, gap.span()) {
			line, next_top := l.shape_line(mut b, ctx, cur, gap, line_top, rtl)
			out << line
			line_top = next_top
			gap = line_gap(floats, line_top, own_line, content_x, content_width)
			cur = []
			w = 0.0
		}
		cur << a
		w += a.width
	}
	if cur.len > 0 {
		line, _ := l.shape_line(mut b, ctx, cur, gap, line_top, rtl)
		out << line
	}
	return out
}

// shape_line shapes the atoms of one line, and returns the line together with the y the
// next line starts at -- which is what the break loop needs to know before it can ask
// which floats the next line has to avoid.
//
// `gap` is the interval of the line no float covers. The pen starts at its left edge in
// both directions, and a right-to-left line is anchored at its right edge, which is what
// makes the shortening mirror: a Persian line beside a left float starts at that float's
// left edge rather than at the block's.
fn (mut l Layouter) shape_line(mut b &Box, ctx &style.Context, line_atoms []Atom, gap LineGap,
	y int, rtl bool) (LaidLine, int) {
	// Half-leading, CSS 2.1 10.8.1: each item's leading is split half above and half below
	// its own text, so a line box is as tall as the tallest item on it plus that item's
	// half-leading.
	// Iterating the atoms on this line directly, rather than every run in the box, is
	// what keeps a 28px run on the second line from inflating the first.
	mut above := 0.0
	mut below := 0.0
	for a in line_atoms {
		if a.is_box {
			// An atomic box sits on the baseline: its bottom margin edge is the line's
			// baseline, which is `vertical-align: baseline` for inline-block. So its
			// whole height is above the baseline and none of it below.
			above = fmax(above, f64(a.box.rect.height))
			continue
		}
		rs := font_style_of(b.runs[a.run].style, b.runs[a.run].font_size, ctx)
		m := l.fonts.line_metrics(&rs)
		half := (m.line_height - (m.ascent + m.descent)) / 2.0
		above = fmax(above, m.ascent + half)
		below = fmax(below, m.descent + half)
	}
	line_height := px(above + below)
	baseline := f64(y) + above
	// The line's segments, in source order. Consecutive atoms of one run are joined
	// into a single segment, so a word spanning two atoms still joins and shapes as a
	// word. They are collected before any of them is placed because a right-to-left
	// line has to know the width of every segment before it can put the first one
	// down: its pen starts at the right edge, not the left.
	mut segs := []Segment{}
	mut i := 0
	for i < line_atoms.len {
		if line_atoms[i].is_box {
			segs << Segment{
				is_box: true
				width:  line_atoms[i].width
				box:    line_atoms[i].box
			}
			i++
			continue
		}
		mut j := i
		mut sb := strings.new_builder(32)
		for j < line_atoms.len && line_atoms[j].run == line_atoms[i].run {
			sb.write_string(line_atoms[j].content)
			j++
		}
		r := b.runs[line_atoms[i].run]
		run_style := font_style_of(r.style, r.font_size, ctx)
		// Read once: `Builder.str()` clears the builder, so a second call on the
		// same one answers with the empty string and the segment would be shaped as
		// nothing at all -- which is a line that silently loses its text.
		seg_str := sb.str()
		mut seg_w := 0.0
		for k in i .. j {
			seg_w += line_atoms[k].width
		}
		if rtl {
			// The atoms' widths are each word measured on its own, and Arabic joining
			// makes a word a different width when it is shaped with its neighbours than
			// when it is shaped alone. Both directions are measured: on the default face
			// the sentence these tests break into lines came to 150.09 by its atoms
			// where it drew 125.89, and 145.60 where it drew 143.36; on the face these
			// tests ask for, the two agree to the last decimal. Neither can be relied
			// on, so the segment is measured the way the shaper will draw it and the
			// line is anchored by that -- otherwise the ink ends short of the right edge
			// by exactly the difference the font happens to introduce.
			seg_w = l.fonts.advance(&run_style, seg_str)
		}
		segs << Segment{
			text:  seg_str
			style: run_style
			width: seg_w
		}
		i = j
	}
	// The pen. Left to right it starts at the left edge of the gap and walks right,
	// which is what it has always done. Right to left it starts one line width in from
	// the gap's right edge and the same segments are then walked left to right from
	// there, so the first thing written is the rightmost thing drawn, a line shorter
	// than its gap sits flush against that edge, and an atomic box is placed by the
	// same pen.
	mut pen := f64(gap.left)
	if rtl {
		mut total := 0.0
		for s in segs {
			total += s.width
		}
		pen = f64(gap.right) - total
	}
	origin := pen
	mut glyphs := []text.PositionedGlyph{}
	for s in segs {
		if s.is_box {
			mut bx := s.box
			bx.rect.x = int(pen)
			bx.rect.y = int(baseline) - bx.rect.height
			pen += s.width
			continue
		}
		st := s.style
		glyphs << l.fonts.shape(s.text, &st, pen, baseline)
		pen += s.width
	}
	return LaidLine{
		glyphs: glyphs
		width:  pen - origin
		height: line_height
	}, y + line_height
}

// intrinsic_atom_width is the width an atom contributes to its box's intrinsic
// widths, which is not the width it happened to be laid out at.
//
// An atomic box with a percentage width is the case that forced this to exist, and it
// is ARCHITECTURE.md section 5's case exactly. `place_atomic` probes a shrink-to-fit
// box at `unbreakable_width` so that the content's intrinsic widths are its own, so a
// `width: 50%` child inside it resolves against that probe and comes out at half of a
// million. Folding *that* into the parent's max-content made the parent's intrinsic
// width 250,000, the shrink-to-fit clamp `min(max(min-content, available), max-content)`
// then answered 250,000 instead of the 400 the line had, and a fourteen-pixel word
// rendered inside a box half a million pixels wide. Measured: 500,000 and 800,000 for
// 50% and 80% in a 400px viewport, where the correct answers are the content's own
// width.
//
// A percentage of a base that is itself being measured is not a width, so it cannot
// contribute one. CSS resolves this the same way -- percentages are treated as `auto`
// during intrinsic sizing -- so the box's own content width is the answer, and that is
// what this returns.
fn intrinsic_atom_width(a Atom) f64 {
	if a.is_box && a.box != nil && a.box.style.width.unit == .percent {
		return f64(a.box.max_content_width)
	}
	return a.width
}

// atomic_fit is the shrink-to-fit clamp of CSS 2.1 10.3.9: the box takes the preferred
// width, held between the preferred minimum and the space available. The intrinsic
// widths it reads carry the box's own frame, so the result is a border-box width.
fn atomic_fit(bx &Box, available int) int {
	return min_of(max_of(bx.min_content_width, available), bx.max_content_width)
}

// place_marker builds a list item's marker box (CSS 2.1 12.5), which is a box outside
// the principal one: to its left for `ltr`, to its right for `rtl`, and it does not take
// part in the line -- the UA sheet's `padding-left: 40px` on the list is what makes room
// for it, exactly as a browser's does.
//
// `content_y` is the item's own content top, which is the first line's: that is the
// vertical anchor a marker hangs from, so a one-line item and a four-line item put
// their marker in the same place relative to their own top edge.
//
// The marker is either text (`decimal`, the alphabets, the romans) or a shape (`disc`,
// `circle`, `square`). The text case is shaped here rather than in paint because shaping
// is a font question and this is the layer that owns the font library.
fn (mut l Layouter) place_marker(mut b &Box, ctx &style.Context, content_x int, content_width int, content_y int) {
	if b.style.display != .list_item || b.style.list_style_type == .none {
		return
	}
	fs := font_style_of(b.style, b.font_size, ctx)
	m := l.fonts.line_metrics(&fs)
	// The marker is sized off the item's own font, so a 28px item gets a marker a
	// reader can see next to it rather than one drawn for a 16px default.
	mut size := int(b.font_size / 2)
	if size < 4 {
		size = 4
	}
	baseline := int(f64(content_y) + m.ascent)
	mp_style := b.style.list_style_type
	if mp_style == .disc || mp_style == .square {
		// A shape marker: recorded on the box for paint to fill, because which shape it
		// is a paint question and the geometry is box arithmetic.
		w := size
		b.marker_kind = mp_style
		top := baseline - w / 2
		if b.style.direction == .rtl {
			b.marker_rect = Rect{ x: content_x + content_width, y: top, width: w, height: w }
		} else {
			b.marker_rect = Rect{ x: content_x - size - 8, y: top, width: w, height: w }
		}
		return
	}
	label := marker_text(mp_style, b.list_index)
	if label == '' {
		return
	}
	mut glyphs := l.fonts.shape(label, &fs, 0, f64(baseline))
	// Shifted by the marker's own width so the text ends where the marker box starts: a
	// right-aligned marker, which is what "3." next to a paragraph looks like. The width
	// comes from `advance`, because a positioned glyph carries its pen start and its
	// sub-pixel offset but not how far it runs -- summing `sub_x` gives a number near
	// zero, which left the marker's "1." overlapping the word beside it.
	adv := l.fonts.advance(&fs, label)
	origin := if b.style.direction == .rtl {
		f64(content_x + content_width)
	} else {
		f64(content_x) - adv - 8
	}
	mut out := []text.PositionedGlyph{}
	for g in glyphs {
		out << text.PositionedGlyph{
			x:       g.x + origin
			y:       g.y
			font_id: g.font_id
			gid:     g.gid
			size:    g.size
			sub_x:   g.sub_x
			sub_y:   g.sub_y
			cluster: g.cluster
			bitmap:  g.bitmap
		}
	}
	b.marker_glyphs = out
}

// marker_text is what a list marker *says*: the numbering for the ordered types, and
// nothing for the shapeless ones. The position argument is the item's index among its
// siblings, which `place` counted.
fn marker_text(kind style.ListStyleType, index int) string {
	match kind {
		.decimal { return index.str() + '.' }
		.decimal_leading_zero {
			if index < 10 {
				return '0' + index.str() + '.'
			}
			return index.str() + '.'
		}
		.lower_alpha, .upper_alpha {
			mut n := index
			mut letters := []u8{}
			for n > 0 {
				mut r := (n - 1) % 26
				n = (n - 1) / 26
				// 97 is `a`.
				letters << u8(97 + r)
			}
			mut out := ''
			for i := letters.len - 1; i >= 0; i-- {
				out += letters[i].ascii_str()
			}
			if kind == .upper_alpha {
				return out.to_upper() + '.'
			}
			return out + '.'
		}
		.lower_roman, .upper_roman {
			mut out := roman(index)
			if out == '' {
				return ''
			}
			if kind == .upper_roman {
				return out.to_upper() + '.'
			}
			return out + '.'
		}
		else { return '' }
	}
}

// roman is the Roman numeral for a positive number, lowercase, and the empty string for
// anything else. It is the one numbering scheme with more than a digit per value, so it
// is a table of values and names rather than arithmetic.
fn roman(n int) string {
	if n <= 0 || n > 3999 {
		return ''
	}
	values := [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
	names := ['m', 'cm', 'd', 'cd', 'c', 'xc', 'l', 'xl', 'x', 'ix', 'v', 'iv', 'i']
	mut left := n
	mut out := ''
	for i in 0 .. values.len {
		for left >= values[i] {
			out += names[i]
			left -= values[i]
		}
	}
	return out
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
	// `runes()`, not the string itself: `for c in content` walks the *bytes*, and a
	// Persian character is two of them. `rune(c).str()` on a byte turns that byte into the
	// Latin-1 character of the same value, so "سلام" tokenized to "Ø³Ù„Ø§Ù…" -- six Latin
	// characters -- which then measured, shaped and drew as Latin-1. The cast in the
	// comment below was written to stop 'a' becoming "97" and it does that; what it also
	// did, for every non-ASCII character on the page, was replace the letter with two
	// pieces of another alphabet.
	for c in content.runes() {
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
		// `c.str()` on a `rune` is the character. On a `u8` it would be the *number*: 'a'
		// becomes "97" and 'b' becomes "98", so "ab" tokenized to "9798" and a whole page
		// rendered as its own ASCII codes.
		cur += c.str()
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
