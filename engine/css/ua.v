module css

// The user-agent stylesheet: the default styling a browser applies before any
// author CSS exists.
//
// It is a plain string, not a parsed value, so the engine has no global state to
// initialise and a test can compare the source. The style layer parses it once at
// startup, exactly as it parses an author's stylesheet, which means a bug in the
// tokenizer or parser shows up in the UA sheet too rather than hiding in it.
//
// The defaults follow the HTML standard's rendering section, not any particular
// browser. `display` is the only property listed exhaustively: everything that
// should be inline is left alone, because the initial value of `display` is
// inline and writing it out would double the size of the sheet for no effect. The
// properties that appear are the ones engine/style computes values for, so
// nothing here is a promise about behaviour that does not exist yet.

// The table display types of CSS 2.1 section 17. They are listed here rather than left
// to the initial value because a `<tbody>` with `display: none` drops every row in it,
// which is what this sheet used to do: the table parts were blocks and the containers
// were none, and a table rendered as a stack of stray cells. `col` and `colgroup` accept
// their own display values but generate no box this engine lays out -- the column widths
// come from the cells, which is where CSS 2.1's own table puts them when a stylesheet
// has no `<col>` elements.

pub const user_agent_css = 'html, body, div, p, h1, h2, h3, h4, h5, h6, section, article,\n' +
	'header, footer, nav, aside, main, figure, figcaption, blockquote, pre, hr, form,\n' +
	'fieldset, address, dl, dt, dd, ol, ul, li, details, summary,\n' +
	'noscript, legend {\n' +
	'  display: block;\n' +
	'}\n' +
	'table { display: table; border-spacing: 2px; }\n' +
	'thead { display: table-header-group; }\n' +
	'tbody { display: table-row-group; }\n' +
	'tfoot { display: table-footer-group; }\n' +
	'tr { display: table-row; }\n' +
	'th, td { display: table-cell; }\n' +
	'caption { display: table-caption; }\n' +
	'colgroup { display: table-column-group; }\n' +
	'col { display: table-column; }\n' +
	'head, link, meta, script, style, title, base, param, area, track, source,\n' +
	'datalist, template {\n' +
	'  display: none;\n' +
	'}\n' +
	'body { margin: 8px; }\n' +
	'p { margin: 1em 0; }\n' +
	'h1 { font-size: 2em; font-weight: bold; margin: 0.67em 0; }\n' +
	'h2 { font-size: 1.5em; font-weight: bold; margin: 0.83em 0; }\n' +
	'h3 { font-size: 1.17em; font-weight: bold; margin: 1em 0; }\n' +
	'h4 { font-weight: bold; margin: 1.33em 0; }\n' +
	'h5 { font-size: 0.83em; font-weight: bold; margin: 1.67em 0; }\n' +
	'h6 { font-size: 0.67em; font-weight: bold; margin: 2.33em 0; }\n' +
	'blockquote { margin: 1em 40px; }\n' +
	'figure { margin: 1em 40px; }\n' +
	'ul, ol { margin: 1em 0; padding-left: 40px; }\n' +
	'ul { list-style-type: disc; }\n' +
	'ol { list-style-type: decimal; }\n' +
	'dl { margin: 1em 0; }\n' +
	'dd { margin-left: 40px; }\n' +
	'pre { font-family: monospace; white-space: pre; margin: 1em 0; }\n' +
	'code, kbd, samp, tt { font-family: monospace; }\n' +
	'hr { border-style: inset; border-width: 1px; margin: 0.5em 0; }\n' +
	'b, strong, th { font-weight: bold; }\n' +
	'i, em, cite, var, dfn, address { font-style: italic; }\n' +
	'u, ins { text-decoration: underline; }\n' +
	's, strike, del { text-decoration: line-through; }\n' +
	'small { font-size: 0.83em; }\n' +
	'big { font-size: 1.17em; }\n' +
	'sub { font-size: 0.83em; vertical-align: sub; }\n' +
	'sup { font-size: 0.83em; vertical-align: super; }\n' +
	'a { color: #0000ee; text-decoration: underline; }\n' +
	'center { display: block; text-align: center; }\n' +
	'legend { padding: 0 2px; }\n' +
	'fieldset { margin: 0 2px; padding: 0.35em 0.75em 0.625em; border: 2px groove; }\n' +
	'button, input, select, textarea { font-size: 0.83em; }\n' +
	'textarea { white-space: pre-wrap; }\n'
