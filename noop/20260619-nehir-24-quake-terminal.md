# Quake Terminal Windows — wontfix (issue #24)

GitHub issue: [#24 — Quake Terminal Windows](https://github.com/Guria/nehir/issues/24)
Labels: `enhancement`, `wontfix`
Reporter: @syepes

All file references should be re-verified before acting on them; line numbers drift.

---

## TL;DR

- **Verdict: wontfix for Nehir core.** A built-in quake/dropdown terminal is out of
  scope by owner decision. Nehir stays focused on window-management / layout concerns,
  not shipping an integrated terminal.
- The request originates from OmniWM, which had an integrated quake terminal. That
  implementation was a recurring source of stability problems (see owner rationale below)
  and is deliberately **not** being ported into Nehir core.
- **Recommended path for users:** a dedicated terminal app with its own quick-terminal
  mode (Ghostty is the maintainer's own choice). A concrete, community-verified config is
  inlined below — no external link needed.
- **Only plausible native-integration path:** extract OmniWM's original quake-terminal
  solution into a **separate companion project**. That is explicitly owner-endorsed as an
  idea but is out of scope for this repo and is not tracked here.
- Nehir already has to coexist with external quick-terminal overlays (e.g. Ghostty's). Those
  interactions are tracked under separate docs (FFM suppression, viewport-reveal-on-overlay
  activation, quick-terminal-close workspace switch) — they are overlay/window-management
  concerns, **not** a Nehir-side terminal feature.

---

## Request (restated)

The reporter migrated from OmniWM (`https://github.com/bispaul/OmniWM`) and asks for the
OmniWM-style **Quake Terminal** feature in Nehir: a global hotkey that drops down a terminal
overlay from the top of the screen, managed by the window manager itself.

Issue body (verbatim):

> I just migrated over from https://github.com/bispaul/OmniWM it would be great to also have
> the Quake Terminal feature this is nice :-)

---

## Owner verdict (decisive)

The maintainer (@Guria, OWNER) explicitly declined to build this into Nehir, on stability
and focus grounds. Verbatim quotes from the issue thread:

> While I initially liked OmniWM's integrated terminal, I noticed that it can sometimes create
> more problems than it solves. For example, running certain processes inside Zellij in the
> integrated quake terminal could hang the entire OmniWM app.

> Because of that, I decided to keep Nehir focused on layout concerns first and avoid dealing
> with these kinds of quirks for now. They would distract from the main goal: making the layout
> engine more stable, predictable, and easier to reason about.

On the practical alternative the owner actually uses:

> I also use built in Ghostty built in quick terminal. It isn't perfect but closest to my
> expectations.

On the only path that could bring native integration without burdening Nehir core:

> it might be a good idea to extract original OmniWM solution to a separate project too

The `wontfix` label on the issue is consistent with all of the above.

---

## Recommended approach for users (Ghostty quick-terminal, inlined)

The community converged on Ghostty's built-in quick terminal as the practical replacement.
A complete, thread-verified config (from @shadww in the issue, confirmed useful by others):

```ini
# Ghostty config
initial-window = false
macos-hidden = always
keybind = global:alt+escape=toggle_quick_terminal
quick-terminal-position = center
quick-terminal-screen = mouse
quick-terminal-animation-duration = 0.1
quick-terminal-size = 70%,95%
quick-terminal-autohide = false
background-opacity = 0.7
background-blur = 0
```

Notes captured in-thread:
- `initial-window = false` + `macos-hidden = always` avoids keeping a normal Ghostty window
  open and hides it from the Dock, addressing the common complaint that a Ghostty window must
  always be present for the quick terminal to work.
- `keybind = global:...` is what makes the toggle a true global hotkey independent of Nehir.
- Known residual quirk mentioned by a user: the global quick-terminal toggle may not fire while
  a browser password field has focus (a Ghostty / system-level limitation, not a Nehir one).

This is a user-side configuration; it requires no Nehir change. Nehir treats Ghostty's quick
terminal as an unmanaged overlay (see cross-references below).

---

## Only plausible native-integration path (out of scope here)

The owner's "extract OmniWM solution to a separate project" is the only route to native
integration that does not pull terminal-runtime complexity into Nehir core. It is explicitly
*an idea*, not a commitment, and:

- would live in a **separate repository**, not under `Sources/Nehir/`;
- would still have to solve the original OmniWM pain points (e.g. a subprocess/Zellij session
  hanging the host app) that motivated the wontfix decision;
- is not tracked on this planning branch because no Nehir-core work is implied.

If a companion project is ever started, the planning entry point would be a fresh
`planned/` doc scoped to that project, not this issue.

---

## Codebase check (main app worktree)

A read-only scan of the main app worktree
(the main Nehir source tree) confirms Nehir core has **no**
quake / quick-terminal implementation today:

- `grep -rInE "quake|quickTerminal|quick_terminal|QuakeTerminal" Sources/Nehir --include="*.swift"`
  → **no matches.**

There is therefore nothing to port, extend, or deprecate in `Sources/Nehir/` for this issue.

---

## Relationship to existing Nehir quick-terminal docs (not this feature)

Nehir already has to *coexist* with external quick-terminal overlays (Ghostty's being the
canonical case). Those are window-management / overlay-handling concerns — separate from, and
not to be confused with, a Nehir-built terminal. Relevant docs on this branch:

- `completed/20260615-ffm-suppress-over-unmanaged-overlay-windows.md` — FFM should not steal
  focus to the niri tile behind an unmanaged overlay (Ghostty Quick Terminal). Implemented via
  the CGEvent `mouseEventWindowUnderMousePointer` guard in the mouse event tap; owner path
  `Sources/Nehir/Core/Controller/{MouseEventHandler,WMController}.swift`.
- `discovery/20260615-viewport-reveal-from-unmanaged-overlay-activation.md` — toggling an
  unmanaged overlay (Ghostty Quick Terminal) activates its app, which Nehir resolves to the
  managed main window and reveals that column, scrolling a viewport the user did not target.
- `completed/20260615-quick-terminal-close-switches-workspace.md` — closing the Ghostty quick
  terminal switches the active workspace; the recovery guard is destroy-gated and misses
  hide/order-out close behavior.
- `discovery/20260617-move-mouse-to-focused-warps-across-monitors-on-quick-terminal-close.md`
  — related pointer-warp interaction on quick-terminal close.

None of these implement or require a Nehir-side terminal. They confirm the owner's framing:
Nehir's job is to handle these overlays correctly, not to ship one.

---

## Verdict

**wontfix** — keep in `noop/`. No Nehir-core change. Users should configure a dedicated
terminal's quick-terminal mode (Ghostty config inlined above). Native integration, if ever
pursued, belongs in a separate companion project, not in this repo.
