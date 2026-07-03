# Discovery: trackpad gestures silently no-op when the cursor is over an empty workspace

Status: discovery — the runtime evidence and the source mechanism are both fully
confirmed; the gesture pipeline is working exactly as coded. Follow-up fix plan:
`planned/20260702-fix-trackpad-gesture-empty-workspace-routing-and-silent-drop.md`
(diagnostics unconditional; the fallback-routing phase carries the still-open product
decision from "Fix options" below).

Validated against the main Nehir source tree on 2026-07-02 at commit `61a67ba4`
("Show other displays' workspaces in the workspace bar Move to Workspace submenu"),
the same build that produced the capture (`nehir v61a67b*`).

## Summary

A runtime trace captured on 2026-07-02 between `13:06:39Z` and `13:06:54Z` shows the
user attempting **nine** consecutive three-finger horizontal swipes over ~3.5 seconds
(`13:06:45Z`–`13:06:48Z`) with zero visible effect, then moving the cursor to the
other monitor and immediately scrolling successfully. From the user's point of view
"gestures were ignored for some time".

Every ignored swipe was correctly recognized: it was **armed** (clean
`idleAdmissionKind=began` admission with 3 active touches) and **committed** (the
16-unit recognition threshold was crossed). The reason nothing happened is routing +
content, not recognition:

- Gestures route to the active workspace on the **monitor under the cursor**
  (`MouseEventHandler.resolveScrollContext`).
- The cursor was parked at `(1439.5, 1562.3)` — on the external HP Z27k G3 display —
  whose visible workspace 6 (`1F01F5C1`) had **zero columns** (`layout=no-columns`).
  All seven managed windows lived on workspace 1 (`B900E3ED`) on the built-in display.
- With no columns, `ViewportState.beginGesture` refuses the gesture
  (`guard !columns.isEmpty else { return false }`), so **every committed movement
  frame is silently dropped**: no viewport mutation, no
  `touch_scroll_gesture_update` record, no skip record, no user-visible feedback of
  any kind.

Counts from the capture: workspace 6 received 9 `touch_scroll_gesture_armed`,
9 `touch_scroll_gesture_committed`, 9 `touch_scroll_gesture_end`, and
**0 `touch_scroll_gesture_update`** records. Workspace 1 received 111
`touch_scroll_gesture_update` records once the cursor crossed over at `13:06:48Z`.

## Topology and startup state

- Display 1: Built-in Retina Display, frame `(0, 0, 1728, 1117)`, main, showing
  workspace 1 (`B900E3ED-F1AA-408E-B075-F0CD4BD23960`).
- Display 3: HP Z27k G3, frame `(-104, 1117, 1920, 1080)`, showing workspace 6
  (`1F01F5C1-F020-43B3-B616-1834790F51C6`).
- Nehir had just been enabled: the capture starts at `13:06:39Z` with
  `windows total=0` and `startedServices=false`; a `startup_full_rescan` at
  `13:06:40Z` admitted all 8 initial windows (Slack, Teams, 3× Helium, VS Code,
  Ghostty) to workspace 1 on display 1. At capture end: `windows total=7 tiled=7`,
  all still on workspace 1. Workspace 6 was therefore genuinely empty the whole time —
  the routing picked the right workspace for the cursor position; that workspace just
  had nothing to scroll.
- `interactionWorkspace=B900E3ED` (workspace 1, built-in display) for the entire
  capture — including while the ignored gestures targeted workspace 6.

## Evidence: the ignored gestures (13:06:45Z–13:06:48Z)

Representative cycle on workspace 6 (repeated nine times with near-identical values;
trailing always-`nil` `lastViewportMutation*` fields trimmed):

```text
2026-07-02T13:06:45Z workspace=6 id=1F01F5C1-… reason=touch_scroll_gesture_armed input=trackpadTouches requiredFingers=3 activeTouches=3 phase=1 inputPhaseName=began previousGesturePhase=idle idleAdmission=true idleAdmissionKind=began rawActiveCount=3 startTouch=0.684,0.571 columns=0 activeColumnIndex=0 currentOffset=0.0 targetOffset=0.0 currentViewStart=nil targetViewStart=nil gesture=false animating=false layout=no-columns
2026-07-02T13:06:45Z workspace=6 id=1F01F5C1-… reason=touch_scroll_gesture_committed input=trackpadTouches requiredFingers=3 activeTouches=3 cumulativeX=-15.876 cumulativeY=-7.040 threshold=16.000 columns=0 … layout=no-columns
2026-07-02T13:06:45Z workspace=6 id=1F01F5C1-… reason=touch_scroll_gesture_end input=trackpadTouches snap=true focusSelection=none focusFollowsMouse=false endedGestureIsAnimating=false previousActiveColumnIndex=0 endedActiveColumnIndex=0 columns=0 … gesture=false animating=false layout=no-columns
```

Key facts visible in these records:

- Admission is healthy: `idleAdmissionKind=began`, `activeTouches=3` — this is **not**
  a recurrence of the idle-`.changed` admission bug fixed in
  `completed/20260701-fix-trackpad-idle-changed-admission-and-contact-ramp.md`.
- Commit is healthy: the Euclidean threshold crossed
  (`hypot(15.876, 7.040) ≈ 17.4 ≥ 16.0`) and the movement was predominantly
  horizontal.
- The workspace is empty: `columns=0`, `layout=no-columns`, `currentViewStart=nil`.
- `gesture=false` even in the *committed* and *end* records — the engine-side gesture
  never began; only the handler-side state machine progressed.
- No `touch_scroll_gesture_update` and no `touch_scroll_gesture_end_candidate`
  records exist for any of the nine cycles.

During this whole window the mouse-focus trace shows the cursor stationary on the
external display:

```text
2026-07-02T13:06:45Z gesture.skip reason=underCount loc=(1439.5,1562.3) requiredFingers=3 activeTouches=1 phase=4
```

(the continuous `underCount` records are a single resting contact between swipe
attempts; location `(1439.5, 1562.3)` is inside display 3's frame
`(-104, 1117, 1920, 1080)`).

## Evidence: the contrast gesture that worked (13:06:50Z)

At `13:06:48Z` the mouse-focus trace shows the cursor jumping to the built-in display
(`loc=(1082.2,764.5)` and onward). The next swipe routes to workspace 1 and behaves
normally — commit followed immediately by a stream of updates:

```text
2026-07-02T13:06:50Z workspace=1 id=B900E3ED-… reason=touch_scroll_gesture_committed … columns=7 …
2026-07-02T13:06:50Z workspace=1 id=B900E3ED-… reason=touch_scroll_gesture_first_update …
2026-07-02T13:06:50Z workspace=1 id=B900E3ED-… reason=touch_scroll_gesture_update … (18 consecutive updates)
2026-07-02T13:06:50Z workspace=1 id=B900E3ED-… reason=touch_scroll_gesture_end_candidate …
2026-07-02T13:06:50Z workspace=1 id=B900E3ED-… reason=touch_scroll_gesture_end …
```

Same trackpad, same fingers, two seconds later — the only difference is the monitor
under the cursor.

## Source mechanism (all cites against `61a67ba4`)

1. **Routing follows the cursor.**
   `Sources/Nehir/Core/Controller/MouseEventHandler.swift:2289-2308`
   (`resolveScrollContext(at:)`) maps the gesture location to a monitor via
   `location.monitorApproximation(in:)` and then takes
   `WorkspaceManager.activeWorkspaceOrFirst(on:)`
   (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2445-2452`). There is no
   check for whether that workspace has any columns, and no fallback to the
   interaction workspace.

2. **Arm and commit never consult content.** The `.idle` branch
   (`MouseEventHandler.swift:1660-1717`) locks the resolved context and arms; the
   `.armed` branch (`MouseEventHandler.swift:1764-1806`) commits purely on cumulative
   touch distance and direction. An empty workspace passes both stages.

3. **The drop point is silent.** Each committed frame calls
   `applyTrackpadViewportScrollDelta` (`MouseEventHandler.swift:1819-1825`, body at
   `1829-1877`). Inside `withNiriViewportState`, when the engine-side gesture has not
   begun it calls `vstate.beginGesture(isTrackpad:columns:)`
   (`MouseEventHandler.swift:1860-1862`), and
   `Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift:37` rejects it:
   `guard !columns.isEmpty else { return false }`. The closure returns early,
   `didApply` stays `false`, and the update trace at
   `MouseEventHandler.swift:1877-1879` is gated on `didApply` — so the frame vanishes
   with **no trace record at all**. The handler stays in `.committed`, continues
   consuming frames, and on touch release `finalizeOrCancelCommittedGesture`
   (`MouseEventHandler.swift:2006`, end record at `2195`) emits a normal-looking
   `touch_scroll_gesture_end snap=true`.

So the pipeline reports armed → committed → end for a gesture that was 100% discarded
in between. Nothing in the trace, and nothing on screen, says "empty workspace".

## Relationship to prior gesture work

- `completed/20260701-fix-trackpad-idle-changed-admission-and-contact-ramp.md` —
  fixed *admission* correctness. This capture proves admission is now clean
  (`idleAdmissionKind=began` on all nine attempts); the present issue is downstream
  of admission.
- `completed/20260701-fix-trackpad-recognition-debt-and-release-projection.md` —
  movement tuning and release projection; orthogonal (no movement is ever applied
  here).
- `completed/20260701-add-runtime-diagnostics-for-main-gesture-and-bar-issues.md` —
  added the `idleAdmissionKind`/`layout=` fields that made this diagnosis one-pass.
- `discovery/20260625-precommitted-viewport-shifts-before-trackpad-gesture.md` —
  established that the armed record mutates no viewport state, which this capture
  reuses (armed/committed on workspace 6 left `currentOffset=0.0` untouched).
- `noop/20260616-omniwm-301-three-finger-swipe-stuck-under-app-gesture-competition.md`
  — a different "swipe does nothing" report; that one was app gesture competition,
  this one is empty-workspace routing.

None of the prior plans cover the empty-workspace case; this is a new finding.

## Fix options

**A. Make the no-op observable (low risk, do regardless of B/C).**
At arm time (`.idle` branch, after `resolveScrollContext`) check
`engine.columns(in: wsId).isEmpty`; either skip arming with a
`gesture.skip reason=emptyWorkspace` record, or arm but emit an explicit
`touch_scroll_gesture_empty_workspace` viewport record. Also emit a drop record when
`didApply == false` in `applyTrackpadViewportScrollDelta` so committed frames can
never vanish untraced again. This turns any future report of this class into a
one-grep diagnosis. It does not change UX by itself.

**B. Fall back to a scrollable workspace (UX decision).**
When the workspace under the cursor has no columns, retarget the gesture at the
interaction workspace (`interactionWorkspace` was workspace 1 here — exactly the
workspace the user went on to scroll manually). Converts a guaranteed no-op into
probably-what-the-user-meant. Cost: breaks the strict "gesture acts where the cursor
is" model; a swipe over an empty external monitor would visibly move windows on the
other display. If adopted, it should probably apply only when the cursor workspace is
empty, never as general routing.

**C. Give on-screen feedback on the empty workspace.**
E.g. a brief workspace-bar pulse or overscroll hint on the targeted (empty) workspace
so the user learns "the gesture landed here and there is nothing to scroll". Heavier
to build; only worth considering if B is rejected.

**Recommendation:** implement A unconditionally (it is pure diagnostics and closes
the silent-drop hole at `MouseEventHandler.swift:1860-1877`); decide B as a product
question before writing a fix plan. A alone does not change what the user experienced
— it only makes the next capture self-explanatory.

## Validation sketch (for whichever fix is chosen)

1. Two monitors, all windows on monitor A's workspace, empty visible workspace on
   monitor B, cursor parked on monitor B.
2. Three-finger horizontal swipe.
3. Capture a runtime trace:
   - With A: the swipe must produce an explicit `emptyWorkspace` skip/drop record
     instead of a bare armed→committed→end cycle with zero updates.
   - With B: the swipe must produce `touch_scroll_gesture_update` records on monitor
     A's workspace (matching what manual scrolling there produces today).
4. Regression: swipe on the populated workspace still scrolls; swipe on an empty
   *single-monitor* setup still no-ops without crash.
