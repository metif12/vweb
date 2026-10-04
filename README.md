# vweb

یک موتور رندر HTML+CSS که از پایه در V نوشته شده است. صفحه را به یک بافر
پیکسل تبدیل می‌کند. مرورگر نیست، و JavaScript اجرا نمی‌کند.

> **زبان:** کد و کامنت‌ها انگلیسی. مستندات و یادداشت‌ها فارسی.

## وضعیت

فاز ۰ کامل. یک بافر RGBA نرم‌افزاری با ترکیب درست، زیرساخت تست golden، و
لایهٔ متن روی vtext با glyph cache. هنوز هیچ HTML یا CSS ای خوانده نمی‌شود.

| فاز | وضعیت |
| --- | --- |
| ۰ — داربست و هدف رستر | **کامل** |
| ۱ — برش عمودی (HTML + CSS پایه + layout بلوکی + متن) | در جریان |
| ۲ — inline و intrinsic sizing | شروع نشده |
| ۳ — CSS صفحات واقعی (flex/float/table را ندارد) | شروع نشده |
| ۴ — Flexbox | شروع نشده |
| ۵ — Grid | شروع نشده |
| ۶ — پوستهٔ پنجره | شروع نشده |
| ۷ — JavaScript | طبق تصمیم شما، بعد از کامل شدن رندر |

جزئیات و دروازه‌های پذیرش: [`docs/PHASES.md`](docs/PHASES.md)

**آنچه از قبل ساخته شده و کار می‌کند:**

- `engine/css` — tokenizer و parser طبق CSS Syntax 3، به‌علاوهٔ CSSOM، یک
  سریالایزر که round-trip می‌شود، UA stylesheet، و ارزیابی media query. ۱۱۲ تست.
- `engine/selector` — گرامر selector و تطبیق روی درخت `vlib/net/html`، با
  specificity. ۶۵ تست.
- `engine/style` — طول‌ها، رنگ‌های نام‌دار CSS، computed value، ارث‌بری، و
  cascade با origin و importance و specificity و ترتیب، شامل `@media` و
  `@supports`. ۷۴ تست.
- `engine/display` — box tree: عرض و ارتفاع، box model، جمع‌شدن حاشیه‌ها، عرض
  استفاده‌شدهٔ border، جعبهٔ بی‌نام برای متن درون‌خطی، و شکستن بند با فاصلهٔ خط
  ثابت. ۳۰ تست.
- `engine/paint` — display list و ترکیب آن روی canvas: پس‌زمینه، چهار نوار
  border، خط زیرنویس/میان‌خط/بالای متن، و رنگ متن. ۲۱ تست.
- `engine/raster` — بافر premultiplied با حساب صحیح، ترکیب source-over،
  بیت‌مپ coverage برای متن، کلیپ، خروجی PNG. ۳۰ تست.
- `text` — پل کامل به vtext: پنج تماس اندازه‌گیری که layout لازم دارد و یک
  تماس رسم، و شکستن بند با فاصلهٔ خط ثابت. ۴۷ تست.
- `loader` — `file://` و `http(s)://` به Resource، با جدول media type و
  percent-decoding. ۲۷ تست.
- `engine/tree` — چند predicate روی `html.Tag`. تنها تکرار عمدی پروژه؛ دلیلش در
  فایلش و در `notes/JOURNAL.md` آمده.

## ساختار

```
engine/html/       یک نازک‌کننده روی vlib/net.html — نه پارسر موازی
engine/tree/       predicate و ناوبری روی html.Tag (درختی ندارد)
engine/css/        tokenizer، parser، CSSOM و UA stylesheet
engine/selector/   گرامر selector، specificity و تطبیق
engine/style/      cascade و computed values
engine/display/   box tree و box model و جمع‌شدن حاشیه‌ها
engine/paint/     display list و ترکیب روی canvas
engine/raster/    هدف RGBA، blend، primitives
text/             پل به vtext و glyph cache
loader/           file:// و http:// → Resource (۲۷ تست)
shell/            پنجره، ورودی، chrome
cmd/vweb/         نقطهٔ ورود
```

**درخت سند از `vlib/net/html` می‌آید، نه از این پروژه.** در ابتدا
`engine/dom` را اینجا نوشته بودم، بعد فهمیدم که همان چیزی است که ماژول
`net/html` در vlib باید باشد — پس آنجا درست شد و اینجا حذف شد. نوشتن نسخهٔ
موازی، همان کاری است که قرار بود از آن جلوگیری کنیم.

آنچه `net/html` حالا فراهم می‌کند که قبلاً نمی‌داد: متن به‌عنوان گره، پیوند
Sibling، void element، end tag ضمنی، `<tbody>` ضمنی، صفت بدون نقل، و متن
انتهای سند.

قواعد ماژول‌بندی V رعایت شده: خط `module` برابر نام پوشه است، و مسیر
import نسبت به پوشهٔ `v.mod` نقطه‌جدا می‌شود. این الگو از `coreutils`
(«`import common.testing`» برای پوشه‌ای که `module testing` دارد) گرفته شده.

## ساخت و تست

```powershell
. .\env.ps1
& $env:VEXE -cc tcc -Wimpure-v test .
```

`env.ps1` را همیشه بخوانید؛ دلیلش در `notes/JOURNAL.md` آمده. `-cc tcc` صریح
لازم است — `-stats` هم تیک‌کر را می‌شکند.

## وابستگی‌ها

- [vtext](../vtext) — لایهٔ متن. شکل‌دهی، bidi، اتصال عربی، GSUB/GPOS، fallback.
  همهٔ پروژه‌های مرجع این را از HarfBuzz می‌گیرند؛ اینجا pure V است.
- `vlib/net.html` — درخت سند. این پروژه آن را مصرف می‌کند و گسترش می‌دهد.
- `vlib/stbi` — رمزگشایی تصویر. دیکودرها از طریق
  `vlib/image` در دسترس‌اند (`image.register_stbi_formats()`).
- `vlib/net/http` — بارگذار منابع، با SChannel روی ویندوز.

بدون JS engine. بدون binding مرورگر به سیستم. بدون Chromium.

## چرا این پروژه

سه پروژه مرجع بررسی شدند. نتیجهٔ کلیدی این بود که **مسیر درست، حذف کردن لایهٔ
رندر است، نه کوچک کردن آن**:

- **Lightpanda** (۳۵٬۷۰۰ ستاره) layout ندارد اصلاً. `Page.captureScreenshot`
  یک رندر *reader-mode* است با parley و tiny-skia، نه پیکسل‌های صفحه.
  خودشان هم این را نوشته‌اند: «text and structure rather than a pixel match».
- **servo/serv وجود ندارد.** پنج بررسی مستقل، همه ۴۰۴. هر معماری و تاریخچه‌ای
  که به آن نسبت داده شود ساختگی است. نزدیک‌ترین پروژهٔ واقعی
  `andre-eriksson/browser` است: wgpu و cosmic-text، بدون JS، ۳ ستاره، و
  ۲.۵ ماه بدون commit.
- **Ladybird** در pre-alpha با هدف stable در ۲۰۲۸. این عدد، مهم‌ترین دادهٔ
  مقیاس‌بندی است.

و مهم‌تر از همه: آن پروژهٔ نزدیک، دیوارش را در فایل خودش اعلام کرده است.
`docs/css.md` نشان می‌دهد `width` و `max-width` پیاده شده‌اند ولی
`min-width`، `min-height` و `max-height` نه. یعنی **intrinsic sizing** همان
چیزی است که حل نشده. این همان چیزی است که فاز ۲ این پروژه است، و همان چیزی
که باید از روز اول برایش طراحی شود.

جزئیات: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## مستندات

| فایل | محتوا |
| --- | --- |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | تصمیم‌های معماری و دلیلشان |
| [`docs/PHASES.md`](docs/PHASES.md) | فازبندی و دروازهٔ پذیرش هر فاز |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | دفتر تصمیم‌ها |
| [`notes/JOURNAL.md`](notes/JOURNAL.md) | آنچه اندازه گرفته شد، با تاریخ |
| [`notes/V-GOTCHAS.md`](notes/V-GOTCHAS.md) | تله‌های زبان V که به آن‌ها خوردیم |

`notes/` برای چیزهایی است که **اندازه‌گیری شده‌اند**. نسخهٔ واقعی از یک
تصمیم، عددی است که آمده و نتیجه‌اش، نه استدلالی که بعداً سرهم شده.
