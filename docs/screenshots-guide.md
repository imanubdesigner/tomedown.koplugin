# Guida e Checklist Screenshot Tomedown v2.1.0

Questa guida contiene l'elenco completo di tutti gli screenshot da realizzare per documentare visivamente la versione **v2.1.0** di Tomedown, suddivisi tra **KOReader (Kindle / e-Reader)** e **Obsidian (Desktop)**.

---

## 📱 Gruppo 1: Screenshot su KOReader (Kindle / e-Reader)

Per questi screenshot puoi copiare la cartella [~/Downloads/tomedown.koplugin](file:///home/manu/Downloads/tomedown.koplugin) direttamente sul dispositivo in `/mnt/us/koreader/plugins/tomedown.koplugin` (oppure usare KOReader locale su Omarchy).

### 1. Menu Principale con Nuova Icona Top Bar
- **File di destinazione:** `assets/menu/reader/tomedown_reader_new_menu.png`
- **Inquadratura:** Schermata intera con un libro aperto e il menu a discesa di Tomedown aperto.
- **Cosa mostrare:**
  - Nella barra superiore di navigazione: la **nuova icona** ufficiale (sagoma libro con nastro segnalibro ad ala di rondine e freccia centrata).
  - Nel menu: le voci con icone, tra cui *Esporta questo libro*, *Esporta libri nuovi e modificati*, *Esporta digest di lettura*, *Libro corrente*, *Impostazioni*, *Informazioni*.

### 2. Popup Informazioni (About) con Nuovo Logo
- **File di destinazione:** `assets/menu/about_popup_v210.png`
- **Inquadratura:** Popup centrato *Informazioni su Tomedown*.
- **Cosa mostrare:**
  - Il nuovo logo panoramico ad alta definizione (icona libro + scritta tipografica *Tomedown*).
  - La dicitura di versione `v2.1.0`.
  - La descrizione e i link ai repository Codeberg e GitHub.

### 3. Menu Impostazioni → File
- **File di destinazione:** `assets/menu/settings/markdown_menu.png`
- **Inquadratura:** Schermata del gruppo *Impostazioni → File*.
- **Cosa mostrare:**
  - *Cartella locale*, *Struttura cartelle*, *Crea un digest di lettura (00 - Reading Digest.md)*.
  - *Formato esportazione (.md/.txt)*, *Copie di backup (N)*.
  - *Esporta impostazioni su file*, *Ripristina impostazioni da backup…*.

### 4. Finestra Conferma Pulizia Backup
- **File di destinazione:** `assets/menu/settings/confirm_delete_backups.png`
- **Inquadratura:** Popup ConfirmBox centrato.
- **Percorso:** *Impostazioni* → *File* → *Copie di backup* → *Elimina tutti i backup…*.
- **Cosa mostrare:** Il popup con il conteggio dei file: *"Eliminare tutti i N file di backup (*.bak) nella cartella locale? Le note esportate non verranno toccate."* con pulsanti *Elimina* e *Annulla*.

### 5. Menu Impostazioni → Indice
- **File di destinazione:** `assets/menu/settings/index_menu.png`
- **Inquadratura:** Schermata del gruppo *Impostazioni → Indice*.
- **Cosa mostrare:**
  - *Crea una nota indice (00 - Index.md)*, *Ordinamento indice*, *Layout indice*, *Link indice*.
  - *Mostra Sto leggendo nell'indice*, *Visualizzazione tag nell'indice: %1*.
  - *Mostra libri completati nell'indice*, *Mostra bacheca libreria nell'indice*, *Mostra nuvola di tag nell'indice*.

### 6. Menu Impostazioni → Stile
- **File di destinazione:** `assets/menu/settings/settings_highlights_menu.png`
- **Inquadratura:** Schermata del gruppo *Impostazioni → Stile*.
- **Cosa mostrare:**
  - *Note a mano libera*, *Cartella disegni: drawings*.
  - *Titolo del libro nel testo*, *Stile panoramica*, *Bacheca di lettura*, *Sinossi libro*, *Tag nel testo*, *Vetrina citazioni speciali*.

### 7. Sottomenu Stile Panoramica (Overview Style)
- **File di destinazione:** `assets/menu/settings/overview_style_menu.png`
- **Inquadratura:** Popup radio a schermo.
- **Percorso:** *Impostazioni* → *Stile* → *Stile panoramica*.
- **Cosa mostrare:** Le 4 scelte: *Intestazione nel testo*, *Citazione classica*, *Callout ([!summary])*, *Tabella*.

### 8. Sottomenu Copie di Backup Datate
- **File di destinazione:** `assets/menu/settings/backup_copies_dated_menu.png`
- **Inquadratura:** Sottomenu delle copie di backup in *Libro corrente → Copie di backup*.
- **Cosa mostrare:** Le etichette trasparenti con le date reali dei file (es. `Note salvate · 16 Nov 26`, `Ultimo snapshot · 14 Nov 26`).

---

## 💻 Gruppo 2: Screenshot in Obsidian (Desktop)

Apri il tuo vault Obsidian (ad es. `TomedownTest` o la tua cartella note sincronizzata) preferibilmente in **Dark Mode** o **Light Mode** pulita (tema Obsidian standard o minimale).

### 9. Scheda Libro Completa con Nuovi Moduli
- **File di destinazione:** `assets/obsidian/book_note_v210.png`
- **Modalità:** Reading View o Live Preview.
- **File da aprire:** Una nota di un libro con varie evidenziazioni (es. *The Three Impostors*).
- **Elementi da mostrare:**
  - Proprietà frontmatter in cima.
  - Titolo H1 `# The Three Impostors` e sottotitolo H3 `### by Arthur Machen`.
  - Bacheca di lettura `> [!book]` (con Stato, Rating a stelle, Date di lettura e link `← Book index`).
  - Sinossi collassabile `> [!abstract]- Synopsis`.
  - Box Panoramica (ad es. callout `> [!summary] Overview` o tabella).
  - Vetrina citazioni speciali `> [!highlight]- ★ Special highlights`.
  - Citazioni con il nuovo formato orario pulito letterario: `- **p. 3** · 16 Nov 2026 | 09:29`.

### 10. Reading Digest Giornaliero
- **File di destinazione:** `assets/obsidian/reading_digest_v210.png`
- **Modalità:** Reading View o Live Preview.
- **File da aprire:** `00 - Reading Digest.md`.
- **Elementi da mostrare:**
  - Intestazione `# Reading digest` e citazione letteraria iniziale.
  - Intestazione giorno letteraria: `## 16 Nov 2026`.
  - Due libri diversi sotto la stessa data separati dalla linea sottile `---`.
  - Metadati orari puliti sotto ogni citazione (es. `• Adventure... · p. 11 · 09:41`).

### 11. Indice Evoluto con Trofei e Dashboard
- **File di destinazione:** `assets/obsidian/index_v210_trophy_dashboard.png`
- **Modalità:** Reading View.
- **File da aprire:** `00 - Index.md`.
- **Elementi da mostrare:**
  - La bacheca libreria (Dashboard) in alto.
  - La stanza dei trofei: `### Completed books` con rating e statistiche.
  - La tabella principale dei libri con copertine e tag.
  - La sezione *Tag cloud* con le etichette pesate e cliccabili.

### 12. Dettaglio Disegno / Nota a Mano Libera (Stylus)
- **File di destinazione:** `assets/obsidian/handwritten_drawing_embed.png`
- **Modalità:** Live Preview o Reading View.
- **Cosa mostrare:** Una citazione con embed di un disegno SVG/PNG vettoriale (`drawings/...`), con icona ✍️, pagina, orario e block ID `^hl-...`.

---

## 📂 Dove salvare i file
Una volta scattati gli screenshot:
- Quelli di KOReader / menu vanno in: `assets/menu/` o `assets/menu/settings/`
- Quelli di Obsidian vanno in: `assets/obsidian/`
