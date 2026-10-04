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
//   - `direction: rtl` is inherited and reaches the computed style. In Phase 1 it does
//     not move a box: the box tree is laid out left to right and paint is what aligns
//     the run, so the *glyph order* is right while the *box* is not yet mirrored.
//   - The line breaker treats a Persian word as one unbreakable unit, which is what
//     makes a narrow column of Persian text come out ragged rather than hyphenated.
//
// What it does not yet demonstrate, stated here so a reader is not misled: the page is
// laid out as if it were left-to-right, so the right margin will look like a left one.
// Fixing that is paint's half of the work and it is not done.

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
