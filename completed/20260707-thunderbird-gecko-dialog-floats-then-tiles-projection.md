# Thunderbird Gecko dialog needs durable transient metadata and compact-dialog classification

Status: **completed** — fixed on `main` in `579f124d` ("Keep Gecko transient
dialogs floating #142"). The final fix kept the earlier tagless/zero-frame
Gecko built-in, made Gecko transient classification durable in managed
replacement metadata, and added a second compact-dialog built-in for the final
Thunderbird path where Gecko creates the send-confirmation dialog as a normal
small document-tagged window. User validation confirmed the real Thunderbird
reproduction was fixed before regression tests were added.

Follow-up to the completed Thunderbird/Gecko dialog fixes:

- `completed/20260706-thunderbird-gecko-dialog-float-builtin.md`
- `completed/20260706-thunderbird-gecko-dialog-tiled-untagged-unparented-standard-window.md`
- `completed/20260707-thunderbird-gecko-dialog-still-tiles-frame-isempty-guard-defeats-fix.md`

---

## Target window found before planning

The first local Thunderbird reproduction after the zero-frame fix targeted the
send-confirmation dialog:

```text
WindowToken(pid: 12744, windowId: 21921)
bundleId=org.mozilla.thunderbird
```

The admission record proved the earlier zero-frame correction was active:

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

This ruled out two stale hypotheses:

- the Gecko built-in was present and active (`source=builtInRule(geckoTransientDialog)`);
- the zero-frame case was no longer blocked (`wsFrame=(0,0,0,0)` still admitted
  as `disposition=floating`).

---

## First remaining failure: floated at admission, then projected as tiled content

Immediately after the floating decision, Nehir admitted the window as floating:

```text
track_prepared_create token=WindowToken(pid: 12744, windowId: 21921)
  admissionContext=focusedAdmission mode=floating
  bundle=org.mozilla.thunderbird role=AXWindow subrole=AXStandardWindow
  titleLength=nil title=nil frame=(0,0 0x0)
  transient=false degraded=false level=0

window_admitted token=WindowToken(pid: 12744, windowId: 21921)
  admissionContext=focusedAdmission mode=floating
```

Then the same WindowServer id appeared with the real dialog frame:

```text
prepare_create_rejected window=21921
  token=WindowToken(pid: 12744, windowId: 21921)
  context=create reason=existing_entry
  window_info_pid=12744 window_info_level=0 window_info_parent=0
  ws_float=false ws_doc=true ws_frame=(1342,631 389x131)
```

After that, layout snapshots showed the same window inside the tiled column tree:

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

The small native dialog frame was `observed=1342,567,389,131`, but Nehir's tiled
layout wrote `1011x1251` over it. The symptom was no longer “failed to float on
admission”; it was “floated on admission, then treated as standard layout content
and resized like a tiled column”.

The floating-bar/projection trace showed why Nehir later considered it layout
content:

```text
token=WindowToken(pid: 12744, windowId: 21921)
bundleId=org.mozilla.thunderbird accepted reason=userAddressable
frame={{1342.0, 567.0}, {389.0, 131.0}}
layoutReason=standard transientWindowServerEvidence=false
degradedWindowServerChildEvidence=false parentWindowId=nil
```

### Source root cause for the first remaining failure

The tagless Gecko built-in returned a floating admission decision in
`Sources/Nehir/Core/Rules/WindowRuleEngine.swift`, but the metadata that survived
admission was built generically in `Sources/Nehir/Core/Controller/AXEventHandler.swift`.
For the dialog, those generic fields became:

- `role=AXWindow`, `subrole=AXStandardWindow`;
- `parentWindowId=nil` (`wsParent=0`);
- `transientWindowServerEvidence=false` because this level-0, standard-looking
  Gecko surface did not satisfy generic WindowServer transient evidence;
- `userAddressableTransientWindowServerSurface=false` because
  `WindowRuleFacts.userAddressableTransientWindowServerSurface` is gated by
  generic `windowServer?.hasTransientSurfaceEvidence == true`.

`WorkspaceManager` rejects floating projection only for non-standard, transient,
or child surfaces. Because the Gecko-specific classification was not copied into
metadata, none of those rejection branches triggered. The dialog was accepted as
`reason=userAddressable`, appeared in layout projection, and received the tiled
column frame.

### Fix for the first remaining failure

`579f124d` added reusable Gecko predicates and made the metadata durable:

```swift
let hasGeckoTransientDialogEvidence = WindowRuleEngine.isGeckoTransientDialog(facts: facts)
    || WindowRuleEngine.isGeckoCompactTransientDialog(facts: facts)

transientWindowServerEvidence: hasGeckoTransientDialogEvidence
    || (facts.windowServer?.hasTransientSurfaceEvidence ?? false),
userAddressableTransientWindowServerSurface: hasGeckoTransientDialogEvidence
    ? false
    : facts.userAddressableTransientWindowServerSurface
```

That makes both Gecko transient shapes non-user-addressable transient surfaces
for downstream projection and close/recovery logic.

---

## Second remaining failure: Gecko can create the dialog as a compact document-tagged window

A later rebuilt trace proved the metadata-only fix and the recreation-matching
experiment were insufficient for a third Thunderbird creation path. The trace was
truthful because it contained a newly added diagnostic field (`matchKind=none`),
which proved the rebuilt binary was running. But there was no replacement pair to
match.

In that final failing path, the send-confirmation dialog was born with normal
WindowServer credentials:

```text
window_decision token=WindowToken(pid: 12744, windowId: 22560)
  context=focused_admission existingMode=nil
  disposition=managed source=heuristic outcome=trackedTiling
  bundleId=org.mozilla.thunderbird titleLength=nil
  axRole=AXWindow axSubrole=AXStandardWindow
  hasCloseButton=true hasFullscreenButton=true fullscreenButtonEnabled=true
  hasZoomButton=true hasMinimizeButton=true
  wsLevel=0 wsTags=<document tag set> wsParent=0
  wsFrame=(small dialog frame, approximately 389x131)
```

There was no earlier transient precursor in the same managed-replacement burst.
The only later burst was a lone destroy of the compose window (`creates=0,
destroys=1`). Therefore a replacement matcher could not help: admission had to
classify this window directly.

The discriminator that survived all reproductions was compact size. Observed
send-confirmation dialogs were about `389x131` and `402x176`; real Gecko
Thunderbird toplevels in the same captures were about `1011x1251`. The final
rule intentionally uses a narrow compact threshold, not title text, because the
AX title can be missing at admission and can arrive later (`"Sending Message"`),
so title would make reevaluation unstable.

### Final compact-dialog fix

`579f124d` added `geckoCompactTransientDialog` in
`Sources/Nehir/Core/Rules/WindowRuleEngine.swift`:

- Gecko/Mozilla bundle id;
- `AXWindow` + `AXStandardWindow` with successful AX facts;
- non-empty WindowServer frame;
- width `<= 480` and height `<= 240`.

The rule runs after the tagless Gecko rule and before the heuristic. It floats
small document-tagged Thunderbird send dialogs while leaving normal Gecko
windows tiled. The thresholds were tightened from the initial 640×320 idea to
480×240 after review, because stacked tiled windows can become smaller than a
full toplevel; the tighter gate still covers observed dialogs while avoiding a
known stacked-tile demotion risk.

Regression tests in `Tests/NehirTests/WindowRuleEngineTests.swift` cover:

- tagless Gecko dialogs still float via `geckoTransientDialog`;
- compact document-tagged Gecko dialogs float via `geckoCompactTransientDialog`;
- compact Gecko dialogs still float after title arrival;
- a 510×308 stacked-tile-sized Gecko window remains heuristic/managed;
- non-Gecko compact standard windows remain heuristic/managed.

---

## Revert decision after final validation

No revert of the earlier shipped changes is recommended.

- The tagless Gecko built-in is still required for zero-frame or tagless dialogs,
  which the compact rule deliberately does not claim when the frame is empty.
- The zero-frame guard removal is still required for those same windows.
- Durable metadata is still required so windows admitted by either Gecko
  transient path remain non-user-addressable transient surfaces after admission
  and through close/recovery logic.
- The temporary managed-replacement relaxation experiment was not kept. It was
  subsumed by direct compact-dialog classification for the observed recreations
  and carried unnecessary mis-pairing risk.

Final shipped fix: keep tagless/zero-frame Gecko classification, add compact
Gecko classification, and carry both classifications into metadata.
