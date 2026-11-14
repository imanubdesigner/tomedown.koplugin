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

## Notes & sync

### Will an export overwrite what I wrote in a note?

Not if **Keep my notes** is turned on (for all books, or per book). The next export folds new highlights into the existing file, preserves your personal notes and inline comments below quotes, and keeps rotating backup copies (`.bak`, `.bak.1`–`.bak.3`). See [Keep my notes](keep-my-notes.md).

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
