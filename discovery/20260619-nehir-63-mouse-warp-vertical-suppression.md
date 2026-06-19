# Nehir #63 — Monitor warping: want horizontal-only, not vertical

Reported issue: **with monitors logically stacked vertically in macOS System
Settings, Nehir warps the cursor at the left/right edges of each monitor (which
the reporter likes), but the cursor *also* jumps when going up/down between the
monitors. The reporter wants warp on the horizontal axis only, and to suppress
the up/down warp.** All evidence is inlined below; this document does not depend
on any captured trace file.

GitHub issue: https://github.com/Guria/nehir/issues/63 (no labels).

All file references should be re-verified before acting; line numbers drift.

---

## TL;DR — verdict (c): the vertical jump is macOS-native, not Nehir

The up/down cursor jump between vertically-stacked monitors is **not produced by
Nehir**. Nehir's mouse-warp feature already runs in **horizontal-only mode by
default** (`mouseWarp.axis = "horizontal"`), and that mode is structurally
incapable of emitting a warp on a top/bottom edge. The vertical jump the user
sees is **macOS WindowServer's own inter-display cursor behaviour** at the
shared horizontal edge between two vertically-adjacent displays. Nehir has no
public API to disable that macOS-native jump.

So:
- **(a) partially holds** — Nehir's horizontal-only warp is *already* the
  default and already does exactly what the user wants from Nehir's side. There
  is nothing to set beyond confirming `[mouseWarp] axis = "horizontal"`.
- **(c) is the operative verdict** — the residual up/down jump is macOS-native
  and is **not suppressible** by Nehir. The maintainer-confirmed workaround is
  to arrange monitors **diagonally** in System Settings so the displays no
  longer share a horizontal edge.

No source change is recommended for the user's literal request. A separate,
larger "cursor-clamp to monitor" feature could mask the macOS jump but is out of
scope here (see "Optional future feature, explicitly not recommended").

---

## Context (issue + comments)

- Reporter (@stefanpinterBE): "Nehir suggests to set the monitor to be stacked
  vertically (logically) in MacOS settings. Nehir warps the mouse pointer when I
  touch the sides (left and right) of each monitor, which is fine. But macOS
  warps the mouse pointer when going up and down as well now. I'd prefer the
  mouse pointer to only warp horizontally and not vertically as well."
  - Note the reporter explicitly attributes the up/down jump to **macOS**, not
    to Nehir. The investigation below confirms that attribution against source.
- Owner (@Guria): "Currently, this is a known limitation. I've personally seen
  it more as an advantage, so I never tried to change this behavior. I'm going
  to check what is possible here, but any solution may come with some quirks.
  One thing you can do to partially avoid this situation is to arrange your
  monitors diagonally."
- Reporter + @flschulz: the **diagonal arrangement** workaround works for them
  ("solved it by putting my left monitor to the top-left / as diagonally as
  possible… it is then very unlikely that you go with the mouse pointer to the
  upper-left corner and with that you only use the mouse warp").

Where does the "stack vertically" recommendation the reporter mentions come
from? It is **not** about mouse warping. It is the offscreen-clamp guidance in
`docs/offscreen-clamp-fix.md:101-104`:

> "For multi-monitor setups, the practical recommendation is to arrange monitors
> **vertically** in macOS System Settings. Side-by-side horizontal displays put
> another screen directly next to the horizontal parking edge, so a parked/
> clamped offscreen window can bleed onto the neighboring monitor. A vertical
> arrangement keeps horizontal parking edges away from adjacent displays…"

That recommendation is about offscreen-window clamp geometry, and it has the
side effect of exposing the user to macOS's native vertical-edge cursor jump.

---

## What `mouseWarp.axis` actually controls

`Sources/Nehir/Core/Config/MouseWarpAxis.swift` defines a two-case enum
(`:3-6`):

```swift
enum MouseWarpAxis: String, Codable, CaseIterable {
    case horizontal
    case vertical
```

`MouseWarpAxis` has two distinct effects, and they must not be conflated:

1. **Monitor ordering model** — `sortedMonitors(_:)` (`:35-44`) sorts monitors by
   a primary coordinate: `frame.minX` for `.horizontal`, `-frame.maxY` for
   `.vertical` (`primaryCoordinate(for:)`, `:47-53`). This is purely about how
   the linear warp order list (`mouseWarp.monitorOrder`) is derived/displayed in
   Settings (`Sources/Nehir/UI/MonitorSettingsTab.swift:11-27`). It does not, by
   itself, move the cursor.

2. **Which physical edge triggers a warp** — this is the part that matters for
   #63. The axis is read in the warp hot path and selects, exclusively, one of
   two edge detectors.

---

## The edge-warp logic: axis is an EXCLUSIVE switch, never both

All edge-warping lives in `Sources/Nehir/Core/Controller/MouseWarpHandler.swift`.
A CGEvent tap (`setup()`, `:85-121`) watches `.mouseMoved` / left/right drag and
funnels each location through `handleMouseWarpMoved(at:)` (`:158`).

At `:175` the handler reads the axis once:

```swift
let axis = controller.settings.mouseWarpAxis              // MouseWarpHandler.swift:175
```

Then, in every branch that decides whether to warp, the axis is used as an
**exclusive** `switch` that dispatches to *either* a horizontal attempt *or* a
vertical attempt — never both:

- pointer landed outside any monitor frame → `:187-196`
  (`case .horizontal:` → `mouseWarpAttemptHorizontalWarpFromLastMonitor`;
   `case .vertical:` → `mouseWarpAttemptVerticalWarpFromLastMonitor`)
- monitor just changed since last event → `:221-236`
  (`case .horizontal:` → `mouseWarpAttemptHorizontalWarp`; `:222`;
   `case .vertical:` → `mouseWarpAttemptVerticalWarp`; `:231`)
- steady-state edge attempt on the current monitor → `:269-290`
  (`case .horizontal:` → `mouseWarpAttemptHorizontalWarp`; `:270`;
   `case .vertical:` → `mouseWarpAttemptVerticalWarp`; `:282`)

The two detectors test **disjoint** edges:

- Horizontal — `mouseWarpAttemptHorizontalWarp(...)` (`:350`), fires only on
  left/right edges:
  - left: `if location.x <= frame.minX + margin { ... }` (`:360`)
  - right: `if location.x >= frame.maxX - margin { ... }` (`:375`)
  - it transfers the cursor's **Y ratio** to the neighbour's left/right edge
    (`mouseWarpCalculateYRatio`, `:296`; destination mapping `:511-530`).

- Vertical — `mouseWarpAttemptVerticalWarp(...)` (`:424`), fires only on
  top/bottom edges:
  - top: `if location.y >= frame.maxY - margin { ... }` (`:434`)
  - bottom: `if location.y <= frame.minY + margin { ... }` (`:449`)
  - it transfers the **X ratio** (`mouseWarpCalculateXRatio`, `:301`;
    destination mapping `:534-552`).

The actual cursor move is a single funnel at `:494`:
`warpCursor(warpPoint)` — whose default is `CGWarpMouseCursorPosition`
(declared `:42`).

**Consequence for #63:** when `axis = .horizontal`, `mouseWarpAttemptVerticalWarp`
is unreachable from every call site. Nehir therefore **cannot** emit an up/down
warp in horizontal mode. With a vertically-stacked layout, when the cursor
reaches the shared top/bottom edge, the x-coordinate is still strictly inside
`frame.minX + margin ..< frame.maxX - margin`, so neither horizontal condition
(`:360`, `:375`) fires and Nehir's handler does nothing. Whatever jump occurs
there is not coming from this handler.

---

## Default is already horizontal

- `Sources/Nehir/Core/Config/SettingsExport.swift:109` — default export:
  `mouseWarpAxis: MouseWarpAxis.horizontal.rawValue`.
- `Sources/Nehir/Core/Config/SettingsStore.swift:40` — stored default:
  `var mouseWarpAxis = MouseWarpAxis(rawValue: ... ?? "") ?? .horizontal`.
- Round-trip preserve/merge also falls back to `.horizontal`
  (`SettingsStore.swift:471`).

So a user who has never touched the setting — and the #63 reporter, who observes
Nehir warping only on the left/right sides — is already on horizontal-only.
There is no setting that "turns off vertical warp" because Nehir never performs
one in that mode. The reporter's own description ("Nehir warps… when I touch the
sides (left and right)") is consistent only with `axis = .horizontal` being
active (`.vertical` would warp on top/bottom instead).

---

## There is no other edge-warp path in Nehir

A repo-wide scan for the only cursor-warp primitive confirms just two call
sites, both intentional:

```
Sources/Nehir/Core/Controller/MouseWarpHandler.swift:42   warpCursor = CGWarpMouseCursorPosition   (edge warp, this handler)
Sources/Nehir/Core/Controller/WMController.swift:190      warpMouseCursorPosition = CGWarpMouseCursorPosition
```

The `WMController` funnel is used by **explicit user commands**, not edge
detection:
- `moveMouseToFocused.perform` — moves the cursor to the focused window's
  center (`WMController.swift:3784`), gated by the `moveMouseToFocusedWindow`
  focus setting; driven by focus changes, not screen edges.
- `moveMouseToMonitor(_:)` — moves the cursor to a monitor's center
  (`WMController.swift:3790-3799`), invoked from the focus-navigation hotkey
  path (`WorkspaceNavigationHandler.swift:125`).

Neither is triggered by "cursor reaches a screen edge." There is no third edge
detector, no separate vertical-warp component, and no `CGAssociateMouseAndMouseCursorPosition`
usage anywhere in `Sources/Nehir`. The macOS-native jump at a shared vertical
edge is therefore not reachable/observable as a Nehir-initiated warp.

---

## Why macOS's vertical jump cannot be suppressed from Nehir

Nehir warps the cursor only by calling `CGWarpMouseCursorPosition`. That API can
*reposition* the cursor; it cannot *prevent* macOS from repositioning it. The
"cursor jumps to the adjacent display when you push past a shared edge" is
WindowServer/HID-level display-edge behaviour that happens independently of, and
outside, any `CGEvent` tap Nehir can install (`MouseWarpHandler.setup()` uses
`.cgSessionEventTap`, `:107`). There is no public API to disable macOS's
inter-display edge jump for a specific axis. (Compare `docs/offscreen-clamp-
fix.md:111-112`, which states the analogous "macOS clamps both axes and no
tested API can override it" for the offscreen-clamp problem — same class of
WindowServer limitation.)

So the user's literal request — "suppress the vertical warp" — has no Nehir-side
implementation, because the vertical warp is not Nehir's to suppress.

---

## Test evidence (corroborates horizontal-only on vertical physical layouts)

`Tests/NehirTests/MouseWarpHandlerTests.swift` builds fixtures with physically
**vertical** monitor geometry but exercises them under `axis: .horizontal`, e.g.
(`:161-166`):

```swift
let topMonitor = Monitor(displayId: 2, name: "Top",
                         x: 0, y: 900, width: 1440, height: 900)   // stacked ABOVE bottom
let fixture = makeConfiguredMouseWarpFixture(
    monitors: [bottomMonitor, topMonitor],
    monitorOrder: ["Top", "Bottom"],
    axis: .horizontal                                              // horizontal mode on vertical layout
)
```

This is exactly the reporter's topology, and the suite asserts warp behaviour
under `.horizontal` (`:83`, `:165`, `:746`) and `.vertical` (`:101`, `:133`)
independently. The horizontal-mode assertions place the trigger on the left/right
edges, never the top/bottom shared edge — i.e. the test model encodes the same
fact the source does: horizontal mode does not react to vertical edges.

---

## Recommended action / resolution

**No source change for the literal request.** This is a no-op class finding: the
behaviour the user wants from Nehir is already the default, and the behaviour
they want removed is macOS-native and not suppressible by Nehir.

Suggested response on the issue (operational, not code):

1. Confirm the reporter is on `axis = "horizontal"` (default). It already is,
   given they see left/right-only Nehir warps. Nothing to change in settings.
2. Explain that the up/down jump is macOS moving the cursor between two displays
   that share a horizontal edge; Nehir cannot disable that.
3. Offer the maintainer-confirmed **diagonal arrangement** workaround: in
   System Settings → Displays, offset the monitors diagonally (e.g. upper-left
   vs lower-right) so they no longer share a full horizontal edge. Both the
   reporter and @flschulz confirmed this removes the unwanted jump while keeping
   Nehir's horizontal warp useful.
4. Note the tension with `docs/offscreen-clamp-fix.md:101-104`, which
   *recommends* vertical arrangement for offscreen-window clamp reasons. Users
   hitting both problems may need to pick the arrangement that bothers them
   less, or use a diagonal compromise.

### Optional future feature, explicitly not recommended here

A "cursor clamp to current monitor" mode (intercept edge pushes and hold the
cursor inside one display until a modifier is held) could *mask* the macOS
vertical jump. This is a substantial new feature with its own quirks (it would
also block the user's own deliberate cross-display motion, interfere with Nehir's
existing horizontal warp, and require careful coexistence with the event tap).
The owner already flagged that "any solution may come with some quirks." It is
**out of scope** for #63 as filed and should only be pursued as a separate,
deliberately-scoped plan if the diagonal workaround proves insufficient.
