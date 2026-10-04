module style

import engine.raster
import strconv
import strings

// Colours: how a CSS colour becomes premultiplied bytes.
//
// The output type is `raster.Color`, not a colour defined here. That is the whole
// reason raster premultiplies: a colour that comes out of the cascade is already in
// the form the blend step needs, so there is no conversion between parsing and
// painting and no way for the two to disagree about what a half-transparent red is.
//
// A colour that cannot be understood is rejected rather than defaulted. The spec
// makes an invalid value compute to the property's inherited or initial value, and
// substituting black here would silently repaint a page instead of ignoring one
// declaration.

pub fn parse_color(text string) ?raster.Color {
	t := text.trim_space().to_lower()
	if t == '' {
		return none
	}
	if t.starts_with('#') {
		return hex_color(t[1..])
	}
	if t == 'transparent' {
		return raster.Color{ r: 0, g: 0, b: 0, a: 0 }
	}
	if t.starts_with('rgb(') || t.starts_with('rgba(') {
		return functional_color(t)
	}
	return named_color(t)
}

// hex_color reads `#rgb`, `#rgba`, `#rrggbb` and `#rrggbbaa`.
//
// In the short forms each digit is its own channel, so `#abc` is `#aabbcc` -- red
// `aa`, green `bb`, blue `cc` -- not one channel repeated. The expansion is
// `d * 0x11`, which is the same number as writing the digit twice and the one that
// makes the rule obvious.
fn hex_color(digits string) ?raster.Color {
	match digits.len {
		3, 4 {
			mut comps := [255, 255, 255, 255]
			mut i := 0
			for i < digits.len {
				comps[i] = short_channel(digits[i]) or { return none }
				i++
			}
			return raster.rgba(comps[0], comps[1], comps[2], comps[3])
		}
		6, 8 {
			mut comps := [4]u8{}
			comps[3] = 255
			mut i := 0
			mut k := 0
			// Two digits per channel, so the loop stops one digit early. Reading the
			// odd digit of a three-digit colour returns an empty string rather than a
			// byte, which would make the whole colour fail to parse quietly.
			for i + 1 < digits.len {
				hi := hex_digit(digits[i]) or { return none }
				lo := hex_digit(digits[i + 1]) or { return none }
				comps[k] = u8(hi * 16 + lo)
				i += 2
				k++
			}
			return raster.rgba(int(comps[0]), int(comps[1]), int(comps[2]),
				int(comps[3]))
		}
		else {
			return none
		}
	}
}

// short_channel expands one hex digit to a channel value.
fn short_channel(c u8) ?int {
	d := hex_digit(c) or { return none }
	return d * 0x11
}

fn hex_digit(c u8) ?int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	return none
}

// functional_color reads `rgb(...)` and `rgba(...)` with either comma or
// space-separated components, and either syntax for the alpha. CSS has accepted
// all four spellings and real stylesheets use more than one.
fn functional_color(t string) ?raster.Color {
	open := t.index('(') or { return none }
	close := last_byte_index(t, 0x29) or { return none } // ')'
	if close <= open {
		return none
	}
	mut body := t[open + 1..close]
	// The slash syntax puts the alpha after a `/`, and it is the only place a `/`
	// appears, so it is split off before the components rather than being left to
	// become a fifth component of its own.
	mut alpha_part := ''
	if slash := body.index('/') {
		alpha_part = body[slash + 1..].trim_space()
		body = body[..slash]
	}
	mut parts := split_components(body)
	if alpha_part != '' {
		parts << alpha_part
	}
	if parts.len != 3 && parts.len != 4 {
		return none
	}
	// The channel names are spelled out rather than called r, g and b: a local
	// named `r` in a function that returns a struct is the shape V's C backend
	// mixes up, and the one-line fix is not worth the hours of bisecting.
	mut cr := component_number(parts[0]) or { return none }
	mut cg := component_number(parts[1]) or { return none }
	mut cb := component_number(parts[2]) or { return none }
	mut alpha := 255.0
	if parts.len == 4 {
		alpha = alpha_number(parts[3]) or { return none }
	}
	// A percentage channel is relative to 255, and a number is 0..255 clamped. CSS
	// mixes the two freely, including `rgb(50%, 0, 0)`.
	if parts[0].ends_with('%') {
		cr = cr * 255.0 / 100.0
	}
	if parts[1].ends_with('%') {
		cg = cg * 255.0 / 100.0
	}
	if parts[2].ends_with('%') {
		cb = cb * 255.0 / 100.0
	}
	return raster.rgba(clamp_byte(cr), clamp_byte(cg), clamp_byte(cb), clamp_byte(alpha))
}

// last_byte_index finds the last occurrence of a byte. `string.last_index` in V
// answers a yes/no question about the end of the string, so the closing paren of a
// functional notation has to be found by hand.
fn last_byte_index(s string, target u8) ?int {
	mut i := s.len
	for i > 0 {
		i--
		if s[i] == target {
			return i
		}
	}
	return none
}

// split_components splits on commas if there are any, and on whitespace otherwise.
// Mixing the two in one function is invalid, so choosing by which separator is
// present is enough to accept every valid form.
fn split_components(body string) []string {
	mut out := []string{}
	if body.contains(',') {
		for part in body.split(',') {
			t := part.trim_space()
			if t != '' {
				out << t
			}
		}
		return out
	}
	mut cur := strings.new_builder(8)
	for c in body {
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

// component_number reads one channel, which may carry a percent sign. The sign is
// stripped here rather than at the call site because the two syntaxes mix freely:
// `rgb(50%, 0, 0)` is valid.
fn component_number(s string) ?f64 {
	digits := if s.ends_with('%') { s[..s.len - 1] } else { s }
	return strconv.atof64(digits) or { return none }
}

// alpha_number reads an alpha, which is 0..1 as a number or 0%..100% as a
// percentage. `rgb(0 0 0 / 50%)` is 50% of opaque, not 0.5 of it. The result is
// still 0..255 because that is what the blend step wants.
fn alpha_number(s string) ?f64 {
	if s.ends_with('%') {
		v := strconv.atof64(s[..s.len - 1]) or { return none }
		return v * 255.0 / 100.0
	}
	v := strconv.atof64(s) or { return none }
	return v * 255.0
}

fn clamp_byte(v f64) int {
	// Round to nearest rather than truncate. gba(0, 0, 0, 0.5) is 127.5, and
	// truncating it to 127 makes half-transparent black one step too dark -- which
	// is exactly the bias the raster tests already guard against for blending.
	n := int(v + 0.5)
	if n < 0 {
		return 0
	}
	if n > 255 {
		return 255
	}
	return n
}

// named_color reads the CSS named colours. The grey/gray and the cyan/magenta
// spellings are aliases and share an arm, which is why the list is shorter than the
// 148 names in the CSS Color spec.
fn named_color(name string) ?raster.Color {
	return match name {
		'aliceblue' { hex8(0xf0f8ff) }
		'antiquewhite' { hex8(0xfaebd7) }
		'aqua', 'cyan' { hex8(0x00ffff) }
		'aquamarine' { hex8(0x7fffd4) }
		'azure' { hex8(0xf0ffff) }
		'beige' { hex8(0xf5f5dc) }
		'bisque' { hex8(0xffe4c4) }
		'black' { hex8(0x000000) }
		'blanchedalmond' { hex8(0xffebcd) }
		'blue' { hex8(0x0000ff) }
		'blueviolet' { hex8(0x8a2be2) }
		'brown' { hex8(0xa52a2a) }
		'burlywood' { hex8(0xdeb887) }
		'cadetblue' { hex8(0x5f9ea0) }
		'chartreuse' { hex8(0x7fff00) }
		'chocolate' { hex8(0xd2691e) }
		'coral' { hex8(0xff7f50) }
		'cornflowerblue' { hex8(0x6495ed) }
		'cornsilk' { hex8(0xfff8dc) }
		'crimson' { hex8(0xdc143c) }
		'darkblue' { hex8(0x00008b) }
		'darkcyan' { hex8(0x008b8b) }
		'darkgoldenrod' { hex8(0xb8860b) }
		'darkgray', 'darkgrey' { hex8(0xa9a9a9) }
		'darkgreen' { hex8(0x006400) }
		'darkkhaki' { hex8(0xbdb76b) }
		'darkmagenta' { hex8(0x8b008b) }
		'darkolivegreen' { hex8(0x556b2f) }
		'darkorange' { hex8(0xff8c00) }
		'darkorchid' { hex8(0x9932cc) }
		'darkred' { hex8(0x8b0000) }
		'darksalmon' { hex8(0xe9967a) }
		'darkseagreen' { hex8(0x8fbc8f) }
		'darkslateblue' { hex8(0x483d8b) }
		'darkslategray', 'darkslategrey' { hex8(0x2f4f4f) }
		'darkturquoise' { hex8(0x00ced1) }
		'darkviolet' { hex8(0x9400d3) }
		'deeppink' { hex8(0xff1493) }
		'deepskyblue' { hex8(0x00bfff) }
		'dimgray', 'dimgrey' { hex8(0x696969) }
		'dodgerblue' { hex8(0x1e90ff) }
		'firebrick' { hex8(0xb22222) }
		'floralwhite' { hex8(0xfffaf0) }
		'forestgreen' { hex8(0x228b22) }
		'fuchsia', 'magenta' { hex8(0xff00ff) }
		'gainsboro' { hex8(0xdcdcdc) }
		'ghostwhite' { hex8(0xf8f8ff) }
		'gold' { hex8(0xffd700) }
		'goldenrod' { hex8(0xdaa520) }
		'gray', 'grey' { hex8(0x808080) }
		'green' { hex8(0x008000) }
		'greenyellow' { hex8(0xadff2f) }
		'honeydew' { hex8(0xf0fff0) }
		'hotpink' { hex8(0xff69b4) }
		'indianred' { hex8(0xcd5c5c) }
		'indigo' { hex8(0x4b0082) }
		'ivory' { hex8(0xfffff0) }
		'khaki' { hex8(0xf0e68c) }
		'lavender' { hex8(0xe6e6fa) }
		'lavenderblush' { hex8(0xfff0f5) }
		'lawngreen' { hex8(0x7cfc00) }
		'lemonchiffon' { hex8(0xfffacd) }
		'lightblue' { hex8(0xadd8e6) }
		'lightcoral' { hex8(0xf08080) }
		'lightcyan' { hex8(0xe0ffff) }
		'lightgoldenrodyellow' { hex8(0xfafad2) }
		'lightgray', 'lightgrey' { hex8(0xd3d3d3) }
		'lightgreen' { hex8(0x90ee90) }
		'lightpink' { hex8(0xffb6c1) }
		'lightsalmon' { hex8(0xffa07a) }
		'lightseagreen' { hex8(0x20b2aa) }
		'lightskyblue' { hex8(0x87cefa) }
		'lightslategray', 'lightslategrey' { hex8(0x778899) }
		'lightsteelblue' { hex8(0xb0c4de) }
		'lightyellow' { hex8(0xffffe0) }
		'lime' { hex8(0x00ff00) }
		'limegreen' { hex8(0x32cd32) }
		'linen' { hex8(0xfaf0e6) }
		'maroon' { hex8(0x800000) }
		'mediumaquamarine' { hex8(0x66cdaa) }
		'mediumblue' { hex8(0x0000cd) }
		'mediumorchid' { hex8(0xba55d3) }
		'mediumpurple' { hex8(0x9370db) }
		'mediumseagreen' { hex8(0x3cb371) }
		'slateblue' { hex8(0x6a5acd) }
		'mediumslateblue' { hex8(0x7b68ee) }
		'mediumspringgreen' { hex8(0x00fa9a) }
		'mediumturquoise' { hex8(0x48d1cc) }
		'mediumvioletred' { hex8(0xc71585) }
		'midnightblue' { hex8(0x191970) }
		'mintcream' { hex8(0xf5fffa) }
		'mistyrose' { hex8(0xffe4e1) }
		'moccasin' { hex8(0xffe4b5) }
		'navajowhite' { hex8(0xffdead) }
		'navy' { hex8(0x000080) }
		'oldlace' { hex8(0xfdf5e6) }
		'olive' { hex8(0x808000) }
		'olivedrab' { hex8(0x6b8e23) }
		'orange' { hex8(0xffa500) }
		'orangered' { hex8(0xff4500) }
		'orchid' { hex8(0xda70d6) }
		'palegoldenrod' { hex8(0xeee8aa) }
		'palegreen' { hex8(0x98fb98) }
		'paleturquoise' { hex8(0xafeeee) }
		'palevioletred' { hex8(0xdb7093) }
		'papayawhip' { hex8(0xffefd5) }
		'peachpuff' { hex8(0xffdab9) }
		'peru' { hex8(0xcd853f) }
		'pink' { hex8(0xffc0cb) }
		'plum' { hex8(0xdda0dd) }
		'powderblue' { hex8(0xb0e0e6) }
		'purple' { hex8(0x800080) }
		'rebeccapurple' { hex8(0x663399) }
		'red' { hex8(0xff0000) }
		'rosybrown' { hex8(0xbc8f8f) }
		'royalblue' { hex8(0x4169e1) }
		'saddlebrown' { hex8(0x8b4513) }
		'salmon' { hex8(0xfa8072) }
		'sandybrown' { hex8(0xf4a460) }
		'seagreen' { hex8(0x2e8b57) }
		'seashell' { hex8(0xfff5ee) }
		'sienna' { hex8(0xa0522d) }
		'silver' { hex8(0xc0c0c0) }
		'skyblue' { hex8(0x87ceeb) }
		'slategray', 'slategrey' { hex8(0x708090) }
		'snow' { hex8(0xfffafa) }
		'springgreen' { hex8(0x00ff7f) }
		'steelblue' { hex8(0x4682b4) }
		'tan' { hex8(0xd2b48c) }
		'teal' { hex8(0x008080) }
		'thistle' { hex8(0xd8bfd8) }
		'tomato' { hex8(0xff6347) }
		'turquoise' { hex8(0x40e0d0) }
		'violet' { hex8(0xee82ee) }
		'wheat' { hex8(0xf5deb3) }
		'white' { hex8(0xffffff) }
		'whitesmoke' { hex8(0xf5f5f5) }
		'yellow' { hex8(0xffff00) }
		'yellowgreen' { hex8(0x9acd32) }
		else { return none }
	}
}

// hex8 builds an opaque colour from a packed 0xRRGGBB literal, which is how the
// table above is written: the numbers in the spec are the numbers in the source.
fn hex8(v int) raster.Color {
	return raster.rgb((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
}
