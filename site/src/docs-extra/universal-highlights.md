# Highlight Styles & Frontmatter

Tomedown works with Obsidian, GitHub, Logseq, or any plain text viewer. Highlight and note formatting options live in **Tomedown → Settings → Notes & highlights**, frontmatter configuration lives in **Settings → Export → Frontmatter fields**, and you can override any of them for a single book in **Current book → Format & layout**.

## 6 Special highlight styles

Flag standout quotes with **Special Highlight** when selecting text in KOReader. In **Settings → Notes & highlights → Special highlight style**, choose:

1. **Callout (`[!highlight]`)**: Obsidian callout block.
2. **Alert (`[!IMPORTANT]`)**: GitHub-flavored alert box.
3. **Highlight (`==text==`)**: standard Markdown highlight.
4. **Highlight & Bold (`==**text**==`)**: highlighted and bold.
5. **Star & Bold (`⭐ **text**`)**: star badge next to bold text.
6. **Bold (`**text**`)**: clean bold text that works everywhere.

Enable **Every highlight is special** in **Settings → Notes & highlights** if you want *all* highlights to use your chosen style automatically.

<figure class="doc-device-figure">
  <img src="{{base}}/assets/img/docs-09-special-highlight-selection.svg" alt="Special Highlight button in KOReader text selection popup" width="463" height="647" loading="lazy" decoding="async" />
</figure>

### Promote or remove a Special Highlight anytime

You are never locked into your initial choice while reading. Tap any existing highlight on the page in KOReader to toggle its starred status right from the highlight popup:

- **Make special**: promotes a normal highlight into a **★ Special Highlight** so it adopts your chosen highlight style and appears in the *Special highlights showcase*.
- **Remove special**: converts a starred passage back into a standard highlight while keeping the quote and any attached personal note intact.

<figure class="doc-device-figure doc-device-figure-wide">
  <img src="{{base}}/assets/img/docs-09-special-highlight-make-special.svg" alt="Toggling Make special and Remove special on an existing highlight in KOReader" width="746" height="647" loading="lazy" decoding="async" />
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
        <div class="quote-meta"><strong>p. 26</strong> — 14 Nov 2026 | 10:20</div>
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
        <div class="quote-meta"><strong>p. 26</strong> — 14 Nov 2026 | 10:20</div>
      </div>

      <!-- 3. Highlight -->
      <div class="style-pane" data-pane="highlight">
        <blockquote class="obsidian-quote">
          <p><mark class="render-mark">She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</mark></p>
        </blockquote>
        <div class="quote-meta"><strong>p. 26</strong> — 14 Nov 2026 | 10:20</div>
      </div>

      <!-- 4. Highlight & Bold -->
      <div class="style-pane" data-pane="hl-bold">
        <blockquote class="obsidian-quote">
          <p><mark class="render-mark"><strong>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</strong></mark></p>
        </blockquote>
        <div class="quote-meta"><strong>p. 26</strong> — 14 Nov 2026 | 10:20</div>
      </div>

      <!-- 5. Star & Bold -->
      <div class="style-pane" data-pane="star">
        <blockquote class="obsidian-quote">
          <p><span class="render-star">⭐</span> <strong>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</strong></p>
        </blockquote>
        <div class="quote-meta"><strong>p. 26</strong> — 14 Nov 2026 | 10:20</div>
      </div>

      <!-- 6. Bold -->
      <div class="style-pane" data-pane="bold">
        <blockquote class="obsidian-quote">
          <p><strong>She had the feeling that he resented her presence in the country, and was anxious to replace her with a proprietor less poverty-stricken.</strong></p>
        </blockquote>
        <div class="quote-meta"><strong>p. 26</strong> — 14 Nov 2026 | 10:20</div>
      </div>
    </div>
  </div>
</div>

## Notes & highlights menu overview

All formatting controls for highlights, personal notes, chapter headings, page bookmarks, handwritten drawings, and book page modules are organized under **Settings → Notes & highlights** in KOReader:

<figure class="doc-device-figure">
  <img src="{{base}}/assets/img/docs-main-book-page-section-styles.svg" alt="Settings → Notes &amp; highlights full menu in KOReader" width="463" height="647" loading="lazy" decoding="async" />
</figure>

## Book page & Section styles

In **Settings → Notes & highlights → Book page**, you can configure the header layout and rich visual sections of every exported book note:

- **Book title in body**: includes `# Book Title` H1 and `### by Author · *Series (#N)*` H3 at the start of the body.
- **Book cover**: extracts the book's full-color cover into `covers/` and embeds it at the top of the book note and in `00 - Index.md`.
- **Overview style**: pick how the highlights count and star metrics look:
  - **Inline / Heading**: `### **14 highlights · ★ 2 special**` (default).
  - **Classic blockquote**: `> **14 highlights · ★ 2 special**`.
  - **Callout ([!summary])**: `> [!summary] Overview` box.
  - **Table**: compact Markdown summary table.
- **Reading dashboard**: embeds a `> [!book]` dashboard at the top of the note with Status, 5-star Rating, Reading dates (`10 Nov 2026 → 16 Nov 2026`), and a link back to `00 - Index.md`.
- **Book synopsis** & **Synopsis display**: extracts the EPUB description into a `> [!abstract]- Synopsis` section (**Collapsed** by default, or **Expanded**).
- **Tags in body**: appends `#tag1 #tag2` clickable hashtags directly below the header.
- **Special highlights showcase**: generates a collapsible `> [!highlight]- ★ Special highlights (N)` section showcasing your starred quotes at the top.
- **Section styles ▸**: opens the dedicated visual style submenu:
  - **Harmonize book styles**: master toggle to apply a single unified visual style (**Book style**: *Minimal symbols*, *Emoji*, *Code badges*, or *Editorial*) across your book modules, `00 - Index.md`, and `00 - Reading Digest.md`.
  - When **Harmonize book styles** is off, you can configure **Dashboard style**, **Synopsis style**, **Tags style**, and **Showcase style** individually.

<figure class="doc-device-figure doc-device-figure-wide">
  <img src="{{base}}/assets/img/docs-10-book-page-section-styles.svg" alt="Settings → Notes &amp; highlights → Book page &amp; Section styles menus in KOReader" width="746" height="647" loading="lazy" decoding="async" />
</figure>

## Handwritten notes & Stylus drawings

If your device supports a stylus (e.g. Kindle Scribe, Kobo Sage/Elipsa, Android e-ink, or via KOReader's `pencil.koplugin`), Tomedown extracts handwritten annotations from your `.sdr` directory when **Settings → Notes & highlights → Handwritten notes** is enabled:

- Point-sequence pen strokes are converted to crisp **SVG** vector files.
- Drawings are saved into the `drawings/` folder inside your vault (customizable via **Settings → Export → File names & folders → Drawings folder**).
- Drawings are embedded with standard Markdown syntax (`![Handwritten note · p. X](drawings/...)`) and receive permanent block IDs (`^hl-xxxxxxxx`).

## Personal notes format, details, chapters & context

In **Settings → Notes & highlights**:

- **Personal notes format**: choose **Inline** *(default, placed directly below the quote)* or **Footnotes** *(collected as `[^1]` at the end of the file)*.
- **Highlight details**: choose **Page and date** (`- **p. 15** · 16 Nov 2026 | 10:20`), **Page only**, **Date only**, or **None**.
- **Chapter headings**: choose **Heading 1 (`#`)**, **Heading 2 (`##`)**, **Heading 3 (`###`)**, or **None (continuous list)**.
- **Highlight context**: on reflowable books (EPUB, FB2, MOBI…), extracts the words right before and after your highlight and adds a `- **Context:** *…*` line below the quote.
- **Link IDs on highlights**: appends a stable `^hl-xxxxxxxx` block ID at the end of each quote so Obsidian can link to or embed a single highlight.

## Frontmatter fields & custom properties

In **Settings → Export → Frontmatter fields**, you can:

- Toggle YAML frontmatter on or off (*Include YAML frontmatter*).
- Show or hide individual fields (`cover`, `series`, `language`, `pages`, `exported`, `highlights`, `special`, `status`, `progress`).
- Enable **Custom fields** and tap **Custom frontmatter fields…** to add your own `key: value` properties (e.g. `type: book` or `vault: reading`).
- Set a **Frontmatter key order…** (comma-separated list of keys).

<div class="spotlight doc-spotlight" role="region" aria-label="Frontmatter fields and custom key order in KOReader">
  <div class="spotlight-tabs" role="tablist" aria-label="Frontmatter menus">
    <button type="button" class="spotlight-tab is-active" role="tab" aria-selected="true" aria-controls="fm-fields-slide" id="tab-fm-fields">
      <span class="spotlight-tab-num">01</span>
      <span class="spotlight-tab-text">
        <strong>Frontmatter fields</strong>
        <span class="spotlight-tab-sub">Toggle keys &amp; custom properties</span>
      </span>
    </button>
    <button type="button" class="spotlight-tab" role="tab" aria-selected="false" aria-controls="fm-order-slide" id="tab-fm-order">
      <span class="spotlight-tab-num">02</span>
      <span class="spotlight-tab-text">
        <strong>Custom key order</strong>
        <span class="spotlight-tab-sub">Reorder YAML properties</span>
      </span>
    </button>
  </div>
  <div class="spotlight-stage">
    <figure class="spotlight-slide is-active" id="fm-fields-slide" role="tabpanel" aria-labelledby="tab-fm-fields">
      <div class="doc-device-figure">
        <img src="{{base}}/assets/img/frontmatter-fields-kindle.svg" alt="Settings → Export → Frontmatter fields submenu in KOReader" width="463" height="647" loading="lazy" decoding="async" />
      </div>
      <figcaption class="spotlight-caption">Toggle individual YAML keys and enable custom frontmatter properties.</figcaption>
    </figure>
    <figure class="spotlight-slide" id="fm-order-slide" role="tabpanel" aria-labelledby="tab-fm-order">
      <div class="doc-device-figure doc-device-figure-wide">
        <img src="{{base}}/assets/img/frontmatter-key-order-kindle.svg" alt="Frontmatter custom key order dialog in KOReader" width="746" height="648" loading="lazy" decoding="async" />
      </div>
      <figcaption class="spotlight-caption">Customize the exact order of YAML frontmatter keys across your notes.</figcaption>
    </figure>
  </div>
</div>

## Per-book overrides

Inside an open book, go to **Tomedown → Current book → Format & layout** to override export format, Markdown style, personal notes format, highlight details, chapter headings, context, book cover, page bookmarks, handwritten notes, or **Book page** settings for **that book only**. Tap **Reset to global style settings** anytime to return to your library defaults.
