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
               "assets/menu", "assets/obsidian-guide", "assets/tutorials"]


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


class Site:
    def __init__(self, base, offline):
        self.base = base.rstrip("/")
        self.layout = (SRC / "layout.html").read_text(encoding="utf-8")
        self.fonts = fonts_block(offline)

    def render(self, url, title, description, content, wide=False):
        page = self.layout
        for key, val in {
            "fonts": self.fonts,
            "title": html.escape(title),
            "description": html.escape(description, quote=True),
            "content": content,
            "canonical": SITE_URL + url,
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
        out = ['<nav class="docs-nav" aria-label="Documentation">']
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
        return f'<aside class="docs-toc" aria-label="In this chapter"><h4>In this chapter</h4><ul>{lis}</ul></aside>'

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
        cls = "container docs docs-has-toc" if toc_html else "container docs"
        page = (f'<div class="{cls}">{sidebar(item["slug"])}'
                f'<article class="prose">{body}</article>{toc_html}</div>')
        site.render(f'/docs/{item["slug"]}/', f'{item["title"]} · Tomedown docs',
                    item.get("description", "Tomedown documentation"), page)

    first = entries[0][1]["slug"]
    
    sections_html = []
    sec_num = 1
    for sec in nav["sections"]:
        sec_title = sec.get("title", "")
        card_items = []
        for i in sec.get("items", []):
            card_items.append(
                f'<a href="{{{{base}}}}/docs/{i["slug"]}/" class="hub-card" data-title="{html.escape(i["title"]).lower()}" data-desc="{html.escape(i.get("description", "")).lower()}">'
                f'  <div class="hub-card-header">'
                f'    <span class="hub-card-tag">{html.escape(sec_title)}</span>'
                f'    <svg class="hub-card-arrow" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12h14m-7-7l7 7-7 7"/></svg>'
                f'  </div>'
                f'  <h3>{html.escape(i["title"])}</h3>'
                f'  <p>{html.escape(i.get("description", ""))}</p>'
                f'</a>'
            )
        cards_grid = "\n".join(card_items)
        sections_html.append(
            f'<div class="hub-chapter">'
            f'  <div class="hub-chapter-header">'
            f'    <span class="hub-chapter-num">Chapter {sec_num:02d}</span>'
            f'    <h2>{html.escape(sec_title)}</h2>'
            f'  </div>'
            f'  <div class="hub-cards-grid">\n{cards_grid}\n  </div>'
            f'</div>'
        )
        sec_num += 1

    all_sections = "\n".join(sections_html)
    landing = (
        f'<div class="container hub-container">'
        f'  <header class="hub-hero center">'
        f'    <span class="eyebrow">Knowledge Base &amp; Technical Guides</span>'
        f'    <h1>The <em>Library</em> Reference</h1>'
        f'    <p class="lead">Everything you need to craft an enduring personal library from your e-reader highlights.</p>'
        f'    <div class="hub-search-wrap">'
        f'      <svg class="hub-search-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/></svg>'
        f'      <input type="search" id="hub-search-input" class="hub-search-input" placeholder="Jump to any chapter or keyword..." autocomplete="off" />'
        f'      <kbd class="hub-search-kbd">⌘K</kbd>'
        f'    </div>'
        f'  </header>'
        f'  <div id="hub-content" class="hub-chapters-wrap">{all_sections}</div>'
        f'  <p id="hub-empty" class="hub-empty" hidden>No matching chapters found. Try a different keyword.</p>'
        f'  <footer class="hub-footer center">'
        f'    <p class="hub-quote">“Every volume, every note, every highlight — forever yours in plain text.”</p>'
        f'    <p class="muted">Free software under the AGPL-3.0 license · Zero telemetry · 100% offline first.</p>'
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

    site = Site(args.base, args.offline_fonts)
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
