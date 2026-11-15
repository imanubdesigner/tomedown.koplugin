# Frequently asked questions

- [General](#general)
- [Files, formats & tags](#files-formats-tags)
- [Notes & sync](#notes-sync)
- [Updates & help](#updates-help)

## General

### Do I need a cloud account or Obsidian?

No. Tomedown writes plain `.md` (or `.txt`) files directly to a folder on your device, and that works completely offline. Cloud upload (WebDAV, Dropbox, FTP) and Obsidian are optional.

### Which devices does it run on?

Anywhere KOReader runs (Kindle, Kobo, Android, PocketBook…). The plugin is plain Lua and touches no hardware.

### Is it free and open source?

Yes. Tomedown is free software licensed under the GNU AGPL-3.0, with no telemetry and no lock-in.

## Files, formats & tags

### Where do the files go?

By default into `clipboard/tomedown` inside KOReader's data folder: one file per book, plus `00 - Index.md` (and `00 - Reading Digest.md` when exported). You can change the folder in [Menu & Settings](settings.md).

### What happens if I switch between `.md` and `.txt`?

In **Settings → Files → Export format**, you can pick **Markdown (.md)**, **Plain text (.txt)**, or **Both**. When you switch formats, Tomedown automatically manages and cleans up the files on the next export so you do not end up with stale duplicates.

### Why do my EPUB tags look cleaner in `00 - Index.md`?

Tomedown automatically splits Calibre/EPUB subject facets (like `Fiction -- Mystery & Detective`) into clean individual tags and stacks them as compact `#tag` pills so the index table stays tidy.

### Can I customize highlight styles or frontmatter for just one book?

Yes. Open the book, go to **Tomedown → Current book → Style & format**, and override export format, personal notes format, highlight details, chapter headings, context, covers, page bookmarks, or YAML frontmatter for that book alone.

### Can I export only certain selected books?

Yes. Tap **Tomedown → Choose books…** to open an interactive checklist of all books in your library. You can select or deselect individual books, check the total count, and tap **Export selected** to export only those volumes.

### What is Repair all files?

**Repair all files** in the main Tomedown menu regenerates every book note from scratch using KOReader's stored reading history. It is the easiest way to restore notes if a file was deleted by mistake on your computer or if a vault sync went wrong.

## Notes & sync

### Will an export overwrite what I wrote in a note?

Not if **Keep my notes** is turned on (for all books, or per book). The next export folds new highlights into the existing file, preserves your personal notes and inline comments below quotes, and keeps rotating backup copies (`.bak`, `.bak.1`–`.bak.3`). See [Keep my notes](keep-my-notes.md).

### How does Tomedown protect my notes with backup copies?

Tomedown maintains two types of backups right next to your note:
1. **Saved notes (`.bak`)**: when you turn off *Keep my notes* for a book, Tomedown parks your zoned file with your personal notes in `.bak`. It is restored automatically when you turn Keep my notes back on.
2. **Safety copies (`.bak.1`, `.bak.2`, `.bak.3`)**: when an external edit from Obsidian conflicts or a file rewrite occurs, safety snapshots are automatically rotated.

Inside any book, tap **Tomedown → Current book → Backup copies** to view timestamps, file sizes, or delete obsolete copies safely.

```text
Current book
└── Backup copies
    ├── Saved notes      → file .bak   (preserved personal notes)
    ├── Safety copy      → file .bak.1 (latest emergency snapshot)
    └── Safety copy      → file .bak.2 (previous snapshot in rotation)
```

### What does Upload all files again do?

If you configure cloud upload (WebDAV, Koofr, Dropbox, FTP), **Upload all files again** re-examines every local note and uploads any missing or newer files to your cloud server without needing to trigger a full re-export.

### Can I delete obsolete tags across my entire library?

Yes. Open any book, tap **Current book → Book info → Tags → Delete tags…**, and Tomedown will display a clean grid of all tags used across your library. Tapping a tag removes it from every managed book's keywords automatically.

### What happens if I export while offline?

The local export always succeeds. If cloud upload is enabled, the modified files wait in a pending list and upload automatically the next time KOReader connects to Wi‑Fi.

### Which Remotely Save sync direction should I pick?

Leave it on *Bidirectional*. The [Sync direction](sync-direction.md) page explains all five options.

### I already use AnnotationSync. Will they conflict?

No. Tomedown inherits your configured cloud server from KOReader's *Cloud storage*, never touches AnnotationSync's `<md5>.json` files, and only reads `.sdr` folders.

## Updates & help

### How do I update the plugin?

Open **Tomedown → Settings → Updates → Check for updates** right inside KOReader. You can also opt into beta releases or install manually from [GitHub Releases](https://github.com/imanubdesigner/tomedown.koplugin/releases).

### Something does not work

Open an [issue](https://github.com/imanubdesigner/tomedown.koplugin/issues) or ask in [Discussions](https://github.com/imanubdesigner/tomedown.koplugin/discussions).
