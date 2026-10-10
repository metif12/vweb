module style

import strconv

// `background-image`, `background-repeat`, `background-position` and
// `background-size`.
//
// The image itself is not here, and that is the whole design. ARCHITECTURE.md 1
// makes the engine pure -- bytes in, a pixel buffer out, no file and no socket
// anywhere inside it -- so the cascade records a *reference* to an image and the
// caller fetches the bytes, decodes them and hands the bitmap to the painter.
// Nothing in this module opens anything, and a test of the cascade needs no image
// on disk. `engine/page` is where the loader meets the styles.
//
// The three non-image properties resolve to pixels here rather than in layout,
// because a percentage of `background-size` is a percentage of the *box's own*
// rectangle and a length in `em` is a multiple of the box's own font size, and
// both are known by the time a box exists. That is also the limit of what can be
// resolved: `rem` and the viewport units are answered against the box's own font
// size, because the box tree carries no root font size and no viewport, and
// `engine/display` belongs to another stream.

// BackgroundRepeat is `background-repeat`.
pub enum BackgroundRepeat {
	repeat
	repeat_x
	repeat_y
	no_repeat
}

// parse_repeat reads one repeat keyword.
//
// `space` and `round` are real CSS values that change the tile's size rather than
// only where it starts, and they are rejected so the declaration is dropped and
// falls back to the initial `repeat`. That is the same picture as `space` on any
// background whose tile divides the box evenly, which is the case both of them
// exist for.
fn parse_repeat(text string) ?BackgroundRepeat {
	return match text.trim_space().to_lower() {
		'repeat' { BackgroundRepeat.repeat }
		'repeat-x' { BackgroundRepeat.repeat_x }
		'repeat-y' { BackgroundRepeat.repeat_y }
		'no-repeat' { BackgroundRepeat.no_repeat }
		else { return none }
	}
}

// PositionKind says which of a PositionComponent's two fields means anything.
//
// It is the same "unused field is zero" idiom `engine/paint/list.v` uses for its
// Command: a struct with two fields where one is null per kind, rather than a sum
// type this V cannot express inline.
pub enum PositionKind {
	percent
	length
}

// PositionComponent is one axis of `background-position`.
//
// A keyword is stored as the percentage CSS defines it as -- `center` is 50% and
// `right` is 100% -- so an axis has two shapes rather than six and the resolver
// has one branch per shape.
pub struct PositionComponent {
pub mut:
	kind    PositionKind
	percent f64
	length  Length
}

// BackgroundPosition is where the first tile of a background image goes, as
// offsets from the top-left of the positioning area.
pub struct BackgroundPosition {
pub mut:
	x PositionComponent
	y PositionComponent
}

// initial_background_position is `0% 0%`: the top-left corner, which is where a
// background image starts when nothing says otherwise.
fn initial_background_position() BackgroundPosition {
	return BackgroundPosition{
		x: PositionComponent{ kind: .percent, percent: 0.0 }
		y: PositionComponent{ kind: .percent, percent: 0.0 }
	}
}

// parse_background_position reads the longhand, which is one or two components.
//
// The four-value form -- `background-position: right 10px bottom 20px` -- is
// rejected: it names an edge and then an offset from it, and expanding it into
// the two offsets would mean a second representation of the same thing for a
// syntax almost no stylesheet uses.
fn parse_background_position(text string) ?BackgroundPosition {
	return parse_background_position_words(split_words(text))
}

// parse_background_position_words is the same thing for a caller that already
// split the value, which is what the `background` shorthand scanner has.
fn parse_background_position_words(words []string) ?BackgroundPosition {
	if words.len == 0 || words.len > 2 {
		return none
	}
	x := position_component(words[0]) or { return none }
	// A single component is the horizontal one and the vertical defaults to
	// `center`, which is what CSS says: `background-position: center` centres on
	// both axes while `background-position: left` is the left edge and vertically
	// centred.
	mut y := PositionComponent{ kind: .percent, percent: 50.0 }
	if words.len == 2 {
		y = position_component(words[1]) or { return none }
	}
	return BackgroundPosition{ x: x, y: y }
}

// position_component reads one axis: a keyword, a percentage, or a length.
fn position_component(word string) ?PositionComponent {
	t := word.trim_space().to_lower()
	match t {
		'left', 'top' { return PositionComponent{ kind: .percent, percent: 0.0 } }
		'center' { return PositionComponent{ kind: .percent, percent: 50.0 } }
		'right', 'bottom' { return PositionComponent{ kind: .percent, percent: 100.0 } }
		else {}
	}
	if t.ends_with('%') {
		v := strconv.atof64(t[..t.len - 1]) or { return none }
		return PositionComponent{ kind: .percent, percent: v }
	}
	l := parse_length(t) or { return none }
	// `auto` and `none` are not positions. `parse_length` answers them because it
	// is shared with the box-model properties, so they are refused here rather
	// than silently read as the top-left corner.
	if l.unit == .auto || l.unit == .none {
		return none
	}
	return PositionComponent{ kind: .length, length: l }
}

// SizeMode distinguishes the two keyword sizes from the two-component form.
//
// `auto` is a mode rather than two `Length{unit: .auto}` components because
// `auto auto` has to mean "the image's own size", and the resolver needs to say
// that without testing two fields.
pub enum SizeMode {
	auto
	cover
	contain
	explicit
}

// BackgroundSize is the size of one tile.
pub struct BackgroundSize {
pub mut:
	mode   SizeMode
	width  Length
	height Length
}

// initial_background_size is `auto auto`: the image's own dimensions.
fn initial_background_size() BackgroundSize {
	return BackgroundSize{
		mode:   .auto
		width:  Length{ unit: .auto }
		height: Length{ unit: .auto }
	}
}

// is_size_word reports whether a component can belong to a `background-size`.
//
// It exists for the shorthand scanner: the `/` puts the scanner into the size half
// of the value, but CSS lets the repeat keyword, the attachment and the boxes follow
// the size, and they must be dropped rather than read as a size and made to reject
// the whole declaration.
fn is_size_word(text string) bool {
	t := text.trim_space().to_lower()
	if t == 'auto' || t == 'cover' || t == 'contain' {
		return true
	}
	l := parse_length(t) or { return false }
	return l.unit != .none
}

// parse_background_size reads the longhand, which is one or two components or one
// keyword.
fn parse_background_size(text string) ?BackgroundSize {
	return parse_background_size_words(split_words(text))
}

// parse_background_size_words is the same thing for a caller that already split the
// value, which is what the `background` shorthand scanner has.
fn parse_background_size_words(words []string) ?BackgroundSize {
	if words.len == 0 || words.len > 2 {
		return none
	}
	if words.len == 1 {
		one := words[0].trim_space().to_lower()
		if one == 'cover' {
			return BackgroundSize{ mode: .cover }
		}
		if one == 'contain' {
			return BackgroundSize{ mode: .contain }
		}
	}
	mut comps := [Length{ unit: .auto }, Length{ unit: .auto }]
	mut i := 0
	for i < words.len {
		word := words[i].trim_space().to_lower()
		l := parse_length(word) or { return none }
		if l.unit == .none {
			return none
		}
		comps[i] = l
		i++
	}
	// A single length is the width and the height is `auto`, which CSS resolves
	// from the aspect ratio.
	mode := if comps[0].unit == .auto && comps[1].unit == .auto {
		SizeMode.auto
	} else {
		SizeMode.explicit
	}
	return BackgroundSize{ mode: mode, width: comps[0], height: comps[1] }
}

// resolve turns the declaration into the pixel dimensions of one tile.
pub fn (z BackgroundSize) resolve(area_w int, area_h int, img_w int, img_h int, ctx &Context) (int, int) {
	if img_w <= 0 || img_h <= 0 {
		return 0, 0
	}
	match z.mode {
		.auto { return img_w, img_h }
		.cover {
			scale := max_of(f64(area_w) / f64(img_w), f64(area_h) / f64(img_h))
			return round_px(f64(img_w) * scale), round_px(f64(img_h) * scale)
		}
		.contain {
			scale := min_of(f64(area_w) / f64(img_w), f64(area_h) / f64(img_h))
			return round_px(f64(img_w) * scale), round_px(f64(img_h) * scale)
		}
		.explicit {
			// A component that was given is tracked as given, not as non-zero: `0px`
			// is a size CSS accepts, and reading it as "not given" would draw the
			// image at its own size where the author asked for nothing.
			mut w := 0
			mut h := 0
			mut has_w := false
			mut has_h := false
			if !z.width.is_auto() {
				w = round_px(z.width.to_px_or(ctx, f64(area_w)))
				has_w = true
			}
			if !z.height.is_auto() {
				h = round_px(z.height.to_px_or(ctx, f64(area_h)))
				has_h = true
			}
			// CSS sizes the axis left `auto` from the one that was given, so a
			// 50px-wide tile of a 4x2 image is 50x25 rather than 50x2.
			if !has_w {
				w = round_px(f64(h) * f64(img_w) / f64(img_h))
			}
			if !has_h {
				h = round_px(f64(w) * f64(img_h) / f64(img_w))
			}
			return w, h
		}
	}
}

// resolve turns the declaration into the position of the first tile's top-left
// corner, in absolute pixels.
//
// A percentage is of the space left over -- the area less the tile -- and not of
// the area, which is what makes `background-position: 100% 100%` put the image's
// bottom-right corner at the area's bottom-right corner rather than placing it
// entirely outside.
pub fn (p BackgroundPosition) resolve(area_x int, area_y int, area_w int, area_h int, img_w int, img_h int, ctx &Context) (int, int) {
	x := area_x + resolve_axis(p.x, area_w - img_w, ctx)
	y := area_y + resolve_axis(p.y, area_h - img_h, ctx)
	return x, y
}

fn resolve_axis(c PositionComponent, free int, ctx &Context) int {
	match c.kind {
		.percent {
			return round_px(f64(free) * c.percent / 100.0)
		}
		.length {
			return round_px(c.length.to_px_or(ctx, 0.0))
		}
	}
}

// round_px rounds to nearest. ARCHITECTURE.md 3 rounds once, at the point where a
// fraction becomes a pixel, and this is that point for a background.
fn round_px(v f64) int {
	if v >= 0.0 {
		return int(v + 0.5)
	}
	return -int(-v + 0.5)
}

// background_image_urls returns every image URL a `background` value refers to.
//
// The value is scanned as components rather than as a whole because the shorthand
// holds the url() among other things -- `background: red url(a.png) no-repeat` --
// so a caller collecting images to fetch has to ask the same question the
// shorthand asks and look at one component at a time. Reading the value whole
// finds nothing, because `url(a.png) repeat` neither starts with `url(` nor ends
// with `)`.
//
// Multiple backgrounds are comma-separated and `split_top_level` splits them, so
// every layer's url is returned; a caller that only draws the first layer still
// fetches the rest rather than re-fetching later.
pub fn background_image_urls(value string) []string {
	mut out := []string{}
	for part in split_top_level(value) {
		url := parse_image_url(part) or { continue }
		if url != '' {
			out << url
		}
	}
	return out
}

// parse_image_url reads a `background-image` value into the URL it refers to.
//
// The answer is a reference, never bytes: the string is handed to the caller that
// owns the loader, and the engine never sees the file.
//
// `none` answers the empty string, which is how "there is no image" is spelled in
// a Style. An image this engine cannot draw -- `linear-gradient(...)`, which is a
// valid CSS image -- also answers the empty string rather than an error, because
// it is a *valid* declaration and the author's last word has to beat a
// lower-specificity `url()` even though nothing is drawn for it. A value that is
// not an image at all answers an error, so `apply` drops it the way CSS drops an
// invalid declaration.
//
// What the tokenizer does to a `url()` matters here: an unquoted `url(a.png)` is
// a single `url` token whose value is the inner text, so the CSSOM serialises it
// back as `url(a.png)`, while a quoted `url("a.png")` is a `function` token
// followed by a `string` and serialises as `url("a.png")`. Both have to be
// recognised, which is why the quotes are stripped rather than assumed absent.
fn parse_image_url(text string) ?string {
	t := text.trim_space()
	lower := t.to_lower()
	if lower == 'none' {
		return ''
	}
	if !lower.starts_with('url(') || !lower.ends_with(')') {
		// Anything else with parentheses in it is a functional image notation this
		// engine does not draw: a valid CSS image, answered as "nothing drawn".
		if t.contains('(') {
			return ''
		}
		return none
	}
	mut inner := t[4..t.len - 1].trim_space()
	if inner.len >= 2 && (inner.starts_with('"') || inner.starts_with("'")) {
		inner = inner[1..inner.len - 1].trim_space()
	}
	if inner == '' {
		return ''
	}
	return inner
}
