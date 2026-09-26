#!/usr/bin/env python3
"""Genera i banner di tomedown (assets/banner*.svg).

Uso:  python3 assets/gen_banner.py

Varianti: viola (default, banner.svg), ambra, smaraldo.
Le dimensioni dei testi sono vincolate con textLength: il layout resta
identico in qualsiasi font/reader (browser, rsvg, GitHub).
"""
import pathlib

OUT = pathlib.Path(__file__).parent

W, H = 1200, 420
SANS = "ui-sans-serif, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "'iA Writer Mono S', 'JetBrains Mono', Menlo, Consolas, monospace"

THEMES = {
    "banner.svg": dict(
        accent="#a78bfa", grad0="#c4b5fd", grad1="#8b5cf6",
        on_accent="#1e1b4b", glow2="#f472b6", glow2_op="0.08",
        name="tomedown banner (violet)"),
    "banner-amber.svg": dict(
        accent="#fbbf24", grad0="#fcd34d", grad1="#f59e0b",
        on_accent="#10192e", glow2="#38bdf8", glow2_op="0.10",
        name="tomedown banner (amber)"),
    "banner-emerald.svg": dict(
        accent="#34d399", grad0="#6ee7b7", grad1="#10b981",
        on_accent="#052e2b", glow2="#38bdf8", glow2_op="0.08",
        name="tomedown banner (emerald)"),
}

TEMPLATE = """<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-label="tomedown — one Markdown file per book, straight into Obsidian">
  <title>{name}</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0b1220"/>
      <stop offset="1" stop-color="#132138"/>
    </linearGradient>
    <linearGradient id="mark" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{grad0}"/>
      <stop offset="1" stop-color="{grad1}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.12" cy="0.05" r="0.85">
      <stop offset="0" stop-color="{accent}" stop-opacity="0.16"/>
      <stop offset="1" stop-color="{accent}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="glow2" cx="0.95" cy="1" r="0.7">
      <stop offset="0" stop-color="{glow2}" stop-opacity="{glow2_op}"/>
      <stop offset="1" stop-color="{glow2}" stop-opacity="0"/>
    </radialGradient>
  </defs>

  <!-- background -->
  <rect width="{W}" height="{H}" rx="20" fill="url(#bg)"/>
  <rect width="{W}" height="{H}" rx="20" fill="url(#glow)"/>
  <rect width="{W}" height="{H}" rx="20" fill="url(#glow2)"/>

  <!-- logo mark -->
  <rect x="64" y="58" width="96" height="96" rx="26" fill="url(#mark)"/>
  <rect x="64" y="58" width="96" height="96" rx="26" fill="none" stroke="#0b1220" stroke-opacity="0.25" stroke-width="2"/>
  <text x="112" y="129" text-anchor="middle" font-family="{SANS}" font-size="64" font-weight="800" fill="{on_accent}">t</text>

  <!-- wordmark -->
  <text x="184" y="130" font-family="{SANS}" font-size="88" font-weight="800" letter-spacing="-2" fill="#f8fafc">tomedown</text>

  <!-- slogans -->
  <text x="64" y="214" font-family="{SANS}" font-size="27" font-weight="600" fill="#94a3b8">One Markdown file per book — into Obsidian.</text>
  <text x="64" y="252" font-family="{SANS}" font-size="20" fill="#64748b">Set it once, forget it: exports + upload every time you ask</text>

  <!-- settings card -->
  <rect x="700" y="58" width="436" height="244" rx="16" fill="#0a101f" fill-opacity="0.85" stroke="#23314e" stroke-width="1.5"/>
  <circle cx="724" cy="84" r="5" fill="#ef4444" fill-opacity="0.85"/>
  <circle cx="742" cy="84" r="5" fill="#f59e0b" fill-opacity="0.85"/>
  <circle cx="760" cy="84" r="5" fill="#22c55e" fill-opacity="0.85"/>
  <text x="782" y="89" font-family="{MONO}" font-size="14" fill="#64748b">tomedown · best settings</text>
  <line x1="700" y1="106" x2="1136" y2="106" stroke="#1b2740" stroke-width="1.5"/>

  <g font-family="{MONO}" font-size="16">
    <text x="724" y="142" fill="#64748b">upload</text>
    <text x="856" y="142" fill="#34d399">true</text>

    <text x="724" y="174" fill="#64748b">index</text>
    <text x="856" y="174" fill="#e2e8f0">00 - Index.md</text>

    <text x="724" y="206" fill="#64748b">local</text>
    <text x="856" y="206" fill="#e2e8f0">clipboard/tomedown</text>

    <text x="724" y="238" fill="#64748b">server</text>
    <text x="856" y="238" fill="#e2e8f0">app.koofr.net/dav/Koofr</text>

    <text x="724" y="270" fill="#64748b">remote</text>
    <text x="856" y="270" fill="#e2e8f0">/Bookshelf/Kindle</text>
  </g>

  <!-- feature chips -->
  <g font-family="{SANS}" font-size="16" fill="#cbd5e1">
    <rect x="64"  y="330" width="187" height="40" rx="20" fill="#0e1830" stroke="#26344f"/>
    <text x="157" y="355" text-anchor="middle" textLength="155" lengthAdjust="spacingAndGlyphs">Highlights + notes</text>

    <rect x="263" y="330" width="170" height="40" rx="20" fill="#0e1830" stroke="#26344f"/>
    <text x="348" y="355" text-anchor="middle" textLength="138" lengthAdjust="spacingAndGlyphs">YAML frontmatter</text>

    <rect x="445" y="330" width="144" height="40" rx="20" fill="#0e1830" stroke="#26344f"/>
    <text x="517" y="355" text-anchor="middle" textLength="112" lengthAdjust="spacingAndGlyphs">00 - Index.md</text>

    <rect x="601" y="330" width="213" height="40" rx="20" fill="#0e1830" stroke="#26344f"/>
    <text x="707" y="355" text-anchor="middle" textLength="181" lengthAdjust="spacingAndGlyphs">Koofr → Remotely Save</text>

    <rect x="826" y="330" width="144" height="40" rx="20" fill="#0e1830" stroke="#26344f"/>
    <text x="898" y="355" text-anchor="middle" textLength="112" lengthAdjust="spacingAndGlyphs">Backoff 2s/4s</text>

    <rect x="982" y="330" width="92" height="40" rx="20" fill="#0e1830" stroke="#26344f"/>
    <text x="1028" y="355" text-anchor="middle" textLength="60" lengthAdjust="spacingAndGlyphs">EN / IT</text>
  </g>
</svg>
"""


def main():
    for filename, theme in THEMES.items():
        svg = TEMPLATE.format(W=W, H=H, SANS=SANS, MONO=MONO, **theme)
        (OUT / filename).write_text(svg, encoding="utf-8")
        print("wrote", filename)


if __name__ == "__main__":
    main()
