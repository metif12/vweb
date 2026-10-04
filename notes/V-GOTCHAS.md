
---

## ۳۴. `mut p := parent` روی پارامتر اشاره‌ای، **کپی** می‌سازد

```v
fn attach(mut parent &html.Tag, children ...&html.Tag) {
	for child in children {
		parent.children << child   // درست
	}
}
```

ولی این **کپی** است، نه alias:

```v
fn attach(parent &html.Tag, children ...&html.Tag) {
	mut p := parent          // کپیِ Tag، نه اشاره به همان
	p.children << child      // بچه‌ها روی کپی می‌روند
}                          // درخت خالی می‌ماند
```

نشانه‌اش فوری نیست: کد کامپایل می‌شود، تست هم کامپایل می‌شود، و شکست
خیلی بعدتر به شکل `nil` ظاهر می‌شود (`box_for(...)` چیزی پیدا نمی‌کند و
`b.rect` می‌ترکد). قاعده: برای نوشتن از یک پارامتر اشاره‌ای، خودِ پارامتر
`mut` باشد — `fn f(mut p &T)` — و فراخوانندهٔ آن `mut x` بخواهد.

## ۳۵. روی پارامتر اشاره‌ایِ `mut`، `mut` تا همهٔ فراخوانی‌ها سرایت می‌کند

```v
mut body := el('body', '', '')
attach(mut body, div)      // body باید mut باشد
```

و اگر متغیر محلی باشد، باید `mut` شود — وگرنه کامپایلر خطای «`body` is
immutable» می‌دهد. این با آن gotcha قدیمی فرق دارد: آن یکی دربارهٔ `mut` روی
**پارامتر** بود، این یکی دربارهٔ **فراخوانی**.

## ۳۶. حلقه روی slice تغییرناپذیر، نوشتن را رد می‌کند

```v
for mut child in children {   // error: `children` is immutable
	child.parent = parent
}
```

و با `mut child := child_ref` هم رد می‌شود:

```v
mut child := child_ref        // error: child.parent aliases mutable
```

راه‌حل: اول در یک آرایهٔ **محلیِ mut** کپی کن، بعد از آن بنویس. آرایهٔ محلی
modifiable است و نوشتن از راه آن قبول می‌شود:

```v
mut kids := []&T{}
for child in children {
	kids << child
}
mut i := 0
for i < kids.len {
	mut child := kids[i]
	child.parent = parent
	i++
}
```

و `mut children ...&T` هم **مجاز نیست**: `variadic arguments cannot be mut`.

## ۳۷. `for mut x in arr` متغیر حلقه را `&T` می‌کند

```v
for mut child in b.children { ... }        // child از نوع &Box
l.place(mut child, ...)                     // error: &Box where &Box expected → &&Box
```

یعنی `for mut x in xs` **یک سطح اشاره اضافه می‌کند**. اگر می‌خواهی فیلدهای
ساختارِ داخل آرایه را بنویسی، `for x_ref in xs { mut x := x_ref }` درست است
و `for mut x in xs` اشتباه.

## ۳۸. `[]*T` در V وجود ندارد

```v
pub fn boxes(root &Box) []*Box {    // parser: unexpected token `[`
```

آرایه‌ای از اشاره‌ها `[]&Box` است. ضمناً `&Box{root}` به‌عنوان initializer
هم خطاست: `array initializer elements must use square brackets` — بنویس
`mut out := []&Box{}` و بعد `out << root`.

## ۳۹. `f64.round()` وجود ندارد

```v
int(v.round())            // error: unknown method or field: f64.round
```

از `math.round` استفاده کن:

```v
fn px(v f64) int { return int(math.round(v)) }
```

و یک قاعدهٔ کلی‌تر: هر جا رُند کردن لازم است، آن را در **یک** تابع
(`px`) جمع کن. رُند کردن با بریدن، هر جعبه را کمی به سمت صفر متمایل می‌کند و
خطا در عمق درخت جمع می‌شود.

## ۴۰. `x: value` فقط برای پارامتر bool نیست

```v
l.place(b, w, 0, 0, top_escapes: false, bottom_escapes: false)
// error: cannot use `key: value` arguments as `bool` in call to `l.place`
```

آرگومان‌های نام‌دار در V فقط برای چند پارامتر آخر و به شکل `f(a: 1)` هستند،
نه به شکل `name: value`. اگر خوانایی لازم است، **نامِ پارامتر را خوب انتخاب کن**
و موقعیتی صدا بزن.
---

## ۴۱. متدِ نوعِ ماژولِ دیگر را نمی‌شود تعریف کرد

```v
// در ماژول paint، روی raster.Canvas از ماژول raster
pub fn (mut c raster.Canvas) render(l &DisplayList) { }
// error: unknown function: canvas.render
```

V فقط متدهایی را قبول می‌کند که در **همان ماژولِ تعریفِ نوع** نوشته شده باشند.
راه‌حل: یک تابع آزاد. و چون receiver دیگر نداری، `mut` را روی آرگومان می‌بری:

```v
pub fn composite(mut c raster.Canvas, l &DisplayList) { ... }
composite(mut canvas, p.list)   // نه composite(canvas, p.list)
```

## ۴۲. `mut x, mut y := f()` برای چند بازگشتی

```v
fn page() (&html.Tag, &html.Tag) { ... }

root, body := page()        // بعد attach(mut body, ...) خطا می‌دهد
mut root, mut body := page() // درست
```

## ۴۳. `[4]T{a, b, c, d}` با عناصر موضعی خطای پارس است

```v
s.border_style = [.none, .none, .none, .none]   // expected [4]BorderStyle, not []BorderStyle
```

در V 0.5.2 یک initializer آرایه با عناصر موضعی، `[]T` در نظر گرفته می‌شود نه
`[N]T`. راه درست، ساختن آرایهٔ خالی و پر کردن اندیسی است:

```v
mut no_border := [4]style.BorderStyle{}
s.border_style = no_border
```

و همین دلیل است که `border_px = [t, r, b, l]` چهار خط شد.

## ۴۴. `x.y.len() == n` به‌جای `==` پارس نمی‌شود

```v
assert l.commands.len() == 2
// error: invalid number of operand for `==`. Only one allowed on each side.
```

اول در یک محل بریز، بعد مقایسه کن:

```v
n := l.commands.len
assert n == 2
```

## ۴۵. `notice` را جدی بگیر

```v
notice: `parent` is immutable, cannot have a mutable reference to an immutable object
```

یعنی «این اجرا می‌شود و شاید هرگز اشکال ندهد». در `match_test.v` همین notice
تنها سرنخِ یک باگی بود که **۳۱ تست را بی‌اعتبار کرده بود**: `mut p := parent`
کپی می‌گرفت، بچه‌ها روی کپی می‌رفتند، و matcher چون فقط `parent.children` را
می‌خواند همان کپی را می‌دید و همه‌چیز سبز بود.

قاعده: خروجی کامپایلر را تا آخر بخوان. `notice` را نه پاک کن نه نادیده بگیر —
یا علتش را درست کن یا بنویس چرا این‌جا امن است.
---

## ۴۶. یک build با کش گرم، دربارهٔ کامپایل شدن یک ماژول بیرونی چیزی نمی‌گوید

`vweb/v.mod` می‌گوید `dependencies: ['vtext']` و `~/.vmodules/vtext` یک junction
به working tree زندهٔ آن پروژه است. آن درخت کامپایل **نمی‌شد**:

```
vtext/layout.v:176: error: cannot use `vtext.Line` as `&&vtext.Line`
```

و با این حال هر build سبز بود، چون کش در `TMPDIR` گرم بود. اولین build با کش سرد
همان لحظه نشان داد `text`، `engine/display` و `engine/paint` اصلاً build نمی‌شوند.

قاعده: **اولین build از هر dependency بیرونی باید با کش سرد باشد، نه آخری.**
تازه‌بودن مسیر `TMPDIR` چیزی ثابت نمی‌کند؛ کلید کش شامل تغییرات آن پروژه هم
می‌شود. و وقتی گزارش «سبز» می‌دهی، بنویس که با کش گرم بوده یا نبوده — وگرنه همان
عدد را به حساب کد خودت می‌گذاری.

## ۴۷. یک کاراکتر `'a'` در مقایسه با `u8`، `string` است

```v
if b[i] == ':' { ... }        // b is []u8
// error: infix expr: cannot use `string` (right expression) as `u8`
```

در این build، یک literal تک‌کاراکتری در سمت راستِ یک `u8`، `string` حساب می‌شود.
راه‌حل: مقدار بایت را عدد بنویس (`u8(58)`) یا یک جدول ثابت بایت بساز و اسم بگذار.
برای `match c { '0'...'9' }` هم همین مسئله است — آن بازوی `match` کامپایل نمی‌شود.

نکتهٔ جدا: `str[i]` هم `string` می‌دهد نه `u8`. برای کار با بایت، `s.bytes()`
بگیر و روی آن با اندیس برو.

## ۴۸. نام ثابت نمی‌تواند حرف بزرگ داشته باشد

```v
const b_C = u8(67)      // error: const names cannot contain uppercase letters
```

`b_upper_c` بنویس. برای متغیر محلی هم همین قاعده است (`b_F` خطا می‌دهد)، ولی
برای ثابت‌ها و توابع با `snake_case` است و V این را در نام متغیر محلی هم
اجرا می‌کند.

## ۴۹. `match` شرط نمی‌گیرد

```v
match {              // error: invalid expression
	c >= b_0 && c <= b_9 { return int(c - b_0) }
}
```

`match` یک expression می‌خواهد. اگر شرط داری، `if`/`else if` بنویس. این با
`if x := f(); cond` فرق دارد که اصلاً پارس نمی‌شود — آن یکی gotchaی جدا و
جداگانه‌ای است.