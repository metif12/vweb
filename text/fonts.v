module text

// Loading fonts and matching CSS families to concrete files.
//
// vtext does codepoint fallback within a FontSet; this module does family
// fallback, which is a different question: given `font-family: Tahoma, sans-serif`
// and `font-weight: 700`, which file do we open, and what happens when the first
// family in the list is not installed.
//
// Weight and italic are matched against the face rather than assumed. A page
// that asks for 700 and gets the regular face renders visibly lighter than
// intended, and the difference is easiest to see in Persian where the bold face
// often has different proportions as well as thicker strokes.

import os
import vtext

// A generic CSS family keyword. A family list that exhausts without a match
// lands on one of these rather than failing.
pub enum Generic {
	sans
	serif
	monospace
	cursive
	fantasy
}

// Font face files, by base name rather than by full path.
//
// Full paths are deliberately not baked in here. A golden-image test has to be
// reproducible on a machine that has never had this browser installed, so the
// fonts it uses have to be ones the repository ships, and that means the search
// directory cannot be a compile-time constant. The library holds the directories;
// this list holds the names to look for in them.
//
// The order within each list matters more than the individual choices: a page
// that gets a serif where it asked for sans-serif is a font stack bug, not a
// missing font.

pub const sans_faces = ['segoeui.ttf', 'arial.ttf', 'tahoma.ttf', 'verdana.ttf']
pub const sans_bold_faces = ['segoeuib.ttf', 'arialbd.ttf', 'tahomabd.ttf', 'verdanab.ttf']
pub const serif_faces = ['georgia.ttf', 'times.ttf', 'cambria.ttf', 'constantia.ttf']
pub const serif_bold_faces = ['georgiab.ttf', 'timesbd.ttf', 'cambriab.ttf', 'constanb.ttf']
pub const mono_faces = ['consola.ttf', 'cour.ttf']
pub const mono_bold_faces = ['consolab.ttf', 'courbd.ttf']

// Arabic-script fallbacks. Segoe UI covers Arabic on Windows, but a page that
// explicitly asks for a Latin-only family, or a host with different fonts
// installed, will not have it — and a missing Arabic face shows up as boxes in
// exactly the content this browser is built for.
pub const arabic_faces = ['segoeui.ttf', 'tahoma.ttf', 'arial.ttf', 'times.ttf']
pub const arabic_bold_faces = ['segoeuib.ttf', 'tahomabd.ttf', 'arialbd.ttf', 'timesbd.ttf']

// search_dirs is where system fonts are looked for, in order. This is the
// default; FontLibrary holds its own copy so a test can point it elsewhere.
pub const default_search_dirs = ['C:/Windows/Fonts', '/usr/share/fonts', '/usr/local/share/fonts',
	'/System/Library/Fonts', '/Library/Fonts']

// LoadedFont is a font file that was successfully opened, with the id used in
// GlyphKey.
pub struct LoadedFont {
pub:
	id   int
	path string
pub mut:
	font &vtext.Font
}

// FontLibrary holds every font the engine has opened, and hands out ids.
@[heap]
pub struct FontLibrary {
pub mut:
	ctx     &vtext.Context
	entries []LoadedFont
	by_path map[string]int
	// search_dirs is where font files are looked for. A test replaces it, or
	// sets it to a directory that does not exist, to make resolution fail or
	// succeed deterministically instead of depending on what the host has
	// installed.
	search_dirs []string
	// One cache for the whole library, not one per font set, so a glyph drawn by
	// two different rules is rasterized once.
	cache &GlyphCache
	// The Arabic fallback chain, shared across styles. Splitting it by weight
	// matters: a bold Arabic face has to come from the bold candidates or every
	// Persian heading renders regular while its Latin heading is bold.
	arabic_chain &vtext.FontSet
}

pub fn new_font_library() &FontLibrary {
	return &FontLibrary{
		ctx:          vtext.new_context()
		entries:      []LoadedFont{}
		by_path:      map[string]int{}
		search_dirs:  default_search_dirs.clone()
		cache:        new_glyph_cache()
		arabic_chain: vtext.new_font_set()
	}
}

// use_only_from points the library at one directory and forgets what it had
// loaded. This is how a golden-image test makes itself reproducible: vendored
// fonts in, host fonts out.
pub fn (mut lib FontLibrary) use_only_from(dir string) {
	lib.search_dirs = [dir]
	lib.clear()
}

// clear drops every loaded font and empties the caches, so a different set of
// search directories can be used from a clean state.
pub fn (mut lib FontLibrary) clear() {
	lib.entries = []LoadedFont{}
	lib.by_path = map[string]int{}
	lib.arabic_chain = vtext.new_font_set()
	lib.cache.clear()
}

// find_face resolves a base name to a full path in the first search directory
// that has it, preferring an earlier directory over a better-named file in a
// later one. That is what lets a vendored `segoeui.ttf` override the system one.
pub fn (lib &FontLibrary) find_face(base string) string {
	for dir in lib.search_dirs {
		p := os.join_path(dir, base)
		if os.exists(p) {
			return p
		}
	}
	return ''
}

// add opens a font file, or returns the id of an already-open one. A path that
// does not exist yields -1 rather than an error, because a family list is a
// suggestion and a missing font is normal rather than exceptional.
pub fn (mut lib FontLibrary) add(path string) int {
	if existing := lib.by_path[path] {
		return existing
	}
	if !os.exists(path) {
		return -1
	}
	f := vtext.load_font_file(path) or {
		return -1
	}
	id := lib.entries.len
	lib.entries << LoadedFont{
		id:   id
		path: path
		font: f
	}
	lib.by_path[path] = id
	return id
}

// open_first opens the first path in a candidate list that exists. This is how a
// face for one style is found: the answer is "the best one available", not "the
// first one named".
pub fn (mut lib FontLibrary) open_first(paths []string) int {
	for p in paths {
		id := lib.add(p)
		if id >= 0 {
			return id
		}
	}
	return -1
}

pub fn (lib &FontLibrary) get(id int) ?&LoadedFont {
	if id < 0 || id >= lib.entries.len {
		return none
	}
	return lib.entries[id]
}

pub fn (lib &FontLibrary) len() int {
	return lib.entries.len
}

// faces_for maps a generic family and a weight onto a list of candidate base
// names. Bold starts at 600, which is where CSS puts the bold threshold, so a
// weight of 600 must not render regular.
//
// Italic is accepted and ignored. There are no italic candidates in the lists
// above yet, so the upright face is the only useful answer: an upright glyph is
// readable and a blank is not. Adding italics means adding the candidate names,
// not changing this function.
pub fn faces_for(generic Generic, weight int, italic bool) []string {
	_ := italic
	bold := weight >= 600
	return match generic {
		.serif {
			if bold { serif_bold_faces } else { serif_faces }
		}
		.monospace {
			if bold { mono_bold_faces } else { mono_faces }
		}
		else {
			if bold { sans_bold_faces } else { sans_faces }
		}
	}
}

pub fn arabic_faces_for(weight int) []string {
	return if weight >= 600 { arabic_bold_faces } else { arabic_faces }
}

// open_face opens the first candidate base name that resolves to a file. This is
// how a face for one style is found: the answer is "the best one available", not
// "the first one named".
pub fn (mut lib FontLibrary) open_face(names []string) int {
	for base in names {
		p := lib.find_face(base)
		if p != '' {
			id := lib.add(p)
			if id >= 0 {
				return id
			}
		}
	}
	return -1
}

// font_set_for builds the fallback chain a style should shape against: the
// chosen face first, then the Arabic chain behind it so a Latin-only primary
// still renders Persian. `new_script_font_set` rather than `new_font_set` is
// what makes this work: a flat chain would give the Latin face precedence for
// the Persian word in a mixed line.
pub fn (mut lib FontLibrary) font_set_for(primary_id int) &vtext.FontSet {
	if primary_id < 0 || primary_id >= lib.entries.len {
		return lib.arabic_chain
	}
	primary := lib.entries[primary_id].font
	fs := vtext.new_script_font_set(primary, primary)
	for i in lib.arabic_chain.fonts {
		fs.add(i)
	}
	return fs
}

// ensure_arabic_chain fills the shared Arabic fallback set once, at the weight
// the page asked for. It is a no-op after the first call so the chain does not
// grow without bound over a long session; a page that mixes bold and regular
// Persian therefore gets the chain built for whichever it used first, which is a
// real limitation and is recorded in PHASES.md rather than papered over.
pub fn (mut lib FontLibrary) ensure_arabic_chain(weight int) {
	if lib.arabic_chain.len() > 0 {
		return
	}
	for base in arabic_faces_for(weight) {
		p := lib.find_face(base)
		if p == '' {
			continue
		}
		id := lib.add(p)
		if id >= 0 {
			lib.arabic_chain.add(lib.entries[id].font)
		}
	}
}
