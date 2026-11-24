#!/usr/bin/env python3
"""Build the Tomedown site into ./dist.

    python3 build.py                      docs read from the `main` branch
    python3 build.py --docs DIR           docs read from DIR (a checkout of main)
    python3 build.py --base /tomedown.koplugin   path prefix for GitHub Pages
    python3 build.py --offline-fonts      use ./dev-fonts instead of Google Fonts

Every page is written as <slug>/index.html, so URLs never show ".html".
The only dependency is Python-Markdown (pip install markdown).
"""
import argparse
import html
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
DIST = ROOT / "dist"
SITE_URL = "https://imanubdesigner.github.io/tomedown.koplugin"
REPO_BLOB = "https://github.com/imanubdesigner/tomedown.koplugin/blob/main/"

GOOGLE_FONTS = """<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Caveat:wght@500;600&family=Instrument+Serif:ital@0;1&family=Instrument+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap">"""

# files that make up the wiki; copied out of `main` when --docs is not given
DOC_SOURCES = ["docs", "OBSIDIAN.md", "TUTORIAL.md", "SYNC-DIRECTION.md",
               "assets/menu", "assets/obsidian"]


def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def extract_main(dest):
    """git archive of the doc sources of `main`, unpacked into dest."""
    repo = ROOT.parent / "tomedown.koplugin"
    if not (repo / ".git").exists():
        fail("no ../tomedown.koplugin checkout: pass --docs DIR")
    # not `git archive`: the plugin's .gitattributes export-ignores the docs
    names = subprocess.run(["git", "-C", str(repo), "ls-tree", "-r", "--name-only", "main", *DOC_SOURCES],
                           check=True, capture_output=True, text=True).stdout.split("\n")
    for name in filter(None, names):
        data = subprocess.run(["git", "-C", str(repo), "show", f"main:{name}"],
                              check=True, capture_output=True).stdout
        out = dest / name
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(data)


def fonts_block(offline):
    if not offline:
        return GOOGLE_FONTS
    if not (ROOT / "dev-fonts").is_dir():
        fail("--offline-fonts needs ./dev-fonts (see README.md)")
    return '<link rel="stylesheet" href="{{base}}/assets/css/dev-fonts.css">'


def write_page(url, text):
    """url like '/about/' -> dist/about/index.html ('/' -> dist/index.html)."""
    out = DIST / url.strip("/") / "index.html" if url != "/" else DIST / "index.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")


def read_plugin_version(docs_root):
    meta_file = docs_root / "_meta.lua"
    if meta_file.exists():
        m = re.search(r'version\s*=\s*"([^"]+)"', meta_file.read_text(encoding="utf-8"))
        if m:
            return m.group(1)
    return "2.1.0"


class Site:
    def __init__(self, base, offline, version="2.1.0"):
        self.base = base.rstrip("/")
        self.layout = (SRC / "layout.html").read_text(encoding="utf-8")
        self.fonts = fonts_block(offline)
        self.version = version

    def render(self, url, title, description, content, wide=False):
        page = self.layout
        for key, val in {
            "fonts": self.fonts,
            "title": html.escape(title),
            "description": html.escape(description, quote=True),
            "content": content,
            "canonical": SITE_URL + url,
            "version": self.version,
            "v_version": f"v{self.version}",
        }.items():
            page = page.replace("{{" + key + "}}", val)
        page = page.replace("{{base}}", self.base)
        write_page(url, page)


def parse_front(text):
    """<!-- title: X | description: Y --> on the first line."""
    m = re.match(r"\s*<!--\s*(.*?)\s*-->\s*", text, re.S)
    meta = {}
    if m:
        for part in m.group(1).split("|"):
            k, _, v = part.partition(":")
            meta[k.strip()] = v.strip()
        text = text[m.end():]
    return meta, text


def build_pages(site):
    for f in sorted((SRC / "pages").glob("*.html")):
        meta, body = parse_front(f.read_text(encoding="utf-8"))
        name = f.stem
        url = "/" if name == "index" else f"/{name}/"
        site.render(url, meta.get("title", "Tomedown"), meta.get("description", ""), body)


def first_heading(md, fallback):
    m = re.search(r"^#\s+(.+)$", md, re.M)
    return m.group(1).strip() if m else fallback


def doc_path(docs_root, name):
    """'extra/x.md' lives in this branch, everything else in main."""
    return SRC / "docs-extra" / name[6:] if name.startswith("extra/") else docs_root / name


def build_docs(site, docs_root, slugmap, nav):
    entries = []
    for section in nav["sections"]:
        for item in section["items"]:
            src = doc_path(docs_root, item["src"])
            if not src.exists():
                fail(f"docs-nav.json points to a missing file: {item['src']}")
            entries.append((section["title"], item, src))

    def sidebar(active):
        out = ['<nav class="docs-nav" aria-label="Documentation">',
               '  <div class="docs-nav-header">',
               '    <span class="docs-nav-title">Chapters</span>',
               '    <button type="button" class="docs-nav-close" id="docs-nav-close" aria-label="Close chapters menu">✕</button>',
               '  </div>']
        last = None
        for sec, item, _ in entries:
            if sec != last:
                if last is not None:
                    out.append("</ul>")
                out.append(f'<h4>{html.escape(sec)}</h4><ul>')
                last = sec
            cur = ' aria-current="page"' if item["slug"] == active else ""
            out.append(f'<li><a href="{{{{base}}}}/docs/{item["slug"]}/"{cur}>{html.escape(item["title"])}</a></li>')
        out.append("</ul></nav>")
        return "\n".join(out)

    def fix_links(body):
        def href(m):
            target = m.group(1)
            if re.match(r"(https?:|mailto:|#|\{\{)", target):
                return m.group(0)
            path, _, frag = target.partition("#")
            name = Path(path).name.lower()
            frag = f"#{frag}" if frag else ""
            if name in slugmap:
                return f'href="{{{{base}}}}/docs/{slugmap[name]}/{frag}"'
            if name == "readme.md":
                if frag == "#install":
                    return f'href="{{{{base}}}}/download/"'
                return f'href="{{{{base}}}}/{frag}"'
            return f'href="{REPO_BLOB}{path.replace("../", "")}{frag}"'

        def img(m):
            target = re.sub(r"^(\.\./)+", "", m.group(1))
            if target.startswith("assets/"):
                return f'src="{{{{base}}}}/repo-assets/{target[7:]}"'
            return m.group(0)

        body = re.sub(r'href="([^"]*)"', href, body)
        return re.sub(r'src="([^"]*)"', img, body)

    def render_toc(tokens):
        items = []
        for t in tokens:
            if t.get("level") == 1:
                items.extend(t.get("children", []))
            else:
                items.append(t)
        flat = []
        for h2 in items:
            flat.append((h2["id"], h2["name"], 2))
            for h3 in h2.get("children", []):
                flat.append((h3["id"], h3["name"], 3))
        if len(flat) < 2:
            return ""
        lis = "".join(
            f'<li class="toc-l{lvl}"><a href="#{html.escape(hid)}">{html.escape(html.unescape(name))}</a></li>'
            for hid, name, lvl in flat
        )
        return f'<aside class="docs-toc" aria-label="On this page"><h4>On this page</h4><ul>{lis}</ul></aside>'

    md = markdown.Markdown(extensions=["tables", "fenced_code", "toc", "sane_lists"],
                           extension_configs={"toc": {"permalink": "#", "permalink_class": "header-anchor", "permalink_title": "Permanent link"}})
    anchor_svg = ('<svg class="anchor-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" '
                  'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" '
                  'aria-hidden="true"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/>'
                  '<path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>')
    for _, item, src in entries:
        text = src.read_text(encoding="utf-8")
        md.reset()
        body = fix_links(md.convert(text))
        body = re.sub(r'(<a class="header-anchor"[^>]*>)#</a>', r'\1' + anchor_svg + '</a>', body)
        toc_html = render_toc(getattr(md, "toc_tokens", []))
        toc_mobile_btn = ('<button type="button" class="docs-mobile-btn docs-mobile-toc-toggle" id="docs-toc-toggle" aria-expanded="false" aria-label="Toggle section outline">'
                          '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/></svg>'
                          '<span>On this page</span>'
                          '<svg class="docs-mobile-caret" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="6 9 12 15 18 9"/></svg>'
                          '</button>') if toc_html else ''
        mobile_bar = (f'<div class="docs-mobile-bar">'
                      f'  <button type="button" class="docs-mobile-btn docs-mobile-nav-toggle" id="docs-nav-toggle" aria-expanded="false" aria-label="Open chapters menu">'
                      f'    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="18" x2="21" y2="18"/></svg>'
                      f'    <span>Chapters</span>'
                      f'  </button>'
                      f'  {toc_mobile_btn}'
                      f'</div>'
                      f'<div class="docs-backdrop" id="docs-backdrop" aria-hidden="true"></div>')
        cls = "container docs docs-has-toc" if toc_html else "container docs"
        page = (f'{mobile_bar}'
                f'<div class="{cls}">{sidebar(item["slug"])}'
                f'<article class="prose">{body}</article>{toc_html}</div>')
        site.render(f'/docs/{item["slug"]}/', f'{item["title"]} · Tomedown docs',
                    item.get("description", "Tomedown documentation"), page)

    first = entries[0][1]["slug"]
    
    item_icons = {
        "quickstart": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/></svg>',
        "faq": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>',
        "file-format": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/></svg>',
        "reading-digest": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>',
        "universal-highlights": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m18 2-3 3-9 9-4 1 1-4 9-9 3-3a2.12 2.12 0 0 1 3 3z"/><path d="M9 15l-5 5"/><line x1="14" y1="6" x2="18" y2="10"/></svg>',
        "templates-and-folders": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>',
        "settings": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/><line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/></svg>',
        "current-book": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/><path d="M9 7h6"/><path d="M9 11h4"/></svg>',
        "keep-my-notes": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>',
        "obsidian": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polygon points="12 2 19 8 16 22 8 22 5 8 12 2"/><polyline points="12 2 12 22"/><polyline points="5 8 12 13 19 8"/></svg>',
        "sync-direction": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg>',
        "tutorial": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z"/></svg>',
        "developing": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>',
        "privacy": '<svg class="hub-card-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/></svg>',
    }
    chapter_subtitles = {
        "Start here": "First steps, installation, and quick answers.",
        "Formats & Output": "How your book notes, library catalog, and daily digest are structured.",
        "Customization": "Fine-tune highlight styles, header modules, YAML keys, and folder hierarchy.",
        "Using Tomedown": "In-reader controls, menu groups, and non-destructive two-way note merging.",
        "Cloud & Obsidian (Optional)": "Vault integration, sync direction, and step-by-step cloud setup.",
        "Project & Legal": "Architecture, automated test suite, and zero-telemetry privacy guarantee.",
    }
    sections_html = []
    sec_num = 1
    item_num = 1
    for sec in nav["sections"]:
        sec_title = sec.get("title", "")
        sec_sub = chapter_subtitles.get(sec_title, "")
        card_items = []
        for i in sec.get("items", []):
            title_str = i.get("title") or i["slug"].replace("-", " ").title()
            desc_str = i.get("description", "")
            icon_svg = item_icons.get(i["slug"], item_icons["file-format"])
            card_items.append(
                f'<a href="{{{{base}}}}/docs/{i["slug"]}/" class="hub-card" data-title="{html.escape(title_str).lower()}" data-desc="{html.escape(desc_str).lower()}">'
                f'  <div class="hub-card-lead">'
                f'    <span class="hub-card-index">{item_num:02d}</span>'
                f'    <span class="hub-card-icon-wrap">{icon_svg}</span>'
                f'  </div>'
                f'  <div class="hub-card-main">'
                f'    <h3>{html.escape(title_str)}</h3>'
                f'    <p>{html.escape(desc_str)}</p>'
                f'  </div>'
                f'  <svg class="hub-card-arrow" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12h14m-7-7l7 7-7 7"/></svg>'
                f'</a>'
            )
            item_num += 1
        cards_grid = "\n".join(card_items)
        sub_html = f'<p class="hub-chapter-desc">{html.escape(sec_sub)}</p>' if sec_sub else ''
        sections_html.append(
            f'<section class="hub-chapter">'
            f'  <div class="hub-chapter-header">'
            f'    <span class="editorial-kicker hub-chapter-num">Chapter {sec_num:02d}</span>'
            f'    <h2>{html.escape(sec_title)}</h2>'
            f'    {sub_html}'
            f'  </div>'
            f'  <div class="hub-cards-grid">\n{cards_grid}\n  </div>'
            f'</section>'
        )
        sec_num += 1

    all_sections = "\n".join(sections_html)
    landing = (
        f'<div class="container hub-container">'
        f'  <header class="hub-hero center">'
        f'    <span class="editorial-kicker">Documentation &amp; Technical Manual</span>'
        f'    <h1>The <mark class="editorial-highlight">Library</mark> Reference</h1>'
        f'    <p class="lead">Setup, formats, highlight styles, menu settings, and vault sync for your e-reader library.</p>'
        f'    <div class="hub-search-wrap">'
        f'      <svg class="hub-search-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/></svg>'
        f'      <input type="search" id="hub-search-input" class="hub-search-input" placeholder="Jump to any chapter or keyword..." autocomplete="off" />'
        f'      <kbd class="hub-search-kbd">⌘K</kbd>'
        f'    </div>'
        f'  </header>'
        f'  <div id="hub-content" class="hub-chapters-wrap">{all_sections}</div>'
        f'  <p id="hub-empty" class="hub-empty" hidden>No matching chapters found. Try a different keyword.</p>'
        f'  <footer class="hub-footer center">'
        f'    <p class="hub-quote">“Every volume, every note, every highlight: forever yours in plain text.”</p>'
        f'    <p class="muted">Free software under the AGPL-3.0 license. Zero telemetry and 100% offline first.</p>'
        f'  </footer>'
        f'</div>'
    )
    site.render("/docs/", "Documentation · Tomedown", "Comprehensive documentation: setup, settings, formats, highlight styles, and Obsidian integration.", landing)
    return first


def copy_static(docs_root, offline):
    shutil.copytree(SRC / "assets", DIST / "assets", dirs_exist_ok=True)
    repo_assets = docs_root / "assets"
    if repo_assets.is_dir():
        shutil.copytree(repo_assets, DIST / "repo-assets", dirs_exist_ok=True)
    if offline:
        css = []
        for fam, files in {
            "Instrument Serif": [("InstrumentSerif-Regular.ttf", 400, "normal"), ("InstrumentSerif-Italic.ttf", 400, "italic")],
            "Instrument Sans": [("InstrumentSans-Regular.ttf", 400, "normal"), ("InstrumentSans-Medium.ttf", 500, "normal"), ("InstrumentSans-SemiBold.ttf", 600, "normal")],
            "JetBrains Mono": [("JetBrainsMono-Regular.woff2", 400, "normal"), ("JetBrainsMono-Medium.woff2", 500, "normal")],
        }.items():
            for fname, weight, style in files:
                if not (ROOT / "dev-fonts" / fname).exists():
                    fail(f"dev-fonts/{fname} is missing")
                css.append(f'@font-face{{font-family:"{fam}";src:url("../dev-fonts/{fname}");'
                           f'font-weight:{weight};font-style:{style};font-display:swap}}')
        (DIST / "assets" / "css" / "dev-fonts.css").write_text("\n".join(css), encoding="utf-8")
        shutil.copytree(ROOT / "dev-fonts", DIST / "assets" / "dev-fonts", dirs_exist_ok=True)
    (DIST / ".nojekyll").write_text("")
    (DIST / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {SITE_URL}/sitemap.xml\n")


def write_sitemap():
    urls = sorted("/" + str(p.parent.relative_to(DIST)).replace(".", "") + ("/" if p.parent != DIST else "")
                  for p in DIST.rglob("index.html"))
    urls = [u.replace("//", "/") for u in urls]
    body = "".join(f"<url><loc>{SITE_URL}{u}</loc></url>" for u in urls)
    (DIST / "sitemap.xml").write_text(
        f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{body}</urlset>')


def check_links(base):
    """No internal link may end in .html or point to a file that does not exist."""
    bad = []
    for page in DIST.rglob("*.html"):
        text = page.read_text(encoding="utf-8")
        for m in re.finditer(r'(?:href|src)="([^"]+)"', text):
            link = m.group(1).split("#")[0].split("?")[0]
            if not link or re.match(r"(https?:|mailto:|data:)", link):
                continue
            if not link.startswith(base + "/") and link != base:
                if link.startswith("/"):
                    bad.append((page, m.group(1), "missing base prefix"))
                continue
            rel = link[len(base):].lstrip("/")
            if rel.endswith(".html") and page.name != "404.html":
                bad.append((page, m.group(1), "internal link ends in .html"))
                continue
            target = DIST / rel
            if target.is_dir():
                target = target / "index.html"
            if not target.exists() and rel.startswith("repo-assets/"):
                # an image the docs in main refer to but main does not have
                print(f"  warning: {page.relative_to(DIST)}: {link} is missing in main", file=sys.stderr)
            elif not target.exists():
                bad.append((page, m.group(1), "target does not exist"))
    for page, link, why in bad:
        print(f"  {page.relative_to(DIST)}: {link}  ({why})", file=sys.stderr)
    if bad:
        fail(f"{len(bad)} broken internal link(s)")
    print("link check: ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--docs", help="checkout of repository root (default: repo containing site/)")
    ap.add_argument("--base", default="", help="path prefix, e.g. /tomedown.koplugin")
    ap.add_argument("--offline-fonts", action="store_true")
    args = ap.parse_args()

    tmp = None
    if args.docs:
        docs_root = Path(args.docs).resolve()
    elif (ROOT.parent / "_meta.lua").exists():
        docs_root = ROOT.parent
    else:
        tmp = tempfile.TemporaryDirectory()
        docs_root = Path(tmp.name)
        extract_main(docs_root)

    if DIST.exists():
        for child in DIST.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
    else:
        DIST.mkdir(parents=True, exist_ok=True)

    site = Site(args.base, args.offline_fonts, read_plugin_version(docs_root))
    nav = json.loads((ROOT / "docs-nav.json").read_text(encoding="utf-8"))
    slugmap = {}
    for s in nav["sections"]:
        for i in s["items"]:
            slugmap[Path(i["src"]).name.lower()] = i["slug"]
            slugmap[i["slug"].lower()] = i["slug"]
    # a title in docs-nav.json wins; otherwise the first heading of the file
    for sec in nav["sections"]:
        for i in sec["items"]:
            p = doc_path(docs_root, i["src"])
            if p.exists():
                i.setdefault("title", first_heading(p.read_text(encoding="utf-8"), i["slug"]))

    build_pages(site)
    build_docs(site, docs_root, slugmap, nav)
    copy_static(docs_root, args.offline_fonts)
    # 404 at the root of dist, as GitHub Pages expects
    shutil.move(DIST / "404" / "index.html", DIST / "404.html")
    shutil.rmtree(DIST / "404")
    write_sitemap()
    check_links(site.base)
    print(f"built {sum(1 for _ in DIST.rglob('index.html'))} pages into {DIST}")


if __name__ == "__main__":
    main()
