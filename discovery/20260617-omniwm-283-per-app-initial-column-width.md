# OmniWM issue #283 — "Per-app initial column width rules" — Discovery

Groom 2026-07-07: in flight — a plan exists (planned/20260621-omniwm-283-per-app-initial-column-width.md); no per-app initial column-width effect yet (verified against main 7a025b78).

Source issue: https://github.com/BarutSRB/OmniWM/issues/283
Scope of this doc: determine whether nehir can/should support per-app
**initial** column-width rules (e.g. Kitty opens at 50%, Safari at 100%),
distinct from per-app minimum size, and where such a feature would attach.

All file/line references were verified against the Nehir source tree at `904df02` ("Add bunch of discoveries mapped to
issues from OmniWM"). Line numbers drift — re-verify before implementing.

---

## TL;DR

- **nehir has no per-app initial column-width support at all.** The symbol does
  not exist (`initialWidth` / `initialColumnWidth` / `initialProportion` /
  `startupWidth` → no matches anywhere in the tree), and on window admission the
  column width is computed **entirely from workspace/monitor settings** — the
  matched app's `bundleId` never reaches the column-width resolver.
- **The feature is well-scoped and partly plumbed.** `AppRule` already carries
  the match primitives (`bundleId`, `appNameSubstring`, `titleSubstring`/`Regex`,
  `axRole`, `axSubrole`) and an effect-block (`minWidth`/`minHeight`), and a
  `WindowDecision.ruleEffects` flows per-app effects into admission. An
  `initialColumnWidth` effect slots into that exact pipeline; the missing piece is
  a consumption site at column **creation** (today only the *floor* `minWidth` is
  consumed, at the relayout layer).
- **Verdict:** 🔴 **Applies / owns a new action.** This is an open feature, not a
  reproducing bug; nehir lacks the capability, the premise is valid, and the code
  to extend exists. Distinct from sibling min-size work (#384, 🟢 Fixed) and
  cross-workspace width preservation (#295, 🔴 Applies) — the boundary is drawn
  below.

## Provenance: is this nehir's code?

Yes, all of it. `AppRule` and the rule pipeline are nehir-original config code;
the Niri layout engine is inherited from upstream. nehir's
`AppRule` already models per-app effects — it just has no initial-width effect.

- `Sources/Nehir/Core/Config/AppRule.swift` — the rule struct (match + effect fields).
- `Sources/Nehir/Core/Rules/WindowRuleEngine.swift:40` — `ManagedWindowRuleEffects`
  (the per-window effect carrier).
- `Sources/Nehir/Core/Config/SettingsStore.swift:731` — `appRule(for: bundleId)`,
  the match lookup primitive.
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:116` — `addWindow`,
  the admission site that creates a column.

## The upstream ask

The reporter wants per-app *startup* width via App Rules:

> Kitty starts at 50% width; Safari starts at 100% width. … This is different
> from minimum width/height constraints. The request is for the starting width
> assigned when a matching app creates or claims a new column, while still
> allowing the user to resize it afterward.

Proposed shape: `initialColumnWidth = 0.5` (a proportion), exposed in App Rules
alongside the existing min-size fields. That maps cleanly onto nehir's existing
`[match]` / `[effect]` TOML rule format (see `docs/CONFIGURATION.md:209`).

## The code in question

### 1. The rule struct has match primitives + min-size effects, but no width

```swift
// Sources/Nehir/Core/Config/AppRule.swift:57-78  (struct AppRule fields)
var bundleId: String
var appNameSubstring: String?
var titleSubstring: String?
var titleRegex: String?
var axRole: String?
var axSubrole: String?
var manage: WindowRuleManageAction?
var layout: WindowRuleLayoutAction?
var assignToWorkspace: String?
var minWidth: Double?
var minHeight: Double?
//  ^ no initialWidth / initialColumnWidth field
```

The effect carrier mirrors this exactly, and likewise has no width:

```swift
// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:40-47
struct ManagedWindowRuleEffects: Equatable, Sendable {
    var minWidth: Double?
    var minHeight: Double?
    var matchedRuleId: UUID?
    static let none = ManagedWindowRuleEffects()
}
```

### 2. Admission sizing is workspace-scoped — app identity is absent

When a window is admitted, `addWindow` creates or claims a column and sizes it
from workspace defaults. The matched bundleId is **never** consulted:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:116  (func addWindow)
func addWindow(token: WindowToken, to workspaceId: WorkspaceDescriptor.ID,
               afterSelection selectedNodeId: NodeId?, focusedToken: WindowToken? = nil) -> NiriWindow {
    let root = ensureRoot(for: workspaceId)

    if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: root) {
        initializeNewColumnWidth(existingColumn, in: workspaceId)   // :125 — no token/bundleId
        ...
    }
    ...
    let newColumn = NiriContainer()
    initializeNewColumnWidth(newColumn, in: workspaceId)            // :153 — no token/bundleId
    ...
}
```

`initializeNewColumnWidth` → `resolvedColumnResetWidth` → `effectiveDefaultColumnWidth`,
all keyed on `workspaceId` only:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:210-233
func resolvedColumnResetWidth(in workspaceId: WorkspaceDescriptor.ID) -> (proportion: CGFloat, presetWidthIdx: Int?) {
    let resolvedDefaultColumnWidth = effectiveDefaultColumnWidth(in: workspaceId)   // :213 — workspace-scoped
    let width = CGFloat(resolvedDefaultColumnWidth.fraction)
    switch resolvedDefaultColumnWidth {
    case .custom: return (width, matchingPresetIndex(for: width))
    case .balanced: return (width, nil)
    }
}

func initializeNewColumnWidth(_ column: NiriContainer, in workspaceId: WorkspaceDescriptor.ID) {
    let resolvedWidth = resolvedColumnResetWidth(in: workspaceId)
    column.width = .proportion(resolvedWidth.proportion)
    column.presetWidthIdx = resolvedWidth.presetWidthIdx
    column.cachedWidth = 0
    column.isFullWidth = false
    column.savedWidth = nil
    column.hasManualSingleWindowWidthOverride = false
    column.widthAnimation = nil
    column.targetWidth = nil
}

// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Monitors.swift:81-83
func effectiveDefaultColumnWidth(in workspaceId: WorkspaceDescriptor.ID) -> DefaultColumnWidth {
    effectiveSettings(in: workspaceId).defaultColumnWidth     // per-workspace/monitor settings only
}
```

`grep -r "initialWidth\|initialColumnWidth\|initialProportion\|startupWidth\|openingWidth"`
across the tree → **no matches.** The capability does not exist.

### 3. Where the per-app effect *does* flow today (the floor, not the width)

`minWidth` is resolved per-window and merged into the window's *constraint
floor* at the relayout layer — applied continuously, not at creation:

```swift
// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:335-340  (decision(for:))
let effects = ManagedWindowRuleEffects(
    minWidth: userRule?.rule.minWidth,
    minHeight: userRule?.rule.minHeight,
    matchedRuleId: userRule?.rule.id
)

// Sources/Nehir/Core/Controller/WMController.swift:2085-2088  (admission captures effects onto the entry)
minWidth: evaluation.decision.ruleEffects.minWidth,
minHeight: evaluation.decision.ruleEffects.minHeight,
matchedRuleId: evaluation.decision.ruleEffects.matchedRuleId,

// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:506-509  (floor merge, relayout layer)
if let minW = entry.ruleEffects.minWidth {
    mergedConstraints.minSize.width = max(mergedConstraints.minSize.width, minW)   // ← a FLOOR, continuous
}
```

So `minWidth` is a constraint that **clamps column width up** every layout pass
(the guarantee documented in sibling #384). An **initial** width is a different
axis: it must be consumed **once, at column creation**, not merged into the
constraint floor. The plumbing for "matched rule → per-window effect" exists;
the missing step is carrying that effect into `addWindow`/`initializeNewColumnWidth`.

### 4. The lone-window interaction (the design gotcha)

The reporter's examples (Kitty 50% / Safari 100%) are typically a lone window on
a fresh workspace. The lone-window path **ignores** `column.width` and renders
the full working area unless a manual-override flag is set:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:700-707
private func resolvedSingleWindowWidth(for context: SingleWindowLayoutContext,
                                       in workingFrame: CGRect, gaps: CGFloat) -> CGFloat {
    guard context.container.hasManualSingleWindowWidthOverride else {
        return workingFrame.width * CGFloat(context.maxWidthFraction.clamped(to: 0.0 ... 1.0))
        //                                                                  default policy .fill → 1.0 → 100%
    }
    if context.container.cachedWidth <= 0 {
        context.container.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
    }
    return max(0, context.container.cachedWidth)
}
```

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:22-24
enum LoneWindowPolicy: Equatable, Identifiable, Codable {
    case fill
    case centered(maxWidthFraction: Double)
}
```

**Consequence:** setting only `column.width = .proportion(0.5)` is *insufficient*
for the Kitty-on-empty-workspace case — the `.fill` policy still yields 100%. The
feature must also set `column.hasManualSingleWindowWidthOverride = true` so the
lone-window path honors the rule's width (exactly the flag the #295 fix relies
on, `initializeNewColumnWidth` clears it at `NiriLayoutEngine.swift:229`). Using
that flag for a rule-set width is a semantic overload of "manual override" — it
should be an explicit design decision, not an accident.

## Why it applies (and owns a new action)

1. **The capability is wholly absent.** No symbol, no field, no plumbing from the
   matched `bundleId` to column creation. Admission sizing is 100% workspace-
   scoped (`addWindow` → `initializeNewColumnWidth` → `resolvedColumnResetWidth`
   → `effectiveDefaultColumnWidth(in:)`). The reporter's "Kitty 50% / Safari 100%"
   cannot be expressed today.

2. **The premise is valid and the extension surface exists.** `AppRule` already
   matches by `bundleId` (plus advanced matchers), `ManagedWindowRuleEffects`
   already carries per-window effects, and `WindowDecision.ruleEffects` already
   flows into admission (`WMController.swift:2086`). Adding an `initialColumnWidth`
   effect reuses this pipeline; only the *consumption* site is new.

3. **It is genuinely distinct from `minWidth`.** `minWidth` is a constraint floor,
   enforced every layout, clamping width **up** (per #384). `initialColumnWidth`
   is a one-time starting proportion, applied at column creation, freely
   resizable afterward. An app can carry both (e.g. Kitty: `initialColumnWidth =
   0.5`, `minWidth = 400`) with no conflict.

## Boundary with sibling discoveries (coordinate here)

- **#384** (`noop/20260616-omniwm-384-respect-window-min-size-in-niri-column-width.md`,
  🟢 Fixed): the *floor* axis. nehir already propagates `minSize` into
  `resolveSpan`/`widthBounds` (`NiriNode.swift:526`/`:551`) and clamps column
  width **up** to it. Porting #384 is a no-op and delivers **none** of this
  feature — initial width and min floor are orthogonal. An `initialColumnWidth`
  implementation must still *respect* the #384 floor: if a rule's `0.5` resolves
  below the app's enforced min-size, the min-size wins (clamp the initial width up
  to `widthBounds().min` after applying the rule).
- **#295** (`20260616-omniwm-295-niri-window-width-preservation.md`, 🔴 Applies):
  the *move* axis. Both touch `initializeNewColumnWidth`: #295 via
  `moveWindowToWorkspace` (`NiriLayoutEngine+WorkspaceOps.swift:36`/`:40`), #283
  via `addWindow` (`:125`/`:153`). They must be coordinated so the precedence is
  intentional — proposed: a brand-new admission uses the rule width (else
  workspace default); a moved window with a rule uses the rule width; a moved
  window without a rule preserves the source width (#295's fix). Otherwise a
  #295 fix that blindly copies source state would clobber a per-app rule.
- **#268** ("Minimum window size seemingly ignored") is upstream's hazier twin of
  the same min-size-vs-initial-width confusion; #283 is the better-articulated,
  actionable half.

## Recommendation

**Implement per-app initial column width as a new `AppRule` effect**, threading
the existing rule pipeline and consuming it at column creation. Concrete shape:

1. **Config / model** — add `var initialColumnWidth: Double?` (proportion,
   `0.0...1.0`) to:
   - `AppRule` (`AppRule.swift`: field, `CodingKeys`, memberwise init, and the
     `init(from:)` decoder at `:120-141`).
   - `ManagedWindowRuleEffects` (`WindowRuleEngine.swift:40`).
   - The admission entry built in `WMController.swift:2079-2090`.
   - The `WindowDecision`/evaluation passthrough and the IPC projection
     (`IPCRuleProjection.swift:41`/`:60`/`:78`/`:93`, `IPCRuleValidator`,
     `CLIParser.swift:380`) and file store render (`AppRuleFileStore.swift:57`).
   - `WindowRuleEngine.decision(for:)` (`:335-340`): add
     `initialColumnWidth: userRule?.rule.initialColumnWidth` to the effects.

2. **Consume at column creation** — give `initializeNewColumnWidth` (or `addWindow`)
   access to the admitted window's `initialColumnWidth` (plumb the token's effect
   through; `addWindow` already receives the `token`). When non-nil:
   - set `column.width = .proportion(initialColumnWidth)` and
     `column.presetWidthIdx = matchingPresetIndex(for: initialColumnWidth)`
     (`NiriLayoutEngine.swift:236`);
   - set `column.hasManualSingleWindowWidthOverride = true` **so the lone-window
     path honors it** (`NiriLayout.swift:700-707`) — see §4;
   - clamp the resolved initial width up to the column's min floor
     (`widthBounds().min`, `NiriNode.swift:551`) so the rule never violates the
     app's own min-size (#384 guarantee).

3. **Config format** (mirrors the existing `minWidth` block in
   `docs/CONFIGURATION.md:209-220`):
   ```toml
   # apprules.d/net.kovidgoyal.kitty.toml
   [match]
   bundleId = "net.kovidgoyal.kitty"

   [effect]
   initialColumnWidth = 0.5     # 0.0–1.0 of working-area width; applied once at column creation
   minWidth = 400               # orthogonal floor; both may coexist
   ```

4. **Coordinate #295/#384 precedence** per the boundary section above.

## Suggested tests

1. **Rule width honored for a lone window on an empty workspace.** App rule
   `bundleId = kitty, initialColumnWidth = 0.5`; admit Kitty to an empty workspace
   on a `visibleFrame.width = 2000` monitor. Assert the emitted frame width is
   ~1000 (50%), `hasManualSingleWindowWidthOverride == true`, and the `.fill`
   policy does **not** override it to 2000. This is the core regression lock for
   §4.
2. **Rule width below the app's min-size is clamped up.** Rule `initialColumnWidth
   = 0.3` (→600px) with an app `minSize.width = 900`. Assert the column resolves
   to ≥900 (the #384 floor wins over the rule), never sub-minimum.
3. **Applied once, not re-triggered.** After Kitty's column exists, admit a second
   window to it (different app, no rule). Assert the column width is unchanged —
   the rule fires at creation only, not on every append.
4. **Cross-workspace move precedence (#295 interaction).** A window carrying an
   `initialColumnWidth` rule moved to a fresh workspace (#295 path via
   `moveWindowToWorkspace`) ends up at the rule width, not the target default and
   not a stale source width.
5. **No rule → unchanged.** An app without a rule admitted today behaves exactly
   as before (workspace `defaultColumnWidth`), so the feature is strictly
   additive.
