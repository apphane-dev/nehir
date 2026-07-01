# Structural-replacement correlation merges distinct same-pid startup windows into one — Discovery

**Status:** completed — the fix this doc's findings pointed at shipped on
`main` as `0b0ec493` ("Prevent structural-replacement correlation from
merging same-pass sibling windows") via PR #126 on 2026-07-01, and was
further validated against a third, higher-multiplicity (10-window/11-window)
capture the same day. Implementation record:
[`20260701-confirm-pid-window-list-after-partial-ax-enumeration.md`](20260701-confirm-pid-window-list-after-partial-ax-enumeration.md).
Moved from `discovery/` to `completed/` on 2026-07-01.

Discovery (2026-07-01), captured using the Phase 1 instrumentation added by
[`20260701-confirm-pid-window-list-after-partial-ax-enumeration.md`](20260701-confirm-pid-window-list-after-partial-ax-enumeration.md).
Two runtime trace captures of a real cold start (taken seconds apart, the
second picking up where the first left off) show the same root cause this
plan is investigating, but it is **not** the plan's central hypothesis
(`AppAXContext.getWindowsAsync()` returning a partial `kAXWindowsAttribute`
list). In both captures, the very first AX windows query for the affected
pids already returned every window id the app actually had. What collapses
several of those real windows down to one managed entry is the
**structural-replacement correlation** (`rekeyStructuralManagedReplacementIfNeeded`,
`Sources/Nehir/Core/Controller/AXEventHandler.swift:837`) firing against a
*different, still-live* window from the same rescan pass — not against a
genuinely removed one.

All source references verified against the main Nehir source tree at
`472f7185` on 2026-07-01 (`git log -1 --format='%h %s' main`), the same
revision the originating plan and both prior discoveries cite. The functions
discussed here are unmodified by that plan's Phase 1 instrumentation patch.

---

## TL;DR

- **Symptom.** At cold start, VS Code Insiders (`com.microsoft.VSCodeInsiders`,
  pid `54505`) opened 5 real windows. The startup full rescan's very first AX
  query for that pid returned all 5 ids in one call. Only **1** of the 5 ended
  up managed; the other 4 are listed under "Visible Unmanaged WindowServer
  Windows" with `axWindowsCount=5 axContainsWindow=true`, and **stay there
  for the rest of both captures** (no recovery within the observed window).
  Helium (`net.imput.helium`, pid `22641`) shows the same shape: AX reported
  8 window ids on the first query; the rescan admitted 4 directly and merged
  the other 4 into those 4 via the same mechanism, before a later
  `pid_reevaluation` burst re-confirms the same set.
- **The AX query was not the gap.** The new `ax_windows_query` trace (added by
  Phase 1 of the referenced plan) shows, at the very first call for each pid:
  `ax_windows_query pid=54505 newContext=true count=5
  windowIds=[7528, 7526, 5960, 7527, 2194]` and `ax_windows_query pid=22641
  newContext=true count=8 windowIds=[6537, 7539, 7535, 7533, 7531, 7529, 6892,
  3416]`. Both already list every id that ever appears anywhere later in
  either capture. No `ax_window_count_mismatch` fired in either capture (the
  new AX-vs-WindowServer cross-check from the same Phase 1 work never
  triggered), consistent with the AX query being complete from the start.
- **What actually happens: a same-pass rekey chain.** The new `context=` tag
  on `window_admitted` (also Phase 1) shows the startup full rescan admitting
  one VS Code window (`windowId: 7528`, `context=startup_full_rescan`),
  immediately followed by four consecutive `window_rekeyed
  reason=managedReplacement` events in the same pass, each absorbing the next
  candidate into the previous one's token: `7528 → 7526 → 5960 → 7527 →
  2194`. The same shape happens for Helium: `windowId: 7535` is admitted, then
  rekeyed `7535 → 7533 → 7531 → 6892`, while a second Helium chain admits
  `7529` then rekeys it `7529 → 3416`. By the end of the rescan pass, 5
  VS Code candidates have collapsed to 1 managed token and 8 Helium candidates
  have collapsed to 4.
- **Why they match.** `rekeyStructuralManagedReplacementIfNeeded`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:837`, called from the
  full-rescan per-window loop at
  `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1346-1360`)
  looks for a *currently live* same-pid managed entry whose
  `ManagedReplacementMetadata` (bundleId, role, subrole, window level, and a
  frame-closeness check) matches the new candidate
  (`structuralReplacementMatch`, `AXEventHandler.swift:3783`;
  `managedReplacementStructuralAnchorsMatch`, `AXEventHandler.swift:4014`).
  At the moment the full rescan runs, every one of an app's brand-new windows
  shares the same default/restore frame — confirmed in this capture's
  pre-rescan WindowServer dump, where all 5 VS Code entries report the
  identical frame `{{-971.0, 71.0}, {972.0, 1226.0}}` despite three different
  titles (`Welcome`, `Welcome`, `LayoutProcess.swift — swift-client`,
  `Welcome`, `Untitled-4 — modern-stack`) — so the frame-closeness check
  cannot tell "the same window, recreated with a new id" apart from "a
  different window of the same app that just hasn't been laid out yet."
  Nothing in the matcher excludes a candidate from the *same rescan pass* as
  a match target; it only checks "is there a live same-pid entry with similar
  structural metadata," and there always is one once the first candidate in
  the pass has been admitted.
- **Not transient.** Re-running the same scenario ~20 seconds later (the
  second capture) shows pid `54505` in exactly the same state — the same 4
  window ids still listed as unmanaged with `axWindowsCount=5`, no new
  `window_admitted` or `window_rekeyed` event for that pid anywhere in the
  second capture. Unlike the original VS Code discovery (which recovered the
  missing windows in ~7s via individual focus events), this capture shows no
  recovery at all within either capture's window — the merge is a one-way,
  silent loss of 4 real windows, not a delayed admission.

---

## Topology / initial state

Single display, `ID(displayId: 1)`, notch, frame `(0.0, 0.0, 2056.0, 1329.0)`.
Both captures share the same workspace (`4C9E2802-7352-49DE-B4B3-05B55E851526`,
workspace 1). The first capture spans the literal startup full rescan
(`windows total=0`, `no-managed-windows` at capture start); the second capture
starts ~20 seconds later, after the first capture's churn had already
settled, and shows no further change to the affected pid.

At the very start of the first capture, before any rescan has run, the
"Visible Unmanaged WindowServer Windows" dump already lists all 5 VS Code
window ids and all 8 Helium window ids, each with a fresh,
just-queried `axWindowsCount`/`axContainsWindow` pair:

```text
windowId=7527 pid=54505 owner=Code - Insiders title=Welcome
  frame={{-971.0, 71.0}, {972.0, 1226.0}} axWindowsCount=5 axContainsWindow=true
windowId=7526 pid=54505 owner=Code - Insiders title=Welcome
  frame={{-971.0, 71.0}, {972.0, 1226.0}} axWindowsCount=5 axContainsWindow=true
windowId=5960 pid=54505 owner=Code - Insiders title="LayoutProcess.swift — swift-client"
  frame={{-971.0, 71.0}, {972.0, 1226.0}} axWindowsCount=5 axContainsWindow=true
windowId=7528 pid=54505 owner=Code - Insiders title=Welcome
  frame={{-971.0, 71.0}, {972.0, 1226.0}} axWindowsCount=5 axContainsWindow=true
windowId=2194 pid=54505 owner=Code - Insiders title="Untitled-4 — modern-stack"
  frame={{-971.0, 71.0}, {972.0, 1226.0}} axWindowsCount=5 axContainsWindow=true
```

Three of the five are still on VS Code's "Welcome" placeholder (the screen
shown before a restored workspace folder finishes loading); the other two
already show real, distinct file/workspace titles. All five share the
identical pre-layout frame. The Helium entries at the same moment show more
varied frames and titles (`New Incognito tab`, `AI & Trends` ×3, an article
title, a video title), several of them also sharing frames pairwise — the
same precondition that produces the chain seen for Helium below.

---

## What the evidence proves

### 1. The first AX query for each pid already returned every id seen later

```text
ax_windows_query pid=54505 newContext=true count=5 windowIds=[7528, 7526, 5960, 7527, 2194]
ax_windows_query pid=22641 newContext=true count=8 windowIds=[6537, 7539, 7535, 7533, 7531, 7529, 6892, 3416]
```

No subsequent `ax_windows_query` for either pid — including the second
capture's queries, ~20 seconds later — ever reports a window id not already
present in these two lines. There is no partial-result, "AX hadn't settled
yet" signature here: the very first call already had the complete list. The
plan's central hypothesis (`AppAXContext.getWindowsAsync()` returning fewer
windows than the app actually has on the first query) is **not** what is
happening in either of these two captures.

### 2. `ax_window_count_mismatch` never fired

The Phase 1 cross-check in `AXManager.fullRescanEnumerationSnapshot()`
(`Sources/Nehir/Core/Ax/AXManager.swift:451`) compares each pid's AX-reported
window count against the WindowServer/CGWindowList on-screen count for that
pid and traces a mismatch. Neither capture contains a single
`ax_window_count_mismatch` line. This is consistent with finding 1: AX and
WindowServer agree on the window count at rescan time: nothing is being
under-counted at the AX-query layer.

### 3. The startup rescan admits one window per pid, then rekeys the rest into it

The reconcile trace for the first capture, restricted to pid `54505`:

```text
event=window_admitted token=WindowToken(pid: 54505, windowId: 7528) ... context=startup_full_rescan
event=window_rekeyed from=WindowToken(pid: 54505, windowId: 7528) to=WindowToken(pid: 54505, windowId: 7526) reason=managedReplacement
event=window_rekeyed from=WindowToken(pid: 54505, windowId: 7526) to=WindowToken(pid: 54505, windowId: 5960) reason=managedReplacement
event=window_rekeyed from=WindowToken(pid: 54505, windowId: 5960) to=WindowToken(pid: 54505, windowId: 7527) reason=managedReplacement
event=window_rekeyed from=WindowToken(pid: 54505, windowId: 7527) to=WindowToken(pid: 54505, windowId: 2194) reason=managedReplacement
```

All four `window_rekeyed` events carry the same timestamp as the admission
(sub-second; well inside the 150ms managed-replacement grace window,
`Sources/Nehir/Core/Controller/AXEventHandler.swift:432`). The net effect:
5 real, AX-confirmed, distinctly-titled windows produce exactly 1 managed
entry (`2194`). The same shape happens for Helium in the same pass:

```text
event=window_admitted token=WindowToken(pid: 22641, windowId: 6537) ... context=startup_full_rescan
event=window_admitted token=WindowToken(pid: 22641, windowId: 7539) ... context=startup_full_rescan
event=window_admitted token=WindowToken(pid: 22641, windowId: 7535) ... context=startup_full_rescan
event=window_rekeyed from=WindowToken(pid: 22641, windowId: 7535) to=WindowToken(pid: 22641, windowId: 7533) reason=managedReplacement
event=window_rekeyed from=WindowToken(pid: 22641, windowId: 7533) to=WindowToken(pid: 22641, windowId: 7531) reason=managedReplacement
event=window_admitted token=WindowToken(pid: 22641, windowId: 7529) ... context=startup_full_rescan
event=window_rekeyed from=WindowToken(pid: 22641, windowId: 7531) to=WindowToken(pid: 22641, windowId: 6892) reason=managedReplacement
event=window_rekeyed from=WindowToken(pid: 22641, windowId: 7529) to=WindowToken(pid: 22641, windowId: 3416) reason=managedReplacement
```

8 Helium candidates collapse to 4 managed tokens (`6537`, `7539`, `6892`,
`3416`) within the same rescan pass. (Helium's count later appears to recover
to 8 distinct managed windows via a `pid_reevaluation` burst ~5 seconds later
— see "Relationship to the Helium discovery" below — but VS Code's 4 lost
windows never recover in either capture.)

### 4. The merge is source-explainable: same-pid, same-pass, frame-indistinguishable candidates

The full-rescan per-window loop
(`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1346-1360`)
calls `rekeyStructuralManagedReplacementIfNeeded` for every window whose
`existingEntry == nil` — which, on a cold-start rescan, is every window in the
pass, processed one at a time. That function
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:837`) looks for a
structural match via `structuralReplacementMatch`
(`AXEventHandler.swift:3783`), which searches the *currently managed* entries
for the same pid (not specifically removed/destroyed ones) for one whose
`ManagedReplacementMetadata` is close enough:
`managedReplacementMetadataMatches`/`managedReplacementStructuralAnchorsMatch`
(`AXEventHandler.swift:3933`, `:4014`) compare bundleId, role, subrole, window
level, and a frame-closeness check
(`framesAreCloseForManagedReplacement`, `AXEventHandler.swift:4034`) — title
is not part of the comparison at all.

Because every one of an app's brand-new windows shares the same
not-yet-laid-out default frame (confirmed above: all 5 VS Code entries report
the identical frame before the rescan ran), the second, third, fourth, and
fifth candidates each find the *previous candidate from the same pass* as a
"structural match" and get rekeyed into it instead of being admitted as
separate windows. The matcher has no way to distinguish "this is the same
window, recreated under a new AX id after being destroyed" (the case this
mechanism exists for) from "this is a different, still-live window of the
same app that happens to share a startup placeholder frame" (what is
happening here).

### 5. The loss is not transient

The second capture, taken ~20 seconds after the first ended, shows pid
`54505` in an identical state: the same 4 ids (`7527`, `7526`, `5960`,
`7528`) still listed under "Visible Unmanaged WindowServer Windows" with
`axWindowsCount=5 axContainsWindow=true`, and **no** `window_admitted`,
`window_rekeyed`, or any other reconcile event for pid `54505` anywhere in
the second capture. Unlike the original VS Code discovery (recovered via
individual focus events within ~7 seconds), nothing in either of these two
captures ever touches pid `54505` again — the 4 windows stay unmanaged for
the rest of both observation windows.

---

## Relationship to the plan and the two prior discoveries

This capture was taken specifically to validate or refute
[`20260701-confirm-pid-window-list-after-partial-ax-enumeration.md`](20260701-confirm-pid-window-list-after-partial-ax-enumeration.md)'s
central hypothesis ("a single per-app `kAXWindowsAttribute` query can return
fewer windows than the app actually has, and Nehir trusts that first answer
as final"). **The hypothesis is not supported by this capture.** Both
affected pids' first AX query already returned every window id that exists
anywhere in either trace. The real mechanism is downstream of the AX query,
in the structural-replacement correlation that runs during admission itself.

This means the fix direction in that plan's "Design" section — schedule a
delayed re-query of `kAXWindowsAttribute` after a newly-created AX context
admits windows, and route any new ids through the existing reevaluation path
— **would not fix what this capture shows**. Re-querying
`kAXWindowsAttribute` for pid `54505` again would return the same 5 ids
(confirmed: it already did, identically, in the second capture, 20 seconds
later); the structural-replacement correlation would immediately re-collapse
them the same way, because nothing about a second query changes the frames
the 5 candidates share.

This does **not** mean
[`20260701-startup-full-rescan-under-enumerates-multi-window-app.md`](20260701-startup-full-rescan-under-enumerates-multi-window-app.md)
and
[`20260630-visible-unmanaged-windows-admitted-late-as-columns.md`](20260630-visible-unmanaged-windows-admitted-late-as-columns.md)
were wrong about the *symptom* — both correctly describe real, AX-owned,
multi-window apps ending up under-managed at startup, and the Helium
discovery's batched-recovery shape (a `pid_reevaluation` burst sweeping
several windows in at once) reproduces almost exactly in this capture's
Helium half, down to the same `reason=managedReplacement` churn it already
flagged ("Nehir's managed-replacement correlation rekeys ... and re-admits
the same ids several times during the burst"). What this capture adds is the
piece neither prior discovery could prove without the Phase 1 instrumentation
("the question is what the *startup rescan's own* query saw a moment
earlier," in the first discovery's words): the rescan's own query was already
complete. The defect is in how the rescan's per-window admission loop
correlates candidates against each other within the same pass, not in what
AX reported.

### Why VS Code did not recover here but did in the original discovery

The original VS Code discovery's missing windows were recovered via
individual `AXFocusedWindowChanged` events reaching
`admitFocusedWindowBeforeNonManagedFallback`. In this capture, pid `54505`
never received any further AX or focus event in either observation window —
the user's attention stayed on Helium and Slack. This is consistent with
"recovery only happens if something incidentally touches the missing
windows," which both prior discoveries already named as the core gap; this
capture simply did not get that incidental touch for VS Code within its
observation window. It is also possible the merge itself prevents recovery
even when a missing window *is* later focused (since the AX windows query
already iterated and merged the placeholder-frame siblings — a subsequent
focus would need to reconstruct an `AXWindowRef` for one of the now-orphaned
ids, which depends on `resolveAXWindowRef` / `AppAXContext.windows` still
holding a live element reference for it). Neither capture exercises this
path, so it remains untested.

---

## What would make this more conclusive

- **Whether the structural-replacement matcher should exclude same-pass
  candidates.** This capture strongly suggests `structuralReplacementMatch`
  needs some signal that distinguishes "a live entry admitted earlier in this
  very rescan pass" from "a live entry from a prior pass / a genuinely
  destroyed-and-recreated window," but does not itself prove what that signal
  should be (e.g., excluding matches against entries admitted in the same
  pass entirely, vs. requiring a destroy event to have actually been observed
  for the old token before allowing a structural match).
- **Whether title is a safe additional discriminator.** The three "Welcome"
  VS Code windows in this capture *do* share a title, but the two with real
  content do not — adding title to the match criteria would not by itself
  separate the three identical "Welcome" placeholders from each other, only
  from the two real-content windows. Not exercised here.
- **Whether a later focus event would actually recover an orphaned id**, or
  whether the merge leaves the orphaned `AXWindowRef`s unreachable. Neither
  capture exercises a focus or create event for pid `54505` after the merge.
- **Hit rate across more cold starts.** Two captures (one continuing into the
  other) from the same session is not enough to know how often multi-window
  apps share an indistinguishable startup frame versus genuinely staggering
  their window creation enough to avoid the same-pass collision.

---

## Relationship to other discoveries

- **Refines the central hypothesis of:**
  [`20260701-confirm-pid-window-list-after-partial-ax-enumeration.md`](20260701-confirm-pid-window-list-after-partial-ax-enumeration.md) —
  this capture was taken using that plan's Phase 1 instrumentation
  specifically to confirm or refute its hypothesis; see "Relationship to the
  plan" above.
- **Same symptom class, same app, different mechanism shown:**
  [`20260701-startup-full-rescan-under-enumerates-multi-window-app.md`](20260701-startup-full-rescan-under-enumerates-multi-window-app.md) —
  that discovery could not distinguish "AX query missed it" from other
  explanations because it lacked the raw query log; this capture supplies
  that log and shows the query was complete.
- **Same recovery shape (partially) reproduced:**
  [`20260630-visible-unmanaged-windows-admitted-late-as-columns.md`](20260630-visible-unmanaged-windows-admitted-late-as-columns.md) —
  the Helium half of this capture reproduces that discovery's batched
  `pid_reevaluation` recovery and its `reason=managedReplacement` churn
  almost exactly, now with the admission-context tagging that discovery's own
  "Tracing improvements" section asked for.
