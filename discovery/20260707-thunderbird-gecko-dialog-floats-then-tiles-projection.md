# Thunderbird Gecko dialog floats at admission, then gets tiled by projection

Status: **actionable**. Follow-up to the completed Thunderbird/Gecko dialog fixes:

- `completed/20260706-thunderbird-gecko-dialog-float-builtin.md`
- `completed/20260706-thunderbird-gecko-dialog-tiled-untagged-unparented-standard-window.md`
- `completed/20260707-thunderbird-gecko-dialog-still-tiles-frame-isempty-guard-defeats-fix.md`

The latest local Thunderbird reproduction shows that the zero-frame guard fix did
work: the target dialog is now classified by the Gecko built-in and admitted as
floating. The remaining bug is later: the same floating dialog becomes
user-addressable layout content after Thunderbird publishes its real WindowServer
frame, so the tiled layout writes a full column frame over the small dialog.

---

## Target window found before planning

The target screenshot is the Thunderbird send-confirmation dialog. In the capture
it is:

```text
WindowToken(pid: 12744, windowId: 21921)
bundleId=org.mozilla.thunderbird
```

The admission record identifies it as the exact window under investigation:

```text
window_decision token=WindowToken(pid: 12744, windowId: 21921)
  context=focused_admission existingMode=nil
  disposition=floating source=builtInRule(geckoTransientDialog)
  outcome=trackedFloating layout=fallbackLayout deferred=nil
  bundleId=org.mozilla.thunderbird titleLength=nil
  axRole=AXWindow axSubrole=AXStandardWindow
  hasCloseButton=true hasFullscreenButton=true fullscreenButtonEnabled=true
  hasZoomButton=true hasMinimizeButton=true
  wsLevel=0 wsTags=0x100000000 wsAttributes=0x1 wsParent=0
  wsFrame=(0.0,0.0,0.0,0.0)
```

This matters because it rules out the previous two hypotheses:

- the Gecko built-in is present and active (`source=builtInRule(geckoTransientDialog)`);
- the zero-frame case is no longer blocked (`wsFrame=(0,0,0,0)` still admits as
  `disposition=floating`).

---

## What still goes wrong

Immediately after the floating decision, Nehir admits the window as floating:

```text
track_prepared_create token=WindowToken(pid: 12744, windowId: 21921)
  admissionContext=focusedAdmission mode=floating
  bundle=org.mozilla.thunderbird role=AXWindow subrole=AXStandardWindow
  titleLength=nil title=nil frame=(0,0 0x0)
  transient=false degraded=false level=0

window_admitted token=WindowToken(pid: 12744, windowId: 21921)
  admissionContext=focusedAdmission mode=floating
```

Then the same WindowServer id appears again with the real dialog frame:

```text
prepare_create_rejected window=21921
  token=WindowToken(pid: 12744, windowId: 21921)
  context=create reason=existing_entry
  window_info_pid=12744 window_info_level=0 window_info_parent=0
  ws_float=false ws_doc=true ws_frame=(1342,631 389x131)
```

After that, layout snapshots show the same window inside the tiled column tree:

```text
layout=...
  c1[x=1017.0,cached=1011.0,...]{
    w21921:selected{
      cur=14,7,1011,1251
      target=14,7,1011,1251
      live=14,7,1011,1251
      replacement=14,71,1011,1251
      observed=1342,567,389,131
      hidden:nil
    }
  }
```

The small native dialog frame is `observed=1342,567,389,131`, but Nehir's tiled
layout writes `1011x1251` over it. The symptom is therefore no longer “failed to
float on admission”; it is “floated on admission, then treated as standard layout
content and resized like a tiled column”.

The floating-bar/projection trace confirms why Nehir later considers it layout
content:

```text
token=WindowToken(pid: 12744, windowId: 21921)
bundleId=org.mozilla.thunderbird accepted reason=userAddressable
frame={{1342.0, 567.0}, {389.0, 131.0}}
layoutReason=standard transientWindowServerEvidence=false
degradedWindowServerChildEvidence=false parentWindowId=nil
```

---

## Source root cause

The Gecko dialog built-in currently only returns a floating admission decision.
It lives in `Sources/Nehir/Core/Rules/WindowRuleEngine.swift:746-770` and matches
Thunderbird/Firefox standard top-level windows that have no WindowServer document
or floating tag:

```swift
guard let bundleId = facts.ax.bundleId?.lowercased(),
      Self.geckoBundleIds.contains(bundleId),
      facts.ax.attributeFetchSucceeded,
      facts.ax.role == kAXWindowRole as String,
      facts.ax.subrole == kAXStandardWindowSubrole as String,
      let windowServer = facts.windowServer,
      windowServer.parentId == 0,
      !windowServer.hasDocumentTag,
      !windowServer.hasFloatingTag
else { return nil }

return WindowDecision(disposition: .floating, source: .builtInRule(Self.geckoTransientDialogRuleName), ...)
```

But the metadata that survives admission is built generically in
`Sources/Nehir/Core/Controller/AXEventHandler.swift:5090-5102`:

```swift
ManagedReplacementMetadata(
    role: facts.ax.role,
    subrole: facts.ax.subrole,
    windowLevel: facts.windowServer?.level,
    parentWindowId: normalizedParentWindowId(facts.windowServer?.parentId),
    frame: facts.windowServer?.frame,
    transientWindowServerEvidence: facts.windowServer?.hasTransientSurfaceEvidence ?? false,
    degradedWindowServerChildEvidence: facts.degradedWindowServerChildEvidence,
    userAddressableTransientWindowServerSurface: facts.userAddressableTransientWindowServerSurface
)
```

For this Thunderbird dialog, those generic fields become:

- `role=AXWindow`, `subrole=AXStandardWindow`;
- `parentWindowId=nil` (`wsParent=0`);
- `transientWindowServerEvidence=false` because this level-0, standard-looking
  Gecko surface does not satisfy generic WindowServer transient evidence;
- `userAddressableTransientWindowServerSurface=false` because
  `WindowRuleFacts.userAddressableTransientWindowServerSurface` is gated by
  generic `windowServer?.hasTransientSurfaceEvidence == true`
  (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:137-149`).

That means `WorkspaceManager` later sees a normal standard AX window. Its
floating projection gate in
`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2756-2777` rejects only
non-standard, transient, or child surfaces:

```swift
if !isStandardAXWindowSurface(metadata) {
    return .rejected(reason: "nonStandardAXSurface")
}

if hasTransientEvidence {
    if frame == nil { return .rejected(reason: "transientWindowServerSurface(noFrame)") }
    if metadata?.userAddressableTransientWindowServerSurface != true {
        return .rejected(reason: "transientSurfaceNotUserAddressable")
    }
}

if hasChildEvidence {
    return .rejected(reason: "windowServerChildSurface")
}

return .accepted(reason: "userAddressable")
```

Because the Gecko-specific classification was not copied into metadata, none of
those rejection branches triggers. The dialog is accepted as
`reason=userAddressable`, appears in layout projection, and receives the tiled
column frame.

`WindowModel.upsert` also explains how an already tracked window can have its
mode/metadata refreshed when the same token is seen again:
`Sources/Nehir/Core/Workspace/WindowModel.swift:407-416` updates workspace, calls
`setMode(mode, for: token)`, and overwrites `managedReplacementMetadata` when an
entry for the same token already exists. This makes it especially important that
the Gecko transient classification survives every path that can prepare metadata
for the existing token.

---

## Fix direction

Do **not** revert the previous Gecko fixes. The latest evidence proves they are
partly correct: the target window now reaches `source=builtInRule(geckoTransientDialog)`
and `mode=floating` even with a zero WindowServer frame.

The fix should make the Gecko transient classification durable for downstream
projection/lifecycle metadata. A Gecko transient dialog must remain a
non-user-addressable transient surface after its real frame appears.

Implementation options, in preferred order:

1. Add a helper/fact for “Gecko transient dialog” and use it both in
   `WindowRuleEngine.geckoTransientDialogDecision` and when constructing
   `ManagedReplacementMetadata` in `AXEventHandler`.
2. Or expose enough `WindowDecision` source information to metadata creation so
   `source=builtInRule(geckoTransientDialog)` sets transient metadata.

The metadata outcome for these windows should be:

```text
transientWindowServerEvidence=true
userAddressableTransientWindowServerSurface=false
```

Then `WorkspaceManager.swift:2764-2769` will reject the dialog from projection as
`transientWindowServerSurface(noFrame)` while its frame is empty, or
`transientSurfaceNotUserAddressable` after the real `389x131` frame appears.

---

## Revert decision

No revert of the changes shipped for #146/#153 is recommended.

- The current target window proves the Gecko built-in now catches the previously
  missed zero-frame dialog.
- Reverting would restore the earlier behavior where the dialog tiled immediately
  by heuristic.
- The necessary change is a follow-up that carries the Gecko transient decision
  into metadata/projection, not a rollback of the classifier.
