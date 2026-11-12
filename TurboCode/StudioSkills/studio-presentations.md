---
name: studio-presentations
description: "Method for any presentation, slide deck or pitch built in the Studio VM: how to outline the story, a 16:9 HTML slide base that also prints to PDF, rules for how much goes on a slide, and the slide-by-slide check. Load it before writing slides."
---

# Slides people can follow

Build the deck as one HTML file: it plays in the browser with the arrow keys and prints to a PDF with one slide per page. Follow this unless the user asks for a different look. If they ask for a PowerPoint file, build it with python-pptx in a venv and keep the content rules below.

## Outline first

1. Ask yourself who is in the room and what they should decide or remember.
2. List the figures and facts you were given, from the user's message and from /work. This list is your only source.
3. Write only the slide titles, each as a full sentence that states its point: "Churn fell after the pricing change", not "Churn".
4. Read the titles in order. They must tell the whole story on their own. Fix the outline before making any slide.
5. Plan about one slide per minute of talk. Without a duration, eight to twelve slides.

**A topic without a figure is a gap, not a request to estimate.** When the user asks for something that is not in your list (a saving, a cost, a market size), put `[missing: office cost per month]` on the slide where the figure would go and ask for it in your reply. Do not estimate it, recall a typical value, or write "about". The same goes for quotes, names and logos. An invented number in front of an audience costs the user more than an empty space.

## Base (copy, then adapt)

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Deck title</title>
<style>
@page { size: 1280px 720px; margin: 0; }
:root { --bg: #ffffff; --text: #18181b; --muted: #62626b; --line: #dcdce0; --accent: #1d4ed8; }
* { box-sizing: border-box; }
html, body { margin: 0; background: #111; }
body { font: 28px/1.4 "Helvetica Neue", Helvetica, Arial, "Liberation Sans", sans-serif;
       color: var(--text); }
.slide { width: 1280px; height: 720px; padding: 64px 80px; background: var(--bg);
         display: none; flex-direction: column; overflow: hidden; position: absolute;
         top: 0; left: 0; transform-origin: top left; }
.slide.current { display: flex; }
h1 { font-size: 64px; line-height: 1.1; letter-spacing: -0.02em; margin: 0 0 16px; }
h2 { font-size: 40px; line-height: 1.2; margin: 0 0 32px; }
p, li { margin: 0 0 16px; max-width: 46ch; }
ul { margin: 0; padding-left: 1.1em; }
.sub { color: var(--muted); }
.body { flex: 1; display: flex; flex-direction: column; justify-content: center; }
.split { display: grid; grid-template-columns: 1fr 1fr; gap: 56px; align-items: center; }
.big { font-size: 144px; font-weight: 700; line-height: 1; color: var(--accent);
       font-variant-numeric: tabular-nums; }
.foot { font-size: 16px; color: var(--muted); display: flex; justify-content: space-between; }
figure { margin: 0; } img, svg { max-width: 100%; max-height: 440px; }
table { border-collapse: collapse; font-size: 24px; width: 100%; }
th, td { text-align: left; padding: 10px 16px; border-bottom: 1px solid var(--line); }
.num { text-align: right; font-variant-numeric: tabular-nums; }
.notes { display: none; }
@media print {
  html, body { background: none; }
  .slide { display: flex; position: static; transform: none !important; break-after: page; }
}
</style>
</head>
<body>
<section class="slide">
  <div class="body"><h1>Deck title</h1><p class="sub">Speaker · Date</p></div>
</section>
<section class="slide">
  <h2>A full sentence that states this slide's point</h2>
  <div class="body split">
    <div><p>The one thing to say about it.</p></div>
    <div class="big">42%</div>
  </div>
  <div class="foot"><span>Source</span><span>2</span></div>
  <aside class="notes">What to say out loud.</aside>
</section>
<script>
const slides = [...document.querySelectorAll('.slide')]; let i = 0;
function show(n) { i = Math.max(0, Math.min(slides.length - 1, n));
  const k = Math.min(innerWidth / 1280, innerHeight / 720);
  slides.forEach((s, j) => { s.classList.toggle('current', j === i);
    s.style.transform = `scale(${k})`; }); }
addEventListener('keydown', e => {
  if (['ArrowRight', 'PageDown', ' '].includes(e.key)) show(i + 1);
  if (['ArrowLeft', 'PageUp'].includes(e.key)) show(i - 1); });
addEventListener('click', () => show(i + 1)); addEventListener('resize', () => show(i));
show(0);
</script>
</body>
</html>
```

## Rules

- **One idea per slide.** If a slide needs "and" in its title, make two.
- **Thirty words at most** under the title, and no more than four bullets. A slide is not a document; what the speaker says goes in `.notes`.
- **Show, then tell.** One chart, one figure or one big number per slide, with the conclusion in the title. Label the chart directly; no legends far from the data.
- **Text never smaller than 24px** on the slide, apart from the footer. If it does not fit, cut words; do not shrink.
- **Same place every time**: title top left, content in `.body`, source and slide number in `.foot`.
- **One accent color.** White or near-white background. No gradients, shadows, clip art, emoji or animations.
- **Open and close.** First slide: title and speaker. Last slide: the decision or next step you want, not "Thank you" or "Questions?".
- Charts as inline SVG or a bundled library; images as local files. Nothing loaded from the network.

## Make the PDF

```
chromium --headless --no-pdf-header-footer \
  --print-to-pdf=/out/deck.pdf file:///home/cowork/sessions/ID/deck.html
```

Use the real session path. Put both the HTML deck and the PDF in /out, with any image files the deck needs.

## Check before you finish

1. Install the PDF tools once: `sudo apt-get install -y poppler-utils`.
2. `pdfinfo /out/deck.pdf`: the page count must equal the number of slides. More pages means a slide overflowed.
3. Render the slides small: `pdftoppm -png -scale-to 640 /out/deck.pdf /tmp/slide`
4. If you can see images, look at them with `vm_view_image`: every slide up to ten, otherwise the first, the last and the densest ones. If you cannot, count the words on each slide instead.
5. Fix: text cut off at the bottom or right edge, a title on three lines, a slide that is only bullets, a chart without labels, two slides making the same point, a gap marker you could have filled.
6. Go through every number on every slide: is it in your list from step 2 of the outline? Replace any that is not with a gap marker.
7. Read the titles in order one last time. Do they still tell the story?
