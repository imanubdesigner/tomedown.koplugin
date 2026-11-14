# Getting Started (Local-First)

You do **not** need a cloud account or Obsidian to use Tomedown. Everything works offline on your e-reader first.

## 1. Install the plugin

**Wireless (straight on your e-reader):**

<div class="dl-stores">
  <div class="dl-store-card">
    <div class="dl-store-top">
      <strong>Storefront</strong>
      <span class="bento-pill bento-pill-hl">Wireless</span>
    </div>
    <p>Open <strong>Storefront</strong> in KOReader, search <code>Tomedown</code>, and tap <strong>Install</strong>.</p>
  </div>
  <div class="dl-store-card">
    <div class="dl-store-top">
      <strong>AppStore</strong>
      <span class="bento-pill bento-pill-hl">Wireless</span>
    </div>
    <p>Browse <strong>AppStore</strong> on your device, pick <code>Tomedown</code>, and restart KOReader.</p>
  </div>
</div>

**Or via USB cable:**

1. Connect your e-reader to your computer via USB.
2. Download `tomedown.koplugin-v*.zip` from the [GitHub Releases](https://github.com/imanubdesigner/tomedown.koplugin/releases) page (or from [Download]({{base}}/download/)).
3. Unzip it **into** your KOReader `plugins/` folder (for example `/mnt/us/koreader/plugins/` on Kindle). The zip already contains the `tomedown.koplugin/` folder.
4. Eject and restart KOReader (or enable *Tomedown* in **☰ → Plugin management**).

<figure class="doc-device-figure">
  <img src="{{base}}/assets/img/quickstart-menu-kindle.svg" alt="KOReader top menu showing Tomedown as the first entry" />
</figure>

## 2. Run your first export

1. Open **☰ → Tomedown**.
2. On a fresh install, Tomedown offers to export your entire reading history in one tap. You can also choose **Export this book**, **Export new and changed books**, or **Choose books…**.
3. Your notes are written immediately to your device:

```text
koreader/clipboard/tomedown/
├── 00 - Index.md
├── Arthur Machen - The Three Impostors.md
└── ...
```

> **Tip:** Enable **Settings → Files → Export when I close a book** if you want Tomedown to update the file automatically whenever you close a book or put your device to sleep.

## 3. Read or sync (when you're ready)

- **Offline / USB**: copy the `tomedown/` folder to your computer whenever you want. Every file is plain Markdown (`.md`) or plain text (`.txt`).
- **Cloud & Obsidian (optional)**: if you want automatic wireless sync to an Obsidian vault, see the [Obsidian guide](../obsidian/) and [Setup tutorial](../tutorial/).
