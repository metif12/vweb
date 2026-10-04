module loader

import net.http
import os

// Turning a URL into bytes.
//
// This is the thinnest possible layer and it is meant to stay that way. The engine
// does not know about URLs, and the engine does not open sockets; what it asks for is
// "these bytes, and what they are", and this module is the only place that has an
// opinion about how they arrive.
//
// Three decisions are worth stating.
//
// A `Resource` carries the bytes *and* the media type, because the second is what the
// consumer needs and recomputing it from the URL at the point of use is how two
// consumers end up disagreeing about the same file.
//
// The media type comes from the file extension, never from a server's `Content-Type`.
// A server is a remote party and its answer for a local file is a guess; for a remote
// file its answer is authoritative and is checked in `from_response`. Doing it this way
// round means a page renders the same whether it was opened from disk or over HTTP.
//
// Relative URLs resolve against a base directory the caller sets, once, and not
// against the process's working directory. A renderer whose file URLs depend on where
// it happened to be launched is not testable.

// Resource is one fetched thing: where it came from, what it is, and its bytes.
@[heap]
pub struct Resource {
pub mut:
	// url is the URL as resolved, after redirects, so that a caller can report it and a
	// relative URL inside it can be resolved against it in turn.
	url string
	// body is never copied. A caller that keeps a Resource keeps the whole file, which is
	// what a parser wants and what copying a 2 MB script would double.
	body []u8
	mime string
}

// Loader resolves and fetches URLs. One per document, because it holds the base the
// document's relative URLs resolve against.
@[heap]
pub struct Loader {
pub mut:
	// base is a directory, with a trailing separator or not; both are accepted.
	base string
	// allow_insecure permits http:// for a document that was itself loaded over
	// https://. It is a field rather than a policy because Phase 1 has no https
	// document to be inconsistent with, and a decision made here with no consequence
	// is a decision made twice later.
	allow_insecure bool = true
}

// load resolves a URL and fetches it.
pub fn (mut l Loader) load(url string) !Resource {
	target := l.resolve(url) or { return err }
	if target.starts_with('http://') || target.starts_with('https://') {
		return l.from_http(target)!
	}
	return from_file(target)!
}

// load_text fetches and decodes as UTF-8, with a byte order mark removed.
//
// The mark matters more than it looks: a stylesheet saved by a Windows editor starts
// with three bytes that are not whitespace, and the CSS tokenizer rejects the first
// selector. Stripping it here means no consumer has to know.
pub fn (mut l Loader) load_text(url string) !string {
	r := l.load(url)!
	return decode_utf8(r.body)
}

// resolve turns a possibly-relative URL into an absolute one, or fails with the reason.
//
// It is public because a caller holding a base needs to resolve a URL it will fetch
// later -- a `<link href>` recorded during a scan, say -- and resolving it twice is how
// a relative path ends up based on the wrong document.
pub fn (l &Loader) resolve(url string) !string {
	if url.len == 0 {
		return error('empty url')
	}
	if url.starts_with('http://') || url.starts_with('https://') {
		return url
	}
	if url.starts_with('data:') {
		return error('data: urls are not supported')
	}
	if url.starts_with('file://') {
		return from_file_url(url)!
	}
	if scheme_of(url) != '' {
		return error('unsupported url scheme `' + scheme_of(url) + '` in `' + url + '`')
	}
	if is_absolute(url) {
		return url.replace('\\', '/')
	}
	if l.base == '' {
		return error('relative url `' + url + '` with no base directory')
	}
	// The base's separators are normalised here rather than trusted: a base handed in
	// from a Windows path is as likely to carry a backslash as not, and `C:\site` plus
	// `/` is a path that works but reads like a typo in every message it appears in.
	mut base := l.base.replace('\\', '/')
	if !base.ends_with('/') {
		base += '/'
	}
	return base + url
}

fn (mut l Loader) from_http(url string) !Resource {
	if url.starts_with('http://') && !l.allow_insecure {
		return error('refusing an insecure url for a secure document: ' + url)
	}
	resp := http.get(url)!
	if resp.status_code != 200 {
		return error('http ' + resp.status_code.str() + ' for ' + url)
	}
	// Response.body is a string in vlib, not bytes, so the conversion is here rather
	// than at every use.
	mut r := Resource{ url: url, body: resp.body.bytes(), mime: mime_for(url) }
	// A server that says what it is, is believed. The extension is only a fallback for
	// the file: scheme, where there is no server to ask. An if-guard cannot be used
	// here: it needs an Option, and or { '' } yields a plain string.
	// Header.get takes a CommonHeader enum, not a string; the string-keyed form is
	// get_custom, which also wants a config. Content-Type is the one header this module
	// reads, so it is asked for by name rather than by scanning the map.
	ct := resp.header.get(.content_type) or { '' }
	if ct != '' {
		base := ct.split(';')[0].trim_space()
		if base != '' {
			r.mime = base.to_lower()
		}
	}
	if r.mime == '' {
		r.mime = 'application/octet-stream'
	}
	return r
}

fn from_file(path string) !Resource {
	// os.read_file returns a string in this V; Resource holds bytes so that a caller
	// can hand the same buffer to a decoder without a second conversion.
	body := os.read_file(path) or { return err }
	return Resource{ url: path, body: body.bytes(), mime: mime_for(path) }
}

// from_file_url turns a `file://` URL into a path.
//
// The awkward part is Windows, where the canonical form is `file:///C:/dir/page.html`
// -- three slashes, then a drive letter -- and dropping the leading slash gives a
// relative path. Both that and the two-slash form are accepted, and the result is
// returned with forward slashes, which every Windows API V exposes accepts.
fn from_file_url(url string) !string {
	mut rest := url[7..]
	b := rest.bytes()
	if rest.starts_with('/') && b.len > 2 && b[2] == b_colon {
		rest = rest[1..]
	}
	if rest == '' {
		return error('file url with no path: ' + url)
	}
	return percent_decode(rest)
}

// Byte values for the characters this module tests for.
//
// They are spelled as numbers because a one-character literal is typed as a `string` by
// this V build, and comparing one with a `u8` -- which is what every check below is --
// does not compile: "cannot use `string` as `u8`". `engine/loader` is the only place in
// the project that inspects bytes rather than text, so this is cheaper than changing
// how the rest of it compares characters.
const b_slash = u8(47)
const b_0 = u8(48)
const b_9 = u8(57)
const b_colon = u8(58)
const b_upper_a = u8(65)
const b_upper_c = u8(67)
const b_upper_z = u8(90)
const b_a = u8(97)
const b_c = u8(99)
const b_plus = u8(43)
const b_minus = u8(45)
const b_dot = u8(46)
const b_z = u8(122)
const b_percent = u8(37)

// is_scheme_byte reports whether a byte may appear in a URL scheme: ALPHA / DIGIT /
// "+" / "-" / "." from RFC 3986.
fn is_scheme_byte(c u8) bool {
	return (c >= b_a && c <= b_z) || (c >= b_upper_a && c <= b_upper_z)
		|| (c >= b_0 && c <= b_9) || c == b_plus || c == b_minus || c == b_dot
}

// scheme_of returns the lowercase scheme of a URL, or '' when it has none.
//
// It works on bytes rather than on `url[i]`, because in V 0.5.2 indexing a string
// yields a one-character *string*.
fn scheme_of(url string) string {
	b := url.bytes()
	mut colon := -1
	mut i := 0
	for i < b.len {
		if b[i] == b_colon {
			colon = i
			break
		}
		i++
	}
	if colon <= 0 {
		return ''
	}
	// A Windows drive letter is a path, not a scheme: without this every absolute path
	// on this platform is reported as an unknown scheme.
	if colon == 1 && (b[0] == b_upper_c || b[0] == b_c) {
		return ''
	}
	i = 0
	for i < colon {
		if !is_scheme_byte(b[i]) {
			return ''
		}
		i++
	}
	return url[..colon].to_lower()
}

// is_absolute reports whether a path names a location rather than a file to look for
// next to the base.
//
// The drive letter is two bytes: `b[0]` is the letter and `b[1]` is the colon. An
// earlier version checked `b[2]`, which is the separator *after* the colon, so every
// Windows path came back relative and got concatenated onto the base. The test for an
// absolute path caught it; the drive-letter case in scheme_of did not, because that one
// counts the colon's position properly.
fn is_absolute(path string) bool {
	b := path.bytes()
	if b.len >= 3 && b[1] == b_colon && (b[0] == b_upper_c || b[0] == b_c) {
		return true
	}
	return path.starts_with('/')
}

// percent_decode expands %XX. A URL that reaches this module has usually been through
// a parser that already decoded it once, so a stray `%` that is not followed by two hex
// digits is left exactly as it was rather than being treated as an error: a file whose
// name really does contain a percent sign is more likely than a malformed escape, and
// refusing to load it would be the surprising outcome.
fn percent_decode(s string) string {
	mut out := []u8{}
	mut i := 0
	for i < s.len {
		if s[i] == b_percent && i + 2 < s.len {
			if hi := hex_value(s[i + 1]) {
				if lo := hex_value(s[i + 2]) {
					out << u8(hi << 4 | lo)
					i += 3
					continue
				}
			}
		}
		out << s[i]
		i++
	}
	return out.bytestr()
}

// hex_value is the value of one hex digit, or an error. 0-9 are their own values, a-f
// and A-F are ten more.
//
// Written as an if chain rather than a `match` on ranges because the range arm wants
// character literals, which this V build types as strings; see the byte constants above.
fn hex_value(c u8) !int {
	if c >= b_0 && c <= b_9 {
		return int(c - b_0)
	}
	if c >= b_a && c <= u8(102) {
		return int(c - b_a) + 10
	}
	if c >= b_upper_a && c <= u8(70) {
		return int(c - b_upper_a) + 10
	}
	return error('not hex')
}

// decode_utf8 turns bytes into a string and removes a byte order mark.
//
// `bytestr()` rather than `str()`: the bytes come from a file and are not known to be
// valid UTF-8 until they have been checked, and V's conversion is the one that can
// fail. A file that is not UTF-8 is an error here rather than a page of replacement
// characters, because a stylesheet that silently decodes wrong is a bug that surfaces
// as an unrelated-looking one.
fn decode_utf8(body []u8) !string {
	if body.len >= 3 && body[0] == 0xef && body[1] == 0xbb && body[2] == 0xbf {
		return body[3..].bytestr()
	}
	return body.bytestr()
}

// media_types is the extension table, and it is a table rather than a chain of `ends_with`
// calls for the reason the CSS side has one: a chain is a hundred comparisons and no way
// to see what is in it.
//
// Only types the engine can act on are listed. A `.woff` or `.otf` is absent on purpose
// rather than mapped to something approximate; a font the engine cannot read should be
// refused, and refusing it later with a real message beats serving it as something it
// is not.
const media_types = {
	'html':  'text/html'
	'htm':   'text/html'
	'css':   'text/css'
	'js':    'text/javascript'
	'mjs':   'text/javascript'
	'json':  'application/json'
	'txt':   'text/plain'
	'png':   'image/png'
	'jpg':   'image/jpeg'
	'jpeg':  'image/jpeg'
	'gif':   'image/gif'
	'svg':   'image/svg+xml'
	'webp':  'image/webp'
	'ico':   'image/x-icon'
	'wasm':  'application/wasm'
	'ttf':   'font/ttf'
	'woff2': 'font/woff2'
}

// mime_for guesses a media type from a path's extension.
pub fn mime_for(path string) string {
	b := path.bytes()
	// Scanned backwards rather than with `last_index_of`, which this V's string does
	// not have. The last dot only counts if it is after the last separator: a dot in a
	// directory name is not an extension, and `/a.b/page` has none.
	mut dot := -1
	mut i := b.len - 1
	for i >= 0 {
		if b[i] == b_dot {
			dot = i
			break
		}
		if b[i] == b_slash || b[i] == u8(92) {
			break
		}
		i--
	}
	if dot < 0 || dot == b.len - 1 {
		return 'application/octet-stream'
	}
	ext := path[dot + 1..].to_lower()
	return media_types[ext] or { 'application/octet-stream' }
}
