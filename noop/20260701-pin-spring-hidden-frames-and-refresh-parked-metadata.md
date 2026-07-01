# Pin spring hidden/reveal frames and refresh parked replacement metadata — Deferred / no-op for now

Verified against `main` plus the diagnostics branch `gesture-traces` on 2026-07-01
(`a67afc14 Add runtime diagnostics for gesture, navigation, and frame issues`, based on
`07ce4168 Reconcile stale hidden-window live frames`). This plan covers the hidden-window
rendering/metadata cluster exposed by the improved frame diagnostics.


---

## Decision update — pushed back 2026-07-01

Do **not** implement this plan yet. The diagnostics prove suspicious internal states, but the
need for a behavior change is not sufficiently established. This plan is moved out of
`planned/` as a no-op-for-now / deferred investigation.

Current assessment:

- `hidden_replacement_frame_mismatch` is the strongest signal because parked offscreen
  frames can diverge from managed-replacement metadata. This may deserve a small future
  metadata-only fix, but it should be tied to a concrete bad reveal/restore observation.
- `spring_frame_classification ... frameSource=currentSpring targetPinned=false` proves the
  render path samples current spring frames for hidden/edge-transition windows. It does
  **not** by itself prove a user-visible slide-through bug. Target pinning could also
  introduce popping or break reveal continuity.
- AX-first parking remains explicitly deferred. Existing verify mismatches with `dx=0.0`
  and `dy≈windowHeight` still look like coordinate-space readback artifacts, not visible
  placement failures.

Before reviving this plan, capture a baseline from current source and record the evidence
inline in the new/updated plan:

1. Fast trackpad edge swipes across a large workspace.
2. Workspace-bar far direct window clicks.
3. Repeated hide/reveal parking cycles to both left and right.

Baseline metrics to collect:

```text
spring_frame_classification total=N
hiddenToVisible currentSpring targetPinned=false=N
visibleToHidden currentSpring targetPinned=false=N
edgeReveal currentSpring targetPinned=false=N
hidden_replacement_frame_mismatch count=N
updatedReplacementMetadata=false count=N
max abs(replacementDx), max abs(replacementDy)
hidePlan.verify dx=0 dy≈height count=N
hidePlan.verify dx!=0 or visibleRisk=true count=N
```

Also record the human-visible result for each scenario:

```text
Observed visible slide-through: yes/no
Observed window flying/popping: yes/no
Action that caused it: swipe / bar click / reveal
```

Decision gate for future work:

- If only replacement metadata is tied to bad behavior, split out and implement a
  metadata-refresh-only fix first.
- If hidden/edge current-spring samples correlate with visible artifacts, design a separate
  spring-pinning or transition-policy fix and validate it independently.
- Do not use parking verify `dx=0 dy≈height` as acceptance evidence for AX-first parking.

---

## Problems

Improved traces now prove two related hidden-window issues:

1. During active scroll springs, hidden-state windows and hidden/visible transitions are
   still classified from `currentSpring` frames with `targetPinned=false`. That means
   hidden-to-visible and visible-to-hidden windows can receive intermediate spring-sampled
   frames instead of being pinned to their final target classification/frame.
2. When windows are parked offscreen, managed-replacement metadata can still point at old
   in-strip frames. Later reconcile/restore paths can use that stale replacement geometry.

A third observation appears alongside these records: SkyLight parking verification often
reports `dy=1226.0` with the x coordinate already correctly offscreen. That looks like a
coordinate-space readback artifact, not a visible slide-through, and should not be fixed
by AX-first parking unless a separate capture proves visible risk.

---

## Runtime evidence — spring classification

Across improved swipe and workspace-bar captures, `spring_frame_classification` emitted
many records with `frameSource=currentSpring` and `targetPinned=false`.

Counts across the improved captures:

- one swipe capture: `hiddenToVisible=7`, `visibleToHidden=9`, `hidden=46`, `visible=15`;
- another swipe capture: `hiddenToVisible=13`, `visibleToHidden=15`, `hidden=36`,
  `visible=9`;
- a faster edge swipe: `hiddenToVisible=10`, `visibleToHidden=15`, `hidden=8`,
  `visible=2`;
- workspace-bar clicks: `hiddenToVisible=7`, `visibleToHidden=9`, `hidden=50`,
  `visible=10`.

Examples include hidden windows becoming visible at intermediate current-spring frames:

```text
reason=spring_frame_classification token=WindowToken(pid: 454, windowId: 10823) windowId=10823 frameSource=currentSpring visibilityClass=hiddenToVisible bucket=inside hiddenSide=right wasHiddenState=transient(Optional(Nehir.HideSide.right)) currentFrame={{784.0,32.0},{951.0,1226.0}} viewport={{32.0,32.0},{1992.0,1226.0}} targetPinned=false
reason=spring_frame_classification token=WindowToken(pid: 48389, windowId: 11487) windowId=11487 frameSource=currentSpring visibilityClass=hiddenToVisible bucket=crossing hiddenSide=right wasHiddenState=transient(Optional(Nehir.HideSide.right)) currentFrame={{-197.0,32.0},{951.0,1226.0}} viewport={{32.0,32.0},{1992.0,1226.0}} targetPinned=false
reason=spring_frame_classification token=WindowToken(pid: 454, windowId: 12446) windowId=12446 frameSource=currentSpring visibilityClass=hiddenToVisible bucket=crossing hiddenSide=right wasHiddenState=transient(Optional(Nehir.HideSide.right)) currentFrame={{1765.0,32.0},{951.0,1226.0}} viewport={{32.0,32.0},{1992.0,1226.0}} targetPinned=false
```

Workspace-bar direct clicks show the same class of records during animated jumps:

```text
reason=spring_frame_classification token=WindowToken(pid: 8662, windowId: 8983) windowId=8983 frameSource=currentSpring visibilityClass=hiddenToVisible bucket=crossing hiddenSide=left wasHiddenState=transient(Optional(Nehir.HideSide.left)) currentFrame={{-720.5,32.0},{1834.0,1226.0}} viewport={{32.0,32.0},{1992.0,1226.0}} targetPinned=false
reason=spring_frame_classification token=WindowToken(pid: 48720, windowId: 12440) windowId=12440 frameSource=currentSpring visibilityClass=visibleToHidden bucket=offscreen hiddenSide=right wasHiddenState=none currentFrame={{2055.5,32.0},{951.0,1226.0}} viewport={{32.0,32.0},{1992.0,1226.0}} targetPinned=false
```

These records do not prove the user saw an artifact in every case, but they prove the
render path is still using current spring samples for hidden-state transitions rather than
pinning them to the target frame/classification.

---

## Runtime evidence — stale replacement metadata

The improved parking diagnostics also emitted replacement mismatches when hiding windows:

```text
hidden_replacement_frame_mismatch token=WindowToken(pid: 48720, windowId: 12440) windowId=12440 hiddenReason=layoutTransient(Nehir.HideSide.right) hiddenSide=right parked=(2055,32 951x1226) replacement=(1044,32 951x1226) replacementDx=-1011.0 replacementDy=0.0 updatedReplacementMetadata=false
hidden_replacement_frame_mismatch token=WindowToken(pid: 48720, windowId: 12442) windowId=12442 hiddenReason=layoutTransient(Nehir.HideSide.right) hiddenSide=right parked=(2055,32 951x1226) replacement=(1533,71 951x1226) replacementDx=-522.0 replacementDy=39.0 updatedReplacementMetadata=false
hidden_replacement_frame_mismatch token=WindowToken(pid: 48720, windowId: 10784) windowId=10784 hiddenReason=layoutTransient(Nehir.HideSide.right) hiddenSide=right parked=(2055,32 951x1226) replacement=(1533,32 951x1226) replacementDx=-522.0 replacementDy=0.0 updatedReplacementMetadata=false
```

Workspace-bar clicks showed left-side parked mismatches of almost a full viewport/column:

```text
hidden_replacement_frame_mismatch token=WindowToken(pid: 8662, windowId: 8983) windowId=8983 hiddenReason=layoutTransient(Nehir.HideSide.left) hiddenSide=left parked=(-1833,32 1834x1226) replacement=(111,32 1834x1226) replacementDx=1944.0 replacementDy=0.0 updatedReplacementMetadata=false
hidden_replacement_frame_mismatch token=WindowToken(pid: 48720, windowId: 12440) windowId=12440 hiddenReason=layoutTransient(Nehir.HideSide.left) hiddenSide=left parked=(-950,32 951x1226) replacement=(1044,32 951x1226) replacementDx=1994.0 replacementDy=0.0 updatedReplacementMetadata=false
hidden_replacement_frame_mismatch token=WindowToken(pid: 48389, windowId: 11487) windowId=11487 hiddenReason=layoutTransient(Nehir.HideSide.left) hiddenSide=left parked=(-950,32 951x1226) replacement=(1043,32 951x1226) replacementDx=1993.0 replacementDy=0.0 updatedReplacementMetadata=false
```

The diagnostic explicitly reports `updatedReplacementMetadata=false`, confirming that the
current hide path observes the mismatch but does not fix metadata.

---

## Runtime evidence — parking verify mismatch is likely not the primary issue

The same captures showed SkyLight verification mismatches like:

```text
hidePlan.verify id=12440 requested=(2055,32) observed=(2055,-1194) dx=0.0 dy=1226.0 fallback=YES
hidePlan.verify id=8983 requested=(-1833,32) observed=(-1833,-1194) dx=0.0 dy=1226.0 fallback=YES
```

Here `dx=0.0`: the x coordinate is already correctly offscreen. The `dy` equals the window
height (`1226.0`), so this looks like a coordinate-space readback artifact. Do not port an
AX-first parking behavior change from the broken attempt branch unless a separate capture
shows `visibleRisk=true` or an observed frame overlapping the active viewport.

---

## Source comparison

Diagnostics branch source confirms this is still main behavior with observation added:

- `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` classifies spring frames and
  records `targetPinned=false`; no target-pinning behavior exists in this branch.
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift` records
  `hidden_replacement_frame_mismatch` and explicitly appends
  `updatedReplacementMetadata=false`.
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift` still applies hide/parking
  plans through the existing SkyLight-first verify/fallback path; the improved diagnostics
  classify the mismatch but do not change backend order.

---

## Fix strategy

### Phase 1 — pin hidden/edge transition frames to spring target

When a scroll animation is active, compute the layout at the spring target as well as at
the current spring sample. For tokens whose visibility class changes or whose hidden state
would place them at/near an offscreen edge, use the target classification/frame for the
actual frame application.

Implementation shape:

- add a helper near layout planning that computes target frames when
  `state.viewOffsetPixels.isAnimating && !state.viewOffsetPixels.isGesture`;
- for `hiddenToVisible`, `visibleToHidden`, and `edgeReveal` classes, use target frames for
  the duration of the spring;
- keep normal visible-window motion on current spring samples so the main strip still
  animates smoothly;
- record `targetPinned=true` for pinned tokens during validation.

### Phase 2 — keep target pinning stable for the whole spring

Maintain a per-workspace set/map of tokens pinned to their final spring target. Without
this, a token can flip between current-spring and target-spring classification as it crosses
the viewport edge.

Validation expectation:

- improved diagnostics should still emit classification records, but transition records
  should say `targetPinned=true`;
- hidden-to-visible windows should no longer receive a sequence of intermediate visible
  frames before reaching the final target.

### Phase 3 — refresh replacement metadata when parking

When a hide/parking plan moves a window offscreen or reconciles an already-hidden window,
update managed-replacement metadata to the parked frame if metadata exists.

Implementation shape:

- after constructing a hide `WindowPositionPlan`, call the existing
  `WorkspaceManager.updateManagedReplacementFrame(...)` with the requested parked frame;
- also update from a reconciled live hidden frame when the already-hidden repair path sees
  a live frame different from cached state;
- keep hidden-state proportional restore metadata unchanged unless the window is actually
  being restored.

Validation expectation:

- `hidden_replacement_frame_mismatch` should disappear for parked windows, or emit with
  `updatedReplacementMetadata=true` if the diagnostic is kept;
- reveal/restore paths should no longer start from old in-strip replacement x positions.

### Phase 4 — defer AX-first parking

Do not change parking backend order in this cluster unless a new capture proves visible
risk. The current evidence shows x-correct offscreen placement and y-offset readback
artifacts, so AX-first parking is not part of this plan.

---

## Validation

Use a ten-column workspace with multiple hidden/offscreen windows and perform:

1. fast edge-to-edge swipe releases;
2. direct workspace-bar jumps between far window items;
3. repeated hide/reveal cycles that park windows left and right.

The cluster is validated when:

- transition records show `targetPinned=true` for hidden/edge transition tokens;
- frame-apply traces no longer show hidden/revealed windows receiving visible intermediate
  current-spring positions;
- replacement mismatch diagnostics are gone or marked updated;
- parking verify mismatches with `dx=0.0 dy=height` are treated as harmless and not used as
  acceptance criteria for this fix.

No tests should be added until the runtime fix is confirmed in the real repro.
