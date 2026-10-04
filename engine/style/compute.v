module style

import engine.raster
import strconv
import strings

// Turning declaration text into typed values.
//
// Every parser here returns an Option rather than a default. CSS says an invalid
// value makes the declaration compute to the property's inherited or initial value,
// and returning a default would silently *apply* something instead -- a bad colour
// becoming black is a page that renders wrong, while dropping it is a page that
// renders as the author intended minus one mistake.
//
// The values are split into components here, not into strings. `margin: 1px 2px`
// becomes four Lengths at this point rather than staying text until layout, because
// every consumer would otherwise re-parse the same text.

// is_bare_number reports whether a value is a number with no unit at all. Every
// character has to be part of the number: checking only the first is what made
// `150%` look like a bare number and turn `line-height: 150%` into a parse failure.
fn is_bare_number(text string) bool {
	if text == '' {
		return false
	}
	for c in text.bytes() {
		is_digit := c >= 0x30 && c <= 0x39
		is_sign := c == 0x2b || c == 0x2d
		is_number_part := c == 0x2e || c == 0x65 || c == 0x45
		if !(is_digit || is_sign || is_number_part) {
			return false
		}
	}
	return true
}

fn parse_number(text string) ?f64 {
	v := strconv.atof64(text.trim_space()) or { return none }
	return v
}

fn parse_display(text string) ?Display {
	return match text.trim_space().to_lower() {
		'block' { Display.block }
		'inline' { Display.inline }
		'none' { Display.none }
		'list-item' { Display.list_item }
		'inline-block' { Display.inline_block }
		'flow-root' { Display.flow_root }
		// `flex` and `grid` are Phase 4 and 5. Treating them as block means a
		// stylesheet written for them lays out as something reasonable instead of
		// dropping the rule and leaving the element unstyled.
		'flex', 'inline-flex', 'grid', 'inline-grid' { Display.block }
		else { return none }
	}
}

fn parse_font_weight(text string) ?FontWeight {
	t := text.trim_space().to_lower()
	return match t {
		'normal', '400' { FontWeight.normal }
		'bold', '700' { FontWeight.bold }
		'bolder' { FontWeight.bolder }
		'lighter' { FontWeight.lighter }
		else {
			// A number outside the named range is a numeric weight. CSS allows any
			// number, and the text layer will interpolate or pick the nearest face.
			n := strconv.atoi(t) or { return none }
			if n < 1 || n > 1000 {
				return none
			}
			if n >= 600 {
				return FontWeight.bold
			}
			FontWeight.normal
		}
	}
}

fn parse_font_style(text string) ?FontStyle {
	return match text.trim_space().to_lower() {
		'normal' { FontStyle.normal }
		'italic' { FontStyle.italic }
		'oblique' { FontStyle.oblique }
		else { return none }
	}
}

// parse_text_decoration reads the shorthand, which is a list of keywords. An
// unknown keyword makes the whole declaration invalid, so the value is rejected
// rather than partly applied.
fn parse_text_decoration(text string) ?TextDecoration {
	mut found := TextDecoration.none
	mut any := false
	for word in split_words(text) {
		match word {
			'none' { found = .none }
			'underline' { found = .underline }
			'line-through' { found = .line_through }
			'overline' { found = .overline }
			// `underline dotted red` is decoration style and colour, which paint
			// does not draw yet. Accepting and ignoring the extras keeps the
			// underline itself, which is the part that shows.
			else {
				if !is_decoration_modifier(word) {
					return none
				}
				continue
			}
		}
		any = true
	}
	if !any {
		return none
	}
	return found
}

fn is_decoration_modifier(word string) bool {
	return match word {
		'solid', 'double', 'dotted', 'dashed', 'wavy' { true }
		else {
			// A colour or a length, e.g. `underline 1px dotted red`.
			parse_color(word) != none || parse_length(word) != none
		}
	}
}

fn parse_text_align(text string) ?TextAlign {
	return match text.trim_space().to_lower() {
		'left' { TextAlign.left }
		'right' { TextAlign.right }
		'center' { TextAlign.center }
		'justify' { TextAlign.justify }
		'start' { TextAlign.start }
		'end' { TextAlign.end }
		else { return none }
	}
}

fn parse_text_transform(text string) ?TextTransform {
	return match text.trim_space().to_lower() {
		'none' { TextTransform.none }
		'uppercase' { TextTransform.uppercase }
		'lowercase' { TextTransform.lowercase }
		'capitalize' { TextTransform.capitalize }
		else { return none }
	}
}

fn parse_white_space(text string) ?WhiteSpace {
	return match text.trim_space().to_lower() {
		'normal' { WhiteSpace.normal }
		'pre' { WhiteSpace.pre }
		'nowrap' { WhiteSpace.nowrap }
		'pre-wrap' { WhiteSpace.pre_wrap }
		'pre-line' { WhiteSpace.pre_line }
		else { return none }
	}
}

fn parse_direction(text string) ?Direction {
	return match text.trim_space().to_lower() {
		'ltr' { Direction.ltr }
		'rtl' { Direction.rtl }
		else { return none }
	}
}

fn parse_vertical_align(text string) ?VerticalAlign {
	t := text.trim_space().to_lower()
	// A length or percentage is a relative alignment, which needs the line box and is
	// Phase 2. It is accepted and treated as `baseline` rather than dropped, because
	// dropping it would change the line's height.
	if keyword_length(t) != none || parse_length(t) != none {
		return VerticalAlign.baseline
	}
	return match t {
		'baseline' { VerticalAlign.baseline }
		'top' { VerticalAlign.top }
		'middle' { VerticalAlign.middle }
		'bottom' { VerticalAlign.bottom }
		'sub' { VerticalAlign.sub }
		'super' { VerticalAlign.super }
		'text-top' { VerticalAlign.text_top }
		'text-bottom' { VerticalAlign.text_bottom }
		else { return none }
	}
}

fn parse_list_style_type(text string) ?ListStyleType {
	return match text.trim_space().to_lower() {
		'none' { ListStyleType.none }
		'disc' { ListStyleType.disc }
		'circle' { ListStyleType.circle }
		'square' { ListStyleType.square }
		'decimal' { ListStyleType.decimal }
		'decimal-leading-zero' { ListStyleType.decimal_leading_zero }
		'lower-alpha', 'lower-latin' { ListStyleType.lower_alpha }
		'upper-alpha', 'upper-latin' { ListStyleType.upper_alpha }
		'lower-roman' { ListStyleType.lower_roman }
		'upper-roman' { ListStyleType.upper_roman }
		else { return none }
	}
}

fn parse_list_style_position(text string) ?ListStylePosition {
	return match text.trim_space().to_lower() {
		'inside' { ListStylePosition.inside }
		'outside' { ListStylePosition.outside }
		else { return none }
	}
}

fn parse_visibility(text string) ?Visibility {
	return match text.trim_space().to_lower() {
		'visible' { Visibility.visible }
		'hidden' { Visibility.hidden }
		'collapse' { Visibility.collapse }
		else { return none }
	}
}

fn parse_border_style(text string) ?BorderStyle {
	return match text.trim_space().to_lower() {
		'none' { BorderStyle.none }
		'hidden' { BorderStyle.hidden }
		'solid' { BorderStyle.solid }
		'dashed' { BorderStyle.dashed }
		'dotted' { BorderStyle.dotted }
		'double' { BorderStyle.double }
		'groove' { BorderStyle.groove }
		'ridge' { BorderStyle.ridge }
		'inset' { BorderStyle.inset }
		'outset' { BorderStyle.outset }
		else { return none }
	}
}

// parse_length reads one length, a percentage, `auto`, or a keyword length.
fn parse_length(text string) ?Length {
	t := text.trim_space().to_lower()
	if t == '' {
		return none
	}
	if t == 'auto' {
		return Length{ unit: .auto }
	}
	if t == 'none' {
		return Length{ unit: .none }
	}
	if k := keyword_length(t) {
		return k
	}
	mut num_text := t
	mut unit_text := ''
	if t.ends_with('%') {
		num_text = t[..t.len - 1]
		unit_text = '%'
	} else {
		// A trailing alphabetic run is the unit. Scanning backwards over letters is
		// what lets `1e3px` split correctly, and it is why the unit is looked for
		// after the number rather than before it.
		mut i := t.len
		for i > 0 {
			c := t[i - 1]
			if !(c >= `a` && c <= `z`) {
				break
			}
			i--
		}
		num_text = t[..i]
		unit_text = t[i..]
	}
	v := strconv.atof64(num_text) or { return none }
	unit := unit_from_string(unit_text)
	if unit == .none {
		return none
	}
	return Length{ value: v, unit: unit }
}

// parse_line_height accepts a length, a percentage, a number, and the keywords. A
// number is kept as a unitless length: it multiplies the font size, and layout is
// where that multiplication happens.
fn parse_line_height(text string) ?Length {
	t := text.trim_space().to_lower()
	if t == 'normal' {
		return Length{ value: 0.0, unit: .none }
	}
	// A bare number is unitless and multiplies the font size, so it must be read
	// before parse_length, which would call a missing unit px and turn
	// line-height: 2 into two pixels.
	if is_bare_number(t) {
		n := strconv.atof64(t) or { return none }
		return Length{ value: n, unit: .none }
	}
	if l := parse_length(t) {
		if l.unit == .none || l.unit == .px || l.unit == .percent {
			return l
		}
		return none
	}
	n := strconv.atof64(t) or { return none }
	return Length{ value: n, unit: .none }
}

// parse_edges reads the four-value box shorthand, in any of its forms: one value for
// all sides, two for vertical then horizontal, three for top then horizontal then
// bottom, four for each side.
fn parse_edges(text string) ?Edges {
	parts := split_top_level(text)
	if parts.len == 0 || parts.len > 4 {
		return none
	}
	mut vals := [4]Length{}
	mut i := 0
	for p in parts {
		l := parse_edge_component(p) or { return none }
		vals[i] = l
		i++
	}
	match i {
		1 {
			return Edges{vals[0], vals[0], vals[0], vals[0]}
		}
		2 {
			return Edges{vals[0], vals[1], vals[0], vals[1]}
		}
		3 {
			return Edges{vals[0], vals[1], vals[2], vals[1]}
		}
		else {
			return Edges{vals[0], vals[1], vals[2], vals[3]}
		}
	}
}

// parse_edge_component reads one component of a box shorthand, which may be a
// keyword length (`thin`), a normal length, `auto`, or -- for border-width -- the
// keyword that means zero width.
fn parse_edge_component(text string) ?Length {
	t := text.trim_space().to_lower()
	if t == 'medium' || t == 'thick' || t == 'thin' {
		return keyword_length(t) or { return none }
	}
	return parse_length(t)
}

fn parse_color_edges(text string) ?[4]raster.Color {
	parts := split_top_level(text)
	if parts.len == 0 || parts.len > 4 {
		return none
	}
	mut vals := [4]raster.Color{}
	mut i := 0
	for p in parts {
		c := parse_color(p) or { return none }
		vals[i] = c
		i++
	}
	match i {
		1 {
			return [vals[0], vals[0], vals[0], vals[0]]
		}
		2 {
			return [vals[0], vals[1], vals[0], vals[1]]
		}
		3 {
			return [vals[0], vals[1], vals[2], vals[1]]
		}
		else {
			return vals
		}
	}
}

// apply_background handles the `background` shorthand, of which Phase 1 acts on the
// colour alone. The rest -- image, position, repeat, attachment -- is parsed far
// enough to know it was there and then ignored, so that
// `background: #fff url(x.png) no-repeat` sets the colour instead of being dropped
// whole.
fn apply_background(mut s Style, text string) {
	for part in split_top_level(text) {
		if c := parse_color(part) {
			s.background_color = c
		}
	}
}

// first_family returns the first family in a `font-family` list, which is the one
// the text layer will ask for. The text layer does the fallback across faces.
fn first_family(text string) string {
	mut rest := text.trim_space()
	// A quoted family is used as written, minus the quotes.
	if rest.starts_with('"') || rest.starts_with("'") {
		mut quote := '"'
		if rest.starts_with("'") {
			quote = "'"
		}
		inside := rest[1..]
		if end := inside.index(quote) {
			return inside[..end]
		}
		return inside
	}
	for i, c in rest {
		if c == `,` {
			return rest[..i].trim_space()
		}
	}
	return rest
}

// split_words splits on whitespace, for the keyword-list values.
//
// The pieces are built with a strings.Builder rather than by appending to a []u8 and
// calling `bytestr` on it. The second version aliases a buffer that `<<` reallocates,
// which corrupts the heap: it showed up as an unrelated crash three functions away,
// and as a C compile error in a different module entirely.
fn split_words(text string) []string {
	mut out := []string{}
	mut cur := strings.new_builder(8)
	for c in text.bytes() {
		if c == ` ` || c == `\t` || c == `\n` {
			if cur.len > 0 {
				out << cur.str()
				cur = strings.new_builder(8)
			}
			continue
		}
		cur.write_byte(c)
	}
	if cur.len > 0 {
		out << cur.str()
	}
	return out
}

// split_top_level splits a value on whitespace and commas, but keeps a parenthesised
// run together. `margin: calc(1px + 2px) 0` is two components, not five, and a comma
// inside a function is not a component boundary either.
fn split_top_level(text string) []string {
	mut out := []string{}
	mut depth := 0
	mut cur := strings.new_builder(16)
	for c in text.bytes() {
		if c == `(` {
			depth++
		} else if c == `)` {
			if depth > 0 {
				depth--
			}
		}
		if depth == 0 && (c == ` ` || c == `\t` || c == `\n` || c == `,`) {
			if cur.len > 0 {
				out << cur.str()
				cur = strings.new_builder(16)
			}
			continue
		}
		cur.write_byte(c)
	}
	if cur.len > 0 {
		out << cur.str()
	}
	return out
}
