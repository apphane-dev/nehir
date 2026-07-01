# Add runtime diagnostics for main gesture and bar-click issues — Plan

Verified against `main` on 2026-07-01 at `07ce4168 Reconcile stale hidden-window live frames`.
This is a **diagnostics-only** plan: add trace fields and compact diagnostic records so
isolated repros can prove or dismiss the remaining main-branch issues before behavioral
fixes are ported. Do not change gesture/navigation behavior in this plan.

---

## Why this plan exists

Recent main-branch captures did not show obvious user-visible artifacts, but they did
show trace-level signatures of several remaining issue classes. The current trace stream
is close, but it is missing enough provenance that each issue still requires inference:

- idle trackpad gestures can be armed from raw phase `.changed`, but the trace does not
  explicitly mark this as an idle admission anomaly;
- the first committed gesture update can include the full pre-recognition movement, but
  the trace does not tie the first update back to the commit cumulative distance;
- release projection can target a far snap, but the trace does not report projected
  screen/column distance or the candidate snap delta in an actionable way;
- bar/window clicks can start a spring across distant columns, but the viewport trace does
  not identify the navigation source or motion policy that chose animation;
- hidden/revealed windows can be moved by spring-time frames, but frame-apply traces do
  not say whether a frame came from the current spring sample or the final spring target;
- startup/full-rescan omissions still require cross-reading AX/create/full-rescan records.

The goal is to add diagnostics that make the next capture self-classifying: a reader
should be able to grep one reason string and know whether a suspected issue actually
occurred.

---

## Inlined evidence motivating the diagnostics

The following values are quoted from two main-branch runtime captures. No local trace file
names or machine paths are required to understand the evidence.

### Gesture admission from idle `.changed`

A swipe capture on a four-column workspace emitted multiple idle gesture arms whose raw
phase was `.changed` (`phase=4`), for example:

```text
reason=touch_scroll_gesture_armed input=trackpadTouches requiredFingers=3 activeTouches=3 phase=4 startTouch=0.559,0.576 columns=4 activeColumnIndex=2 currentOffset=-30.0 targetOffset=-30.0 currentViewStart=2814.9 targetViewStart=2814.9
reason=touch_scroll_gesture_armed input=trackpadTouches requiredFingers=3 activeTouches=3 phase=4 startTouch=0.701,0.727 columns=4 activeColumnIndex=2 currentOffset=-30.0 targetOffset=-30.0 currentViewStart=2814.9 targetViewStart=2814.9
```

One arm used `phase=1`, proving the trace can distinguish raw phases, but the current
records do not call out the important state transition: `previousGesturePhase=idle` plus
`inputPhase=changed`.

### Recognition catch-up first update

The same capture committed near the recognition threshold and then applied a much larger
first update:

```text
reason=touch_scroll_gesture_committed input=trackpadTouches requiredFingers=3 activeTouches=3 cumulativeX=15.779 cumulativeY=3.423 threshold=16.000 columns=4 activeColumnIndex=2 currentOffset=-30.0 targetOffset=-30.0 currentViewStart=2814.9 targetViewStart=2814.9
reason=touch_scroll_gesture_update input=trackpadTouches delta=-149.899 phase=committed columns=4 activeColumnIndex=2 currentOffset=-278.8 targetOffset=-278.8 currentViewStart=2566.1 targetViewStart=2566.1 gesture=true animating=false
```

Other commits showed the same pattern: `cumulativeX=-15.649` followed by `delta=148.668`,
`cumulativeX=21.017` followed by `delta=-199.661`, and `cumulativeX=-19.635` followed
by `delta=186.528`. The trace needs a first-update diagnostic that links those two
records without manual pairing.

### Release projection across distant columns

The swipe capture also showed release projections that crossed most of a four-column
workspace:

```text
reason=touch_scroll_gesture_end_candidate input=trackpadTouches snap=true activeColumnIndex=3 currentOffset=-113.765 currentViewStart=4006.435 projectedOffset=-6427.916 projectedViewStart=-2307.716 velocity=-18970.924
reason=touch_scroll_gesture_end input=trackpadTouches snap=true previousActiveColumnIndex=3 endedActiveColumnIndex=0 columns=4 activeColumnIndex=0
```

and:

```text
reason=touch_scroll_gesture_end_candidate input=trackpadTouches snap=true activeColumnIndex=0 currentOffset=-715.418 currentViewStart=-715.418 projectedOffset=4462.024 projectedViewStart=4462.024 velocity=15555.671
reason=touch_scroll_gesture_end input=trackpadTouches snap=true previousActiveColumnIndex=0 endedActiveColumnIndex=3 columns=4 activeColumnIndex=3
```

The existing end-candidate record gives raw numbers, but not the derived facts that matter
for triage: projected screen distance, projected column delta, selected snap column, and
whether a proposed clamp would have changed the target.

### Direct bar/window click uses animated navigation

A workspace/window click capture showed direct navigation between far columns still using
a spring path. The viewport trace contained repeated spring transitions, for example:

```text
reason=relayout.viewportOffsetChanged columns=4 activeColumnIndex=0 currentOffset=5812.2 targetOffset=-520.5 currentViewStart=5832.4 targetViewStart=-520.5 gesture=false animating=true
reason=scroll_animation_start displayId=1 registered=true columns=4 activeColumnIndex=0 currentOffset=1715.1 targetOffset=-520.5 currentViewStart=1757.0 targetViewStart=-520.5 gesture=false animating=true
```

and later:

```text
reason=relayout.viewportOffsetChanged columns=4 activeColumnIndex=3 currentOffset=-4638.4 targetOffset=-79.1 currentViewStart=-520.5 targetViewStart=4041.1 gesture=false animating=true
reason=scroll_animation_start displayId=1 registered=true columns=4 activeColumnIndex=3 currentOffset=-2652.8 targetOffset=-79.1 currentViewStart=1435.1 targetViewStart=4041.1 gesture=false animating=true
```

The capture had many `lastViewportMutation=animateToOffset.spring` records and no
`animateToOffset.staticFallback` records. The missing diagnostic is the cause: whether
the action was a workspace click, a window item click, a command/hotkey navigation, and
what `MotionSnapshot` was passed to `ensureSelectionVisible` / `animateToOffset`.

### Spring-time frame writes can look like slide-through, but are not classified

During a swipe capture, a large window (`1834x1226`) was repeatedly written from on-screen
x positions to offscreen-left positions while a spring was running:

```text
enqueue id=10784 target={{-737.5, 32.0}, {1834.0, 1226.0}}
confirmed id=10784 target={{-738.0, 32.0}, {1834.0, 1226.0}}
enqueue id=10784 target={{-921.5, 32.0}, {1834.0, 1226.0}}
confirmed id=10784 target={{-922.0, 32.0}, {1834.0, 1226.0}}
enqueue id=10784 target={{-1138.0, 32.0}, {1834.0, 1226.0}}
confirmed id=10784 target={{-1138.0, 32.0}, {1834.0, 1226.0}}
...
enqueue id=10784 target={{-1680.5, 32.0}, {1834.0, 1226.0}}
confirmed id=10784 target={{-1681.0, 32.0}, {1834.0, 1226.0}}
```

This may be expected visible-column movement, or it may be the hidden/reveal pinning
issue. The frame trace does not say whether token `10784` was classified visible,
hidden, edge-revealed, or target-pinned for each frame. Add that context before deciding
whether to change rendering behavior.

---

## Scope

### In scope

- Add trace fields / records only.
- Keep records compact and grep-friendly.
- Prefer low-volume records emitted at state transitions, first updates, release
  candidates, navigation starts, and frame-plan classification decisions.
- Make records self-contained enough for durable discovery docs without reopening raw
  traces.

### Out of scope

- Behavior changes such as rejecting idle `.changed`, clamping projection, disabling bar
  click motion, or pinning spring target frames.
- Regression tests for behavior. Runtime traces and user validation remain the acceptance
  signal before adding tests for fixes.
- Any planning-doc references to local trace filenames or machine-specific paths.

---

## Proposed diagnostics

### 1. Raw multitouch source and idle admission diagnostics

Source areas:

- `Sources/Nehir/Core/Multitouch/MultitouchGestureSource.swift`
- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` (`handleTouchScrollGesture`,
  gesture skip/arm tracing helpers)

Add fields to `touch_scroll_gesture_armed`:

- `inputPhaseRaw` and `inputPhaseName` (`began`, `changed`, `ended`, `cancelled`)
- `previousGesturePhase`
- `idleAdmission=true|false`
- `idleAdmissionKind=began|changed|other`
- `rawActiveCount` and `requiredFingers`
- for raw multitouch events, `previousRawActiveCount` and `activeCountDelta`

Add one explicit warning record when the handler arms from idle using a non-begin phase:

```text
reason=touch_scroll_gesture_idle_changed_admission input=trackpadTouches inputPhase=changed requiredFingers=3 activeTouches=3 previousGesturePhase=idle startTouch=...
```

This record is diagnostic only. It should not skip or abort the gesture.

### 2. Recognition first-update diagnostics

Source area:

- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` around the armed→committed
  transition and the first committed update.

Persist the commit metrics in gesture state until the first `touch_scroll_gesture_update`:

- `commitCumulativeX`
- `commitCumulativeY`
- `recognitionThreshold`
- `commitTimestamp`
- `commitInputPhase`
- `firstUpdateRawDelta`
- `firstUpdateSignedDelta`
- `firstUpdateIncludesRecognitionDebt=true|false`
- `deadZoneOvershootX` (what would be applied by a dead-zone implementation)

Emit a single compact record for the first update after commit:

```text
reason=touch_scroll_gesture_first_update input=trackpadTouches commitCumulativeX=15.779 threshold=16.000 rawDelta=-149.899 appliedDelta=-149.899 wouldDeadZoneDelta=... phase=committed
```

Keep normal `touch_scroll_gesture_update` records unchanged or append `firstUpdate=true`
to the first one.

### 3. Release projection diagnostics

Source areas:

- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` (`touch_scroll_gesture_end_candidate`)
- `Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift` (`endGesture`)

Extend end-candidate records with derived fields:

- `rawProjectedOffset` / `rawProjectedViewStart` (same as current projection before any
  future clamp)
- `projectionDeltaFromCurrent`
- `projectionScreens`
- `projectedColumnDelta`
- `closestSnapColumn`
- `closestSnapDistance`
- `targetColumnDelta`
- `wouldClamp=true|false`
- `clampScreens=<configured value or nil>`
- `clampedProjectedViewStart` / `clampedTargetColumn` (diagnostic only if clamp is not
  implemented yet)

The plan is not to clamp here; it is to let captures say, "this release would have been
changed by the planned clamp."

### 4. Navigation-source and motion-policy diagnostics

Source areas:

- `Sources/Nehir/Core/Controller/WindowActionHandler.swift`
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`
- `Sources/Nehir/Core/Layout/Niri/ViewportState+Animation.swift`
- `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` if relayout commit records need
  to propagate navigation context.

Add a small navigation context propagated into viewport mutation provenance:

- `navigationSource=workspaceBarWindow|workspaceBarWorkspace|hotkey|command|overview|focusConfirm|unknown`
- `targetToken`
- `targetWorkspace`
- `fromActiveColumnIndex`
- `targetColumnIndex`
- `columnDelta`
- `motionAnimationsEnabled=true|false`
- `requestedMotion=enabled|disabled|policy`
- `directSelection=true|false`

Emit a single record before applying the viewport patch:

```text
reason=navigate.window target=WindowToken(...) source=workspaceBarWindow fromColumn=0 targetColumn=3 columnDelta=3 motionAnimationsEnabled=true directSelection=true
```

Append `navigationSource` and `motionAnimationsEnabled` to `lastViewportMutation` records
where practical. This makes a bar-click capture self-classify without inferring from
`animateToOffset.spring` alone.

### 5. Spring-frame classification diagnostics for hidden / visible / edge-revealed frames

Source areas:

- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift`
- `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift`
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`

When layout computes frames during an active scroll animation, classify each token whose
frame is applied:

- `frameSource=currentSpring|springTarget|static|gesture`
- `visibilityClass=visible|hidden|edgeReveal|hiddenToVisible|visibleToHidden|workspaceInactiveHidden`
- `hiddenSide=left|right|top|bottom|nil`
- `wasHiddenState=<summary>`
- `targetPinned=true|false` (diagnostic; false on current main)
- `currentFrame` and `targetFrame` only for tokens whose visibility class changes or whose
  frame crosses the viewport edge.

Avoid per-frame spam for normal visible windows. Emit only when:

- a token transitions `hidden -> visible` or `visible -> hidden`;
- a hidden token receives a visible/in-viewport frame;
- an edge-revealed token receives more than one distinct spring-sampled frame;
- a large frame crosses the viewport boundary during a spring.

Example diagnostic:

```text
reason=spring_frame_classification token=WindowToken(...) frameSource=currentSpring visibilityClass=hiddenToVisible hiddenSide=right currentFrame={{549.0,32.0},{972.0,1226.0}} targetFrame={{1546.0,32.0},{972.0,1226.0}} targetPinned=false
```

### 6. Startup/full-rescan omission diagnostics

Source areas:

- `Sources/Nehir/Core/Ax/AXManager.swift`
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`
- `Sources/Nehir/Core/Controller/AXEventHandler.swift`

Add a compact full-rescan reconciliation summary:

- `pid`
- `windowServerLevel0VisibleCount`
- `axWindowCount`
- `failedPID=true|false`
- `omittedVisibleWindowIds=[...]`
- for each omitted visible level-0 candidate: `windowId`, `pid`, `parent`, `level`,
  `alpha`, `bounds`, `axRefResolvable=true|false`, `topLevelAX=true|false`,
  `trackedAfterRescan=true|false`

Emit only when counts differ or a visible level-0 document window is omitted. This
separates harmless `missing_ax_ref` for menus/level-101 surfaces from real startup
admission gaps.

### 7. Parking-write backend / coordinate diagnostics

Source area:

- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift` (`applyPositionPlans`)

If a hide/parking plan verifies with a mismatch, record enough data to classify whether
it is a visible slide-through or a coordinate-space readback artifact:

- `backend=skylight|ax`
- `requestedOrigin`
- `observedOrigin`
- `dx`, `dy`
- `width`, `height`
- `observedXOffscreen=true|false`
- `observedYDeltaEqualsHeight=true|false`
- `visibleRisk=true|false` (true only when x/y overlap the active viewport)

This keeps the AX-first parking question separate from confirmed visible artifacts.

### 8. Replacement metadata / hidden-state frame diagnostics

Source areas:

- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift`

When hiding or reconciling a hidden window, emit a low-volume diagnostic if replacement
metadata disagrees with the parked frame:

- `token`
- `windowId`
- `hiddenReason`
- `hiddenSide`
- `parkedFrame`
- `replacementFrame`
- `replacementDx`, `replacementDy`
- `updatedReplacementMetadata=true|false` (diagnostic only on main if no update occurs)

Example:

```text
reason=hidden_replacement_frame_mismatch token=WindowToken(...) hiddenSide=right parked={{2055.0,32.0},{972.0,1226.0}} replacement={{297.0,32.0},{972.0,1226.0}} replacementDx=1758.0 updatedReplacementMetadata=false
```

---

## Implementation phases

### Phase 1 — Gesture diagnostics

1. Add phase-name formatting for `NSEvent.Phase`.
2. Add idle-admission fields to `touch_scroll_gesture_armed`.
3. Add diagnostic-only `touch_scroll_gesture_idle_changed_admission`.
4. Store commit metrics in gesture state and emit `touch_scroll_gesture_first_update`.
5. Extend end-candidate projection records with derived distance/clamp fields.

Verification capture:

- Repeat the fast multi-swipe sequence.
- Confirm the capture contains either `idleAdmissionKind=began` for clean starts or
  `touch_scroll_gesture_idle_changed_admission` for the issue.
- Confirm first-update records show whether `appliedDelta` includes recognition debt.
- Confirm end-candidate records report projected screen/column distance.

### Phase 2 — Navigation diagnostics

1. Thread a lightweight navigation source through direct window/workspace navigation.
2. Emit `navigate.window` and/or `navigate.workspace` before applying the viewport patch.
3. Include source and motion policy in viewport mutation provenance where available.

Verification capture:

- Click first/last window items in the bar.
- Confirm records say `source=workspaceBarWindow`, `columnDelta`, and
  `motionAnimationsEnabled`.
- Confirm workspace clicks and window clicks can be distinguished.

### Phase 3 — Frame classification diagnostics

1. Add frame classification at layout/frame-diff time for active scroll animations.
2. Emit only transition/risk records to avoid trace spam.
3. Include hidden-state and target-vs-current-spring frame provenance.

Verification capture:

- Perform fast swipe-release across edge columns with hidden windows present.
- Confirm any visible hidden/reveal movement is classified as `hiddenToVisible`,
  `visibleToHidden`, or `edgeReveal`, with `frameSource` and `targetPinned` fields.

### Phase 4 — Admission / parking / replacement diagnostics

1. Add full-rescan omission summaries for visible level-0 candidates.
2. Add parking verify coordinate-risk classification.
3. Add replacement metadata mismatch diagnostics during hide/reconcile.

Verification capture:

- Cold start with several visible document windows.
- Open transient/auxiliary windows that previously produced `missing_ax_ref` noise.
- Confirm real level-0 omissions are distinct from harmless menu/overlay rejects.
- Confirm parking mismatches say whether they are visible risk or coordinate artifact.

---

## Acceptance criteria

- A swipe capture can prove or dismiss, by grep alone:
  - idle `.changed` admission;
  - recognition catch-up debt;
  - multi-column release projection.
- A bar/workspace click capture can distinguish:
  - workspace item click vs window item click;
  - direct navigation vs focus-confirm reveal;
  - animated vs static motion policy.
- A spring/frame capture can identify whether hidden/edge-revealed windows are receiving
  current-spring frames or target frames.
- Startup/admission captures separate harmless `missing_ax_ref` auxiliary surfaces from
  visible level-0 document windows that were omitted despite resolvable AX refs.
- Diagnostics are compact enough to leave runtime tracing usable and do not require any
  local filesystem path or raw trace filename to interpret.

---

## Notes for future fix plans

Once diagnostics land and a repro confirms an issue, create separate behavior plans/fixes
for each class. Do not bundle behavior changes into this diagnostics work. Likely follow-up
fix candidates are:

- require idle gestures to start from `.began` and make the raw source emit `.began` on
  contact-count increases;
- subtract recognition dead-zone debt from the first committed update;
- clamp trackpad release projection;
- disable motion for direct workspace-bar window clicks;
- pin hidden/edge-revealed frames to spring targets;
- supplement full rescans from visible WindowServer level-0 document windows;
- refresh hidden replacement metadata to parked frames.
