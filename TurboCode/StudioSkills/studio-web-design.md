---
name: studio-web-design
description: "House style for any web page, HTML report, dashboard or landing page built in the Studio VM: a ready CSS base, layout rules, patterns for tables, key figures and charts, and the screenshot check. Load it before writing HTML or CSS, including for React or Vite apps."
---

# Web pages that look professional

Follow this unless the user asks for a different look. Plain and consistent beats decorated. Start from the base below; do not design a palette or type scale of your own.

## Base (copy as is)

One file, no CDN, no web fonts, no external images: the page must work offline after export. In React or Vite, put the CSS in `src/index.css` and use the same class names.

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Page title</title>
<style>
:root {
  --bg: #fafaf9; --surface: #ffffff; --text: #1c1917; --muted: #6b6560;
  --line: #e7e5e4; --accent: #1d4ed8; --good: #15803d; --bad: #b91c1c;
  --s1: 4px; --s2: 8px; --s3: 16px; --s4: 24px; --s5: 40px; --s6: 64px;
  --radius: 8px;
  --sans: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #171514; --surface: #201e1d; --text: #f5f5f4; --muted: #a8a29e;
          --line: #353130; --accent: #7aa2ff; --good: #4ade80; --bad: #f87171; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text);
       font: 16px/1.6 var(--sans); -webkit-font-smoothing: antialiased; }
.page { max-width: 1080px; margin: 0 auto; padding: var(--s5) var(--s4) var(--s6); }
.prose { max-width: 68ch; }
h1 { font-size: 2rem; line-height: 1.2; letter-spacing: -0.02em; margin: 0 0 var(--s2); }
h2 { font-size: 1.25rem; line-height: 1.3; margin: var(--s5) 0 var(--s3); }
h3 { font-size: 1rem; margin: var(--s4) 0 var(--s2); }
p { margin: 0 0 var(--s3); }
.lede { font-size: 1.125rem; color: var(--muted); margin-bottom: var(--s4); }
.meta, small { font-size: 0.8125rem; color: var(--muted); }
a { color: var(--accent); }
.grid { display: grid; gap: var(--s3);
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); }
.card { background: var(--surface); border: 1px solid var(--line);
        border-radius: var(--radius); padding: var(--s4); }
.stat .label { font-size: 0.8125rem; color: var(--muted); }
.stat .value { font-size: 1.75rem; font-weight: 600; line-height: 1.2;
               font-variant-numeric: tabular-nums; }
.up { color: var(--good); } .down { color: var(--bad); }
.table-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 0.9375rem; }
th { text-align: left; font-size: 0.8125rem; font-weight: 600; color: var(--muted);
     padding: var(--s2) var(--s3); border-bottom: 1px solid var(--line); }
td { padding: var(--s2) var(--s3); border-bottom: 1px solid var(--line); }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
code, pre { font-family: var(--mono); font-size: 0.875rem; }
pre { background: var(--surface); border: 1px solid var(--line);
      border-radius: var(--radius); padding: var(--s3); overflow-x: auto; }
figure { margin: var(--s4) 0; }
figcaption { font-size: 0.8125rem; color: var(--muted); margin-top: var(--s2); }
svg, img { max-width: 100%; height: auto; }
button, .button { font: inherit; padding: var(--s2) var(--s3); border-radius: 6px;
                  border: 1px solid var(--line); background: var(--surface);
                  color: var(--text); cursor: pointer; }
.button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
@media print { body { background: #fff; } .card { break-inside: avoid; } }
</style>
</head>
<body>
<main class="page">
  <header>
    <p class="meta">Category · Date</p>
    <h1>Title that states the subject</h1>
    <p class="lede">One sentence with the main finding.</p>
  </header>
  <section class="grid">
    <div class="card stat"><div class="label">Label</div><div class="value">123.4</div>
      <div class="meta up">+2.1% vs last month</div></div>
  </section>
  <h2>Section</h2>
  <div class="prose"><p>Text.</p></div>
</main>
</body>
</html>
```

## Rules

- **Structure first.** Title, one-sentence summary, then the three or four figures that matter, then detail. A reader should get the point from the first screen.
- **Left-align** text and headings. Center nothing except a short hero line on a landing page.
- **Spacing** only from `--s1`…`--s6`. More space between sections than inside them.
- **One accent color**, used for links, the primary button and the main data series. `--good` and `--bad` only for values that are good or bad.
- **Three text sizes per screen** at most, plus the title. Weight 400 and 600 only.
- **Long text** goes in `.prose`. Tables, charts and grids may use the full `.page` width.
- **Numbers**: right-aligned in tables with class `num`, same number of decimals in a column, units in the header, thousands separators.
- **Tables**: wrap in `.table-wrap`. No vertical lines, no zebra stripes, no colored header row.
- **Cards** group related content. Do not put a card inside a card, and do not wrap the whole page in one.

## Avoid

Gradients, glows and heavy shadows. Emoji as icons or bullets. Colored backgrounds behind sections. More than one accent. All-caps headings. Rounded pills everywhere. Centered paragraphs. Placeholder text, fake logos, stock-photo boxes. Animations, unless asked.

## Charts

- Inline SVG needs no dependency and is enough for one line or a few bars. For more, install a library with npm and bundle it, or copy its file next to the page. Never load one from a CDN.
- One idea per chart. A title that says what it shows, units on the axis, the source in a `figcaption`.
- Series colors: `--accent` first, then `--muted`, then `--good` / `--bad` only when they mean that. Thin grid lines in `--line`. No 3D, no pie chart with more than four slices.
- Read colors from the CSS variables so the chart follows dark mode.

## Check before you finish

1. Take both screenshots:
   `chromium --headless --screenshot=/tmp/desktop.png --window-size=1280,900 <url>`
   `chromium --headless --screenshot=/tmp/phone.png --window-size=390,844 <url>`
2. If you can see images, look at them with `vm_view_image`. Otherwise reread the HTML for these faults.
3. Fix: text or tables wider than the screen, overlapping elements, a title that wraps badly, empty cards, charts without labels, unstyled default buttons, placeholder text left in.
4. Every number on the page must come from the data. Write "n/a" when a value is missing.
