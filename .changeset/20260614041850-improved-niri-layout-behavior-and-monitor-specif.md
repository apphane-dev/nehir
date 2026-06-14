---
"nehir": minor

---

Breaking: improved Niri layout behavior and monitor-specific layout settings with a simplified configuration model.

- **Breaking:** renamed the Niri balanced-width config from `maxVisibleColumns` / `niriMaxVisibleColumns` to `balancedColumnCount` / `niriBalancedColumnCount`. Old keys are not migrated or accepted.
- **Breaking:** replaced the old single-window aspect-ratio config with **Lone Window** policy. Use `Fill` for full working-area lone windows, or `Centered(width)` for capped centered lone windows.
- Added per-monitor spacing overrides in Layout settings. You can now customize **Inner Gap** and per-edge **Screen Margins** separately for each display, while leaving individual values set to **Use Global** when you want them to inherit the global defaults.
- Added explicit per-monitor **Lone Window** overrides. Each monitor can now use **Use Global**, **Fill**, or **Centered** with its own centered width, so a display can intentionally force Fill even when the global default is Centered.
- Fixed lone-window layouts after monitor changes. When a constrained single window is left alone on a smaller or different display, Nehir now keeps it inside the monitor’s visible area instead of letting it leak offscreen.
- Made lone-window scrolling and snapping more predictable. Fill lone windows remain responsive while scrolling but no longer settle one gap off-center; centered lone windows can still snap left, center, or right; and over-constrained lone windows can be scrolled to reveal their overflowing edges.
- Corrected inner-gap semantics for stacked and tabbed columns. Inner gap now means spacing between adjacent tiled windows, not extra top/bottom padding at the monitor edge. Use screen margins/outer gaps for edge padding.
- Preserved proportional column behavior for viewport-fitting layouts such as `50% + 50%` and Reveal Partial’s `Default` mode, so existing proportional Niri workflows continue to fit naturally.
