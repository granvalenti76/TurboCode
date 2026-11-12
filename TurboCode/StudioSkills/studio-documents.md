---
name: studio-documents
description: "Method for any document delivered as a PDF from the Studio VM: report, letter, proposal, quote, invoice, CV, handout. A print CSS base, page-break rules, the Chromium command that makes the PDF, and the page-by-page check. Load it before writing a document meant to be printed or sent."
---

# Documents that print well

Write the document as one HTML file with print CSS, then let Chromium turn it into a PDF. Follow this unless the user asks for a different look. If they ask for a Word file, build it with python-docx in a venv and keep the writing rules below.

## Before writing

- **Reader and purpose.** Who reads it, and what should they do afterwards? That decides the length. One page when it fits.
- **Conventions of the reader**, not yours: language, date format, decimal separator, currency, paper size (A4, or Letter for the US).
- **Facts only from the user or from /work.** List what you were given; that list is your only source. If something essential is missing (a recipient, an amount, a date), ask. For the rest leave a visible gap such as `[missing: VAT number]` and list the gaps in your reply.
- **A topic without a figure is a gap, not a request to estimate.** When the user asks you to include something you have no data for, mark it; do not estimate it, recall a typical value, or write "about". Never invent names, addresses, figures or references: the user will sign and send this.

## Base (copy, then adapt)

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Document title</title>
<style>
@page { size: A4; margin: 22mm 20mm 24mm; }
:root { --text: #1a1a1a; --muted: #5f5f5f; --line: #cfcfcf; --accent: #1d3f8f; }
* { box-sizing: border-box; }
html { font: 10.5pt/1.5 "Helvetica Neue", Helvetica, Arial, "Liberation Sans", sans-serif;
       color: var(--text); }
body { margin: 0; }
h1 { font-size: 20pt; line-height: 1.2; margin: 0 0 4pt; }
h2 { font-size: 13pt; margin: 18pt 0 6pt; }
h3 { font-size: 10.5pt; margin: 12pt 0 4pt; }
h1, h2, h3 { break-after: avoid; }
p { margin: 0 0 8pt; orphans: 3; widows: 3; }
.meta { color: var(--muted); font-size: 9pt; }
.summary { border-left: 2pt solid var(--accent); padding-left: 10pt; margin: 12pt 0; }
table { width: 100%; border-collapse: collapse; margin: 8pt 0 12pt; font-size: 9.5pt; }
thead { display: table-header-group; }
th { text-align: left; font-weight: 600; border-bottom: 1pt solid var(--text); padding: 4pt 6pt; }
td { border-bottom: 0.5pt solid var(--line); padding: 4pt 6pt; vertical-align: top; }
tr, figure, .keep { break-inside: avoid; }
.num { text-align: right; font-variant-numeric: tabular-nums; }
tr.total td { font-weight: 600; border-top: 1pt solid var(--text); border-bottom: 0; }
figure { margin: 10pt 0; } figcaption { font-size: 9pt; color: var(--muted); }
img, svg { max-width: 100%; }
.page-break { break-before: page; }
.columns { display: flex; justify-content: space-between; gap: 24pt; }
</style>
</head>
<body>
<header>
  <p class="meta">Organisation · Date</p>
  <h1>Title that states the subject</h1>
</header>
<p class="summary">The main point in two sentences.</p>
<h2>Section</h2>
<p>Text.</p>
</body>
</html>
```

## Shape by kind

- **Report**: title block, summary first, sections whose headings say what they found, sources at the end.
- **Letter**: sender, place and date, recipient, subject line, body in short paragraphs, closing, room for a signature. No headings inside.
- **Quote or invoice**: both parties in `.columns`, number and date, a table of lines with `num` columns, a `total` row, then terms. Compute every total with code and print the result; do not add up by hand.
- **CV or handout**: one page, strongest content in the top third.

## Rules

- One font family, two weights, black text. One accent at most, and the page must still read well printed in grey.
- Headings stay with the text that follows; table rows and figures are never split. Use `.page-break` where a new part should start on a new page.
- Numbers right-aligned, same decimals in a column, units in the header.
- Images are local files embedded in the page, sharp at print size. Nothing loaded from the network.
- No emoji, clip art, colored panels, or decorative lines. No placeholder text in the delivered file.

## Make the PDF

```
chromium --headless --no-pdf-header-footer \
  --print-to-pdf=/out/report-2026-q3.pdf file:///home/cowork/sessions/ID/report.html
```

Use the real session path and a file name the user would recognise. Keep the HTML in the session directory; copy it to /out only if the user wants to edit it.

## Check before you finish

1. Install the PDF tools once: `sudo apt-get install -y poppler-utils`.
2. `pdfinfo file.pdf` gives the page count. Is it the length you intended?
3. Render the pages small: `pdftoppm -png -scale-to 900 file.pdf /tmp/page`
4. If you can see images, look at them with `vm_view_image`: every page up to five, otherwise the first, the last and any page with a table. If you cannot, reread the HTML for these faults.
5. Fix: a last page holding only a few lines, a heading at the bottom of a page, a split table row, text running past the margin, a date or URL printed by the browser in the margin, a blank page, a gap marker you could have filled.
6. Reread the text once as the recipient: every name, date and amount must be in what you were given. Replace any that is not with a gap marker.
