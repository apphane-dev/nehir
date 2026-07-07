# Discovery: command palette — tap-gesture activation vs VoiceOver, and `ObservableObject` → `@Observable`

Groom 2026-07-07: still applicable — Finding 4 of the SwiftUI audit, split out because both sub-findings (`.onTapGesture` vs `Button` for VoiceOver; `ObservableObject` → `@Observable` migration) carry a product/risk decision rather than a mechanical fix; no `planned/` doc, gated on revisiting command-palette work (verified against main 7a025b78).

Status: discovery — static audit, no runtime capture. Splits Finding 4 of
`discovery/20260703-swiftui-conformance-audit-foreach-identity-and-deprecated-apis.md`
into its own document because both sub-findings carry a design/risk decision
rather than a mechanical fix. Neither has a follow-up plan yet; recommendations
on whether to write one are at the end.

Audited against the main Nehir source tree on 2026-07-03 at commit `151f4e3a`
("Exempt user-activated apps from the unrequested-admission guard"), using the
swiftui-expert-skill accessibility and state-management references. Deployment
target is macOS 15 (`Package.swift:16`), so `@Observable` (macOS 14+) and all
accessibility APIs named here are available unconditionally.

## Sub-finding A: rows activate via `.onTapGesture`, not `Button`

### What the code does

The command palette is a spotlight-style overlay:
`Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift:158` defines
`CommandPalettePanel: NSPanel`; the SwiftUI tree is hosted through an
`NSHostingView` (`CommandPaletteController.swift:1067`) and shown with
`panel.makeKeyAndOrderFront` (`:368`).

Every result row activates through a bare `.onTapGesture` that sets the
selection and invokes `selectCurrent()` — six sites, three in the main list
(`CommandPaletteController.swift:1289,1301,1313`) and three in the fallback
sections (`:1404,1416,1428`). The rows themselves
(`CommandPaletteWindowRow` / `CommandPaletteMenuRow` / `CommandPaletteCommandRow`)
are plain views, not `Button`s.

### Why the standard "use Button" advice only partly applies

The skill's checklist says "Use `Button` for all tappable elements" — the usual
justification is that `.onTapGesture` is invisible to keyboard and VoiceOver.
Here **keyboard is already handled out-of-band**: an `NSEvent` local key-down
monitor (`CommandPaletteController.swift:770`) routes into `handleKeyDown`
(`:783`), which drives `moveSelection(by:)` (`:829`) on arrow keys and
`selectCurrent(trigger:)` (`:845`) on Return. So a keyboard user can already
navigate and activate rows; the tap gesture is purely the mouse affordance.

The genuine, unmitigated gap is **VoiceOver**. There is **not a single
`accessibility*` modifier in the entire palette file** (grep for `accessibility`
returns nothing). Rows are therefore exposed to VoiceOver, if at all, as inert
text with no button trait, no actionable element, and no grouping/label. A
`Button`-based row would fix the trait and action for free; a tap gesture never
gets there.

### The open design question

Whether this matters — and how to fix it — depends on a product call that the
audit cannot make from source alone:

1. **Is a transient, mouse-summoned `NSPanel` overlay a VoiceOver target the
   team wants to support at all?** It is not a standard focusable window; it is
   dismissed on resign-key. If VoiceOver support for the palette is a non-goal,
   this is a `noop`, not a fix.
2. **If yes, what is the right shape?** Two options, not equivalent:
   - Convert each row to a `Button` with a borderless/custom style and move the
     selection+`selectCurrent()` logic into its action. Smallest diff, earns the
     button trait, but must preserve the existing hover/selection visuals and
     must not double-fire against the key-down monitor's Return handling.
   - Keep the tap gesture for mouse but add explicit
     `.accessibilityElement(children: .combine)` + `.accessibilityAddTraits(.isButton)`
     + `.accessibilityAction` + a label per row, plus an
     `.accessibilityLabel`/value on the search field and mode picker. More code,
     but decouples the a11y model from the pointer model.

Either way it is a scoped, testable change — but it needs the decision in (1)
first, which is why this is discovery, not a plan.

### Not in scope

`Sources/Nehir/UI/AppRulesView.swift:629` uses `.onTapGesture` on an "Advanced
Matchers" disclosure label that is *inside* a `DisclosureGroup`'s own `label:`
(the group already provides the actionable control), so it is a redundant
secondary affordance, not a primary activation gap. `WorkspaceBarView.swift:603`
and `InteractiveMoveDemo.swift:695` are mouse-only surfaces by design. None of
these three are part of this finding.

## Sub-finding B: `CommandPaletteController` is an `ObservableObject`

### What the code does

`CommandPaletteController.swift:165` declares
`final class CommandPaletteController: NSObject, ObservableObject, NSWindowDelegate`
(`@MainActor`, `:164`) with eight `@Published` properties (`:173-195`):
`isVisible`, `searchText`, `selectedMode`, `selectedItemID`, `windows`,
`menuItems`, `commandItems`, `isMenuLoading`. The SwiftUI view holds it via
`@ObservedObject var controller` (`CommandPaletteController.swift:1213`) and
binds exactly one property: `TextField(..., text: $controller.searchText)`
(`:1227`).

### The invalidation cost (hypothesis, unmeasured)

With `ObservableObject`, every `@Published` mutation fires the single
`objectWillChange` publisher, so the whole `CommandPaletteView` body
re-evaluates on **any** change — including each `searchText` keystroke, even for
the parts of the body that don't read `searchText`. Migrating to `@Observable`
would scope invalidation to the views that actually read each property, so
typing would stop re-evaluating the (potentially large) results `LazyVStack`
except where it genuinely depends on the query.

This is a plausible win but **not evidenced**: there is no trace showing palette
typing as a hot path, and per the skill, performance changes are suggestions,
not requirements. It should not be migrated "for performance" without a capture
that shows the cost.

### Migration surface (bounded, with one real risk)

If undertaken, the change is small and self-contained:

- `: NSObject, ObservableObject, NSWindowDelegate` → `@Observable` +
  `: NSObject, NSWindowDelegate` (keep `NSObject`/delegate; the app relies on
  `NSWindowDelegate`).
- Delete all eight `@Published` attributes (the property observers/`didSet`
  bodies at `:174-195` stay — `@Observable` is compatible with `didSet`).
- `@ObservedObject var controller` (`:1213`) → `@Bindable var controller` (or a
  plain `let` plus a local `@Bindable`), required because of the one
  `$controller.searchText` binding at `:1227`.
- `private(set)` properties need `@ObservationIgnored`-free handling — they
  observe fine; only truly non-observed stored state (timers, monitors, the
  `panel`) should get `@ObservationIgnored`.

**Risk to verify before committing:** `@Observable` is applied here to an
`NSObject` subclass that is also an `NSWindowDelegate` and is read from inside an
`NSHostingView` root. The macro supports `NSObject` subclasses, but observation
only tracks reads that happen during SwiftUI body evaluation — any palette state
consumed through AppKit/delegate callbacks rather than the SwiftUI body will not
gain observation and must keep working as plain property access. A build +
manual smoke of open/type/arrow/enter/dismiss is mandatory, plus the existing
palette test suite (`panelForTests`/`selectCurrent` test hooks at
`CommandPaletteController.swift:1156` and the `*ForTests` helpers).

## Recommendations

- **Sub-finding A** — worth a plan **only after** the product decision in
  "The open design question" (1). If VoiceOver support for the palette is a
  goal, write a plan for the `Button`-conversion option (smaller, earns the
  trait) with explicit regression checks against the key-down monitor and the
  selection visuals. If it is not a goal, record a short `noop` saying so. Do
  not do a blind mechanical swap — it risks double-firing activation and
  regressing hover styling for no confirmed benefit.
- **Sub-finding B** — do **not** migrate speculatively. Leave as-is until either
  (a) a trace shows palette typing invalidation is a real cost, or (b) the file
  is being substantially reworked anyway and the migration rides along under the
  skill's "don't migrate soft-deprecated/legacy patterns during unrelated edits"
  scoping rule. The migration surface above is captured so that, when the
  trigger comes, it is a one-sitting change rather than a re-investigation.
