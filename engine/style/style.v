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
	font_size        Length
	font_family      string
	font_weight      FontWeight
	font_style       FontStyle
	line_height      Length
	text_align       TextAlign
	text_decoration  TextDecoration
	white_space      WhiteSpace
	direction        Direction
	margin           Edges
	padding          Edges
	border_width     Edges
	border_color     [4]raster.Color
	border_style     [4]BorderStyle
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
		.inline, .none { false }
		else { true }
	}
}

pub fn (d Display) is_inline() bool {
	return match d {
		.inline { true }
		else { false }
	}
}
