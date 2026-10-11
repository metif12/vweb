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
		// CSS 2.1 section 17. A stylesheet that lays out a page with tables must not
		// have every rule dropped: without these the whole table renders as a stack of
		// unstyled blocks, which is the most common way a real page falls apart.
		'table' { Display.table }
		'inline-table' { Display.inline_table }
		'table-row-group' { Display.table_row_group }
		'table-header-group' { Display.table_header_group }
		'table-footer-group' { Display.table_footer_group }
		'table-row' { Display.table_row }
		'table-column-group' { Display.table_column_group }
		'table-column' { Display.table_column }
		'table-cell' { Display.table_cell }
		'table-caption' { Display.table_caption }
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

// parse_overflow reads CSS 2.1 11.1.
fn parse_overflow(text string) ?Overflow {
	return match text.trim_space().to_lower() {
		'visible' { Overflow.visible }
		'hidden' { Overflow.hidden }
		'scroll' { Overflow.scroll }
		'auto' { Overflow.auto }
		'clip' { Overflow.clip }
		else { return none }
	}
}

// parse_radii reads the `border-radius` shorthand: one to four lengths for the
// horizontal radii, and optionally the same for the vertical ones after a `/`.
//
// The two-value form abbreviates the four the same way the box-model shorthands
// do -- clockwise from the top-left -- so it is expanded here rather than in the
// cascade, where every other four-sided shorthand is. The vertical set defaults
// to the horizontal one, which is what makes a plain `border-radius: 8px` a circle
// at each corner rather than nothing at all.
//
// A component that is not a length makes the whole declaration invalid, which is
// what `apply` does with a `none` answer: drops it. A `/` with nothing after it is
// the same.
fn parse_radii(text string) ?Radii {
	mut hx := []string{}
	mut vy := []string{}
	mut after_slash := false
	for p in split_top_level(text.trim_space()) {
		if p == '/' {
			if after_slash {
				// A second slash is not a shape this grammar has.
				return none
			}
			after_slash = true
			continue
		}
		if after_slash {
			vy << p
		} else {
			hx << p
		}
	}
	mut out := Radii{}
	if !fill_radii(mut out.x, hx) {
		return none
	}
	if vy.len == 0 {
		out.y = out.x
		return out
	}
	if !fill_radii(mut out.y, vy) {
		return none
	}
	return out
}

// fill_radii expands one to four components into the four corners, clockwise from
// the top-left. It answers false when there is nothing to expand or too much, so
// that a caller can refuse the declaration rather than keeping a half of it.
fn fill_radii(mut corners [4]Length, parts []string) bool {
	if parts.len == 0 || parts.len > 4 {
		return false
	}
	mut vals := [Length{}, Length{}, Length{}, Length{}]
	mut i := 0
	for p in parts {
		l := parse_length(p) or { return false }
		vals[i] = l
		i++
	}
	if i == 1 {
		vals[1] = vals[0]
		vals[2] = vals[0]
		vals[3] = vals[0]
	} else if i == 2 {
		vals[2] = vals[0]
		vals[3] = vals[1]
	} else if i == 3 {
		vals[3] = vals[1]
	}
	corners[0] = vals[0]
	corners[1] = vals[1]
	corners[2] = vals[2]
	corners[3] = vals[3]
	return true
}

// parse_corner reads one `border-<corner>-radius` longhand, whose value is one
// length or two -- the horizontal radius then the vertical one.
fn parse_corner(text string) ?Corner {
	parts := split_top_level(text.trim_space())
	if parts.len == 0 || parts.len > 2 {
		return none
	}
	mut c := Corner{}
	if !corner_axis(mut c.x, parts[0]) {
		return none
	}
	if parts.len == 2 {
		if !corner_axis(mut c.y, parts[1]) {
			return none
		}
		return c
	}
	c.y = c.x
	return c
}

fn corner_axis(mut l Length, word string) bool {
	v := parse_length(word) or { return false }
	l = v
	return true
}

// Corner is one corner's two radii, which is what a `border-<corner>-radius`
// longhand carries before the cascade writes it into a Radii.
pub struct Corner {
pub mut:
	x Length
	y Length
}

fn parse_float(text string) ?Float {
	return match text.trim_space().to_lower() {
		'left' { Float.left }
		'right' { Float.right }
		'none' { Float.none }
		else { return none }
	}
}

// parse_position reads CSS 2.1 9.3.2. `sticky` is refused rather than approximated:
// it is not in CSS 2.1, and treating it as `relative` would apply its offset
// permanently instead of only while the box is stuck.
fn parse_position(text string) ?Position {
	return match text.trim_space().to_lower() {
		'static' { Position.static }
		'relative' { Position.relative }
		'absolute' { Position.absolute }
		'fixed' { Position.fixed }
		else { return none }
	}
}

// parse_z_index reads `z-index: auto | <integer>`.
//
// A negative value is valid and is what puts a box behind its parent's background, so
// the integer is taken as-is rather than clamped at zero. A non-integer is refused:
// CSS 2.1 says the property takes an integer, and `2.5` is a typo rather than a
// request for 2.
fn parse_z_index(text string) ?ZIndex {
	t := text.trim_space().to_lower()
	if t == 'auto' {
		return ZIndex{ auto: true }
	}
	n := strconv.atoi(t) or { return none }
	return ZIndex{ value: n }
}

fn parse_clear(text string) ?Clear {
	return match text.trim_space().to_lower() {
		'left' { Clear.left }
		'right' { Clear.right }
		'both' { Clear.both }
		'none' { Clear.none }
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

// apply_background handles the `background` shorthand, of which the colour, the
// image, the repeat, the position and the size all reach the computed style.
//
// CSS says a shorthand resets every longhand it stands for, so all five are set
// whether or not the value mentions them: `background: red` clears an image, a
// position and a size that a lower-specificity rule had put there, which is what
// the author meant by writing the shorthand instead of `background-color`.
//
// The components are told apart by what they parse as, in an order that cannot
// confuse them: a repeat keyword first (nothing else spells `no-repeat`), then a
// position component (a keyword, a length or a percentage), then a colour, then
// an image. The size sits after a `/`, which is the only place a slash may appear
// in the grammar.
fn apply_background(mut s Style, text string) {
	// The reset happens before the scan, not only when a component is found.
	s.background_color = raster.transparent
	s.background_image = ''
	s.background_repeat = .repeat
	s.background_position = initial_background_position()
	s.background_size = initial_background_size()
	mut pos_words := []string{}
	mut size_words := []string{}
	mut in_size := false
	for part in split_top_level(text) {
		// A repeat keyword is checked before the slash is looked at, because CSS's
		// grammar lets it come after the size and no size component can ever be
		// spelled `no-repeat`.
		if r := parse_repeat(part) {
			s.background_repeat = r
			continue
		}
		if part == '/' {
			in_size = true
			continue
		}
		if in_size {
			// The other components may follow the size -- CSS allows the attachment
			// and the boxes in any order -- so a component that is not a size is
			// dropped rather than read as one and made to reject the whole
			// declaration.
			if is_size_word(part) {
				size_words << part
			}
			continue
		}
		if _ := position_component(part) {
			pos_words << part
			continue
		}
		if col := parse_color(part) {
			s.background_color = col
			continue
		}
		if url := parse_image_url(part) {
			s.background_image = url
			continue
		}
		// Anything else -- `fixed`, `scroll`, a typo -- is dropped. CSS drops it too:
		// a component the shorthand does not understand invalidates the
		// declaration, and dropping one component is the more useful half of that
		// because the rest of the shorthand still applies.
	}
	if p := parse_background_position_words(pos_words) {
		s.background_position = p
	}
	if z := parse_background_size_words(size_words) {
		s.background_size = z
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
