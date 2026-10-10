// persian -- render a right-to-left page.
//
//	v run examples/persian [out.png]
//
// This is the example that matters most, because it is the reason the project exists.
// Everything else in examples/ shows a CSS feature; this one shows the pipeline handling
// text whose direction, word order and script are all different from what the layout
// engine was built around.
//
// What it demonstrates, and what it therefore also asserts:
//
//   - Persian shapes through the Arabic fallback chain, so the Latin body face does not
//     have to cover it.
//   - `direction: rtl` is inherited and reaches the computed style, and `layout_runs`
//     lays the line out from the box's right edge: a line shorter than its box sits
//     flush right, the first character of the string is the rightmost glyph, and an
//     atomic inline-level box is placed by the same pen.
//   - The line breaker treats a Persian word as one unbreakable unit, which is what
//     makes a narrow column of Persian text come out ragged rather than hyphenated.
//
// What it does not yet demonstrate, stated here so a reader is not misled: there is no
// bidi algorithm, so a line has one direction -- its box's -- and a Latin word inside a
// Persian sentence is drawn in its own order but not reordered relative to the Persian
// runs around it. There is also no `text-align`, so a short line can only be flush
// right. Both are Phase 3's work.
//
// The Arabic fallback chain works. `font_set_for` (text/fonts.v:243) builds a flat chain with the
// primary first and the Arabic faces behind it, so a Persian run whose primary face has no Arabic
// reaches them. `sans-serif` below is a choice rather than a workaround: on Windows it resolves to a
// face that covers Arabic, which answers Latin and Persian from one file and keeps the page to one
// face. `serif` or `monospace` would draw the Latin in Georgia or Consolas and the Persian in
// whatever the Arabic chain found.

import engine.page
import os

const source = '<!DOCTYPE html>
<html>
<head>
<style>
  body { font-family: sans-serif; direction: rtl; color: #1b1b1b; }
  h1 { color: #0b5d3b; font-size: 1.6em; }
  .note { background-color: #eef7f1; border-right: 4px solid #0b5d3b; padding: 10px 14px; }
</style>
</head>
<body>
<h1>یک صفحهٔ فارسی</h1>
<p>این متن فارسی است و باید با جهت راست به چپ و با شکل‌دهی درست نوشته شود.</p>
<div class="note">حاشیهٔ راست این کادر باید سمت راست باشد.</div>
<p>Mixed content: متن فارسی با a few English words در میانه.</p>
</body>
</html>
'

fn main() {
	mut out := 'examples/persian/out.png'
	if os.args.len > 1 {
		out = os.args[1]
	}
	opts := page.Options{ width: 640, height: 420 }
	page.render_to_png(source, out, opts) or {
		eprintln('persian: ' + err.msg())
		exit(1)
	}
	println('wrote ' + out)
}
