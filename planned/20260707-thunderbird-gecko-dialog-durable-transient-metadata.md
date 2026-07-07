# Plan: keep Gecko transient dialogs out of layout projection after floating admission

Status: **planned**. Root cause:
`discovery/20260707-thunderbird-gecko-dialog-floats-then-tiles-projection.md`.

## Goal

Fix the remaining Thunderbird send-confirmation dialog bug. The dialog is now
correctly admitted as floating by `builtInRule(geckoTransientDialog)`, including
when its initial WindowServer frame is zero. The remaining failure is that the
same dialog later gets accepted as `userAddressable` layout content after
Thunderbird publishes a real frame, so Nehir writes a tiled column frame over the
small dialog.

Make the Gecko transient classification durable in metadata so downstream
projection/lifecycle code treats these windows as non-user-addressable transient
surfaces.

## Evidence recap

Target window found in the latest Thunderbird reproduction:

```text
WindowToken(pid: 12744, windowId: 21921)
bundleId=org.mozilla.thunderbird
```

The classifier works at admission:

```text
window_decision token=WindowToken(pid: 12744, windowId: 21921)
  disposition=floating source=builtInRule(geckoTransientDialog)
  outcome=trackedFloating
  axRole=AXWindow axSubrole=AXStandardWindow
  wsLevel=0 wsTags=0x100000000 wsAttributes=0x1 wsParent=0
  wsFrame=(0.0,0.0,0.0,0.0)

track_prepared_create ... mode=floating ... frame=(0,0 0x0)
window_admitted ... mode=floating
```

Then the same WindowServer id receives a real dialog frame:

```text
prepare_create_rejected window=21921 reason=existing_entry
  ws_float=false ws_doc=true ws_frame=(1342,631 389x131)
```

And layout projection/tiled layout takes it over:

```text
w21921:selected{
  cur=14,7,1011,1251 target=14,7,1011,1251
  observed=1342,567,389,131
}
```

Projection also reports the metadata problem directly:

```text
accepted reason=userAddressable
transientWindowServerEvidence=false degradedWindowServerChildEvidence=false
parentWindowId=nil
```

## Files to touch

- `Sources/Nehir/Core/Rules/WindowRuleEngine.swift`
  - Add a reusable predicate/fact for Gecko transient dialogs, or otherwise make
    the current `geckoTransientDialogDecision` classification reusable by
    metadata construction.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift`
  - When building `ManagedReplacementMetadata`, mark Gecko transient dialogs as
    transient and non-user-addressable.
  - Ensure this applies to both initial zero-frame admission and later metadata
    refreshes for the same token.
- `Tests/NehirTests/WindowRuleEngineTests.swift` and/or existing
  `AXEventHandler`/workspace-manager tests
  - Add coverage for the metadata/projection behavior, not only the admission
    decision.

## Do-not-touch fences

- Do **not** revert the existing Gecko built-in or the zero-frame correction.
  The latest evidence proves they correctly classify the target window at
  admission.
- Do **not** broaden the rule to all standard level-0 Thunderbird windows. Main
  and compose windows with document evidence must remain tiled.
- Do **not** change `SkyLight.swift` tag decoding unless a test proves it is
  wrong. Current failure is metadata/projection, not tag decoding.
- Follow the main repo instruction: because this started from runtime debugging,
  avoid adding/updating tests until the runtime fix has been validated in the
  real repro, unless the supervising user explicitly asks for tests before that.

## Implementation sketch

### 1. Centralize the Gecko transient predicate

Avoid duplicating the fragile guard in two places. Introduce a helper that checks
exactly the facts used by the built-in:

```swift
static func isGeckoTransientDialog(facts: WindowRuleFacts) -> Bool {
    guard let bundleId = facts.ax.bundleId?.lowercased(),
          geckoBundleIds.contains(bundleId),
          facts.ax.attributeFetchSucceeded,
          facts.ax.role == kAXWindowRole as String,
          facts.ax.subrole == kAXStandardWindowSubrole as String,
          let windowServer = facts.windowServer,
          windowServer.parentId == 0,
          !windowServer.hasDocumentTag,
          !windowServer.hasFloatingTag
    else { return false }
    return true
}
```

Use that helper in `geckoTransientDialogDecision(...)` so admission behavior does
not change.

Visibility can be `internal` if `AXEventHandler` needs to call it. Prefer a
narrow helper over string-matching the decision source if that is simpler and
keeps metadata source-backed.

### 2. Make metadata durable for this class

In `AXEventHandler.makeManagedReplacementMetadata(...)`, compute:

```swift
let isGeckoTransientDialog = WindowRuleEngine.isGeckoTransientDialog(facts: facts)
```

Then set metadata booleans so the downstream projection gate recognizes this as
an app-managed transient, not a user-addressable floating window:

```swift
transientWindowServerEvidence: isGeckoTransientDialog
    || (facts.windowServer?.hasTransientSurfaceEvidence ?? false),
userAddressableTransientWindowServerSurface: isGeckoTransientDialog
    ? false
    : facts.userAddressableTransientWindowServerSurface
```

Preserve existing behavior for all non-Gecko-transient windows.

### 3. Preserve the classification during metadata refresh

Verify every path that constructs `ManagedReplacementMetadata` for an existing
entry routes through `makeManagedReplacementMetadata(...)` or receives equivalent
booleans. The important trace path is the already-tracked same token receiving a
later non-zero frame (`prepare_create_rejected ... reason=existing_entry`), then
projection accepting it as `userAddressable`.

If a later overlay/merge can overwrite the transient booleans from WindowServer
info alone, merge with OR semantics for `transientWindowServerEvidence` and never
promote a Gecko transient to `userAddressableTransientWindowServerSurface=true`.

### 4. Validate manually first

Before tests, run a local Thunderbird reproduction:

1. Start Nehir with runtime tracing enabled.
2. Send a Thunderbird message to trigger the send-confirmation dialog.
3. Confirm the target window still logs:

```text
source=builtInRule(geckoTransientDialog) outcome=trackedFloating
```

4. Confirm it no longer appears as a tiled layout node with a full-height target
frame.
5. Confirm projection no longer logs `accepted reason=userAddressable` for the
Gecko transient dialog. Expected rejection is one of:

```text
transientWindowServerSurface(noFrame)
transientSurfaceNotUserAddressable
```

### 5. Tests after runtime validation

After the user validates the runtime fix, add regression coverage:

- zero-frame Gecko transient still returns floating from `WindowRuleEngine`;
- the metadata for that same facts shape has
  `transientWindowServerEvidence == true` and
  `userAddressableTransientWindowServerSurface == false`;
- a real Gecko document/main/compose window with document tag remains managed;
- a non-Gecko standard document window is unchanged.

## Gates

Fast compile/typecheck gate:

```bash
swift test --filter WindowRuleEngineTests
```

Full gate once the fix is validated and tests are added:

```bash
swift test
```

## Changeset

This is a user-visible bug fix. Add a patch changeset after the implementation is
ready:

```bash
mise run changeset patch "Keep Thunderbird Gecko transient dialogs out of tiled layout projection"
```

Reference only the Nehir issue/PR number if there is a local Nehir ticket. Do not
reference upstream issue numbers in the changeset.

## Commit message shape

Use a plain-English subject, not Conventional Commits, for example:

```text
Keep Gecko transient dialogs out of layout projection
```
