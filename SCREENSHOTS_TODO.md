# Tomedown — Checklist Screenshot da Realizzare (`SCREENSHOTS_TODO.md`)

Questo documento raccoglie tutti gli screenshot aggiornati da catturare su **KOReader** e **Obsidian** per sostituire i box placeholder visibili su `index.html` e nella sezione `/docs` del sito.

> **Nota:** Ogni box placeholder visibile sul sito mostra già il nome esatto del file (con l'estensione corretta `.svg` o `.webp`) e dispone del pulsante **Copy filename** per copiare rapidamente il nome negli appunti. Nessun file immagine precedente (`.png`, `.svg`, `.webp`) è stato eliminato dal disco.
>
> **Regola Formati:**
> - **`.svg` (Preset vettoriale KOReader):** Tutte le schermate in cui è inquadrato solo il dispositivo e-reader con i menu/dialoghi/card singole del programma (stile `~/Documents/TomedownBrain/2.1.1/screenshots/SVG/`).
> - **`.webp` (Qualità `q90` o `q95`):** Le composizioni della Home (es. dispositivo + nota Markdown o composizione di più card insieme come *Book summary* + *Last export*) e tutte le schermate desktop di **Obsidian / MarkText**.

---

## 1. Homepage (`index.html`)

- [ ] **`home-01-hero-overview.webp`**
  - **Dove appare:** Hero section principale in `index.html`.
  - **Cosa inquadrare:** Composizione principale della Hero (16:9, es. 2000×1125 px): a destra un e-reader con KOReader aperto sul nuovo menu **Tomedown** (o sulla card **Book summary** / **Special Highlight**), e a sinistra la corrispondente nota Markdown renderizzata in Obsidian con copertina, *Reading dashboard*, *Book synopsis* e citazioni.
- [ ] **`home-02-koreader-cards.webp`**
  - **Dove appare:** Sezione *How it looks in practice* in `index.html` (colonna sinistra).
  - **Cosa inquadrare:** Schermata di KOReader che mostra la card arrotondata **Current book → Book summary** (con i 3 contatori KPI cliccabili *Highlights*, *★ Special*, *Notes*, formato attivo e stato) affiancata alla card **Last export** o al menu principale ristrutturato.
- [ ] **`home-03-obsidian-vault-views.webp`**
  - **Dove appare:** Sezione *How it looks in practice* in `index.html` (colonna destra).
  - **Cosa inquadrare:** Finestra desktop di Obsidian (16:10) che mostra il catalogo `00 - Index.md` (copertine 90×120, barre di avanzamento a 5 celle `▰▰▰▰▰`, *Completed books* Trophy Room e *Tag cloud*) insieme al diario cronologico `00 - Reading Digest.md`.

---

## 2. Documentazione — Getting Started (`/docs/quickstart/`)

- [ ] **`docs-01-main-menu.svg`**
  - **Dove appare:** `/docs/quickstart/` — Sezione *1. Install the plugin*.
  - **Cosa inquadrare:** Il menu principale di **Tomedown** aperto da un libro in KOReader (Reader view): mostra le voci **Export this book**, **All books ▸**, **Current book ▸**, **Last export**, **Settings ▸** e **About**.
- [ ] **`docs-02-all-books-menu.svg`**
  - **Dove appare:** `/docs/quickstart/` — Sezione *2. Run your first export*.
  - **Cosa inquadrare:** Il sottomenu **Tomedown → All books** su KOReader (con *Export changed books*, *Export all books again…*, *Select books…*, *Export reading digest*) oppure la schermata checklist interattiva di **Select books…**.

---

## 3. Documentazione — Reading Digest (`/docs/reading-digest/`)

- [ ] **`docs-03-reading-digest-obsidian.webp`**
  - **Dove appare:** `/docs/reading-digest/` e `/docs/obsidian/`.
  - **Cosa inquadrare:** La nota `00 - Reading Digest.md` aperta in Obsidian (Reading View): mostra il blocco *Overview* in alto, le intestazioni di data letteraria (es. `## 16 Nov 2026`), i divisori orizzontali `---` tra libri letti nello stesso giorno e gli orari puliti (`09:41`) sotto ogni citazione.
- [ ] **`docs-04-digest-menu-koreader.svg`**
  - **Dove appare:** `/docs/reading-digest/` — Sezione *How to export it*.
  - **Cosa inquadrare:** Su KOReader, il sottomenu **Tomedown → All books** con la voce **Export reading digest** visibile in fondo, oppure il toggle **Reading digest (00 - Reading Digest.md)** dentro **Settings → Export**.

---

## 4. Documentazione — Templates, Folders & Index (`/docs/templates-and-folders/`)

- [ ] **`docs-05-export-format-menu.svg`**
  - **Dove appare:** `/docs/templates-and-folders/` — Sezione *Export format (.md and .txt)*.
  - **Cosa inquadrare:** Il sottomenu radio **Settings → Export → Export format** su KOReader con le tre opzioni: *Markdown (.md)*, *Plain text (.txt)* e *Both (.md and .txt)*.
- [ ] **`docs-06-filenames-folders-menu.svg`**
  - **Dove appare:** `/docs/templates-and-folders/` — Sezione *File names & folders*.
  - **Cosa inquadrare:** Il nuovo sottomenu **Settings → Export → File names & folders** su KOReader che mostra le quattro voci: *File name template*, *Folder organization*, *Covers folder* e *Drawings folder*.
- [ ] **`docs-07-index-library-menu.svg`**
  - **Dove appare:** `/docs/templates-and-folders/` e `/docs/settings/` — Sezione *Index & library*.
  - **Cosa inquadrare:** Il gruppo **Settings → Index & library** su KOReader con il master toggle *Index note (00 - Index.md)*, le opzioni di struttura (*Index order*, *Index layout*, *Index links*, *Index style*, *Tags display*) e i quattro toggle delle sezioni (*Reading now section*, *Completed books*, *Library dashboard*, *Tag cloud*).
- [ ] **`docs-08-longpress-file-dialog.svg`**
  - **Dove appare:** `/docs/templates-and-folders/` — Sezione *Manage books anywhere (Long-press shortcuts)*.
  - **Cosa inquadrare:** Il dialogo che appare tenendo premuto (long-press) un libro nel File Manager o in History su KOReader, mostrando i pulsanti rapidi di Tomedown: **Export this book**, **Tags…**, **Book visibility…** e **Import book info**.

---

## 5. Documentazione — Highlight Styles & Frontmatter (`/docs/universal-highlights/`)

- [ ] **`docs-09-special-highlight-selection.svg`**
  - **Dove appare:** `/docs/universal-highlights/` — Sezione *6 Special highlight styles*.
  - **Cosa inquadrare:** Il popup di selezione testo durante la lettura di un libro su KOReader, evidenziando il pulsante **Special Highlight** subito sotto *Highlight*.
- [ ] **`docs-10-book-page-section-styles.svg`**
  - **Dove appare:** `/docs/universal-highlights/` — Sezione *Book page & Section styles*.
  - **Cosa inquadrare:** Il sottomenu **Settings → Notes & highlights → Book page** (con *Book title in body*, *Book cover*, *Overview style*, *Reading dashboard*, *Book synopsis*, *Synopsis display*, *Tags in body*, *Special highlights showcase* e *Section styles ▸*) affiancato o aperto su **Section styles** con il toggle **Harmonize book style**.
- [ ] **`docs-11-frontmatter-fields-menu.svg`**
  - **Dove appare:** `/docs/universal-highlights/` — Sezione *Frontmatter fields & custom properties*.
  - **Cosa inquadrare:** Il sottomenu **Settings → Export → Frontmatter fields** su KOReader, mostrando *Include YAML frontmatter*, i toggle delle chiavi YAML, *Custom fields* e *Frontmatter key order…*.

---

## 6. Documentazione — Menu & Settings (`/docs/settings/`)

- [ ] **`docs-12-settings-groups.svg`**
  - **Dove appare:** `/docs/settings/` — Introduzione.
  - **Cosa inquadrare:** Il menu **Tomedown → Settings** su KOReader con i 7 nuovi gruppi: **Export**, **Index & library**, **Notes & highlights**, **Book info**, **Cloud upload**, **My notes** e **App & updates**.
- [ ] **`docs-13-settings-export.svg`**
  - **Dove appare:** `/docs/settings/` — Sezione *Export*.
  - **Cosa inquadrare:** Il gruppo **Settings → Export** su KOReader mostrando *Export format*, *Markdown style*, *Local folder*, *File names & folders ▸*, *Frontmatter fields ▸*, *Export when I close a book*, *Reading digest (00 - Reading Digest.md)*, *Backup copies* e le azioni *Export settings to file* / *Restore settings from backup…*.
- [ ] **`docs-14-settings-notes-highlights.svg`**
  - **Dove appare:** `/docs/settings/` — Sezione *Notes & highlights*.
  - **Cosa inquadrare:** Il gruppo **Settings → Notes & highlights** su KOReader mostrando i controlli delle evidenziazioni (*Special highlight style*, *Highlight details*, *Highlight context*, *Link IDs on highlights*, *Every highlight is special*), delle note e struttura (*Personal notes format*, *Chapter headings*, *Page bookmarks*, *Handwritten notes*) e la riga *Book page ▸*.
- [ ] **`docs-15-last-export-card.svg`**
  - **Dove appare:** `/docs/settings/` — Sezione *Last export dashboard*.
  - **Cosa inquadrare:** La card arrotondata **Tomedown → Last export** su KOReader: data/ora dell'ultimo export, barra KPI a 3 colonne (*Exported*, *Skipped*, *Errors / Backups*), formato attivo, ultimi titoli esportati e pulsanti **Export updated**, **Upload now** e **Close**.
- [ ] **`docs-16-settings-book-info.svg`**
  - **Dove appare:** `/docs/settings/` — Sezione *Book info*.
  - **Cosa inquadrare:** Il gruppo **Settings → Book info** su KOReader con le due voci: *Update book info automatically* e *Import book info for all books…*.
- [ ] **`docs-17-settings-cloud-upload.svg`**
  - **Dove appare:** `/docs/settings/` — Sezione *Cloud upload*.
  - **Cosa inquadrare:** Il gruppo **Settings → Cloud upload** su KOReader con *Upload to cloud*, *Destination: … ▸* (e il relativo sottomenu unificato con *Choose in cloud storage…*, *Enter remote path…*, *Clear remote path…*) e *Re-upload all files…*.
- [ ] **`docs-18-settings-my-notes.svg`**
  - **Dove appare:** `/docs/settings/` — Sezione *My notes*.
  - **Cosa inquadrare:** Il gruppo **Settings → My notes** su KOReader con *Keep my notes for all books*, *Keep my notes in the index*, *Notes heading* e *Bring in edits made in Obsidian*.
- [ ] **`docs-19-settings-app-updates.svg`**
  - **Dove appare:** `/docs/settings/` — Sezione *App & updates*.
  - **Cosa inquadrare:** Il gruppo **Settings → App & updates** su KOReader mostrando *Top bar icon*, *Check for updates (vX)*, *Release channel: Stable ▸* (con radio *Stable* / *Beta*), *Check for updates in background* e *View changelog*.

---

## 7. Documentazione — Current Book (`/docs/current-book/`)

- [ ] **`docs-20-current-book-menu.svg`**
  - **Dove appare:** `/docs/current-book/` — Introduzione.
  - **Cosa inquadrare:** Il sottomenu **Tomedown → Current book** su KOReader con il nuovo ordine gerarchico: **Book summary** al primo posto, seguito da **★ Special highlights**, separatore, **Book info ▸**, **Book visibility: Normal ▸**, separatore, **Keep my notes in this book**, **Notes heading**, **Backup copies ▸** e **Format & layout ▸**.
- [ ] **`docs-21-book-summary-card.svg`**
  - **Dove appare:** `/docs/current-book/` — Sezione *Book summary dashboard card*.
  - **Cosa inquadrare:** La card arrotondata **Book summary** su KOReader: titolo e autore in alto, i 3 pulsanti KPI cliccabili (*Highlights*, *★ Special*, *Notes*), i dettagli *Format*, *Status*, *Tags* e i pulsanti **Export this book** e **Close**.
- [ ] **`docs-22-highlights-notes-cards.svg`**
  - **Dove appare:** `/docs/current-book/` — Sezione *Highlights, ★ Special & Notes card browser*.
  - **Cosa inquadrare:** La card paginata delle evidenziazioni o delle note personali su KOReader (con sottotitolo *Tap to jump · Hold for ★* oppure *Tap to jump · Hold to edit*, elenco citazioni con capitolo/pagina e frecce di paginazione `◀` / `▶`).
- [ ] **`docs-23-current-book-format-layout.svg`**
  - **Dove appare:** `/docs/current-book/` — Sezione *Format & layout overrides*.
  - **Cosa inquadrare:** Il sottomenu **Current book → Format & layout** su KOReader con indicatori `Global` / `Custom` a destra: mostra *Export format*, *Markdown style*, *Personal notes format*, *Highlight details*, *Chapter headings*, *Highlight context*, *Book cover*, *Page bookmarks*, *Handwritten notes*, *Book page ▸* e *Reset to global style settings*.
- [ ] **`docs-24-book-visibility-radio.svg`**
  - **Dove appare:** `/docs/current-book/` — Sezione *Book visibility radio submenu*.
  - **Cosa inquadrare:** Il nuovo sottomenu radio **Current book → Book visibility** su KOReader con le tre opzioni: *Export and show in the index*, *Export, but hide from the index* e *Do not export*.

---

## 8. Documentazione — Formats & Output, Keep My Notes & Obsidian Guide (`/docs/file-format/`, `/docs/keep-my-notes/`, `/docs/obsidian/`)

- [ ] **`docs-25-book-note-modules-obsidian.webp`**
  - **Dove appare:** `/docs/file-format/` e `/docs/obsidian/`.
  - **Cosa inquadrare:** Una nota libro completa in Obsidian (Reading View) che mostri le Properties YAML, la copertina, i moduli dell'intestazione (*Reading dashboard*, *Book synopsis* richiudibile, tag nel corpo, *Overview* e *★ Special highlights showcase*) seguiti dalle citazioni del capitolo.
- [ ] **`docs-26-obsidian-vs-standard-markdown.webp`**
  - **Dove appare:** `/docs/file-format/` — Sezione *Standard Markdown vs Obsidian style*.
  - **Cosa inquadrare:** Confronto affiancato della stessa nota libro esportata con **Markdown style: Obsidian** (callout `[!...]` e wikilink a sinistra) e con **Markdown style: Standard** (intestazioni Markdown standard `###` e link `[Title](file.md)` a destra).
- [ ] **`docs-27-index-dashboard-obsidian.webp`**
  - **Dove appare:** `/docs/file-format/` e `/docs/obsidian/` — Sezione *The index (00 - Index.md)*.
  - **Cosa inquadrare:** `00 - Index.md` in Obsidian mostrando la *Library dashboard*, la sezione *Completed books* (Trophy Room), la tabella con copertine 90×120, barre di avanzamento a 5 celle e tag impilati, e la *Tag cloud* finale.
- [ ] **`docs-28-keep-my-notes-obsidian.webp`**
  - **Dove appare:** `/docs/keep-my-notes/` e `/docs/obsidian/` — Sezione *Keep my notes*.
  - **Cosa inquadrare:** Una nota libro in Obsidian con la sezione personale `## My notes...` popolata dall'utente sopra il blocco generato da Tomedown, dimostrando come le riflessioni personali sopravvivano a ogni esportazione.
- [ ] **`docs-29-highlight-link-ids-obsidian.webp`**
  - **Dove appare:** `/docs/obsidian/` — Sezione *Link to a single highlight*.
  - **Cosa inquadrare:** Una citazione in Obsidian dotata di block ID stabile `^hl-xxxxxxxx` e l'autocompletamento o la trasclusione live `![[Book title#^hl-xxxxxxxx]]` dentro un'altra nota del vault.
