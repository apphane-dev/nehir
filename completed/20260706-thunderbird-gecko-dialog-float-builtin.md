# Plan: float Gecko (Thunderbird/Firefox) transient dialogs via a scoped built-in

Status: **completed with later follow-ups**. First merged to `main` as
`45d3767f` ("Float Gecko transient dialogs (Thunderbird/Firefox) (#142)"),
2026-07-06, but that first commit accidentally shipped a
`!windowServer.frame.isEmpty` guard and did not float the real zero-frame dialog.
The zero-frame correction landed as `d953d4d3`; a later Thunderbird reproduction
showed additional Gecko creation paths and the final fix landed as `579f124d`
("Keep Gecko transient dialogs floating #142"). See
[[20260707-thunderbird-gecko-dialog-still-tiles-frame-isempty-guard-defeats-fix]]
and [[20260707-thunderbird-gecko-dialog-floats-then-tiles-projection]]. Root
cause: [[20260706-thunderbird-gecko-dialog-tiled-untagged-unparented-standard-window]].
Fixes apphane-dev/nehir discussion #142 (Thunderbird send-confirmation dialog
tiles as a column).

## Goal

Add a narrow built-in `WindowDecision` that floats a **Gecko/Mozilla-family**,
**top-level**, **standard** window whose WindowServer record carries **neither the
document tag nor the floating tag** — the exact signature of Thunderbird's
send-confirmation dialog — while leaving the compose window and the main 3-pane
window tiled.

This mirrors AeroSpace's hardcoded-Firefox approach and yabai's per-app rule
convention (see the root-cause discovery's prior-art section). It is intentionally
an engine built-in, not a user rule, because no `AppRule` matcher can express the
document-tag discriminator today.

## Evidence recap (self-contained)

From the captured `window_decision` records (Thunderbird, `pid 10123`), all
transient windows are admitted `context=focused_admission
disposition=managed source=heuristic`, `titleLength=nil`,
`axRole=AXWindow axSubrole=AXStandardWindow`, all four window buttons present and
`fullscreenButtonEnabled=true`. The only discriminator between the compose window
and the send dialog is the WindowServer tag field:

- Compose window / main window: `wsTags=0x300000100482001` → document bit `0x1`
  **set**, `wsAttributes=0x2`, `wsParent=0`.
- Send-confirmation dialog: `wsTags=0x100000000` → document bit `0x1` **not set**,
  floating bit `0x2` **not set**, `wsAttributes=0x0`, `wsParent=0`.

Tag decoding lives in `Sources/Nehir/Core/SkyLight/SkyLight.swift:913-942`
(`hasDocumentTag = tags & 0x1`, `hasFloatingTag = tags & 0x2`).

## Files to touch

- `Sources/Nehir/Core/Rules/WindowRuleEngine.swift` — add the built-in decision
  function, a Gecko bundle-id set, a rule-name constant, and one call site in
  `decision(...)`.
- `Tests/NehirTests/WindowRuleEngineTests.swift` — add tests.

**Do-not-touch fences:** do not modify `SkyLight.swift`, `AXWindow.swift`
(`heuristicDisposition`), `AXEventHandler.swift`, the `AppRule` schema
(`Sources/Nehir/Core/Config/AppRule.swift`), or any UI. This fix is entirely
inside `WindowRuleEngine`. Do not touch the parallel discovery/plan docs on the
`plans` branch — this worktree is source-only.

## Implementation

### 1. Constants (near the other rule-name constants, ~line 323-332)

```swift
private static let geckoTransientDialogRuleName = "geckoTransientDialog"
private static let geckoBundleIds: Set<String> = [
    "org.mozilla.thunderbird",
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "app.zen-browser.zen",
    "org.mozilla.seamonkey"
]
```

Match bundle ids case-insensitively (lowercase the incoming `bundleId` before the
`contains` check, consistent with `systemTextInputPanelBundleIds` usage at
`:453-454`).

### 2. Decision function (near `cleanShotRecordingOverlayDecision`, ~line 698)

```swift
// Gecko apps (Thunderbird/Firefox) report transient dialogs — e.g. the
// Thunderbird "message sent" confirmation — as top-level AXStandardWindows
// with all window buttons and an enabled fullscreen button, and with a nil AX
// title. They are indistinguishable from real document windows by AX alone, so
// the heuristic tiles them (#142). The one durable discriminator is the
// WindowServer document tag: real Gecko windows (main, compose) carry it; the
// transient dialog carries neither the document nor the floating tag. Float
// those. Title-based user rules cannot address this (title is nil).
private func geckoTransientDialogDecision(
    for facts: WindowRuleFacts,
    workspaceName: String?,
    effects: ManagedWindowRuleEffects
) -> WindowDecision? {
    guard let bundleId = facts.ax.bundleId?.lowercased(),
          Self.geckoBundleIds.contains(bundleId),
          facts.ax.attributeFetchSucceeded,
          facts.ax.role == kAXWindowRole as String,
          facts.ax.subrole == kAXStandardWindowSubrole as String,
          let windowServer = facts.windowServer,
          windowServer.parentId == 0,
          !windowServer.hasDocumentTag,
          !windowServer.hasFloatingTag
    else {
        return nil
    }

    return WindowDecision(
        disposition: .floating,
        source: .builtInRule(Self.geckoTransientDialogRuleName),
        layoutDecisionKind: .fallbackLayout,
        workspaceName: workspaceName,
        ruleEffects: effects,
        heuristicReasons: [],
        deferredReason: nil
    )
}
```

### 3. Call site in `decision(...)`

Insert **immediately after** the `cleanShotRecordingOverlayDecision` block and
**before** the `if facts.ax.title == nil, requiresTitle(...)` deferral (~line
543-552). Placing it here means an explicit user rule (tile or float) still wins
— those are evaluated earlier — while the dialog is caught before it can fall to
the tiling heuristic or the title-missing deferral:

```swift
if let geckoDecision = geckoTransientDialogDecision(
    for: facts,
    workspaceName: workspaceName,
    effects: effects
) {
    return geckoDecision
}
```

Use `layoutDecisionKind: .fallbackLayout` (not `.explicitLayout`) so a user's
explicit tile rule for the app can still override in the earlier `explicitDecision`
branches.

## Tests (`WindowRuleEngineTests.swift`)

The existing `makeWindowRuleFacts` factory + `WindowServerInfo` construction (see
lines 12-46 and 128-137) cover everything needed. Add:

1. **Dialog floats.** Thunderbird facts, `windowServer` with `tags = 0`
   (no document, no floating), `parentId = 0`, standard subrole, all buttons →
   expect `disposition == .floating`, `source == .builtInRule("geckoTransientDialog")`.
2. **Compose/main window tiles.** Thunderbird facts, `windowServer.tags = 0x1`
   (document tag set), else identical → expect `disposition == .managed`
   (heuristic), not the gecko rule.
3. **Floating-tagged Gecko surface is NOT claimed by this rule.** `tags = 0x2`
   (floating, no document) → the pre-existing `transientWindowServerSurface`
   branch already floats it; assert it still floats and that behavior is
   unchanged (guards against double-handling).
4. **Parented Gecko surface unaffected.** `parentId != 0` → falls to the existing
   `parentedWindowServerSurface` float path, not the new rule.
5. **Non-Gecko standard window with no tags still tiles.** `bundleId
   = "com.example.app"`, `tags = 0`, standard, all buttons → `disposition ==
   .managed` (proves the rule is scoped to Gecko and does not regress generic
   tiling).
6. **Explicit user tile rule wins.** A user `AppRule{bundleId: thunderbird,
   layout: .tile}` + dialog facts → `disposition == .managed` (proves the call
   site respects user precedence).

## Gate

- Between steps / fast iteration: `mise run build && mise run test`.
- Full gate once at the end (what CI runs): `mise run check`
  (format:check + lint + build + test). Must be green before commit.

## Commit

Single commit on a feature branch (not `main`):

```
Float Gecko transient dialogs (Thunderbird/Firefox) (#142)

Thunderbird's send-confirmation dialog opens as a tiled column. It presents
as a top-level AXStandardWindow with all buttons, an enabled fullscreen
button, and a nil AX title — indistinguishable from a real document window
by AX, so the heuristic tiles it. The only durable discriminator is the
WindowServer document tag: real Gecko windows carry it, the transient
dialog carries neither document nor floating tag. Add a scoped built-in
decision that floats top-level, tagless, standard Gecko-family windows.
Title-based user rules cannot address this (title is nil). Mirrors
AeroSpace's hardcoded-Firefox handling.

Co-Authored-By: <worker> <...>
```

Add a changeset per repo convention: `mise run changeset patch "Float
Thunderbird/Firefox transient dialogs that previously tiled as columns"`.

## Risk / verification notes

- **Firefox tag stability.** The fix assumes Firefox's real windows (and any
  large dialog the user *wants* tiled) carry the document tag, matching
  Thunderbird `v0.6.0`. Confirmed for Thunderbird from the capture; the worker
  should not attempt to verify Firefox at runtime (no capture available) — test
  coverage encodes the intended behavior and the bundle set can be narrowed to
  `org.mozilla.thunderbird` only if a Firefox regression is later reported.
- **Do not widen** to a general "float any tagless standard window" rule — that
  would over-float non-Gecko apps. Scope stays on `geckoBundleIds`.
- Second candidate discriminator (minimize-button-enabled, per AeroSpace) is
  **not** used here; the document-tag signal has no known caveat, the
  minimize-button one does (buggy under Firefox non-native fullscreen).

## Outcome (2026-07-06)

Delegated to `openai-codex-3/gpt-5.5` in an isolated worktree, then reviewed.
Shipped on `main` as `45d3767f` (branch `impl-thunderbird-gecko-dialog-float`):
`WindowRuleEngine.swift` +53, `WindowRuleEngineTests.swift` +173 (6 new tests),
plus a changeset.

Review caught one correction before merge: the first pass added an unrequested
`!windowServer.frame.isEmpty` guard, which would have **defeated the fix** — the
captured dialog has `wsFrame=(0,0,0,0)` at the moment its AX attributes succeed
(`CGRect.zero.isEmpty == true`), and the worker's test masked it with a hardcoded
non-empty frame. The guard was removed and the float test changed to a `.zero`
frame (helper now defaults `frame: .zero`) to encode the captured reality.
Independently re-ran `swift test --filter WindowRuleEngine` → 35 tests pass.

Note: the full `mise run check` gate was red only due to a **pre-existing,
unrelated** failure —
`RefreshRoutingTests.nativeFullscreenSpaceChangeRetainsMultiColumnNiriOrderWithSameWindowId`
also fails on clean `main`. Tracked separately:
[[20260706-refreshrouting-nativefullscreen-space-change-niri-order-pre-existing-failure]].
