---
"nehir": minor
---

Unified settings config diagnostics — unknown keys are now preserved and surfaced instead of stripped.

Previously, any key in `settings.toml` that the current Nehir schema didn't recognize was treated as a blocking error: on launch Nehir backed up the file, rewrote it without those keys, and showed a **Config Update Required** screen. That silently destroyed valid config written by a newer Nehir version or by hand whenever the app loaded and saved.

This change introduces one policy with a clean blocking/non-blocking split:

- **Unknown keys round-trip.** Settings the schema doesn't model are now captured during decode and re-emitted on save, so a load → edit → save cycle no longer drops them. Missing known values still fall back to defaults.
- **Unknown keys are non-blocking Diagnostics.** Instead of blocking startup, unrecognized keys appear in **Settings → Diagnostics** (and count toward the sidebar badge) as a warning offering **Copy AI Prompt**, **Postpone Warning** (hidden until the next Nehir release), and **Remove Unknown Keys** (writes a timestamped backup, then drops only the unknown keys).
- **Startup recovery only for invalid config.** The launch-time strip is gone. Nehir only blocks pre-startup when `settings.toml` can't be safely loaded at all (TOML parse failure, a known key with the wrong type, or an enforced legacy format). That screen is now **Couldn't load settings.toml**, offers a **Copy AI Prompt**, and never rewrites the file automatically.
- **Warnings surface everywhere.** Non-postponed settings warnings now appear in the status-bar menu's "Issues detected" section and on the **What's New** screen, each with a direct path to Diagnostics.

Invalid values for *known* keys still throw and route to the blocking recovery path — the capture mechanism did not weaken existing validation.
