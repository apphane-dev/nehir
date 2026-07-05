---
title: Nehir Architecture Guide
---

# Nehir Architecture Guide

This document is for contributors who want to understand Nehir's internals. It is not a user guide (see [Documentation Home](index.md)) or IPC/CLI reference (see [IPC-CLI.md](IPC-CLI.md)). For contribution process, see the [Contribution Guide](CONTRIBUTING.md).

**Prerequisites**: Familiarity with Swift, macOS development concepts (AppKit, AXUIElement, CGWindowID), and basic tiling window manager concepts.

---

## Table of Contents

- [1. Project Structure](#1-project-structure)
- [2. Startup & Bootstrap](#2-startup--bootstrap)
- [3. Core Mental Model](#3-core-mental-model)
  - [3.1 The Event-Driven Pipeline](#31-the-event-driven-pipeline)
  - [3.2 Window Identity](#32-window-identity)
  - [3.3 Window Lifecycle](#33-window-lifecycle)
  - [3.4 The Refresh Pipeline](#34-the-refresh-pipeline)
  - [3.5 Layout Engines as Pure State Machines](#35-layout-engines-as-pure-state-machines)
  - [3.6 Thread Safety Model](#36-thread-safety-model)
- [4. Key Subsystems](#4-key-subsystems)
  - [4.1 WMController — The Orchestrator](#41-wmcontroller--the-orchestrator)
  - [4.2 Workspace & Window State](#42-workspace--window-state)
  - [4.3 Niri Layout Engine (Scrolling Columns)](#43-niri-layout-engine-scrolling-columns)
  - [4.4 Focus Lifecycle](#44-focus-lifecycle)
  - [4.5 Input Handling](#45-input-handling)
  - [4.6 Window Rules Engine](#46-window-rules-engine)
  - [4.7 IPC System](#47-ipc-system)
  - [4.8 Accessibility Layer](#48-accessibility-layer)
  - [4.9 Animation System](#49-animation-system)
  - [4.10 Border System](#410-border-system)
  - [4.11 Additional Features](#411-additional-features)
- [5. Data Flow Diagrams](#5-data-flow-diagrams)
- [6. Common Contribution Patterns](#6-common-contribution-patterns)
- [7. Testing](#7-testing)
- [8. Glossary](#8-glossary)

---

## 1. Project Structure

### SwiftPM Targets

Nehir is built with Swift Package Manager (Swift 6.3.2, strict concurrency). There are four targets with a clear dependency graph:

```
NehirIPC          (zero dependencies — shared IPC protocol models)
    ^         ^
    |          \
NehirCtl       Nehir           (CLI tool / core library)
                   ^
                   |
               NehirApp        (@main entry point)
```

| Target | Purpose | Dependencies |
|--------|---------|--------------|
| `NehirIPC` | Shared IPC data models and wire format | None |
| `NehirCtl` | CLI tool (`nehirctl`) | NehirIPC |
| `Nehir` | Core window manager library | NehirIPC, system frameworks |
| `NehirApp` | Executable wrapper with SwiftUI scene | Nehir |

### Source Directory Map

```
Sources/
├── Nehir/                          Main library
│   ├── App/                         Application bootstrap, delegate,
│   │                                and owned-window registry
│   ├── Core/
│   │   ├── AppInfoCache.swift       App icon/name cache
│   │   ├── CommandPaletteMode.swift Command palette mode enum
│   │   ├── PrivateAPIs.swift        Private API declarations via @_silgen_name
│   │   ├── Animation/               Spring, cubic & workspace-switch animations
│   │   ├── Ax/                      Accessibility wrappers, DefaultFloatingApps
│   │   ├── Border/                  Focused window border rendering
│   │   ├── Config/                  Settings store, export, per-monitor settings
│   │   ├── Controller/              WMController, event handlers, refresh pipeline
│   │   ├── Input/                   Hotkey action catalog, binding persistence
│   │   ├── Layout/
│   │   │   ├── DNode.swift          Shared types: WindowToken, WindowHandle
│   │   │   ├── LayoutBoundary.swift Layout snapshots & workspace geometry
│   │   │   ├── SideHiding.swift     Side-hiding edge types
│   │   │   ├── Niri/                Scrolling columns layout engine
│   │   ├── LockScreen/              Lock screen detection
│   │   ├── Menu/                    Menu extraction for MenuAnywhere
│   │   ├── Monitor/                 Display detection, OutputId, restore assignments
│   │   ├── Overview/                Bird's-eye workspace overview mode
│   │   ├── Reconcile/               Runtime snapshot/trace, restore planning,
│   │   │                            and persisted restore models
│   │   ├── Rules/                   Window rule evaluation engine
│   │   ├── SkyLight/                Private macOS API wrappers
│   │   ├── Sleep/                   Sleep prevention manager
│   │   ├── Support/                 Utility types & extensions
│   │   ├── Surface/                 Shared surface policy, hit-testing,
│   │   │                            and capture eligibility
│   │   └── Workspace/               Workspace model, session state,
│   │                                and runtime coordination
│   ├── IPC/                         IPC server, connections, routing
│   └── UI/                          SwiftUI settings, status bar, workspace bar,
│                                    command palette
├── NehirApp/                       @main entry + settings redirect
├── NehirCtl/                       CLI parser, IPC client, renderer
└── NehirIPC/                       models, wire format, socket path
```

### External Dependencies

Nehir has **zero third-party package dependencies**. All functionality is built on:

- **System frameworks**: AppKit, ApplicationServices, Carbon, Metal, MetalKit, QuartzCore
- **SkyLight**: A private Apple framework for low-latency window server access, linked via `-framework SkyLight` unsafe flag
- **System libraries**: libz, libc++

### Building & Running

```bash
# Debug build
swift build

# Run tests
swift test

# Code quality
mise run format        # Rewrite Swift formatting with SwiftFormat
mise run format:check  # Verify SwiftFormat output without rewriting
mise run lint          # Run SwiftLint diagnostics
mise run check         # Verify formatting, lint, build, and test

# Create distributable app bundle
mise run package:release -- true          # Run checks, build, sign, notarize
CONFIGURATION=debug mise run package:release -- false  # Run checks, debug build only
```

---

## 2. Startup & Bootstrap

### Entry Point

The application starts in `Sources/NehirApp/NehirApp.swift`:

```
@main NehirApp (SwiftUI App)
  └─ @NSApplicationDelegateAdaptor → AppDelegate
       └─ applicationDidFinishLaunching()
            └─ bootstrapApplication()
```

### Bootstrap Decision Tree

`AppBootstrapPlanner.decision()` evaluates two preconditions before booting:

```
                        ┌─────────────────────────┐
                        │ AppBootstrapPlanner      │
                        │   .decision()            │
                        └────────┬────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │ "Displays have separate  │
                    │  Spaces" disabled?        │
                    └────────┬───────────┬─────┘
                          NO │           │ YES
                             │           │
              ┌──────────────┘      ┌────┴────────────┐
              │ Show modal:         │ Settings epoch   │
              │ .requireDisplays... │ matches?         │
              └─────────────────┘   └──┬──────────┬───┘
                                    NO │          │ YES
                                       │          │
                          ┌────────────┘     ┌────┴────┐
                          │ Show modal:      │ .boot   │
                          │ .requireSettings │ (normal)│
                          │  Reset           └─────────┘
                          └─────────────────┘
```

### Normal Boot Sequence

When the decision is `.boot`, `finishBootstrap()` runs:

1. **SettingsStore** created — loads the split TOML config files
2. **WMController** created — central orchestrator (see [4.1](#41-wmcontroller--the-orchestrator))
3. **`applyPersistedSettings()`** — registers hotkeys, configures borders, workspaces, gaps, etc.
4. **AppCLIManager** created — CLI exposure workflow
5. **AppBootstrapState** populated — shares `SettingsStore` and `WMController` with SwiftUI redirect flows
6. **StatusBarController** created — menu bar UI, settings entry point, and workspace summary
7. **IPCServer** started (if enabled in settings) — Unix domain socket server

### Service Startup

`WMController.setEnabled(true)` triggers `ServiceLifecycleManager.start()`:

1. Polls for accessibility permissions (blocks until granted)
2. Once trusted: `startServices()` connects all event plumbing:
   - `LayoutRefreshController.setup()` — display links, refresh scheduling
   - `AXEventHandler.setup()` — SkyLight event observation
   - Hotkey registration via `HotkeyCenter`
   - `MouseEventHandler.setup()` — CGEvent taps
   - Display configuration observer
   - App activation/termination/hide/unhide observers
   - Workspace change observation
   - Initial full rescan refresh

---

## 3. Core Mental Model

### 3.1 The Event-Driven Pipeline

Nehir is fundamentally **reactive**. It responds to two categories of events, processes them through a pipeline, and applies the resulting window frames:

```
┌──────────────────────────────────────────────────────────────────┐
│                        EVENT SOURCES                             │
├──────────────────────────┬───────────────────────────────────────┤
│  System Events           │  User Input                          │
│  (SkyLight/CGS)          │  (Carbon/CGEvent)                    │
│  - Window created        │  - Hotkey pressed                    │
│  - Window destroyed      │  - Mouse moved/dragged              │
│  - Frame changed         │  - Scroll wheel (gestures)          │
│  - Front app changed     │  - IPC command (nehirctl)          │
│  - Title changed         │                                     │
└──────────┬───────────────┴──────────┬───────────────────────────┘
           │                          │
           v                          v
┌──────────────────┐    ┌────────────────────────┐
│ CGSEventObserver │    │ HotkeyCenter /          │
│                  │    │ MouseEventHandler /     │
│                  │    │ IPCCommandRouter        │
└────────┬─────────┘    └──────────┬─────────────┘
         │                         │
         v                         v
┌──────────────────┐    ┌──────────────────┐
│ AXEventHandler   │    │ CommandHandler   │
│ (window lifecycle│    │ (command routing │
│  & focus)        │    │  & execution)    │
└────────┬─────────┘    └────────┬─────────┘
         │                       │
         └───────────┬───────────┘
                     v
         ┌───────────────────────┐
         │LayoutRefreshController│
         │ (scheduling,          │
         │  coalescing,          │
         │  debouncing)          │
         └───────────┬───────────┘
                     v
         ┌───────────────────────┐
         │ Layout Engine         │
         │                       │
         │ Input: window list,   │
         │   workspace geometry  │
         │ Output: [WindowToken: │
         │   CGRect] frame map   │
         └───────────┬───────────┘
                     v
         ┌───────────────────────┐
         │ AXManager             │
         │ .applyFramesParallel()│
         │                       │
         │ Writes frames to      │
         │ windows via AX APIs   │
         └───────────────────────┘
```

### 3.2 Window Identity

Windows are identified at three levels, each serving a different purpose:

```swift
// 1. WindowToken — value type, used as dictionary keys everywhere
struct WindowToken: Hashable, Sendable {
    let pid: pid_t       // Process ID
    let windowId: Int    // SkyLight/CGS window ID
}

// 2. WindowHandle — reference type, identity-compared (===)
final class WindowHandle: Hashable {
    var id: WindowToken
    // hash/equality use ObjectIdentifier (reference identity)
}

// 3. AXWindowRef — accessibility bridge to the actual window
struct AXWindowRef: Hashable, @unchecked Sendable {
    let element: AXUIElement   // Accessibility handle for read/write
    let windowId: Int          // SkyLight window ID
}
```

**Why three layers?**
- `WindowToken` is a lightweight value type that survives across relayouts, is `Sendable`, and works as a dictionary key without holding any reference to the accessibility system.
- `WindowHandle` provides reference identity for layout engine tree nodes — two handles wrapping the same token are NOT equal unless they are the same object.
- `AXWindowRef` is the bridge to macOS accessibility APIs for actually reading/writing window attributes (position, size, title). It holds the `AXUIElement` which is a heavyweight system resource.

### 3.3 Window Lifecycle

From creation to destruction, a window passes through these stages:

**Creation:**
1. `CGSEventObserver` receives `.created(windowId, spaceId)` from SkyLight and captures a `WindowCreatePlacementContext` when possible (native-space monitor, active focus request, confirmed focus, interaction monitor, and source metadata).
2. `AXEventHandler` queries window attributes via accessibility APIs (role, subrole, title, size, buttons). AX can occasionally report focused-window state before the SkyLight create event has drained; in that AX-first path, `AXEventHandler` synthesizes the same placement context before admission.
3. `WindowRuleEngine.evaluate()` produces a `WindowDecision`:
   - `.managed` — tiled in the layout engine
   - `.floating` — tracked but positioned independently
   - `.unmanaged` — ignored entirely (e.g., system UI, panels, or user `manage = "ignore"` rules)
4. Rule effects (`ManagedWindowRuleEffects`) are attached to tracked windows. Effects include sizing constraints and sticky visibility; sticky is an overlay/source, not a separate window mode.
5. `WMController.resolveWorkspaceForNewWindow(...)` chooses the workspace from placement inputs. Current frame/interaction monitor evidence beats stale confirmed focus; recent same-pid workspace is only a fallback for focus-cleared AX-first admission.
6. If tracked: `WindowModel` creates an `Entry`, layout engine inserts a node.
7. `LayoutRefreshController` schedules a refresh to compute and apply frames.

**Destruction:**
1. `CGSEventObserver` receives `.destroyed(windowId, spaceId)`
2. `WindowModel` removes the entry
3. Layout engine removes the node from its tree
4. `LayoutRefreshController` schedules a `windowRemoval` refresh
5. Focus recovery runs if the destroyed window was focused

Nehir also guards the native activation race around close/collapse and manually-unstuck sticky surfaces. macOS may focus another window before Nehir receives the destroy, hide, or AX focus-loss signal for the disappearing surface. `AXEventHandler` arms a short `windowCloseFocusRecovery` lease from tracked destroys, untracked auxiliary same-pid destroys, focused-window loss, and the confirmed managed window becoming hidden. While the lease is active, unrelated native activations away from the recovery workspace are suppressed; duplicate confirmations of the already-focused token preserve the active viewport instead of revealing parked columns. If an inactive-workspace `workspaceDidActivateApplication` arrives just before the close signal, Nehir briefly defers and retries it so recovery can arm first; if no recovery appears, the retry is allowed as a real native activation. Hidden, inactive manually-unstuck PiP/sticky-source windows also suppress unrelated activation churn so native PiP focus reports do not immediately reveal the window again. Explicit Nehir focus requests still bypass these guards.

**Managed Replacement:**
Some apps (browsers, terminals) destroy and recreate windows during internal operations. `AXEventHandler` detects these patterns via `ManagedReplacementMetadata` correlation — matching a destroy+create pair within a 150ms grace period to preserve the window's workspace assignment and position.

### 3.4 The Refresh Pipeline

`LayoutRefreshController` is the central coordination point between events and window frame application. It manages scheduling, debouncing, and coalescing of layout refreshes.

**Five Refresh Routes:**

| Route | When Used | What It Does |
|-------|-----------|--------------|
| `fullRescan` | Startup, app launch/termination, space change, display change | Full window enumeration + relayout |
| `relayout` | Config change, window created, window frame changed | Recompute layout from current state |
| `immediateRelayout` | User commands, gestures, workspace switch | Synchronous immediate layout |
| `visibilityRefresh` | App hidden/unhidden | Show/hide windows, no relayout |
| `windowRemoval` | Window destroyed | Remove from layout + relayout + focus recovery |

**RefreshReason → Route Mapping:**

Each `RefreshReason` maps to a route and a scheduling policy:

```
RefreshReason              → Route              → Scheduling
────────────────────────────────────────────────────────────
.startup                   → fullRescan          → plain
.appLaunched               → fullRescan          → plain
.activeSpaceChanged        → fullRescan          → plain
.layoutCommand             → immediateRelayout   → plain
.interactiveGesture        → immediateRelayout   → plain
.workspaceTransition       → immediateRelayout   → plain
.axWindowCreated           → relayout            → debounced(4ms)
.axWindowChanged           → relayout            → debounced(8ms, dropWhileBusy)
.windowDestroyed           → windowRemoval       → plain
.appHidden / .appUnhidden  → visibilityRefresh   → plain
```

**Coalescing:** If a refresh is already in progress, incoming requests are merged into a `pendingRefresh`. When the active refresh completes, the pending refresh fires. This prevents redundant layout calculations during bursts of events.

**Activation boundary:** Relayout may rediscover or sync windows that already existed before the current refresh. Those windows are inserted into the layout state, but automatic focus activation is only emitted for a newly synced window when its workspace is active on its monitor and that monitor is the current interaction monitor. Refreshing an inactive workspace must never steal focus or scroll the user away.

**DisplayLink Integration:** When animations are active (spring-based viewport scrolling, workspace switch effects), a `CADisplayLink` per display fires at the native refresh rate, driving per-frame layout recalculation.

### 3.5 Niri Layout Engine as a Pure State Machine

The Niri layout engine follows this contract:

1. It owns its own **tree data structures** (columns/windows)
2. They receive workspace geometry and gap configuration as input
3. They produce a `[WindowToken: CGRect]` frame dictionary as output
4. They **never touch windows directly** — no accessibility calls, no frame writes

This separation means layout logic can be unit-tested without any macOS UI or accessibility infrastructure. The `LayoutRefreshController` feeds workspace snapshots to the active engine and collects frame outputs, then `AXManager.applyFramesParallel()` writes the frames to actual windows.

When AX readback shows that a real app refused or clamped a requested resize, the refresh controller records an inferred runtime minimum (`inferredResizeMinimumSize`) on the window model, immediately clamps the affected Niri column away from the refused optimistic target, and requests an immediate relayout. The corrected minimum is fed into future layout snapshots, so the real accepted size—not substitute geometry—is used by the layout engine.

### 3.6 Thread Safety Model

**`@MainActor` everywhere.** Nearly all code in Nehir runs on the main thread, including:
- All UI code (AppKit, SwiftUI)
- All accessibility API calls
- All layout computation
- All event handling

**Exceptions:**
- **Per-app AX threads**: `AppAXContext` runs a dedicated thread per application for accessibility observer callbacks. These callbacks post back to the main actor.
- **IPC actors**: `IPCApplicationBridge` and `IPCEventBroker` are Swift actors handling concurrent client connections. They dispatch to `@MainActor` for any window management operations.
- **Lock-based Sendable types**: `CGSEventObserver` uses `OSAllocatedUnfairLock` for the pending event buffer that bridges between the SkyLight callback thread and the main thread.

---

## 4. Key Subsystems

### 4.1 WMController — The Orchestrator

**File:** `Sources/Nehir/Core/Controller/WMController.swift`

`WMController` is the central object that owns or references every major subsystem. It does NOT contain business logic itself — it delegates to specialized handlers.

**Handler constellation** (all lazy-initialized, all hold `weak var controller: WMController?`):

| Handler | Responsibility |
|---------|---------------|
| `commandHandler` | Routes `HotkeyCommand` cases to appropriate handler methods |
| `axEventHandler` | Processes window create/destroy events, manages replacement correlation |
| `mouseEventHandler` | CGEvent tap for mouse events, gestures, focus-follows-mouse |
| `mouseWarpHandler` | Warps cursor to focused window when configured; skipped for pointer/gesture-initiated focus and empty-workspace monitor transitions use center warp |
| `layoutRefreshController` | Refresh scheduling, DisplayLink animation, frame application |
| `workspaceNavigationHandler` | Workspace switching, window-to-workspace moves |
| `windowActionHandler` | Window close, fullscreen toggle, float toggle |
| `serviceLifecycleManager` | App lifecycle, observer setup, permission polling |
| `borderCoordinator` | Orchestrates border updates after layout/focus changes |
| `focusNotificationDispatcher` | Publishes focus change events to IPC subscribers |
| `diagnostics` (`RuntimeDiagnosticsCoordinator`) | Owns the diagnostics/trace surface: runtime-state dump/reset, trace capture toggling and export, the background trace clip buffer, viewport-mutation audit gating, and the debug snapshots behind the Diagnostics tab, DebugBar, command palette, and `nehirctl` debug endpoints |

**Core managers** (owned directly):

| Manager | Purpose |
|---------|---------|
| `settings: SettingsStore` | Persisted user configuration |
| `workspaceManager: WorkspaceManager` | Workspace definitions, window tracking, session state |
| `axManager: AXManager` | Per-app accessibility contexts, frame application |
| `focusBridge: FocusBridgeCoordinator` | Focus state machine with retry logic |
| `windowRuleEngine: WindowRuleEngine` | Window rule evaluation |
| `hotkeys: HotkeyCenter` | Global hotkey registration via Carbon |
| `borderManager: BorderManager` | Focus border window management |
| `niriEngine: NiriLayoutEngine?` | Niri layout state (nil if not in use) |
| `animationClock: AnimationClock` | Monotonic time source for animations |

### 4.2 Workspace & Window State

**WorkspaceManager** (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift`)

Owns workspace definitions, the window model, session state, monitor tracking, and the reconcile runtime used for debugging and relaunch restore behavior.

**Projection invalidation:** WorkspaceManager emits structured invalidations (`onProjectionInvalidated`, `onSessionStateChanged`) when its state mutates. WMController routes these to the appropriate consumers (workspace bar, status bar, IPC events) through a coalesced scheduling pipeline. See `ProjectionInvalidation.swift` for the invalidation kinds and `WMController.requestProjectionRefresh(_:)` for the routing table.

```
WorkspaceManager
├── monitors: [Monitor]                     Display geometry
├── workspacesById: [ID: WorkspaceDescriptor]   Workspace names & monitor assignments
├── windows: WindowModel                    All tracked windows
├── reconcileTrace / runtimeStore           Replayed runtime snapshot and trace state
├── restorePlanner                          Restore and rescue planning
├── bootPersistedWindowRestoreCatalog       Relaunch restore intents loaded from settings
├── globalStickyWindowTokens                Native cross-Space sticky tokens from topology
├── manualStickyWindowTokens                User-pinned sticky tokens
├── manualUnstickyWindowTokens              User opt-outs that beat automatic sticky sources
├── stickyFloatingPromotionTokens           Tiled sticky windows promoted to floating while sticky
├── session: SessionState                   Ephemeral runtime state
│   ├── monitorSessions: [MonitorID: MonitorSession]
│   │   ├── visibleWorkspaceId
│   │   └── previousVisibleWorkspaceId
│   ├── workspaceSessions: [WorkspaceID: WorkspaceSession]
│   │   └── niriViewportState: ViewportState?
│   ├── focus: FocusSession
│   │   ├── focusedToken: WindowToken?                  // exposed as confirmedManagedFocusToken
│   │   ├── pendingManagedFocus: PendingManagedFocusRequest
│   │   │   ├── token: WindowToken?                      // exposed as activeFocusRequestToken
│   │   │   ├── workspaceId: WorkspaceDescriptor.ID?
│   │   │   └── monitorId: Monitor.ID?
│   │   ├── lastTiledFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken]
│   │   ├── lastFloatingFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken]
│   │   ├── isNonManagedFocusActive
│   │   └── isAppFullscreenActive
│   ├── scratchpadToken: WindowToken?
│   └── interactionMonitorId: Monitor.ID?
└── nativeFullscreenRecords                 Fullscreen transition tracking
```

Post-`v0.4.5`, `WorkspaceManager` also owns the reconcile runtime. `RuntimeStore` and `ReconcileTraceRecorder` capture normalized window-management events into a replayable snapshot, exposed through `reconcileSnapshotDump()` and `reconcileTraceDump()` for IPC diagnostics. `PersistedWindowRestoreCatalog` stores relaunch restore intent such as workspace target, preferred monitor, and floating geometry so managed floating windows can be restored or rescued across launches.

**WindowModel** (`Sources/Nehir/Core/Workspace/WindowModel.swift`)

The single source of truth for all tracked windows. Each `Entry` contains:

```swift
struct Entry {
    let handle: WindowHandle
    let axRef: AXWindowRef
    var workspaceId: WorkspaceDescriptor.ID
    var mode: TrackedWindowMode          // .tiling or .floating
    var ruleEffects: ManagedWindowRuleEffects  // min sizes, sticky source
    var floatingState: FloatingState?    // Last frame, normalized position
    var hiddenReason: HiddenReason?      // .workspaceInactive, .layoutTransient, .scratchpad
    var manualLayoutOverride: ManualWindowOverride?
    // ... constraints, parent kind, layout reason
}
```

Entries are indexed by both `WindowToken` and raw `windowId` for fast lookup from different event sources. Sticky is intentionally modeled outside `TrackedWindowMode`: `WorkspaceManager.hasStickyWindowSource(_:)` answers whether a token has any native/rule/manual automatic source, while `isStickyWindow(_:)` applies the manual unsticky override to produce the effective visibility behavior used by layout and workspace-bar projection.

### 4.3 Niri Layout Engine (Scrolling Columns)

**Directory:** `Sources/Nehir/Core/Layout/Niri/`

Niri arranges windows in vertical columns that scroll horizontally, inspired by the [Niri](https://github.com/niri-wm/niri) Wayland compositor.

**Node Tree:**

```
NiriRoot (per workspace)
├── NiriContainer (column 1)
│   ├── NiriWindow (window A)
│   └── NiriWindow (window B)    ← stacked vertically
├── NiriContainer (column 2)
│   └── NiriWindow (window C)
└── NiriContainer (column 3)     ← can be tabbed
    ├── NiriWindow (window D)    ← active tab
    └── NiriWindow (window E)    ← hidden tab
```

All three types inherit from `NiriNode` (base class with `id: NodeId`, `parent`, `children`, `size`, `frame`).

**Key types:**

| Type | Purpose |
|------|---------|
| `NiriRoot` | Per-workspace container. Owns column list and node index. |
| `NiriContainer` | A column. Has `displayMode` (`.normal` or `.tabbed`), transient `usesOverflowTabbedMode`, `width: ProportionalSize`, canonical pixel `cachedWidth`, transient `loneWindowLayoutWidthOverride`, and `activeTileIdx`. |
| `NiriWindow` | Leaf node. Has `token: WindowToken`, `height: WeightedSize`, `constraints`. |
| `ProportionalSize` | `.proportion(CGFloat)` or `.fixed(CGFloat)` — column/window span; proportional spans use Niri-compatible gap accounting via `ProportionalSize.resolveProportionalSpan(...)` |
| `WeightedSize` | `.auto(weight:)` or `.fixed(CGFloat)` — window height within column |
| `ViewportState` | Horizontal scroll offset, selected node, active column, and transient FFM focus markers. View offset is `.static`, `.gesture(ViewGesture)`, or `.spring(SpringAnimation)` |
| `NodeId` | UUID-based identifier for tree nodes |

**Column width presets** cycle through configurable proportions (default: 1/3, 1/2, 2/3). Proportional spans are resolved as `(availableSpace - gap) * proportion - gap`; a contiguous group whose proportions sum to `1.0` therefore fits the viewport under Nehir's gap accounting without users compensating for gaps. Full-width mode expands a column to fill the monitor. `cachedWidth` is the canonical resolved column width used by normal multi-column layout and manual sizing; default lone-window fill/centered policy is stored separately as a transient `loneWindowLayoutWidthOverride`.

**Viewport scrolling:** The viewport tracks which columns are visible separately from the command/focus target. User gestures (trackpad swipe/scroll) drive the viewport via `ViewGesture` → `SwipeTracker`, which accumulates deltas and produces spring animations. Gesture release, viewport scroll commands, keyboard/AX reveal, resize adjustment, and column transitions share `ViewportSnapContext` snap geometry. During an active gesture Nehir keeps selection, border, hotkey target, and keyboard focus stable so the border does not jump under the fingers. On release, the viewport snaps to the nearest snap point unless the Manual Override modifier is held to bypass snap for that trackpad gesture. Focus-follows-mouse never reveals, relayouts, or scrolls the viewport; duplicate AX confirmations for an FFM target are treated as FFM for a short freshness window.

**Centralization boundaries:** Keep layout rules in their owning layer rather than re-deriving them in controllers.

| Rule family | Source of truth | Notes for contributors |
|-------------|-----------------|------------------------|
| Proportional width gap accounting | `ProportionalSize.resolveProportionalSpan(...)` | Do not duplicate `(availableSpace - gap) * proportion - gap`; Reveal Style `.auto` depends on the same `2 * gap` fit tolerance so 50% + 50% columns remain viewport-fitting. |
| Stacked/tiled secondary-axis sizing | `NiriAxisSolver` and the tabbed/shared-frame layout helpers | Inner gaps are between adjacent stacked tiles only (`count - 1` gaps). Top/bottom monitor-edge padding comes from outer gaps, not inner gap. |
| Snap points, viewport bounds, and full-width-column snap exceptions | `ViewportState+Geometry.swift` (`computeSnapGrid`, `viewportStartBounds`, `boundedViewportStart(...)`) and `ViewportSnapContext` | Gesture release, scroll commands, reveal, resize adjustment, and column transitions must share this geometry. Do not add ad-hoc `±gap` snaps elsewhere; columns that approximately fill the viewport intentionally omit synthetic edge snaps that would only lose margins, while over-wide columns keep theirs so clipped content stays reachable. Lone-window snap/bounds math must use `NiriContainer.effectiveViewportWidth`, not raw `cachedWidth`, so transient fill/centered render width and canonical multi-column width stay separated. |
| Lone-window viewport rect and render offset | `SingleWindowViewportGeometry` plus `singleWindowViewportGeometry(...)`, `resolvedSingleWindowViewportRect(...)`, `prepareSingleWindowViewport(...)`, and `prepareAndSeedSingleWindowViewport(...)` in `NiriLayout.swift` | Controllers may prepare/seed geometry, but must not re-derive centered width, center offset, rendered frame offset, or lone-window scrollable span. Lone-window rendering follows the raw viewport offset; the shared snap grid decides where it settles. Single-column workspaces use the same far-overscroll boundary points as multi-column strips, so strong swipes can settle with only an edge sliver visible. Default fill/centered width goes into `loneWindowLayoutWidthOverride`; manual width remains canonical `cachedWidth`. |
| Monitor-aware gap resolution | `SettingsStore.resolvedGapSettings(for:)`, exposed at runtime through `WMController.gapSize(for:)` and `WMController.outerGaps(for:)` | Use these helpers when a monitor is known. Direct `workspaceManager.gaps` / `workspaceManager.outerGaps` access should be limited to no-monitor fallback paths. |
| Monitor-aware Niri settings and lone-window override resolution | `SettingsStore.resolvedNiriSettings(for:)` and `MonitorNiriSettings.loneWindowPolicy` | `nil` means inherit global policy; `.fill` and `.centered(maxWidthFraction:)` are explicit per-monitor overrides. Do not infer override mode from nullable centered width. |

**File Organization:**

The Niri directory is the largest subsystem. Files are organized by responsibility:

| Category | Files | Purpose |
|----------|-------|---------|
| Core engine | `NiriLayoutEngine.swift`, `NiriNode.swift`, `NiriLayout.swift` | Engine class, node tree (Root/Container/Window), pixel-rounding utilities |
| Navigation | `NiriNavigation.swift` | Focus movement between columns and windows |
| Constraint solving | `NiriConstraintSolver.swift` | `NiriAxisSolver` distributes space among windows respecting min/max size constraints |
| Monitor model | `NiriMonitor.swift` | Per-monitor state: geometry, workspace roots, workspace switch animation |
| Viewport | `ViewportState.swift`, `+Animation`, `+ColumnTransitions`, `+Geometry`, `+Gestures` | Horizontal scroll offset, spring physics, gesture tracking |
| Interactive move | `InteractiveMove.swift`, `+InteractiveMove`, `DragGhostController.swift`, `DragGhostWindow.swift`, `SwapTargetOverlay.swift` | Mouse-driven window dragging with ghost thumbnail and swap target indicators |
| Interactive resize | `InteractiveResize.swift`, `+InteractiveResize` | Mouse-driven edge resizing with `ResizeEdge` option set |
| Engine extensions | `+Animation`, `+ColumnOps`, `+Monitors`, `+Sizing`, `+TabbedMode`, `+WindowOps`, `+Windows`, `+WorkspaceOps` | Modular engine operations (see [6.4](#64-modifying-layout-behavior)) |
| UI overlays | `TabbedColumnOverlay.swift` | Visual indicator for tabbed columns |
| Overview bridge | `NiriOverviewSnapshot.swift` | Produces layout snapshots for the Overview renderer |

**Interactive Move/Resize:** Users can drag windows between columns using Option+Shift+click. `InteractiveMove` tracks the drag state (origin column, hover target). `DragGhostController` captures a `ScreenCaptureKit` thumbnail of the dragged window and displays it as a semi-transparent ghost. `SwapTargetOverlay` highlights the drop target. On release, the engine performs a column insertion or window swap. Interactive resize (`InteractiveResize`) allows edge-dragging to change column widths or window heights.

**Constraint Solving:** `NiriAxisSolver` (in `NiriConstraintSolver.swift`) distributes available space among windows in a column while respecting per-window min/max size constraints. Windows with `isConstraintFixed` get exact sizes; remaining space is distributed by weight. This runs during every layout calculation and handles edge cases like tabbed columns (all windows share the same height).

**Overflow tabbing:** If the sum of stacked windows' minimum heights plus gaps exceeds the current column height (or, on vertically oriented monitors, minimum widths plus gaps exceed the current column width), a normal column enters transient `usesOverflowTabbedMode`. This makes the column behave like tabbed for that layout pass without changing its persisted `displayMode`, preventing impossible stack geometry and WindowServer position clamps. The overflow state is computed before hidden/offscreen column placement, so returning from offscreen should already have the correct tabbed frames. If the user toggles tabbed mode while this state is active, Nehir splits the windows into separate columns only when the stacked layout still overflows; otherwise it simply clears the transient forced-tab state and preserves the column.

### 4.4 Focus Lifecycle

**File:** `Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift`

Focus management is complex because Nehir must coordinate its own command target with what macOS actually does. Nehir intentionally separates these concepts:

- **Command/border target** (`WMCommandTarget` and `currentBorderTarget()`): the managed window Nehir commands and the visual border should point at.
- **Confirmed managed focus** (`confirmedManagedFocusToken`): the managed window macOS has actually confirmed through focus observation.
- **Active focus request** (`activeFocusRequestToken`): transient retry/fronting state while Nehir is asking macOS to focus a window.
- **Interaction workspace/monitor** (`interactionWorkspace()`): the workspace context used for commands and routing.

The `FocusBridgeCoordinator` manages the request/confirmation part of this model:

**The Deferred Focus Pattern:**

```
1. User presses focus-left
2. CommandHandler identifies target window
3. FocusBridgeCoordinator.beginManagedRequest(token, workspaceId)
   → Creates an active focus request with status = .pending
4. Private APIs activate the target app + window
   (_SLPSSetFrontProcessWithOptions, makeKeyWindow)
5. macOS confirms focus via AX callback
6. FocusBridgeCoordinator.confirmManagedRequest(token, source)
   → Marks request as .confirmed
   → If no confirmation within retries, re-attempts activation
```

**Key types:**

| Type | Purpose |
|------|---------|
| `KeyboardFocusTarget` | Resolved focus: `token`, `axRef`, `workspaceId`, `isManaged` |
| `ManagedFocusRequest` | In-flight request with `requestId`, `retryCount`, `status` (`.pending`/`.confirmed`) |
| `ActivationEventSource` | How focus was confirmed: `.focusedWindowChanged` (authoritative), `.workspaceDidActivateApplication`, `.cgsFrontAppChanged` |

**Focus serialization:** `focusWindow(_:performFocus:onDeferredFocus:)` serializes focus operations. If a focus request arrives while one is in-flight, it queues as the active focus request successor and fires after the current request completes or times out.

**Close/hide focus recovery:** When the focused window closes, hides, collapses, or otherwise loses AX focus, the OS can immediately report a different managed window as focused. For terminals and apps with dropdown/quick-terminal surfaces, that replacement focus often points at another workspace or parked column. Nehir treats this as a native fallback, not as user navigation, unless it matches an explicit `ManagedFocusRequest`.

Recovery is deliberately short-lived and signal-driven:

- tracked focused-window destroy;
- untracked auxiliary same-pid destroy (common for dropdown helper AX elements);
- focused-window loss from `AXFocusedWindowChanged window=nil`;
- the confirmed managed window becoming hidden while its workspace is active.

During the `windowCloseFocusRecovery` lease, unrelated activations off the recovery workspace are suppressed. Same-workspace activations for a different token are also suppressed when they are native fallbacks rather than requests. Because macOS can report the successor `workspaceDidActivateApplication` before the close signal, Nehir briefly defers ambiguous inactive-workspace native activations and retries them; if recovery armed in the meantime they are suppressed, otherwise the retry proceeds.

### 4.5 Input Handling

**Hotkeys** (`Sources/Nehir/Core/Input/`)

`ActionCatalog` is the source of truth for all hotkey-triggerable actions (90+, several generated per-workspace/per-direction). It defines each action's title, category, layout compatibility, search terms, default and alternate bindings, and optional IPC command linkage. `HotkeyBinding` persists a single binding per action, and `HotkeyBindingRegistry` canonicalizes settings data.

`HotkeyCenter` registers each key+modifiers combination via Carbon's `RegisterEventHotKey` API. Actions are still tagged with layout compatibility:

- `.shared` — works with any layout (focus, move, workspace switch, float, scratchpad, UI toggles)
- `.niri` — Niri-only (moveColumn, toggleColumnTabbed, focusPrevious, cycleColumnWidth)

**Command routing** (`Sources/Nehir/Core/Controller/CommandHandler.swift`)

`CommandHandler.performCommand()` is a switch statement over all `HotkeyCommand` cases, delegating to the appropriate handler. It first checks layout compatibility.

**Mouse events** (`Sources/Nehir/Core/Controller/MouseEventHandler.swift`)

Uses `CGEventTap` for system-wide mouse event interception:
- **Focus-follows-mouse**: Debounced (100ms) focus change on mouse hover. Re-evaluated after scroll/swipe animation settles and after owned Nehir UI windows close, because those paths may not emit a fresh mouse-move event. Tiled hover activation is disabled while a tracked floating window is the active surface above the Niri layout, but a floating window merely visible behind the active tiled window does not block hover focus. Hover activation is also blocked when the pointer is over a visible unmanaged WindowServer window, and briefly suppressed after floating/unmanaged pointer interaction so clicking or dragging those windows does not immediately activate a tiled column behind them.
- **Trackpad gestures**: Three-phase state machine (`idle` → `armed` → `committed`) for horizontal viewport scrolling and workspace switching. Niri viewport gestures snap through `ViewportSnapContext` on release unless the Manual Override modifier is held for snap bypass. Gesture-selected focus suppresses cursor warp so the cursor does not jump to the focused column. When `focusFollowsMouse` is enabled, gesture end updates viewport selection without forcing managed focus; pointer hover decides final focus after the gesture/animation settles.
- **Interactive move/resize**: Option+Shift+drag for window repositioning
- **Event coalescing**: Transient mouse events are batched and drained in coalesced bursts
- **Cursor warp suppression**: `moveMouseToFocusedWindow` is treated as a keyboard/command-navigation affordance. Pointer-initiated focus (hover, window click, floating click/drag, workspace bar click, tab overlay click) and gesture/scroll-initiated focus suppress warping via `suppressMouseMoveToFocusedWindow(for:)`, so the cursor does not jump under the user's hand. Empty-workspace monitor switches are the exception: with no focused window target, command navigation warps to the target monitor center.

**SkyLight events** (`Sources/Nehir/Core/SkyLight/CGSEventObserver.swift`)

Registers for window server notifications via private APIs:

```swift
enum CGSWindowEvent {
    case created(windowId, spaceId)
    case destroyed(windowId, spaceId)
    case frameChanged(windowId)
    case closed(windowId)
    case frontAppChanged(pid)
    case titleChanged(windowId)
}
```

Events are buffered in a lock-protected `PendingCGSEventState` and drained on the main run loop via `CFRunLoopPerformBlock`. Frame change events are coalesced by windowId.

### 4.6 Window Rules Engine

**File:** `Sources/Nehir/Core/Rules/WindowRuleEngine.swift`

Evaluates windows against rules to produce a `WindowDecision`. Evaluation order (first match wins):

1. **User manage-ignore rules** — `manage = "ignore"` is a management decision and wins over manual layout overrides and all other effects.
2. **Manual overrides** — user has explicitly toggled float/tile on this window; manual overrides can beat built-in unmanaged decisions for user-addressable non-standard surfaces.
3. **User-defined rules** — configured in settings, matching on bundle ID, app name, title (literal or regex), AX role/subrole
4. **Built-in rules** — hardcoded rules for known system UI and PiP/default-sticky candidates
5. **Heuristics** — size constraints, window role/subrole analysis

**Key types:**

```swift
struct WindowDecision {
    let disposition: WindowDecisionDisposition  // .managed, .floating, .unmanaged, .undecided
    let source: WindowDecisionSource            // .manualOverride, .userRule(UUID), .builtInRule, .heuristic
    let workspaceName: String?                  // Target workspace (if rule specifies)
    let ruleEffects: ManagedWindowRuleEffects   // minWidth, minHeight, sticky
}

struct WindowRuleFacts {
    let appName: String?
    let ax: AXWindowFacts           // role, subrole, title, buttons
    let sizeConstraints: WindowSizeConstraints?
    let windowServer: WindowServerInfo?
}
```

### 4.7 IPC System

For the protocol specification, wire format, and CLI command reference, see [IPC-CLI.md](IPC-CLI.md). This section covers the internal code architecture.

```
nehirctl                         Nehir process
─────────                         ──────────────
CLIParser                         IPCServer
    │                                 │
CLIRuntime                        acceptConnections() on DispatchQueue
    │                                 │
IPCClient ──── Unix Socket ────► IPCConnection (per client)
  (NDJSON)                            │
                                 IPCApplicationBridge (actor)
                                      │ auth check, protocol version
                                      │
                              ┌───────┼───────┐
                              │       │       │
                     IPCCommand  IPCQuery  IPCRule
                      Router     Router    Router
                              │       │       │
                              └───────┼───────┘
                                      │  @MainActor
                                      v
                                 CommandHandler /
                                 WorkspaceManager /
                                 WindowRuleEngine
```

**Key actors:**
- `IPCApplicationBridge` — Swift actor that receives deserialized requests, checks authorization, and dispatches to the appropriate router on `@MainActor`
- `IPCEventBroker` — Swift actor managing event subscriptions. Uses `AsyncStream` with continuations per channel per connection. `IPCEventDemandTracker` tracks whether any client is subscribed to a channel (so events aren't computed when nobody is listening)

**Public surface registry:** `IPCAutomationManifest` is the source of truth for public IPC commands, queries, rule actions, subscriptions, and CLI discoverability metadata (including completion/help surfaces). The routers execute the behavior; the manifest defines what is exposed.

**Security:** The trust boundary is the local macOS user account, not individual client processes. Each request carries a per-session authorization token stored in plaintext at `<socket-path>.secret`; the server also enforces socket permissions `0o600`, creates new socket directories with `0o700`, and verifies peer UID via `getpeereid()`. If `NEHIR_SOCKET` points into an existing directory, Nehir reuses that directory as-is instead of re-permissioning it, so custom socket paths should live in a private directory owned by the same user.

### 4.8 Accessibility Layer

**File:** `Sources/Nehir/Core/Ax/AXManager.swift`

**Per-app threading model:** `AXManager` maintains an `AppAXContext` per process. Each context runs an AX observer on a dedicated thread to receive accessibility callbacks (focused-window-changed, window-destroyed).

**Frame application pipeline** (`applyFramesParallel()`):

1. Collect requested frames from the layout engine: `[WindowToken: CGRect]`
2. Deduplicate against `lastAppliedFrames` — skip windows whose frame hasn't changed
3. Group frames by PID into `framesByPidBuffer`
4. Dispatch frame writes to per-app contexts in parallel (each with 0.5s timeout)
5. Each context writes size then position (or vice versa) to the `AXUIElement`
6. Collect `AXFrameWriteResult` with any errors
7. Track `recentFrameWriteFailures` for retry budgeting

**Inactive workspace suppression:** Windows on non-visible workspaces are tracked in `inactiveWorkspaceWindowIds`. Frame writes to these windows are skipped, preventing unnecessary AX API calls and visual glitches.

### 4.9 Animation System

**Directory:** `Sources/Nehir/Core/Animation/`

**SpringAnimation** — critically-damped spring physics for smooth, responsive motion:

```swift
struct SpringConfig {
    // Presets:
    static let niriHorizontalViewMovement = SpringConfig(dampingRatio: 1.0, stiffness: 800.0, epsilon: 0.0001)
    static let niriWindowMovement = SpringConfig(dampingRatio: 1.0, stiffness: 800.0, epsilon: 0.0001)
    static let niriWindowResize = SpringConfig(dampingRatio: 1.0, stiffness: 800.0, epsilon: 0.0001)
}
```

Used for: Niri viewport scrolling, column movement, column resize, tabbed/new-window transitions, and window close animations.


**AnimationClock** — monotonic time wrapper around `CACurrentMediaTime()`.

**DisplayLink integration:** `LayoutRefreshController` manages a `CADisplayLink` per display. On each frame tick, it recalculates animated layouts and applies frames, producing 60/120Hz smooth animations.

**Accessibility:** All animation configs support `resolvedForReduceMotion()`, which returns the `reducedMotion` preset when the user has enabled "Reduce Motion" in macOS accessibility settings.

### 4.10 Border System

**Files:** `Sources/Nehir/Core/Border/BorderManager.swift`, `BorderWindow.swift`

A lightweight `NSWindow` overlay that draws a rounded rectangle around the focused window:

- `BorderManager` tracks the current focused window's frame and windowId
- `BorderWindow` renders the border using SkyLight private APIs for window ordering (stays above managed windows but below floating panels)
- Deduplication: skips updates if windowId and frame haven't changed (0.5pt tolerance)
- Configurable: enable/disable, width (points), color (RGBA)

### 4.11 Additional Features

| Feature | Key Files | Description |
|---------|-----------|-------------|
| **Overview** | `Core/Overview/OverviewController.swift` | Bird's-eye view of all workspaces with window thumbnails (ScreenCaptureKit), search, drag-to-reorganize |
| **Command Palette** | `UI/CommandPalette/CommandPaletteController.swift` | Fuzzy-search interface for windows, commands, and menu items |
| **Menu Anywhere** | `UI/MenuAnywhere/MenuAnywhereController.swift` | UI controller that uses the Core menu extraction layer to display any app's menu at cursor position |
| **Workspace Bar** | `UI/WorkspaceBar/WorkspaceBarManager.swift` | Visual workspace indicators with window icons per workspace. Clicks route by `WorkspaceDescriptor.ID` rather than display label so UI labels can change without changing activation identity. |
| **Scratchpad** | `Core/Workspace/WorkspaceManager.swift` | Tracks the transient scratchpad window via `scratchpadToken()`. Show/hide and focus recovery are coordinated by `WMController`. |
| **Status Bar** | `UI/StatusBar/StatusBarController.swift` | Menu bar icon with settings access and workspace summary |

Nehir utility windows such as Settings and App Rules still register through `OwnedWindowRegistry`, but that type now acts as a facade over `SurfaceCoordinator` and `SurfaceScene`. The shared surface system assigns each owned UI surface a `SurfaceKind` and `SurfacePolicy`, centralizing hit-testing, screen-capture inclusion, and managed-focus-recovery suppression across overview, workspace bar, border, and utility windows.

---

## 5. Data Flow Diagrams

### 5.1 Hotkey Command Flow

User presses a hotkey (e.g., Option+Command+Left Arrow to focus left):

```
Carbon EventHandler callback
    │
    v
HotkeyCenter.dispatch(id)
    │ lookup HotkeyCommand by registration ID
    v
CommandHandler.handleCommand(.focus(.left))
    │ check: isEnabled? overview open?
    v
NiriLayoutHandler.focusNeighbor(direction: .left)
    │ determines target window in the Niri tree
    v
FocusBridgeCoordinator.focusWindow(targetToken)
    │ activates app + window via private APIs
    v
LayoutRefreshController.scheduleRefresh(.immediateRelayout, reason: .layoutCommand)
    │
    v
NiriLayoutEngine.calculateLayout(...)
    │ produces [WindowToken: CGRect]
    v
AXManager.applyFramesParallel(frames)
    │ writes new positions to windows
    v
BorderCoordinator.updateBorder(for: targetToken)
    │ moves border to newly focused window
    v
FocusNotificationDispatcher.publish(focusEvent)
    │ notifies IPC subscribers
    v
Done
```

### 5.2 External Window Event Flow

An application opens a new window:

```
macOS window server creates window
    │
    v
CGSEventObserver receives .created(windowId, spaceId)
    │ buffered in PendingCGSEventState (lock-protected)
    │ drained via CFRunLoopPerformBlock on main thread
    v
AXEventHandler.handleWindowCreated(windowId)
    │ creates AXWindowRef from AXUIElement
    │ queries: role, subrole, title, buttons, size
    v
WindowRuleEngine.evaluate(facts)
    │ returns WindowDecision (.managed / .floating / .unmanaged)
    v
WindowModel.track(handle, axRef, workspaceId, mode)
    │ creates Entry, indexes by token and windowId
    v
NiriLayoutEngine.insertWindow(token, into: workspaceRoot)
    │ creates NiriWindow node, appends to active column or new column
    v
LayoutRefreshController.scheduleRefresh(.relayout, reason: .axWindowCreated)
    │ debounced: 4ms
    v
Layout calculation → AXManager.applyFramesParallel()
    │
    v
All windows repositioned to accommodate the new one
```

### 5.3 IPC Command Flow

User runs `nehirctl command focus left`:

```
CLIParser.parse(["command", "focus", "left"])
    │ produces IPCRequest { kind: .command, payload: .command(.focus(direction: .left)) }
    v
IPCClient connects to Unix socket (~/.../ipc.sock)
    │ sends NDJSON: {"version":3,"id":"...","kind":"command","authorizationToken":"...","payload":{"name":"focus","arguments":{"direction":"left"}}}\n
    v
IPCServer accepts connection → IPCConnection reads line
    │ deserializes to IPCRequest
    v
IPCApplicationBridge.response(request) [actor]
    │ verifies authorization token
    │ checks protocol version
    v
IPCCommandRouter.handle(.focus(direction: .left)) [@MainActor]
    │ maps to HotkeyCommand.focus(.left)
    v
CommandHandler.performCommand(.focus(.left))
    │ (same flow as hotkey from here — see 5.1)
    │ returns ExternalCommandResult
    v
IPCResponse { ok: true } → serialized as NDJSON → sent to client
    v
CLIRenderer displays result
```

---

## 6. Common Contribution Patterns

### 6.1 Adding a New Hotkey Command

1. **Add the enum case** in `Sources/Nehir/Core/Input/HotkeyCommand.swift`:
   ```swift
   case myNewCommand
   ```

2. **Handle it** in `Sources/Nehir/Core/Controller/CommandHandler.swift`:
   ```swift
   case .myNewCommand:
       // implementation or delegation to a handler
   ```

3. **Add the action spec** in `Sources/Nehir/Core/Input/ActionCatalog.swift` so the command has its title, category, search metadata, and default or alternate bindings. `DefaultHotkeyBindings.swift` is only a thin wrapper over this catalog.

4. **Expose via IPC** in `Sources/Nehir/IPC/IPCCommandRouter.swift` — add the routing to the new command when it should be scriptable.

5. **Add CLI support** in `Sources/NehirCtl/CLIParser.swift` — add the command name.

6. **Update the automation manifest** in `Sources/NehirIPC/IPCAutomationManifest.swift` — add the command description.

Actions can carry multiple persisted bindings, so any extra default shortcuts should be modeled in `ActionCatalog` rather than as separate commands.

### 6.2 Adding a New IPC Query

1. **Define the response model** in `Sources/NehirIPC/IPCModels.swift`.

2. **Implement the query** in `Sources/Nehir/IPC/IPCQueryRouter.swift`:
   ```swift
   case "my-query":
       let result = // gather data from WorkspaceManager, etc.
       return .success(result)
   ```

3. **Add CLI rendering** in `Sources/NehirCtl/CLIRenderer.swift` — format the response for terminal output.

4. **Add CLI parsing** in `Sources/NehirCtl/CLIParser.swift` — add the query name.

5. **Update the manifest** in `Sources/NehirIPC/IPCAutomationManifest.swift`.

### 6.3 Adding a New Setting

1. **Add the property** to `Sources/Nehir/Core/Config/SettingsStore.swift`.

2. **Wire the runtime behavior** in `WMController.applyPersistedSettings()` or the relevant handler that consumes the setting.

3. **Add UI** in the appropriate settings tab under `Sources/Nehir/UI/`.

4. **Update the TOML settings model** in `Sources/Nehir/Core/Config/SettingsExport.swift`, `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`, and `Sources/Nehir/Core/Config/SettingsTOMLCodec.swift` for persisted user preferences that belong in editable config. Keep runtime cache state out of editable config.

5. **Check settings-file touchpoints** when the change affects config discoverability or UX. `Sources/Nehir/UI/SettingsFileWorkflow.swift` is the open/reveal workflow layer; config file access for users is via the **Config Files** submenu in the status bar menu. Most new settings do not need workflow code changes, but contributor-facing config behavior and copy should remain accurate.

6. **Add round-trip coverage** in tests: verify the setting survives store load/save and TOML encode/decode so it cannot silently disappear from `~/.config/nehir/settings.toml`.

### 6.4 Modifying Layout Behavior

1. **Identify the engine**: Niri code is in `Sources/Nehir/Core/Layout/Niri/`.

2. **Find the relevant extension**: Niri splits logic across extensions:
   - `NiriLayoutEngine+Animation.swift` — animation tick and spring updates
   - `NiriLayoutEngine+ColumnOps.swift` — column add/remove/reorder
   - `NiriLayoutEngine+InteractiveMove.swift` — mouse-driven window moving
   - `NiriLayoutEngine+InteractiveResize.swift` — mouse-driven edge resizing
   - `NiriLayoutEngine+Monitors.swift` — multi-monitor layout
   - `NiriLayoutEngine+Sizing.swift` — width/height calculation
   - `NiriLayoutEngine+TabbedMode.swift` — tabbed column logic
   - `NiriLayoutEngine+WindowOps.swift` — window insert/remove/reorder
   - `NiriLayoutEngine+Windows.swift` — window query and lookup
   - `NiriLayoutEngine+WorkspaceOps.swift` — workspace-level operations

   Focus navigation lives in `NiriNavigation.swift`. Constraint solving lives in `NiriConstraintSolver.swift`.

3. **Write tests** using existing helpers. Layout engines can be tested in isolation — create nodes, call `calculateLayout()`, assert frame positions.

### 6.5 Working with Private APIs

Nehir uses SkyLight (private macOS framework) for low-latency window operations. The wrapper pattern is:

1. **Function declarations** use `@_silgen_name` in `Sources/Nehir/Core/PrivateAPIs.swift`
2. **Dynamic loading** via `dlopen`/`dlsym` in `Sources/Nehir/Core/SkyLight/SkyLight.swift` for functions that can't use `@_silgen_name`
3. All private API usage is wrapped in safe Swift functions with fallback behavior

**Risk model:** Private APIs can break across macOS versions. When adding new private API usage, provide a fallback path using public APIs where possible, and test across macOS versions.

---

## 7. Testing

**Runner:** `swift test` via SwiftPM. Requires macOS 15+.

**Test directory:** `Tests/NehirTests/`

**Test patterns:**

| Pattern | Used For | Example |
|---------|----------|---------|
| Direct unit tests | Layout engines, animation math, rule evaluation | Create nodes, call `calculateLayout()`, assert frames |
| DI via closures | Controllers, handlers | `nativeFullscreenStateProvider`, `frameApplyOverrideForTests` |
| Debug hooks | Refresh pipeline | `RefreshDebugHooks.onFullRescan`, `onRelayout` |
| In-process IPC | IPC protocol, routing | Create socket pair, send/receive in-process |

**Key test support files:**
- `TestSharedStateSupport.swift` — shared test fixtures
- `TokenCompatibilityTestSupport.swift` — window token creation helpers
- `LayoutPlanTestSupport.swift` — layout test utilities
- `MotionTestSupport.swift` — animation/motion test utilities

**What's hard to test:** Anything requiring live accessibility permissions or actual window manipulation. These are covered by the override/hook pattern — production code checks for test overrides (closures/hooks) and uses them instead of real system calls.

---

## 8. Glossary

| Term | Definition |
|------|-----------|
| `WindowToken` | Value type (`pid` + `windowId`) identifying a window. Used as dictionary keys throughout. |
| `WindowHandle` | Reference-type wrapper around `WindowToken`. Identity-compared (`===`). Used in layout trees. |
| `AXWindowRef` | Accessibility bridge (`AXUIElement` + `windowId`) for reading/writing window properties. |
| `TrackedWindowMode` | `.tiling` or `.floating` — whether a tracked window participates in tiling or independent floating placement. Sticky is not a third mode. |
| `ManagedWindowRuleEffects` | Rule/effective overlays attached to a tracked window, including minimum size constraints and sticky visibility. |
| `WorkspaceDescriptor` | A workspace definition: `id` (UUID), `name`, optional `assignedMonitorPoint`. |
| `SessionState` | Ephemeral runtime state in `WorkspaceManager`: focused window, visible workspace per monitor, viewport states. |
| `NiriRoot` / `NiriContainer` / `NiriWindow` | The three-level Niri layout tree: root → columns → windows. |
| `ViewportState` | Niri's horizontal scroll state: `.static`, `.gesture`, or `.spring`. |
| `LayoutRefreshController` | Central refresh coordinator. Schedules, debounces, and coalesces layout recalculations. |
| `RefreshReason` | Why a refresh was requested (e.g., `.axWindowCreated`, `.layoutCommand`). Maps to a refresh route. |
| `RefreshRoute` | How the refresh executes: `fullRescan`, `relayout`, `immediateRelayout`, `visibilityRefresh`, `windowRemoval`. |
| `ManagedFocusRequest` | In-flight focus request with status (`.pending`/`.confirmed`) and retry tracking. |
| `FocusBridgeCoordinator` | Focus state machine coordinating Nehir's focus intent with macOS confirmation. |
| `CGSEventObserver` | SkyLight event listener for window create/destroy/frame-change/front-app-change. |
| `HotkeyCommand` | Enum of all commands that can be triggered by hotkeys or IPC. |
| `IPCApplicationBridge` | Swift actor routing IPC requests to `@MainActor` command/query/rule handlers. |
| `IPCEventBroker` | Swift actor managing real-time event subscriptions for IPC clients. |
| `ProportionalSize` | `.proportion(CGFloat)` or `.fixed(CGFloat)` — Niri column width specification. |
| `WeightedSize` | `.auto(weight:)` or `.fixed(CGFloat)` — Niri window height within a column. |
| `NodeId` | UUID-based identifier for Niri layout tree nodes. |
| `SpringConfig` | Spring parameters: `dampingRatio` controls oscillation damping (`1.0` is critically damped), `stiffness` controls how aggressively the spring accelerates toward its target, `epsilon` is the completion displacement threshold, and `velocityEpsilon` is the completion velocity threshold. Niri presets: `niriHorizontalViewMovement` controls viewport/column scrolling, `niriWindowMovement` controls window/column movement springs, and `niriWindowResize` controls column width resize springs. |
| `WindowDecision` | Result of rule evaluation: `disposition`, `source`, `workspaceName`, `ruleEffects`. |
| `WindowRuleFacts` | Input for rule evaluation: app name, AX facts (role, subrole, title), size constraints, and WindowServer evidence used for PiP/default-sticky classification. |
| `Sticky window` | A managed window with an effective cross-workspace visibility effect from native sticky state, rules, PiP defaults, or manual toggles. Manual unsticky wins for effective behavior. |
| `Scratchpad` | A special slot for a single transient window that can be toggled in/out of view. |
