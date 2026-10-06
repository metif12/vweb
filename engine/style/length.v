module style

// Lengths, and the units CSS resolves them in.
//
// Two decisions here are what make the rest of the engine possible.
//
// Lengths stay unresolved. A length in `em` needs the parent's font size and one in
// `%` needs the containing block's width, and neither is known until the cascade
// has run and layout has begun. Resolving here would mean the cascade needed the
// whole tree, and the tree is not built yet. So a Length carries its number and its
// unit, and layout is what turns it into pixels -- once, at the point where the
// answer exists.
//
// Lengths stay floating point until layout, and are rounded exactly once, when a
// box is given its position and size. ARCHITECTURE.md 3 makes integer arithmetic a
// requirement rather than an optimisation, and this is where the single rounding
// step happens.

pub struct Length {
pub mut:
	value f64
	unit  Unit
}

// Unit is a CSS length unit, or `auto` for a length the property sizes itself.
pub enum Unit {
	// none means "not a length", which is what a keyword like `thin` or `medium`
	// resolves to once it has been turned into a number.
	//
	// It is first so that the zero value of a Length is "not a length" and not `auto`.
	// With `auto` first, a margin that was never declared read as `auto`, which made it
	// impossible to tell `margin: auto` from no margin at all -- and those two have
	// opposite meanings. That is acceptance case 5, and it is why this order is the way
	// it is.
	none
	auto
	px
	pt
	pc
	in
	cm
	mm
	q
	em
	rem
	ex
	ch
	cap
	ic
	lh
	rlh
	vw
	vh
	vmin
	vmax
	vb
	vi
	percent
}

// Context carries the two font sizes a relative length needs, and the viewport,
// because `rem` and `vw` are the only lengths that do not depend on the element
// being styled. Passing them in rather than reaching for globals is what keeps the
// style layer pure.
pub struct Context {
pub mut:
	// font_size is the *parent's* computed font size, which is what `em` resolves
	// against: in CSS an `em` on a font-size property itself resolves against the
	// parent's, not its own.
	font_size       f64
	root_font_size  f64
	viewport_width  f64
	viewport_height f64
}

// default_context is a function rather than a const because taking the address of a
// const struct is not something V 0.5.2 generates usable C for, and every caller needs a
// pointer to it.
pub fn default_context() Context {
	return Context{
		font_size:       16.0
		root_font_size:  16.0
		viewport_width:  0.0
		viewport_height: 0.0
	}
}

// to_px resolves a length to pixels. A percentage is left to the caller, which is
// the only thing that knows what it is a percentage of.
pub fn (l Length) to_px(ctx &Context) f64 {
	return l.to_px_or(ctx, 0.0)
}

// to_px_or resolves to pixels with a fallback for percentages, which is what a
// caller resolves against a containing block it has already measured.
pub fn (l Length) to_px_or(ctx &Context, percent_basis f64) f64 {
	match l.unit {
		.auto, .none { return 0.0 }
		.px { return l.value }
		.pt { return l.value * 96.0 / 72.0 }
		.pc { return l.value * 16.0 }
		.in { return l.value * 96.0 }
		.cm { return l.value * 96.0 / 2.54 }
		.mm { return l.value * 96.0 / 25.4 }
		.q { return l.value * 96.0 / 101.6 }
		.em { return l.value * ctx.font_size }
		.rem { return l.value * ctx.root_font_size }
		// The font-relative metrics CSS defines defaults for, taken from the CSS
		// Values and Units spec's own fallback table rather than measured from a
		// font. Measuring them needs the font layer and is Phase 2 work; these are
		// the numbers the spec says to assume, so a page lays out the same on a
		// machine with no fonts.
		.ex { return l.value * ctx.font_size * 0.5 }
		.ch { return l.value * ctx.font_size * 0.5 }
		.cap { return l.value * ctx.font_size * 0.7 }
		.ic { return l.value * ctx.font_size * 1.0 }
		.lh { return l.value * ctx.font_size * 1.2 }
		.rlh { return l.value * ctx.root_font_size * 1.2 }
		.vw { return l.value * ctx.viewport_width / 100.0 }
		.vh { return l.value * ctx.viewport_height / 100.0 }
		.vmin { return l.value * min_of(ctx.viewport_width, ctx.viewport_height) / 100.0 }
		.vmax { return l.value * max_of(ctx.viewport_width, ctx.viewport_height) / 100.0 }
		.vb, .vi { return l.value * ctx.viewport_height / 100.0 }
		.percent { return l.value * percent_basis / 100.0 }
	}
}

// is_auto reports whether the property sizes this box itself, which is not the
// same as a length of zero: `width: auto` for a block fills the containing block,
// and `width: 0` does not.
pub fn (l Length) is_auto() bool {
	return l.unit == .auto
}

// is_percent reports whether this length is relative to something layout knows.
pub fn (l Length) is_percent() bool {
	return l.unit == .percent
}

fn min_of(a f64, b f64) f64 {
	return if a < b { a } else { b }
}

fn max_of(a f64, b f64) f64 {
	return if a > b { a } else { b }
}

// keyword_lengths maps the CSS keywords that stand for lengths. They are absolute,
// which is why they need no context.
pub fn keyword_length(word string) ?Length {
	return match word {
		'thin' { Length{ value: 1.0, unit: .px } }
		'medium' { Length{ value: 3.0, unit: .px } }
		'thick' { Length{ value: 5.0, unit: .px } }
		'xx-small' { Length{ value: 56.0, unit: .pt } }
		'x-small' { Length{ value: 60.0, unit: .pt } }
		'small' { Length{ value: 66.0, unit: .pt } }
		'medium-size' { Length{ value: 72.0, unit: .pt } }
		'large' { Length{ value: 82.0, unit: .pt } }
		'x-large' { Length{ value: 94.0, unit: .pt } }
		'xx-large' { Length{ value: 106.0, unit: .pt } }
		'xxx-large' { Length{ value: 118.0, unit: .pt } }
		else { return none }
	}
}

// unit_from_string maps a unit as written to its Unit. Case is the author's:
// `PX` and `px` are the same unit, and CSS is case-insensitive for them.
pub fn unit_from_string(s string) Unit {
	return match s.to_lower() {
		'' { .px }
		'px' { .px }
		'pt' { .pt }
		'pc' { .pc }
		'in' { .in }
		'cm' { .cm }
		'mm' { .mm }
		'q' { .q }
		'em' { .em }
		'rem' { .rem }
		'ex' { .ex }
		'ch' { .ch }
		'cap' { .cap }
		'ic' { .ic }
		'lh' { .lh }
		'rlh' { .rlh }
		'vw' { .vw }
		'vh' { .vh }
		'vmin' { .vmin }
		'vmax' { .vmax }
		'vb' { .vb }
		'vi' { .vi }
		'%' { .percent }
		else { .none }
	}
}
