// browser -- a one-window sample browser for the vweb engine.
//
//	browser <url-or-path> [--width N] [--height N] [--shot out.png]
//
// What it is: the load/render path of cmd/vweb inside a real window -- the address comes
// from the argument, the page is rendered once to a canvas, and the canvas is shown in
// the window. The wheel and the arrow/PgUp/PgDn/Home/End keys scroll; Escape or q quits.
// It is Windows-only and deliberately so: the point is a window with the least new C,
// and that is Win32 plus GDI, both of which tcc already ships headers for.
//
// What it is not: a browser with tabs, navigation, an address bar, a scrollbar, HiDPI
// awareness, or a reflow on resize. Resizing the window shows more or less of the same
// render (the viewport is fixed at launch). The page is rendered once because the engine
// draws CPU-side and the window only presents; pages taller than `max_page_height` are
// cut, and that number is a limit of this sample rather than of the engine.
//
// Why GDI and not gg: this program must link the engine, and the engine links vtext,
// and vtext's C rasteriser and gg's fontstash both compile stb_truetype into the same
// translation unit V generates -- so a gg window and the engine cannot live in one
// binary. GDI needs no third-party C at all: a DIB section holds the pixels, and a
// blit shows them.
module main

#flag windows -lgdi32

import engine.page
import loader
import os

#include <windows.h>

type HWND = voidptr
type HDC = voidptr
type HGDIOBJ = voidptr
type HBITMAP = voidptr
type HINSTANCE = voidptr
type HMENU = voidptr
type HCURSOR = voidptr
type WPARAM = usize
type LPARAM = isize

struct WndClassA {
	style          u32
	wnd_proc       voidptr
	cls_extra      i32
	wnd_extra      i32
	instance       HINSTANCE
	icon           voidptr
	cursor         HCURSOR
	background     voidptr
	menu_name      &u8
	class_name     &u8
}

struct Point {
	x i32
	y i32
}

struct Msg {
	hwnd    HWND
	message u32
	wparam  WPARAM
	lparam  LPARAM
	time    u32
	pt      Point
}

struct Rect {
	left   i32
	top    i32
	right  i32
	bottom i32
}

struct PaintStruct {
	hdc          HDC
	erase        i32
	paint_rect   Rect
	restore      i32
	inc_update   i32
	reserved     [32]u8
}

struct BitmapInfoHeader {
	size          u32
	width         i32
	height        i32
	planes        u16
	bit_count     u16
	compression   u32
	size_image    u32
	x_pels_meter  i32
	y_pels_meter  i32
	clr_used      u32
	clr_important u32
}

struct BitmapInfo {
	header BitmapInfoHeader
	quad   u32
}

fn C.RegisterClassA(&WndClassA) u16
fn C.CreateWindowExA(u32, &u8, &u8, u32, i32, i32, i32, i32, HWND, HMENU, HINSTANCE, voidptr) HWND
fn C.ShowWindow(HWND, i32) bool
fn C.UpdateWindow(HWND) bool
fn C.GetMessageA(&Msg, HWND, u32, u32) int
fn C.TranslateMessage(&Msg) bool
fn C.DispatchMessageA(&Msg) isize
fn C.DefWindowProcA(HWND, u32, WPARAM, LPARAM) isize
fn C.PostQuitMessage(i32)
fn C.BeginPaint(HWND, &PaintStruct) HDC
fn C.EndPaint(HWND, &PaintStruct) bool
fn C.GetDC(HWND) HDC
fn C.ReleaseDC(HWND, HDC) i32
fn C.CreateCompatibleDC(HDC) HDC
fn C.CreateDIBSection(HDC, &BitmapInfo, u32, &voidptr, voidptr, u32) HBITMAP
fn C.SelectObject(HDC, HGDIOBJ) HGDIOBJ
fn C.DeleteDC(HDC) bool
fn C.DeleteObject(HGDIOBJ) bool
fn C.BitBlt(HDC, i32, i32, i32, i32, HDC, i32, i32, u32) bool
fn C.LoadCursorA(HINSTANCE, voidptr) HCURSOR
fn C.InvalidateRect(HWND, voidptr, bool) bool
fn C.SetWindowLongPtrA(HWND, i32, isize) isize
fn C.GetWindowLongPtrA(HWND, i32) isize
fn C.GetLastError() u32
fn C.GetModuleHandleW(&u16) HINSTANCE
fn C.GetClientRect(HWND, &Rect) bool

const ws_overlappedwindow = u32(0xCF0000)
const wm_paint = u32(15)
const wm_destroy = u32(2)
const wm_size = u32(5)
const wm_mousewheel = u32(0x20A)
const wm_keydown = u32(0x100)
const wm_erasebkgnd = u32(14)
const srccopy = u32(0xCC0020)
const bi_rgb = u32(0)
const dib_rgb_colors = u32(0)
const sw_shownormal = 1
const wheel_delta = 120

// gwlp_userdata is the window slot that carries this window's App. A Win32 window
// procedure receives no application pointer of its own, so the pointer is stored here
// right after the window is created, and every message reads it back. Messages that
// arrive before it is stored -- during CreateWindowEx itself -- find zero and fall
// through to DefWindowProcA, which is the documented answer for them.
const gwlp_userdata = -21

// App is everything one browser window owns: where it draws, what it shows, and how
// far down it has scrolled. One window means one App, and the window carries the
// pointer to it, so there is no global state to keep consistent.
struct App {
mut:
	hwnd   HWND
	memdc  HDC
	page_w int
	page_h int
	scroll int
}

fn app_of(hwnd HWND) &App {
	return unsafe { &App(voidptr(C.GetWindowLongPtrA(hwnd, gwlp_userdata))) }
}

// max_page_height is how tall the page bitmap may be, in CSS pixels. A 1024-wide page
// at this height is 37 MB of BGRA, which the process holds without noticing and which
// covers every page this browser was written to look at. A longer page is cut rather
// than scaled down, because a scaled-down page would lie about the layout it shows.
const max_page_height = 9000


// base_for is the loader's base for a target: the page's own directory for a path, and
// the URL up to its last slash for an http(s) address. Relative URLs resolve against
// where the page was found, and resolving them anywhere else makes the same page render
// differently depending on where the tool was run from.
fn base_for(target string) string {
	if target.starts_with('http://') || target.starts_with('https://') {
		return target.all_before_last('/') + '/'
	}
	return os.dir(target)
}

fn load_document(target string) &page.Document {
	mut ld := loader.Loader{ base: base_for(target) }
	doc := page.load(target, mut ld) or {
		eprintln('browser: ' + err.msg())
		exit(1)
	}
	for w in doc.warnings {
		eprintln('browser: ' + w)
	}
	return doc
}

// blit_paint copies a premultiplied-RGBA engine canvas into straight BGRA DIB memory:
// unpremultiplied, with the channels swapped, because a 32-bit BI_RGB DIB ignores its
// own alpha byte and whatever is stored in the colour bytes is what shows. A fully
// transparent page pixel would therefore show as black, so it is written as white --
// the page background this browser renders onto anyway.
fn blit_paint(dst &u8, src []u8, w int, h int) {
	mut o := 0
	n := w * h * 4
	for o < n {
		a := int(src[o + 3])
		if a == 0 {
			unsafe {
				dst[o] = u8(255)
				dst[o + 1] = u8(255)
				dst[o + 2] = u8(255)
				dst[o + 3] = u8(255)
			}
		} else if a == 255 {
			unsafe {
				dst[o] = src[o + 2]
				dst[o + 1] = src[o + 1]
				dst[o + 2] = src[o]
				dst[o + 3] = u8(255)
			}
		} else {
			unsafe {
				dst[o] = u8(int(src[o + 2]) * 255 / a)
				dst[o + 1] = u8(int(src[o + 1]) * 255 / a)
				dst[o + 2] = u8(int(src[o]) * 255 / a)
				dst[o + 3] = u8(255)
			}
		}
		o += 4
	}
}

fn (mut app App) clamp_scroll(win_h int) {
	if app.scroll < 0 {
		app.scroll = 0
	}
	mut top := app.page_h - win_h
	if top < 0 {
		top = 0
	}
	if app.scroll > top {
		app.scroll = top
	}
}

fn wndproc(hwnd HWND, msg u32, wp WPARAM, lp LPARAM) isize {
	if msg == wm_destroy {
		C.PostQuitMessage(0)
		return 0
	}
	if unsafe { app_of(hwnd) } == unsafe { nil } {
		return C.DefWindowProcA(hwnd, msg, wp, lp)
	}
	mut app := app_of(hwnd)
	if msg == wm_erasebkgnd {
		// The whole client area is covered by the blit below, so erasing it first only
		// flashes white.
		return 1
	}
	if msg == wm_size {
		C.InvalidateRect(hwnd, unsafe { nil }, true)
		return 0
	}
	if msg == wm_mousewheel {
		delta := int(i16(wp >> 16))
		app.scroll -= delta / wheel_delta * 40
		mut rc := Rect{}
		C.GetClientRect(hwnd, &rc)
		app.clamp_scroll(int(rc.bottom - rc.top))
		C.InvalidateRect(hwnd, unsafe { nil }, true)
		return 0
	}
	if msg == wm_keydown {
		key := int(wp)
		if key == 27 || key == 81 {
			C.PostQuitMessage(0)
			return 0
		}
		mut rc := Rect{}
		C.GetClientRect(hwnd, &rc)
		win_h := int(rc.bottom - rc.top)
		if key == 38 {
			app.scroll -= 40
		} else if key == 40 {
			app.scroll += 40
		} else if key == 33 {
			app.scroll -= win_h
		} else if key == 34 {
			app.scroll += win_h
		} else if key == 36 {
			app.scroll = 0
		} else if key == 35 {
			app.scroll = app.page_h
		}
		app.clamp_scroll(win_h)
		C.InvalidateRect(hwnd, unsafe { nil }, true)
		return 0
	}
	if msg == wm_paint {
		mut ps := PaintStruct{}
		hdc := C.BeginPaint(hwnd, &ps)
		mut rc := Rect{}
		C.GetClientRect(hwnd, &rc)
		mut w := int(rc.right - rc.left)
		mut h := int(rc.bottom - rc.top)
		if w > app.page_w {
			w = app.page_w
		}
		if h > app.page_h - app.scroll {
			h = app.page_h - app.scroll
		}
		if w > 0 && h > 0 {
			C.BitBlt(hdc, 0, 0, w, h, app.memdc, 0, app.scroll, srccopy)
		}
		C.EndPaint(hwnd, &ps)
		return 0
	}
	return C.DefWindowProcA(hwnd, msg, wp, lp)
}
fn usage() {
	eprintln('usage: browser <url-or-path> [--width N] [--height N] [--shot out.png]')
	eprintln('  shows the page in a window; the wheel and arrows scroll, Escape quits')
	eprintln('  --shot renders headlessly to a PNG and exits, for machines with no display')
	exit(1)
}

fn shot(target string, width int, height int, out string) {
	doc := load_document(target)
	canvas := page.render(doc, page.Options{ width: width, height: height })
	canvas.write_png(out) or {
		eprintln('browser: ' + err.msg())
		exit(1)
	}
	println('wrote ' + out)
}

fn main() {
	args := os.args[1..]
	if args.len == 0 {
		usage()
	}
	mut target := ''
	mut width := 1024
	mut height := 768
	mut shot_out := ''
	mut i := 0
	for i < args.len {
		match args[i] {
			'--width' {
				width = args[i + 1].int()
				i += 2
				continue
			}
			'--height' {
				height = args[i + 1].int()
				i += 2
				continue
			}
			'--shot' {
				shot_out = args[i + 1]
				i += 2
				continue
			}
			else {
				if target != '' {
					eprintln('browser: unexpected argument ' + args[i])
					exit(1)
				}
				target = args[i]
				i++
				continue
			}
		}
		break
	}
	if target == '' {
		usage()
	}
	if shot_out != '' {
		shot(target, width, height, shot_out)
		return
	}
	doc := load_document(target)
	mut app := &App{
		hwnd:   unsafe { nil }
		memdc:  unsafe { nil }
		page_w: width
		page_h: max_page_height
		scroll: 0
	}
	canvas := page.render(doc, page.Options{ width: width, height: max_page_height })
	// A null instance: the class name below is unique to this process, so the class
	// lookup by name succeeds, and a failure here is a clean error rather than a crash.
	inst := C.GetModuleHandleW(unsafe { nil })
	class_name := 'vweb_browser'
	mut wc := WndClassA{
		style:       0
		wnd_proc:    wndproc
		cls_extra:   0
		wnd_extra:   0
		instance:    inst
		icon:        unsafe { nil }
		cursor:      C.LoadCursorA(unsafe { nil }, voidptr(32512))
		background:  unsafe { nil }
		menu_name:   unsafe { nil }
		class_name:  class_name.str
	}
	if C.RegisterClassA(&wc) == 0 {
		eprintln('browser: cannot register window class')
		exit(1)
	}
	app.hwnd = C.CreateWindowExA(0, class_name.str, 'vweb'.str, ws_overlappedwindow,
		100, 100, width + 16, height + 39, unsafe { nil }, unsafe { nil }, inst,
		unsafe { nil })
	if app.hwnd == unsafe { nil } {
		eprintln('browser: cannot create window')
		exit(1)
	}
	C.SetWindowLongPtrA(app.hwnd, gwlp_userdata, isize(voidptr(app)))
	// The memory DC and the DIB behind it. Top-down (a negative height) so row zero is
	// the top, which is the order the engine's buffer is already in.
	screen := C.GetDC(app.hwnd)
	app.memdc = C.CreateCompatibleDC(screen)
	mut bmi := BitmapInfo{
		header: BitmapInfoHeader{
			size:       40
			width:      i32(width)
			height:     -i32(max_page_height)
			planes:     1
			bit_count:  32
			compression: bi_rgb
		}
		quad:     0
	}
	mut bits := voidptr(unsafe { nil })
	hbmp := C.CreateDIBSection(screen, &bmi, dib_rgb_colors, &bits, unsafe { nil }, 0)
	C.ReleaseDC(app.hwnd, screen)
	if hbmp == unsafe { nil } {
		eprintln('browser: cannot create the page bitmap')
		exit(1)
	}
	C.SelectObject(app.memdc, hbmp)
	unsafe { blit_paint(&u8(bits), canvas.pix, width, max_page_height) }
	C.ShowWindow(app.hwnd, sw_shownormal)
	C.UpdateWindow(app.hwnd)	mut msg := Msg{}
	for C.GetMessageA(&msg, unsafe { nil }, 0, 0) > 0 {
		C.TranslateMessage(&msg)
		C.DispatchMessageA(&msg)
	}
}
