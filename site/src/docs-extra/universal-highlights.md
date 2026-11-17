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

<div class="styles-showcase" data-reveal aria-label="Interactive 6 special highlight styles preview">
  <div class="showcase-tabs" role="tablist">
    <button type="button" class="style-tab is-active" role="tab" aria-selected="true" data-style="callout">
      <span class="tab-badge">01</span>
      <code>[!highlight]</code>
      <span class="tab-label">Callout</span>
    </button>
    <button type="button" class="style-tab" role="tab" aria-selected="false" data-style="alert">
      <span class="tab-badge">02</span>
      <code>[!IMPORTANT]</code>
      <span class="tab-label">Alert</span>
    </button>
    <button type="button" class="style-tab" role="tab" aria-selected="false" data-style="highlight">
      <span class="tab-badge">03</span>
      <code>==text==</code>
      <span class="tab-label">Highlight</span>
    </button>
    <button type="button" class="style-tab" role="tab" aria-selected="false" data-style="hl-bold">
      <span class="tab-badge">04</span>
      <code>==**text**==</code>
      <span class="tab-label">Highlight &amp; Bold</span>
    </button>
    <button type="button" class="style-tab" role="tab" aria-selected="false" data-style="star">
      <span class="tab-badge">05</span>
      <code>⭐ **text**</code>
      <span class="tab-label">Star &amp; Bold</span>
    </button>
    <button type="button" class="style-tab" role="tab" aria-selected="false" data-style="bold">
      <span class="tab-badge">06</span>
      <code>**text**</code>
      <span class="tab-label">Bold</span>
    </button>
  </div>

  <div class="showcase-window">
    <div class="window-header">
      <div class="window-dots">
        <span></span><span></span><span></span>
      </div>
      <div class="window-title">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
        <span>Arthur Machen - The Three Impostors.md</span>
      </div>
      <span class="window-env">Obsidian Live Render</span>
    </div>

    <div class="window-content">
      <!-- 1. Callout -->
      <div class="style-pane is-active" data-pane="callout">
        <div class="obsidian-callout callout-highlight">
          <div class="callout-header">
            <svg class="callout-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 3a2.828 2.828 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5L17 3z"/></svg>
            <span class="callout-title">Highlight</span>
          </div>
          <p class="callout-body">“She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.”</p>
        </div>
        <div class="quote-meta">• <strong>p. 26</strong> · 14 Nov 2026 | 10:20</div>
      </div>

      <!-- 2. Alert -->
      <div class="style-pane" data-pane="alert">
        <div class="obsidian-callout callout-alert">
          <div class="callout-header">
            <svg class="callout-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>
            <span class="callout-title">Important</span>
          </div>
          <p class="callout-body">“She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.”</p>
        </div>
        <div class="quote-meta">• <strong>p. 26</strong> · 14 Nov 2026 | 10:20</div>
      </div>

      <!-- 3. Highlight -->
      <div class="style-pane" data-pane="highlight">
        <blockquote class="obsidian-quote">
          <p><mark class="render-mark">She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</mark></p>
        </blockquote>
        <div class="quote-meta">• <strong>p. 26</strong> · 14 Nov 2026 | 10:20</div>
      </div>

      <!-- 4. Highlight & Bold -->
      <div class="style-pane" data-pane="hl-bold">
        <blockquote class="obsidian-quote">
          <p><mark class="render-mark"><strong>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</strong></mark></p>
        </blockquote>
        <div class="quote-meta">• <strong>p. 26</strong> · 14 Nov 2026 | 10:20</div>
      </div>

      <!-- 5. Star & Bold -->
      <div class="style-pane" data-pane="star">
        <blockquote class="obsidian-quote">
          <p><span class="render-star">⭐</span> <strong>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</strong></p>
        </blockquote>
        <div class="quote-meta">• <strong>p. 26</strong> · 14 Nov 2026 | 10:20</div>
      </div>

      <!-- 6. Bold -->
      <div class="style-pane" data-pane="bold">
        <blockquote class="obsidian-quote">
          <p><strong>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</strong></p>
        </blockquote>
        <div class="quote-meta">• <strong>p. 26</strong> · 14 Nov 2026 | 10:20</div>
      </div>
    </div>
  </div>
</div>

## Book layout & reading dashboard

Starting in **v2.1.0**, you can configure rich visual modules for every exported book note in **Settings → Style**:

- **Book title in body**: includes `# Book Title` H1 and `### by Author · *Series (#N)*` H3 at the start of the body.
- **Overview style**: pick how the highlights count and star metrics look:
  - **Inline / Heading**: `### **14 highlights · ★ 2 special**` (default).
  - **Classic blockquote**: `> **14 highlights · ★ 2 special**`.
  - **Callout**: `> [!summary] Overview` box.
  - **Table**: compact markdown summary table.
- **Reading dashboard**: embeds an interactive `> [!book]` callout at the top of the note with Status, 5-star Rating, Reading dates (`10 Nov 2026 → 16 Nov 2026`), and a link back to `00 - Index.md`.
- **Book synopsis**: automatically extracts the EPUB description into a collapsible `> [!abstract]- Synopsis` callout.
- **Body tags**: appends `#tag1 #tag2` clickable hashtags directly below the header.
- **Special highlights showcase**: generates a collapsible `> [!highlight]- ★ Special highlights (N)` section showcasing your starred quotes at the top.

<figure class="doc-shot">
  <div class="doc-shot-frame">
    <img class="zoom-modules" src="{{base}}/assets/img/book_modules_v210.webp" alt="Book note header modules in Obsidian: Reading dashboard, collapsible synopsis, tags, Overview, and Special highlights" />
  </div>
  <figcaption>Book layout in Obsidian: Reading dashboard, collapsible Book synopsis, clickable tags, Overview callout, and Special highlights showcase.</figcaption>
</figure>

## Handwritten notes & Stylus drawings

If your device supports a stylus (e.g. Kindle Scribe, Kobo Sage/Elipsa, Android e-ink, or via KOReader's `pencil.koplugin`), Tomedown extracts handwritten annotations from your `.sdr` directory:

- Point-sequence pen strokes are converted to crisp **SVG** vector files.
- Drawings are saved into the `drawings/` folder inside your vault (customizable via *Settings → Style → Drawings folder*).
- Drawings are embedded with standard Markdown syntax (`![Handwritten note · p. X](drawings/...)`) and receive permanent block IDs (`^hl-xxxxxxxx`).

> **Note on hardware testing:** Stroke extraction and pure-Lua SVG rendering are built and unit-tested against KOReader's `.sdr` / `pencil.koplugin` data format, though I do not own a stylus-equipped e-reader for full end-to-end hardware testing. If anything looks off on your device, feedback on GitHub or Codeberg is very welcome.

<figure class="doc-shot">
  <div class="doc-shot-frame">
    <img src="{{base}}/assets/img/handwritten_drawing_embed.webp" alt="Handwritten SVG stylus drawing embedded in an Obsidian book note" />
  </div>
  <figcaption>Vector SVG stylus drawing embedded natively inside the note with block ID and literary timestamp.</figcaption>
</figure>

## Personal notes format (Inline vs Footnotes)

When you attach a note to a highlight in KOReader, **Personal notes format** controls how it appears:

- **Inline** *(default)*: your note is placed directly below the quote.
- **Footnotes**: your note becomes a Markdown footnote (`[^1]`) at the end of the chapter or file, keeping the quote list compact.

## Highlight details, chapters & context

- **Highlight details**: choose **Page and date** (`- **p. 15** · 16 Nov 2026 | 10:20`), **Page only**, **Date only**, or **None**.
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
      <div class="doc-device-frame doc-device-frame-wide">
        <img src="{{base}}/assets/img/current-book-style-kindle.svg" alt="KOReader Tomedown Current book Style and format submenu" />
      </div>
      <figcaption>Override any formatting option for that book alone, or tap <strong>Reset to global style settings</strong>.</figcaption>
    </figure>
  </div>
</div>
