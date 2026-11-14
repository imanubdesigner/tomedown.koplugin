# Privacy Policy

Tomedown is built around a simple principle: your reading life belongs to you. Neither this website nor the KOReader plugin collects personal data, behavioral analytics, or tracking identifiers.

## No cookies, no tracking

This website does **not** use cookies (neither first-party nor third-party), does **not** store tracking tokens in `localStorage` or `sessionStorage`, and does **not** load analytics scripts, advertising pixels, or fingerprinting tools.

## Hosting & external requests

- **Static hosting**: this site is served as static HTML, CSS, and JavaScript files (via GitHub Pages). Like any web server, the hosting provider may process standard technical connection logs (such as IP address and user-agent) according to its own privacy policy.
- **Release & changelog lookup**: on the [Download]({{base}}/download/) and [Changelog]({{base}}/changelog/) pages, your browser fetches public release metadata directly from the GitHub Releases API (`api.github.com/repos/imanubdesigner/tomedown.koplugin/releases`) so you always see the latest version and release notes. No personal information is sent by Tomedown.

## The Tomedown KOReader plugin

The plugin itself runs **100% locally** on your e-reader:

- **Zero telemetry**: Tomedown never phones home, never collects usage statistics, and never sends crash reports.
- **Local-first exports**: highlights, notes, covers, and `00 - Index.md` are written straight to your device storage.
- **Optional network actions**: network traffic occurs only if you explicitly enable Cloud upload (to the WebDAV, Dropbox, FTP, or S3 destination you configured in KOReader) or manually tap **Check for updates**.

## Questions

If you have any questions about privacy or how Tomedown handles your files, open an issue on [GitHub](https://github.com/imanubdesigner/tomedown.koplugin/issues).
