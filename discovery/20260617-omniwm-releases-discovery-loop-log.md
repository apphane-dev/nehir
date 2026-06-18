# Upstream-release discovery loop log — OmniWM v0.4.9.7 → v0.4.9.9

Standard agentic loop — no subagents (same constraint as the per-issue
`discovery-loop-log.md`: orchestrator + worker merged into one agent).

Operator directive: study the recent three upstream OmniWM releases and produce
discovery docs about each change's applicability to the nehir codebase.

Baseline (anchor, re-verified per item):
- Worktree: `worktree/calm-meadow-6229`
- HEAD sha: `904df02` ("Add bunch of discoveries mapped to issues from OmniWM")
- Date prefix: `20260617`
- Releases in scope (the three most recent as of 2026-06-17):
  - **v0.4.9.9** — "Displays have separate Spaces" + raw MultitouchSupport swipe source
  - **v0.4.9.8** — perf/smoothness, native-fullscreen + admission fixes, **major runtime rewrite** (WorldStore / EventIntake / IntentLedger / DeadlineWheel / SurfaceReconciler)
  - **v0.4.9.7** — runtime polish (resize placeholders, Dwindle bezier, semantic Hyper key, own-window tab-stack prevention)

## Documents produced

- `20260617-omniwm-release-v0.4.9.9-separate-spaces-and-multitouch-swipe.md`
- `20260617-omniwm-release-v0.4.9.8-perf-fixes-and-runtime-rewrite.md`
- `20260617-omniwm-release-v0.4.9.7-runtime-polish-hyper-and-tabstack.md`

Each change in each release has exactly one verdict in its release doc. The
three docs are self-contained (no dependency on any machine-local trace; all
evidence is inlined as code citations or verbatim release-note quotes).

## Work order + verdicts (release → change → verdict)

### v0.4.9.9 (2 items)

1. "Displays have separate Spaces" first-class — **🟡 Partial — owns investigation**
2. Raw MultitouchSupport trackpad-swipe source — **🔴 Open — owns a port action** (ties to nehir #53)

### v0.4.9.8 (21 items across Smoother/Faster, Fixes, Under-the-hood)

- Momentum trackpad scrolling — **🟡 Partial — verify**
- Parallel overview thumbnails — **🔴 Open — owns an action** (nehir is sequential)
- AX reads off main thread — **🟡 Partial — audit**
- Smoother animations/relayout coalescing — **🟡 Partial — verify per bullet**
- Less size-grid jitter — **🟡 Partial — investigate**
- Cheaper Hyper event tap — **⚪ N/A** (nehir has no event-tap Hyper)
- Correct animation timing per display — **🟡 Partial — verify**
- Native fullscreen survives window recreation — **🟢 Largely present — verify** (`restoreNativeFullscreenReplacement`)
- FFM no longer warps cursor (#147) — **🟢 Already fixed (noop)** — existing noop doc
- settings.toml preserved — **🔴 Open — already tracked** — existing #410 doc
- Monitor orientation overrides stick + IPC — **🟢 Already present**
- No stray border on system-modal dialogs — **🟡 Verify**
- Stable window stacking — **🟡 Verify**
- Own overlay/ghost windows not tiled — **🟢 Already handled** (`OwnedWindowRegistry`)
- Better window admission (Steam/flapping/retry) — **🟢/🟡 Mostly present — verify**
- Send window across workspaces and back, focus stuck — **🟡 Verify**
- WorldStore — **🔵 Strategic divergence — do not wholesale port**
- EventIntake — **🔵 Selective adoption**
- IntentLedger + DeadlineWheel — **🟡 Selective adoption — owns a plan** (ties to #317/#379/#403)
- SurfaceReconciler — **⚪ N/A as a unit**
- Layout invariant asserts + replay tests — **🟢 Adopt incrementally (process)**

### v0.4.9.7 (8 items)

- Resize placeholder removal — **⚪ N/A** (never had)
- Dwindle bezier motion — **⚪ N/A** (Niri-only, no Dwindle)
- Semantic Hyper key / Caps Lock removal — **⚪ N/A / 🟡 decision (don't build it)**
- Own windows not grouped into tab stacks — **🟢 Already handled** (`OwnedWindowRegistry`)
- Hotkey config/key-recorder simplification — **⚪ N/A**
- Consolidate refresh/focus ownership — **🟡 Selective / own audit (low priority)**
- Stabilize hotkeys/gestures/admission (meta) — **⚪ N/A (superseded by v0.4.9.8 rewrite)**
- Remove stale test harness — **⚪ N/A**

**Batch complete.** All three releases, all 31 changes, each with one verdict.

## Verdict tally

- 🔴 **Open (owns a port/action):** 2 — MultitouchSupport swipe source (v0.4.9.9 #2); parallel overview thumbnails (v0.4.9.8 #2). Plus 1 **already-tracked** Open (settings.toml → #410).
- 🟡 **Partial / owns investigation or plan:** 9 — separate-Spaces (v0.4.9.9 #1); momentum scroll; AX-off-main audit; relayout-coalesce verify; size-grid jitter; per-display animation timing; IntentLedger/DeadlineWheel plan; native-fullscreen verify; modal-dialog border verify; stacking verify; admission-flapping verify; focus-stuck-after-move verify; refresh-ownership audit. (Investigations, not implementation commitments.)
- 🟢 **Already present / fixed (noop-class):** 6 — FFM warp (#147, existing noop); monitor orientation+IPC; own-windows not tiled; own-windows not tab-stacked; Steam tiles by default; native-fullscreen window-recreation (largely).
- ⚪ **N/A / won't port:** 11 — Hyper event tap; Dwindle; resize placeholders; SurfaceReconciler; hotkey-config cleanup; test-harness removal; stability meta-pass; (and the semantic-Hyper "decision" item).
- 🔵 **Strategic divergence (study, do not port):** 2 — WorldStore; EventIntake (as a unit).

## New repo actions owned by this batch (queue these)

Ranked by confidence/leverage:

1. **Port trackpad-swipe source to raw MultitouchSupport** (v0.4.9.9 #2). Highest
   confidence — directly addresses the transport layer of nehir's own open
   issue #53. Phased: private-framework bridge → telemetry side-by-side → switch
   matcher's touch source → wire #53's abort trace → wake/restart re-acquire.
2. **Parallelize overview thumbnail capture** (v0.4.9.8 #2). Low-risk, clear win;
   convert the sequential `await` loop to a `TaskGroup` mirroring `AXManager`'s
   pattern.
3. **Scope IntentLedger/DeadlineWheel for nehir's retry ladders** (v0.4.9.8 #19).
   *Plan*, not a port — target the `scheduleCreatedWindowRetryIfNeeded`/
   focus-revert ladders that are the substrate of the #317/#379/#403 race
   discoveries.
4. **"Displays have separate Spaces" investigation** (v0.4.9.9 #1). Verify the
   failure mode first; ship an accommodate+warn startup check; only add a
   Space-membership admission gate if a real bug is shown.
5. **Layout invariant asserts + violation counter + replay tests** (v0.4.9.8 #21).
   Process/test work; zero coupling to the WorldStore rewrite; cheapest way to
   get the rewrite's reliability win.

## Explicitly not queued (decisions recorded in the release docs)

- **Do not** introduce `WorldStore` (v0.4.9.8 #17) or `SurfaceReconciler` (#20).
- **Do not** build the event-tap semantic Hyper (v0.4.9.7 #3); nehir's
  chord-based Hyper already covers bindings.
- The v0.4.9.7 polish items (Dwindle, resize placeholders, hotkey-config
  cleanup, test-harness removal) have no nehir equivalent and no port.

## Notes for the user

- All release-tag URLs resolve under `BarutSRB/OmniWM` (the `OmniWM-v*` artifact
  names are preserved in-place).
- **No trace filenames referenced.** Every runtime claim is either a code
  citation (`file:line`, verified at `904df02`) or a verbatim quote of the
  upstream release note, per `AGENTS.md`.
- **Non-duplication with the per-issue discovery set.** Two v0.4.9.8 items are
  already owned by existing issue docs: FFM-warp (#147 → existing noop) and
  settings.toml preservation (#410 → existing Open). The release docs point at
  those rather than re-scoping. The MultitouchSupport port is the *transport*
  complement to nehir #53's *matcher* analysis — complementary, not duplicate.
- **Verify-before-close backlog.** Six v0.4.9.8 fixes (native-fullscreen
  recreation, modal border, stacking, admission flapping, focus-stuck-after-move,
  monitor-orientation) appear already-present from symbol evidence but are
  marked 🟡/🟢-verify, not noop-certain. A focused verification pass can convert
  these to noop docs (or surface real gaps) — that is the natural next loop.
