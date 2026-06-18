# OmniWM issue #336 — "Support gesture scroll without scroll snap" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/336>
Scope of this doc: determine whether the requested "modifier-key-gated
non-snapping gesture scroll" feature applies to nehir, and whether
nehir needs to add it.

All file/line references were verified against worktree `worktree-calm-meadow-6229`
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM").
Re-verify before implementing; line numbers drift.

---

> **Filed under `discovery/noop/`** — nehir already ships the exact feature
> #336 asks for, and in a stricter form than the upstream suggestion. During the
> viewport-navigation redesign (`completed/20260612-viewport-navigation-redesign.md`)
> nehir **removed** the global `[gestures] scrollSnap` toggle and instead made the
> **Mouse Modifier** key bypass trackpad scroll snap **per gesture** (held at
> start *or* pressed mid-gesture). Because the requested feature is fully present,
> #336 owns **no new repo action**. Porting the upstream fix (PR #350 "closes
> #336", PR #228 "≈ #336") would re-add the global `scrollSnap` toggle nehir
> deliberately deleted — a regression — so it is **not** to be ported.

## TL;DR

- **Nehir already answers #336 word-for-word: holding the Mouse Modifier while
  trackpad-scrolling bypasses snap and leaves the viewport wherever the user
  parked it (clamped only to valid bounds).** The global `scrollSnap` toggle the
  upstream PRs propose was removed by design.
- **Verdict:** 🟢 **Fixed / not present** — feature implemented in nehir; this
  validates the catalog's instruction to check whether a snap toggle already
  ships. The catalog's `nehir's own` flag on PR #350 is consistent with the
  finding: this is nehir-owned code that nehir has already written.

## What the issue actually asks

Filed by `Guria` on 2026-05-17, **closed** upstream. Title: "Support gesture
scroll without scroll snap." Body (verbatim):

> Sometimes I want to manually position my scroll, but we have forced scroll
> snap logic applied. I wonder if we can introduce scroll with modifier key
> hold to opt in no snap behaviour

So the ask is precisely: **opt out of scroll-snap per gesture, gated by a
held modifier key.** No reproduction, no cited code, no linked PR in the issue
metadata. The catalog notes two upstream attempts: PR #350 "Niri scroll snap
toggle — closes #336" (closed, tagged `nehir's own`) and PR #228 "Niri
snap-to-column-boundaries option (≈#336)" (open draft). Both add a snap toggle;
neither shares nehir's code (nehir forks OmniWM, not the upstream rewrite).

## Provenance: is this nehir's code?

Yes. The
trackpad scroll-gesture path that #336 concerns is entirely present in nehir:

- Trackpad gesture arming / commit / end: `MouseEventHandler.swift` (the same
  path analyzed in the sibling `20260616-omniwm-301` and `20260616-nehir-53` docs).
- Gesture viewport math (snap-vs-preserve): `ViewportState+Gestures.swift`.
- The Mouse Modifier setting (the opt-in key): `SettingsStore` →
  `controller.settings.mouseResizeModifierKey`, surfaced in the UI as
  `BehaviorSettingsTab.swift:89` ("Mouse Modifier").

## The code in question

### 1. The modifier sets a `bypassSnap` flag when the gesture arms

`MouseEventHandler.swift:1516-1524` — at gesture arming, the locked context
records whether the Mouse Modifier is held:

```swift
state.lockedGestureContext = .init(
    workspaceId: currentContext.wsId,
    monitorId: currentContext.monitor.id,
    bypassSnap: Self.modifierFlagsMatch(
        snapshot.modifiers,                                  // path:1519
        required: controller.settings.mouseResizeModifierKey.cgEventFlag
    )
)
```

`MouseEventHandler.swift:81` defines `let bypassSnap: Bool` on the context.

### 2. The modifier can ALSO engage bypass mid-gesture (strictly better than #336)

`MouseEventHandler.swift:1547-1558` — if the gesture armed *without* the
modifier but the user presses it during the committed scroll, bypass is
promoted to `true`:

```swift
if !lockedContext.bypassSnap,
   Self.modifierFlagsMatch(snapshot.modifiers,
       required: controller.settings.mouseResizeModifierKey.cgEventFlag)
{
    lockedContext = .init(workspaceId: lockedContext.workspaceId,
                          monitorId: lockedContext.monitorId,
                          bypassSnap: true)
    state.lockedGestureContext = lockedContext
}
```

### 3. `bypassSnap` becomes `snapToColumn: false` at gesture end

`MouseEventHandler.swift:1782-1784` — the bypass flag drives the snap argument
on `endGesture`:

```swift
endState.endGesture(
    columns: columns,
    ...
    isTrackpad: true,
    snapToColumn: !lockedContext.bypassSnap,                  // path:1783
    ...
)
```

### 4. `snapToColumn == false` preserves the user's manual position

`ViewportState+Gestures.swift:87-100` — when snap is disabled, the gesture ends
by *preserving* the current offset rather than rounding to a column snap:

```swift
guard snapToColumn else {                                    // path:87
    endGesturePreservingCurrentOffset(
        currentOffset: currentOffset,
        velocity: velocity,
        columns: columns, gap: gap, viewportWidth: viewportWidth,
        motion: motion, timestamp: now
    )
    return
}
```

`endGesturePreservingCurrentOffset` (`ViewportState+Gestures.swift:118-157`)
sets the viewport to the user's manual position, clamping **only** to the valid
scroll bounds (`viewportStartBounds`) — never to a column edge — so the user can
freely park the scroll between columns. This is exactly "manually position my
scroll" from the issue body.

### 5. When bypass is active, focus does not follow the snap either

`MouseEventHandler.swift:1790-1792` — `syncViewportSelectionToActiveColumn` is
skipped when bypassing, so a non-snapping scroll does not yank focus to a column:

```swift
if !lockedContext.bypassSnap {                               // path:1791
    selectedWindow = syncViewportSelectionToActiveColumn(columns: columns, state: &endState)
}
```

The end trace even records `snap=\(!lockedContext.bypassSnap)`
(`MouseEventHandler.swift:1829`), confirming bypass is a first-class,
observable state, not an afterthought.

## Why it is already fixed (and why porting would regress)

The feature requested in #336 — "scroll with modifier key hold to opt in no
snap behaviour" — is implemented verbatim, with two improvements over the
issue's literal ask:

1. **Per-gesture, not global.** The redesign
   (`completed/20260612-viewport-navigation-redesign.md:53`) records:
   *"Removed the obsolete `gestureScrollSnap` setting and made the Mouse
   Modifier bypass snap for trackpad scroll gestures."* The accompanying
   changeset (`.changeset/20260612022904-...:19-25`) documents the migration
   away from the global `[gestures] scrollSnap = true/false` toggle. Nehir
   deliberately replaced a global on/off switch with the per-gesture modifier
   bypass — precisely the opt-in the reporter wanted.
2. **Modifier engages mid-gesture too** (`MouseEventHandler.swift:1547-1558`),
   so the user does not have to hold the key before starting the scroll.

Both upstream PRs (#350, #228) move in the opposite direction: they (re-)add a
snap toggle. Porting either would undo nehir's explicit decision to drop the
global toggle and would re-introduce a setting nehir's own changeset marks as
removed with no backward-compatibility mapping. That is a regression, not a
fix.

## Recommendation

- **Do not port PR #350 or PR #228.** nehir already implements #336 in a
  stricter form and deliberately removed the global toggle those PRs (re-)add.
- **Minor, doc-only nit (not owned by #336):** `README.md:191` still describes
  the *removed* design —
  *"Configurable gesture scroll snap. … Controlled by `gestures.scrollSnap` in
  `settings.toml` (default `true`)."* That setting no longer exists (removed in
  the redesign; no match in `Sources/` for `gestureScrollSnap`/`gestures.scrollSnap`).
  The line should be rewritten to describe the current Mouse-Modifier bypass.
  This is README hygiene belonging to the viewport-navigation redesign, not a
  new action #336 motivates; it is noted here only for completeness.

## Suggested tests

N/A — the behavior is already implemented and verified by code inspection. If
the viewport-navigation test suite (deferred per the plan's "Tests intentionally
deferred" note) is later filled in, a natural case to lock in is: *a
trackpad-scroll gesture ending with the Mouse Modifier held leaves
`viewOffsetPixels` at the user's position (within bounds) and does not select a
new active column*, i.e. `bypassSnap == true` ⇒ `snapToColumn == false` ⇒
`endGesturePreservingCurrentOffset`.
