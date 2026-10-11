module style

import engine.raster

// The computed style of one box.
//
// A struct with a field per property, not a map from name to value. Two reasons,
// and both of them show up as bugs avoided rather than as elegance.
//
// A map would make a typo in a property name a runtime miss instead of a compile
// error, and CSS has a hundred and fifty properties whose names differ by one
// character -- `font-weight` and `font-weight` being the kind of difference that a
// map turns into a silently dropped declaration. And a map would make the question
// "which properties are inherited" answerable only by consulting the inheritance
// table at runtime, which is where a missing entry becomes a page that renders.
//
// Inheritance is therefore a method that says what it does, and a test asserts the
// whole table at once.
//
// This is the initial value plus everything the cascade can set. It is not every
// property in CSS: PHASES.md adds them as the phases that need them arrive, so that
// nothing here is a promise about behaviour that does not exist yet.

pub struct Style {
pub mut:
	display          Display
	color            raster.Color
	background_color raster.Color
	// background_image is a *reference* to an image, not the image. ARCHITECTURE.md 1
	// keeps the engine free of I/O, so the cascade records the URL as the stylesheet
	// wrote it and the caller that owns the loader fetches and decodes it; paint is
	// handed a map of URL to bitmap and looks the reference up here. An empty
	// string is `background-image: none`.
	background_image    string
	background_repeat   BackgroundRepeat
	background_position BackgroundPosition
	background_size     BackgroundSize
	font_size           Length
	font_family         string
	font_weight         FontWeight
	font_style          FontStyle
	line_height         Length
	text_align          TextAlign
	text_decoration     TextDecoration
	white_space         WhiteSpace
	direction           Direction
	margin              Edges
	padding             Edges
	border_width        Edges
	border_color        [4]raster.Color
	border_style        [4]BorderStyle
	// border_radius is the four corner radii, horizontal and vertical, in CSS's
	// clockwise order from the top-left. The two arrays are the values before and
	// after a `/`: `border-radius: 10px / 20px` is a corner 10 wide and 20 tall,
	// and `border-radius: 50%` is an ellipse rather than a circle.
	border_radius Radii
	// overflow is what this box does with descendants that do not fit in it. It is
	// not inherited, so it stays at its initial value here.
	overflow Overflow
	// width and height are `auto` unless the cascade says otherwise. The distinction
	// is the whole of Phase 2: `auto` for a block means fill the containing block and
	// `0` means nothing.
	width  Length
	height Length
	// min_width and max_width exist now even though only Phase 2 reads them, because
	// they have to be *in* the struct for the cascade to store them, and adding a
	// field later means re-deciding where it goes.
	min_width  Length
	min_height Length
	max_width  Length
	max_height Length
	// Sizing model for width and height, and the one field in this struct that changes
	// how every other length in it is read rather than being a value in its own right.
	box_sizing          BoxSizing
	list_style_type     ListStyleType
	list_style_position ListStylePosition
	vertical_align      VerticalAlign
	text_transform      TextTransform
	opacity             f64
	visibility          Visibility
	// `float` and `clear` are the two halves of CSS 2.1 9.5, and both are initial
	// values rather than inherited ones: a floated element's children are laid out in
	// the normal flow, and an element that asks to clear the left does not clear it
	// for its descendants. A field that inherited would take out of flow every box
	// below the one that was floated.
	float Float
	clear Clear
	// `position` and `z_index` are the two halves of CSS 2.1 9.3, and like `float`
	// they are initial values: an absolutely positioned child of a relative parent is
	// positioned against *that* parent and not against the parent's own containing
	// block, which is what inheritance of `position` would have made it.
	position Position
	z_index  ZIndex
	// insets are `top`, `right`, `bottom` and `left`, in the same Edges shape as the
	// margin and the padding because they share the shorthand-less four-longhand
	// layout. Their initial value is `auto`, not zero, and that is the whole of the
	// static-position fallback in 10.3.7: `auto` says "this side does not name a
	// position", and zero says "this side names the edge of the containing block".
	insets Edges
}

// Position is which scheme a box is laid out in.
pub enum Position {
	static
	relative
	absolute
	fixed
	// `sticky` is deliberately absent. It is not in CSS 2.1, and accepting it as an
	// alias for `relative` would give a box a permanent offset that CSS says should
	// only apply while it is stuck -- so a page using it keeps the `static` initial
	// value and its content stays in the flow.
}

// ZIndex is `z-index: auto | <integer>`.
//
// `auto` is not zero and is kept apart from it. A positioned box with `z-index:
// auto` paints as step 6 of CSS 2.1 Appendix E.2, in the same group as `0` and in
// document order among it; folding it into 0 would make a box that was never given a
// z-index compete with the ones that were.
pub struct ZIndex {
pub mut:
	auto  bool
	value int
}

pub enum Display {
	block
	inline
	none
	// list_item is inline for Phase 1's purposes -- a bullet is not drawn yet -- but
	// it is not `block` either, because a `li` must still be laid out as a box.
	list_item
	inline_block
	// flow_root contains floats, which is Phase 3. It is accepted so a stylesheet
	// that uses it parses and lays out as a block, rather than dropping the rule.
	flow_root
}

pub enum FontWeight {
	normal
	bold
	bolder
	lighter
}

pub enum FontStyle {
	normal
	italic
	oblique
}

pub enum TextAlign {
	left
	right
	center
	justify
	start
	end
}

pub enum TextDecoration {
	none
	underline
	line_through
	overline
}

pub enum WhiteSpace {
	normal
	pre
	nowrap
	pre_wrap
	pre_line
}

pub enum Direction {
	ltr
	rtl
}

pub enum BorderStyle {
	none
	hidden
	solid
	dashed
	dotted
	double
	groove
	ridge
	inset
	outset
}

// Overflow is what a box does with content that does not fit inside it.
//
// The four clipping values are one behaviour at this stage of the engine: a
// scrollbar, a scrollable overflow region and a hard clip are all distinguished
// by machinery that does not exist yet, and the half that a rendered page shows
// is the same for all of them -- content outside the box is not painted.
pub enum Overflow {
	visible
	hidden
	scroll
	auto
	clip
}

// clips reports whether this value confines descendants to the box's padding box.
pub fn (o Overflow) clips() bool {
	return o != .visible
}

// Radii is `border-radius`: the four corners, each an ellipse.
//
// The index order is CSS's own clockwise order from the top-left, and `x` and `y`
// are the two axes of that corner. Both are Lengths rather than pixels because a
// percentage of `border-radius` is of the box's own dimensions, which is a fact
// about a box and so a question for the box to answer.
pub struct Radii {
pub mut:
	x [4]Length
	y [4]Length
}

// zero_radii is the initial value: no rounding, which is not the same as a radius
// of zero length -- a `border-radius: 0` is spelled that way and means the same
// thing, but the initial value has no length attached to it at all.
pub fn zero_radii() Radii {
	return Radii{}
}

pub enum ListStyleType {
	none
	disc
	circle
	square
	decimal
	decimal_leading_zero
	lower_alpha
	upper_alpha
	lower_roman
	upper_roman
}

pub enum ListStylePosition {
	inside
	outside
}

pub enum VerticalAlign {
	baseline
	top
	middle
	bottom
	sub
	super
	text_top
	text_bottom
}

pub enum TextTransform {
	none
	uppercase
	lowercase
	capitalize
}

pub enum Visibility {
	visible
	hidden
	collapse
}

// Float is which side, if any, a box is taken out of the flow and pushed against.
pub enum Float {
	left
	right
	none
}

// Clear is which sides' earlier floats a box must be pushed below.
pub enum Clear {
	left
	right
	both
	none
}

// Edges is the four sides of a box, in CSS order. An array rather than four named
// fields because every property that has four sides has the same shorthand syntax,
// and a named field per side would make the shorthand parser four times longer.
pub struct Edges {
pub mut:
	top    Length
	right  Length
	bottom Length
	left   Length
}

// initial is the computed style of the root element: everything at its initial
// value, with the two exceptions CSS defines -- the initial `color` is the UA's,
// and the initial `font-size` is `medium`, which is 16px.
pub fn initial() Style {
	return Style{
		display:             .inline
		color:               raster.black
		background_color:    raster.transparent
		background_image:    ''
		background_repeat:   .repeat
		background_position: initial_background_position()
		background_size:     initial_background_size()
		font_size:           Length{ value: 16.0, unit: .px }
		font_family:         'serif'
		font_weight:         .normal
		font_style:          .normal
		line_height:         Length{ value: 0.0, unit: .none }
		text_align:          .start
		text_decoration:     .none
		white_space:         .normal
		direction:           .ltr
		margin:              Edges{}
		padding:             Edges{}
		border_width:        Edges{}
		border_color:        [raster.black, raster.black, raster.black, raster.black]
		border_style:        [.none, .none, .none, .none]
		border_radius:       zero_radii()
		overflow:            .visible
		width:               Length{ unit: .auto }
		height:              Length{ unit: .auto }
		min_width:           Length{ unit: .auto }
		min_height:          Length{ unit: .auto }
		max_width:           Length{ unit: .none }
		max_height:          Length{ unit: .none }
		box_sizing:          .content_box
		list_style_type:     .disc
		list_style_position: .outside
		vertical_align:      .baseline
		text_transform:      .none
		opacity:             1.0
		visibility:          .visible
		float:               .none
		clear:               .none
		position:            .static
		z_index:             ZIndex{ auto: true }
		insets:              auto_edges()
	}
}

// auto_edges is the four `auto` lengths the insets start from. It cannot be `Edges{}`:
// the zero Length is `unit: .none`, which is "not a length", and an inset of `none`
// would read as no inset at all rather than as the side that does not name a position.
pub fn auto_edges() Edges {
	return Edges{
		top:    Length{ unit: .auto }
		right:  Length{ unit: .auto }
		bottom: Length{ unit: .auto }
		left:   Length{ unit: .auto }
	}
}

// inherit copies the inherited properties from parent into this style. It is called
// before the declarations are applied, so a declaration always beats what it
// inherited.
//
// The table is here, in one function, rather than in a list of names elsewhere: a
// missing entry is a property that silently does not inherit, which is exactly the
// bug a test that walks the whole table catches.
pub fn (mut s Style) inherit_from(parent &Style) {
	s.color = parent.color
	s.font_size = parent.font_size
	s.font_family = parent.font_family
	s.font_weight = parent.font_weight
	s.font_style = parent.font_style
	s.line_height = parent.line_height
	s.text_align = parent.text_align
	s.text_decoration = parent.text_decoration
	s.white_space = parent.white_space
	s.direction = parent.direction
	s.list_style_type = parent.list_style_type
	s.list_style_position = parent.list_style_position
	s.vertical_align = parent.vertical_align
	s.text_transform = parent.text_transform
	s.visibility = parent.visibility
	// `border-radius` and `overflow` are deliberately not here. CSS gives both
	// "Inherited: no", and the box-model half of it matters: a rounded, clipping
	// parent would make every block inside it rounded and clipping too, which is
	// what a page containing one `overflow: hidden` section would otherwise render
	// as. They stay at the initial value `initial()` gave them.
}

// inherited is the property-by-property answer to "what passes down the tree", for
// the test that checks the table above against it. It is a function rather than a
// const because the answer is a set of names and a set is not expressible as one
// without allocating on every call.
pub fn inherited_properties() []string {
	return ['color', 'font-size', 'font-family', 'font-weight', 'font-style', 'line-height',
		'text-align', 'text-decoration', 'white-space', 'direction', 'list-style-type',
		'list-style-position', 'vertical-align', 'text-transform', 'visibility']
}

// BoxSizing decides what `width` and `height` measure.
//
// `content_box` is the spec default and the one the whole engine was written against: the
// width is the content, and padding and border are added outside it. `border_box` is what
// `box-sizing: border-box` selects, where the width *includes* padding and border, so the
// content box is what is left after subtracting them.
//
// The two are not interchangeable and the difference is visible without measurement: a
// `width: 100px` div with 20px padding on each side is 140 wide under `content_box` and 100
// under `border-box`.
pub enum BoxSizing {
	content_box
	border_box
}

// is_block_level reports whether this display value gets a box of its own in the
// block layout. An inline element does not -- its content goes into the line box of
// its parent -- and that distinction is the one Phase 1's layout rests on.
//
// display:none is not block-level either, but for a different reason, and the two
// are not interchangeable: a display:none element is skipped, while an inline one is
// measured. Keeping them apart here means layout can ask both questions.
pub fn (d Display) is_block_level() bool {
	return match d {
		.inline, .inline_block, .none { false }
		else { true }
	}
}

pub fn (d Display) is_inline() bool {
	return match d {
		.inline { true }
		else { false }
	}
}
