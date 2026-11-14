# Highlight Styles & Frontmatter

Tomedown works with Obsidian, GitHub, Logseq, or any plain text viewer. Every styling option lives in **Tomedown → Settings → Style**, and you can override any of them for a single book.

## 6 Special highlight styles

Flag standout quotes with **Special Highlight** when selecting text in KOReader. In **Settings → Style → How special highlights look**, choose:

1. **Callout (`[!highlight]`)**: Obsidian callout block.
2. **Alert (`[!IMPORTANT]`)**: GitHub-flavored alert box.
3. **Highlight (`==text==`)**: standard Markdown highlight.
4. **Highlight & Bold (`==**text**==`)**: highlighted and bold.
5. **Star & Bold (`⭐ **text**`)**: star badge next to bold text.
6. **Bold (`**text**`)**: clean bold text that works everywhere.

Enable **Treat every highlight as special** if you want *all* highlights to use your chosen style automatically.

<figure class="doc-device-figure">
  <img src="{{base}}/assets/img/special-highlight-kindle.svg" alt="KOReader text selection popup showing Special Highlight below Highlight" />
</figure>

<div class="special-styles-grid" aria-label="Comparison of the 6 special highlight styles">
  <div class="style-sample">
    <div class="style-sample-head"><span>1. Callout</span><code>[!highlight]</code></div>
    <div class="style-render style-render-callout">
      <div class="style-render-title">Highlight</div>
      <p>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</p>
    </div>
  </div>
  <div class="style-sample">
    <div class="style-sample-head"><span>2. Alert</span><code>[!IMPORTANT]</code></div>
    <div class="style-render style-render-alert">
      <div class="style-render-title">Important</div>
      <p>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</p>
    </div>
  </div>
  <div class="style-sample">
    <div class="style-sample-head"><span>3. Highlight</span><code>==text==</code></div>
    <div class="style-render style-render-quote">
      <p><mark>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</mark></p>
    </div>
  </div>
  <div class="style-sample">
    <div class="style-sample-head"><span>4. Highlight &amp; Bold</span><code>==**text**==</code></div>
    <div class="style-render style-render-quote">
      <p><mark><strong>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</strong></mark></p>
    </div>
  </div>
  <div class="style-sample">
    <div class="style-sample-head"><span>5. Star &amp; Bold</span><code>⭐ **text**</code></div>
    <div class="style-render style-render-quote">
      <p>⭐ <strong>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</strong></p>
    </div>
  </div>
  <div class="style-sample">
    <div class="style-sample-head"><span>6. Bold</span><code>**text**</code></div>
    <div class="style-render style-render-quote">
      <p><strong>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</strong></p>
    </div>
  </div>
</div>

## Personal notes format (Inline vs Footnotes)

When you attach a note to a highlight in KOReader, **Personal notes format** controls how it appears:

- **Inline** *(default)*: your note is placed directly below the quote.
- **Footnotes**: your note becomes a Markdown footnote (`[^1]`) at the end of the chapter or file, keeping the quote list compact.

## Highlight details, chapters & context

- **Highlight details**: choose **Page and date** (`- **p. 15** · 05/11/2026 10:20`), **Page only**, **Date only**, or **None**.
- **Chapter headings**: choose **Heading 1 (`#`)**, **Heading 2 (`##`)**, **Heading 3 (`###`)**, or **None (continuous list)**.
- **Include highlight context**: on reflowable books (EPUB, FB2, MOBI…), extracts the words right before and after your highlight and adds a `- **Context:** *…*` line below the quote so you never lose the surrounding sentence.
- **Add link IDs to highlights**: appends a stable `^hl-xxxxxxxx` block ID at the end of each quote so Obsidian can link to or embed a single highlight.

<div class="spotlight doc-spotlight" aria-label="Highlight context and footnotes preview">
  <div class="spotlight-tabs" role="tablist">
    <button class="spotlight-tab is-active" role="tab" aria-selected="true" data-slide="0">
      <code>Context: …</code>
      <span>Surrounding sentence</span>
    </button>
    <button class="spotlight-tab" role="tab" aria-selected="false" data-slide="1">
      <code>Footnotes [^1]</code>
      <span>Zoomed on note</span>
    </button>
  </div>
  <div class="spotlight-stage">
    <figure class="spotlight-slide is-active" role="tabpanel">
      <div class="spotlight-frame">
        <img class="zoom-context" src="{{base}}/assets/img/highlights-context-obsidian.webp" alt="Obsidian note showing highlight context lines and footnote reference [^1]" />
      </div>
      <figcaption>Surrounding words captured automatically below each quote via <code>Context: …</code>.</figcaption>
    </figure>
    <figure class="spotlight-slide" role="tabpanel">
      <div class="spotlight-frame">
        <img class="zoom-footnote" src="{{base}}/assets/img/highlights-footnote-obsidian.webp" alt="Obsidian note zoomed onto the rendered footnote at the bottom of the file" />
      </div>
      <figcaption>Personal notes collected cleanly at the bottom as Markdown footnotes (<code>[^1]</code>).</figcaption>
    </figure>
  </div>
</div>

## Frontmatter fields & custom properties

In **Settings → Style → Frontmatter fields**, you can:

- Toggle YAML frontmatter on or off (*Include YAML frontmatter*).
- Show or hide individual fields (`cover`, `series`, `language`, `pages`, `exported`, `highlights`, `special`, `status`, `progress`).
- Add **Custom frontmatter fields…** (your own `key: value` properties, e.g. `type: book` or `vault: reading`).
- Set a **Frontmatter key order…** (comma-separated list of keys).

<div class="spotlight doc-spotlight doc-device-spotlight" aria-label="Frontmatter fields and key order in KOReader">
  <div class="spotlight-tabs" role="tablist">
    <button class="spotlight-tab is-active" role="tab" aria-selected="true" data-slide="0">
      <code>Frontmatter fields</code>
      <span>Page 1 · Toggle YAML keys</span>
    </button>
    <button class="spotlight-tab" role="tab" aria-selected="false" data-slide="1">
      <code>Custom &amp; key order</code>
      <span>Page 2 · Properties &amp; order</span>
    </button>
  </div>
  <div class="spotlight-stage">
    <figure class="spotlight-slide is-active" role="tabpanel">
      <div class="doc-device-frame">
        <img src="{{base}}/assets/img/frontmatter-fields-kindle.svg" alt="KOReader Tomedown Frontmatter fields menu page 1" />
      </div>
      <figcaption>Choose exactly which YAML properties to include in exported book notes.</figcaption>
    </figure>
    <figure class="spotlight-slide" role="tabpanel">
      <div class="doc-device-frame doc-device-frame-wide">
        <img src="{{base}}/assets/img/frontmatter-key-order-kindle.svg" alt="KOReader Tomedown Frontmatter fields menu page 2 with custom fields and key order dialog" />
      </div>
      <figcaption>Enable custom fields and define your preferred frontmatter key order.</figcaption>
    </figure>
  </div>
</div>

## Per-book overrides

Inside an open book, go to **Tomedown → Current book → Style & format** to override export format, personal notes format, highlight details, chapter headings, context, cover, page bookmarks, or frontmatter for **that book only**. Tap **Reset to global style settings** anytime to go back to defaults.

<div class="spotlight doc-spotlight doc-device-spotlight" aria-label="Per-book overrides in KOReader">
  <div class="spotlight-tabs" role="tablist">
    <button class="spotlight-tab is-active" role="tab" aria-selected="true" data-slide="0">
      <code>Current book</code>
      <span>Step 1 · Open book menu</span>
    </button>
    <button class="spotlight-tab" role="tab" aria-selected="false" data-slide="1">
      <code>Style &amp; format</code>
      <span>Step 2 · Override &amp; reset</span>
    </button>
  </div>
  <div class="spotlight-stage">
    <figure class="spotlight-slide is-active" role="tabpanel">
      <div class="doc-device-frame">
        <img src="{{base}}/assets/img/current-book-kindle.svg" alt="KOReader Tomedown Current book menu" />
      </div>
      <figcaption>Open <strong>Tomedown → Current book</strong> to manage notes, visibility, and style for the active book.</figcaption>
    </figure>
    <figure class="spotlight-slide" role="tabpanel">
      <div class="doc-device-frame">
        <img src="{{base}}/assets/img/current-book-style-kindle.svg" alt="KOReader Tomedown Current book Style and format submenu" />
      </div>
      <figcaption>Override any formatting option for that book alone, or tap <strong>Reset to global style settings</strong>.</figcaption>
    </figure>
  </div>
</div>
