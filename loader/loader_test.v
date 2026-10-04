module loader

import os

// The tests build a real directory and read real files. A loader is the one place
// where mocking the filesystem would test the mock: `os.read_file` returning what the
// test told it to is not evidence that the path was assembled correctly, and path
// assembly is the whole of what can go wrong here.
//
// No test touches the network. `from_http` needs a server, and a test that needs a
// server is a test that fails for a reason that has nothing to do with the code.

fn fixture_dir() string {
	dir := os.vtmp_dir() + '@loader_test'
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn write_file(dir string, name string, body string) string {
	path := dir + '/' + name
	os.write_file(path, body) or { panic(err) }
	return path
}

// --- resolving --------------------------------------------------------------

fn test_an_absolute_path_resolves_to_itself() {
	l := Loader{ base: 'C:/somewhere' }
	assert l.resolve('C:/other/page.html')! == 'C:/other/page.html'
}

fn test_a_relative_path_resolves_against_the_base() {
	l := Loader{ base: 'C:/site' }
	assert l.resolve('css/main.css')! == 'C:/site/css/main.css'
}

fn test_a_base_with_a_trailing_separator_does_not_gain_a_second_one() {
	l := Loader{ base: 'C:/site/' }
	assert l.resolve('main.css')! == 'C:/site/main.css'
}

fn test_a_base_with_a_backslash_is_accepted() {
	// A base handed to us from a Windows path is as likely to carry a backslash as not.
	l := Loader{ base: 'C:\\site' }
	assert l.resolve('main.css')! == 'C:/site/main.css'
}

fn test_a_relative_path_with_no_base_is_an_error() {
	// Silently resolving against the process's working directory is how a renderer
	// becomes untestable, so this is refused rather than guessed.
	l := Loader{}
	if _ := l.resolve('main.css') {
		assert false, 'expected an error for a relative url with no base'
	}
}

fn test_an_http_url_is_left_alone() {
	l := Loader{ base: 'C:/site' }
	assert l.resolve('http://example.com/a.css')! == 'http://example.com/a.css'
	assert l.resolve('https://example.com/a.css')! == 'https://example.com/a.css'
}

fn test_an_unknown_scheme_is_refused_by_name() {
	// The message has to name the scheme: "unsupported url" on a page with eleven of
	// them is not a diagnostic.
	l := Loader{ base: 'C:/site' }
	res := l.resolve('ftp://example.com/a.css') or { 'ftp' }
	assert res.contains('ftp')
}

fn test_a_data_url_is_refused_by_name() {
	l := Loader{}
	res := l.resolve('data:text/plain,hello') or { 'data' }
	assert res == 'data'
}

fn test_an_empty_url_is_refused() {
	l := Loader{ base: 'C:/site' }
	res := l.resolve('') or { 'empty' }
	assert res == 'empty'
}

fn test_a_windows_drive_letter_is_not_a_scheme() {
	// `C:/page.html` is a path, not a `c` scheme. Getting this wrong makes every
	// absolute path on Windows an unknown scheme.
	l := Loader{}
	assert l.resolve('C:/page.html')! == 'C:/page.html'
}

// --- file urls --------------------------------------------------------------

fn test_a_file_url_with_three_slashes_loses_one_before_the_drive() {
	// The canonical Windows form is file:///C:/dir/page.html, and dropping the leading
	// slash of that gives a *relative* path that happens to start with a drive letter.
	res := from_file_url('file:///C:/dir/page.html') or { return }
	assert res == 'C:/dir/page.html'
}

fn test_a_file_url_with_two_slashes_keeps_its_path() {
	res := from_file_url('file://C:/dir/page.html') or { return }
	assert res == 'C:/dir/page.html'
}

fn test_a_posix_file_url_is_untouched() {
	res := from_file_url('file:///home/user/page.html') or { return }
	assert res == '/home/user/page.html'
}

fn test_a_file_url_with_no_path_is_refused() {
	if _ := from_file_url('file://') {
		assert false, 'expected an error for a file url with no path'
	}
}

fn test_percent_escapes_in_a_path_are_expanded() {
	res := from_file_url('file:///C:/my%20page.html') or { return }
	assert res == 'C:/my page.html'
}

fn test_a_percent_that_is_not_an_escape_is_left_alone() {
	// A file whose name really contains `%` is more likely than a malformed escape.
	res := from_file_url('file:///C:/100%.html') or { return }
	assert res == 'C:/100%.html'
}

fn test_a_lowercase_escape_is_expanded() {
	res := from_file_url('file:///C:/a%2fb') or { return }
	assert res == 'C:/a/b'
}

// --- media types ------------------------------------------------------------

fn test_a_known_extension_gives_its_type() {
	assert mime_for('page.html') == 'text/html'
	assert mime_for('main.css') == 'text/css'
	assert mime_for('logo.PNG') == 'image/png'
}

fn test_an_unknown_extension_is_octet_stream() {
	assert mime_for('archive.zip') == 'application/octet-stream'
}

fn test_no_extension_is_octet_stream() {
	assert mime_for('LICENSE') == 'application/octet-stream'
}

fn test_a_dot_in_a_directory_is_not_an_extension() {
	// `/a.b/page` has no extension. Reading one from the directory name is how a
	// versioned path turns into the wrong media type.
	assert mime_for('assets.v2/page') == 'application/octet-stream'
}

// --- loading ----------------------------------------------------------------

fn test_a_file_is_read_with_its_media_type() {
	dir := fixture_dir()
	path := write_file(dir, 'page.html', '<p>hello</p>')
	mut l := Loader{ base: dir }
	r := l.load(path)!
	assert r.mime == 'text/html'
	assert r.body == '<p>hello</p>'.bytes()
}

fn test_a_relative_url_loads_against_the_base() {
	dir := fixture_dir()
	write_file(dir, 'style.css', 'p { color: red }')
	mut l := Loader{ base: dir }
	r := l.load('style.css')!
	assert r.mime == 'text/css'
	assert decode_utf8(r.body)! == 'p { color: red }'
}

fn test_a_missing_file_is_an_error_and_not_a_panic() {
	// The engine asks for files a stylesheet names, and any of them may be absent. A
	// panic here would take down a render over a missing favicon.
	mut l := Loader{ base: fixture_dir() }
	if _ := l.load('definitely-not-here.css') {
		assert false, 'expected an error for a missing file'
	}
}

fn test_an_empty_file_loads_as_empty_rather_than_failing() {
	dir := fixture_dir()
	path := write_file(dir, 'empty.css', '')
	mut l := Loader{ base: dir }
	assert l.load(path)!.body.len == 0
}

fn test_text_decoding_strips_a_byte_order_mark() {
	// A stylesheet saved by a Windows editor starts with three bytes that are not
	// whitespace, and the CSS tokenizer rejects the first selector because of them.
	dir := fixture_dir()
	// Built as bytes and handed over as a string, because os.write_file takes a string
	// and the point of the fixture is the three bytes in front of the text.
	bom := '\uFEFFp'
	path := dir + '/bom.css'
	os.write_file(path, bom) or { panic(err) }
	mut l := Loader{ base: dir }
	assert l.load_text(path)! == 'p'
}

fn test_text_decoding_leaves_a_file_without_a_mark_alone() {
	dir := fixture_dir()
	path := write_file(dir, 'nobom.css', 'p { color: red }')
	mut l := Loader{ base: dir }
	assert l.load_text(path)! == 'p { color: red }'
}
