# Tomedown Roadmap & TODO

## Next Major: v2.0.0 (Native Top-Level Tab & Custom Icon)

- [ ] **Custom Vector Tab Icon**:
  - Monochrome SVG (`48 × 48 px`, `viewBox="0 0 48 48"`).
  - Safe area: `36 × 36 px` or `40 × 40 px`, stroke width ~2.5px.
  - Transparent background, black path (`#000000` / `currentColor`), inverted automatically on e-ink selection / dark mode.
  - Three-layer asset registration (IconWidget upvalue cache + local user icon fallback).
- [ ] **Menu Placement Setting**:
  - Setting under **Settings → Style** (or **Interface**):
    - *Top bar tab* (dedicated Tomedown icon on the top menu bar alongside File manager, Search, Tools).
    - *Tools menu* (classic behavior: first item under the Tools menu).
  - Inject into `KOMenu:menu_buttons` in `filemanager_menu_order` and `reader_menu_order` when enabled.
- [ ] **Dedicated Top-Level View**:
  - Quick action dashboard when tapping the top-level Tomedown tab.
