# Setup tutorial: cloud + Obsidian (Koofr and Remotely Save as the example)

From zero to reading your KOReader highlights in Obsidian. Two free
accounts, five minutes, no code.

**What you'll get:** one `.md` file per book (highlights, notes, metadata)
in your cloud, synced into your Obsidian vault — plus an index that links
them all.

> The steps below use **Koofr** (free plan: 10 GB, plenty for a lifetime
> of notes) and **Remotely Save** as the concrete example. Any WebDAV
> server works on both sides — Nextcloud, ownCloud, a NAS, your own
> WebDAV — and any Markdown reader works instead of Obsidian; just
> substitute the address and credentials.

> Prerequisite: the plugin itself is installed and enabled
> ([Installation in the README](README.md#installation)).

## Step 1 — Cloud account and app password (Koofr as the example)

1. Create a free account at **https://app.koofr.net** — the 10 GB of the
   free plan are more than enough for a lifetime of `.md` notes.
2. (Optional) create the folder where the notes will live, e.g.
   `Bookshelf/Kindle`.
3. Create an **app password**:
   **https://app.koofr.net/app/admin/preferences/password**
   → add a new app password and copy it. This is what KOReader and
   Obsidian will use — never your real Koofr password. (With your own
   server, use its own password instead.)

Koofr's WebDAV address (used in the next steps):

```
https://app.koofr.net/dav/Koofr
```

Self-hosted (Nextcloud, ownCloud, NAS…)? Use its own URL, username and
password everywhere below instead.

## Step 2 — KOReader: point Tomedown at your cloud

☰ menu → **Tomedown** → **Settings**:

1. ***Upload to cloud*** — leave it ticked (it is by default).
2. ***Server and folder…*** — opens KOReader's Cloud storage browser:

   - add a **WebDAV** server if you don't have one yet:
     for Koofr, address `https://app.koofr.net/dav/Koofr`, username = your
     Koofr e-mail, password = the **app password** from step 1;
   - navigate to the target folder (e.g. `Bookshelf/Kindle`) and tap
     **Choose**.

Already using **AnnotationSync** (or KOReader's Cloud storage)? Then
there's nothing to configure: Tomedown inherits that server
automatically, and *Server and folder…* already shows it. Only set
***Remote folder…*** if your `.md` files should land somewhere else than
the JSONs.

More options (index, page bookmarks, local folder…) are described in the
README's [Configuration](README.md#configuration-one-off) table.

## Step 3 — First export

☰ → **Tomedown**:

- On a **fresh install**, the first time you open the menu Tomedown offers
  to export your whole reading history in one tap (*Export* / *Not now*).
- Later: **Export current book** for the open one, **Only updated** for
  whatever changed, **Import all books from history** if you skipped the
  offer.

The files appear in KOReader's local folder first, then the upload
happens by itself (you'll see *N files exported* and *Cloud: N uploaded*).

## Step 4 — Obsidian: Remotely Save (optional)

Skip this step entirely if you are happy reading the files with any other
Markdown app — they are plain `.md` wherever they are.

1. In Obsidian: **Community plugins** → browse → install and enable
   **Remotely Save**.
2. Open its settings, choose **WebDAV** as the remote service and fill
   the form in (address/credentials from step 1; Koofr values below):

   | Field | Value |
   |---|---|
   | Address | `https://app.koofr.net/dav/Koofr` |
   | Username | your Koofr e-mail |
   | Password | the **app password** from step 1 |

3. Point it at the same folder you chose in step 2 (if you keep the notes
   in a subfolder of the account), choose your sync direction/interval —
   or just hit **Sync now** once to try.
4. If AnnotationSync's `.json` files share the folder, add `*.json` to
   Remotely Save's **Ignore list** so only the notes reach Obsidian.

First sync pulls every book note into the vault; from then on Remotely
Save picks up whatever new export you make.

## Day to day

1. Read and highlight in KOReader as usual.
2. Close the book → export (or tap *Export current book*).
3. Upload to the cloud is automatic; Remotely Save syncs Obsidian on its
   schedule.

Updates of the plugin itself: **Settings → Check for updates…** (notes are
shown formatted, with *Update and restart* right in the window).

## Troubleshooting

- **"Nothing to upload, export something first."** — the local folder is
  empty: run an export first.
- **Upload fails** — the uploader retries 3 times on its own; if it still
  fails, check the server/folder in *Settings → Server and folder…*, then
  use **Reload everything to the cloud**.
- **Notes don't appear in Obsidian** — in Remotely Save run *Test* /
  *Sync now*, check the address is the one of **your** server (with
  Koofr: `https://app.koofr.net/dav/Koofr`, not the plain `/dav/` root,
  which is not writable), and that the same folder is selected on both
  sides.
- **The first-run import offer doesn't show** — it appears only when
  nothing has ever been exported; use **Import all books from history**
  from the menu instead.
- **`.json` files cluttering the vault** — add `*.json` to Remotely
  Save's ignore list (see step 4).

## Links

- [README](README.md) — every setting, the file format, update policy
- [Releases](https://github.com/imanubdesigner/tomedown.koplugin/releases) —
  zips and release notes
- [Issues](https://github.com/imanubdesigner/tomedown.koplugin/issues) —
  something wrong or missing? Tell me there
