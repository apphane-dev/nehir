# Control Center Widget Support — Discovery

Groom 2026-07-07: still applicable — feasibility study; not yet pursued (pure-SPM packaging model unchanged) (verified against main 7a025b78).

Discovery (2026-06-14) into whether Nehir can ship a custom **Control Center
widget**. Short answer: **not today, and not from the current build pipeline.**
It is feasible to add, but it is a build-system + integration project, not a
small feature. This doc captures the constraints, the decisive blocker (with
evidence from a structurally identical project), the integration design, and
scope options.

All file references should be re-verified before implementing; line numbers drift.

---

## TL;DR

- **No widget code exists.** No `WidgetKit` / `ControlWidget` / `AppIntent` /
  `appex` / `NSExtension` references anywhere in `Sources/`.
- **"Control Center widget" is two different things** with different version
  floors (see [Terminology](#terminology)). The Control Center *control*
  (toggle/button in the Control Center pane — almost certainly what is meant)
  requires **macOS 26 (Tahoe)**, which is *above* Nehir's current
  `.macOS(.v15)` deployment target.
- **Decisive blocker:** Nehir is a pure SwiftPM package whose `.app` is
  hand-assembled by `.config/mise/tasks/package/release`. SwiftPM has no
  first-class app-extension target, and on macOS 26 a hand-wrapped `.appex`
  built from a SwiftPM `.executableTarget` **exits cleanly without serving
  descriptors** — verified in a directly parallel project (CodexBar, see
  [Evidence](#decisive-blocker-swift-pm-cannot-emit-a-working-appex-on-macos-26)).
  A real Xcode `com.apple.product-type.app-extension` target is required.
- **Secondary requirements:** an App Group + shared container, new entitlements,
  a host↔extension IPC bridge (Nehir's current per-session Unix socket is not
  reachable from a sandboxed extension as-is), and a bump to the deployment
  target for true Control Center controls.
- **It is a clean fit *architecturally*:** Nehir already exposes a rich, versioned
  IPC command/query surface (`NehirIPC` + `nehirctl`) that an `AppIntent` could
  drive, and live workspace/window snapshots a widget could render.

---

## Terminology

"Control Center widget" is ambiguous. Two distinct Apple APIs:

| Kind | API | Min macOS | What it is |
|---|---|---|---|
| **Control Center control** | `WidgetKit.ControlWidget`, `ControlWidgetToggle`, `ControlWidgetButton`, `AppIntentControlConfiguration` | **macOS 26 (Tahoe)** | A toggle/button living *in the Control Center pane* (also Lock Screen / Action button). Performs an action via `AppIntent`. |
| **Widget / Notification Center / desktop widget** | `WidgetKit.Widget`, `WidgetBundle`, `StaticConfiguration` / `AppIntentConfiguration` | macOS 14 (v15 target covers it) | A card in the widget gallery / Notification Center / desktop. Renders read-mostly content via a `TimelineProvider`. |

This doc assumes the question means a **Control Center control** (the thing that
makes sense for a window manager: quick toggles/actions). If the ask is the
second kind, the version floor is already satisfied and the rest of the analysis
(appex build, app group, IPC bridge) still applies — minus the deployment-target
bump.

---

## Current State of Nehir (what exists, what blocks)

### Build & packaging model

- Pure SwiftPM package (`Package.swift`), deployment target **`.macOS(.v15)`**,
  Swift 6.3.2 (`.swift-version`). No `.xcodeproj`; only the generated
  `.swiftpm/xcode/package.xcworkspace`.
- The `.app` is **hand-assembled** by `.config/mise/tasks/package/release`:
  `swift build -c release --arch arm64 --arch x86_64`, then manual
  `mkdir Contents/MacOS`, `mkdir Contents/Resources`, copy executables +
  `Info.plist` + `AppIcon.icns` + `Nehir_Nehir.bundle`. There is **no
  `Contents/PlugIns/`** and no embedded extension step.
- Codesign + notarization are scripted (`codesign --options runtime`, Developer
  ID, `notarytool`, `stapler`). The `install` mise task and the Homebrew cask
  both consume `dist/Nehir.app`.
- Host app is `LSUIElement` (`Info.plist`) with `.accessory` activation policy
  (`Sources/Nehir/App/AppDelegate.swift`) — a menu-bar/status agent with no Dock
  icon. SwiftUI `@main NehirApp` only provides the `Settings` scene.

### Entitlements & sandbox

- `Nehir.entitlements` grants only `com.apple.security.automation.apple-events`.
  **No App Group, no sandbox** (host is unsandboxed so it can drive AX).
- No `app-group`, `NSXPCConnection`, or Mach-service references anywhere in
  `Sources/` (grep confirmed).

### IPC surface (the natural integration point)

Nehir already has a strong, versioned automation surface that a widget would
reuse:

- Per-user Unix socket at
  `~/Library/Caches/dev.guria.nehir/ipc.sock` (mode `0600`), authorized by
  `getpeereid()` UID check **plus a per-session token** written to
  `ipc.sock.secret` — `Sources/NehirIPC/IPCSocketPath.swift`,
  `Sources/Nehir/IPC/IPCServer.swift`.
- A large command registry declared in
  `Sources/NehirIPC/IPCAutomationManifest.swift`: focus, move, column ops,
  workspace switching (`switch-workspace`, `switch-workspace next/prev/...`),
  monitor focus, layout/sizing, window management, UI/settings toggles, and
  debugging/tracing. ~70+ commands.
- Live snapshot queries (`IPCFocusedWindowSnapshot`, `IPCWorkspaceQuerySnapshot`,
  `IPCDisplayQuerySnapshot`, `IPCWorkspaceBarProjection`, etc. —
  `Sources/NehirIPC/IPCModels.swift`) that a widget could render.
- `nehirctl` already exercises this surface as a separate process — a widget's
  `AppIntent.perform()` is structurally the same caller, just sandboxed.

### What this means

Architecturally, the *content* for a control already exists (commands to bind to
toggles, snapshots to display state). Every blocker is in **packaging, sandboxing,
and process bridging** — none in the window-management core.

---

## Decisive blocker: SwiftPM cannot emit a working `.appex` on macOS 26

An app extension (`.appex`) is a separate bundle in `Contents/PlugIns/` with its
own `@main` entry point and extension-specific linker/entry-point setup that
Xcode's WidgetKit template supplies. SwiftPM has **no first-class notion of a
widget/app-extension target** — `swift build` produces a plain executable. This
is not a cosmetic gap; on macOS 26 it is fatal.

### Evidence (parallel project: CodexBar)

CodexBar is structurally identical to Nehir: an SPM-only package, menu-bar app
(`.accessory`), `.app` hand-wrapped by a shell script, that attempted to add a
widget extension. Documented failure ([steipete/CodexBar#1095](https://github.com/steipete/CodexBar/issues/1095)):

- The hand-wrapped `.appex` (built from a SwiftPM `.executableTarget`) registers
  with `pluginkit`/`chronod` and signs cleanly, then **exits with status 0
  without entering an XPC runloop**. chronod reports
  `NSCocoaErrorDomain Code=4099 … connection to service … invalidated`.
- `lldb` backtrace shows `WidgetBundle.main()` *returns* (3 frames, `exit()`
  called from dyld's post-main epilogue). The user's `main()` returns because
  the blocking runloop that `ExtensionFoundation` normally installs is **not
  wired up** by SwiftPM's plain-executable path.
- Systematically ruled out: `NSExtension`+`NSExtensionPrincipalClass`, bare
  `NSExtension`, `EXAppExtensionAttributes`, both together,
  `LSMinimumSystemVersion=26.0`, a minimal `StaticConfiguration` widget, and
  AppIntents metadata generation. Swapping in an `xcodebuild`-built binary
  changed nothing — "both produce equivalent binaries because
  `CodexBarWidget` is `.executableTarget`, not an extension target."
- **Root cause (their words):** *"SwiftPM has no first-class notion of a 'widget
  extension target,' so neither path applies the extension-specific
  linker/entry-point setup that Xcode's WidgetKit template provides. On macOS 26
  that template setup is what supplies the blocking runloop."*
- **Suggested fix direction (their words):** add a real Xcode
  `com.apple.product-type.app-extension` target and have the packaging script
  consume its `.appex` rather than the SwiftPM-built executable.

A follow-up issue ([#1173](https://github.com/steipete/CodexBar/issues/1173))
covers the next layer of pain: even after a working `.appex`, the widget can
vanish from the gallery if the extension isn't properly **sandboxed** with the
**App Group** entitlement — chronod keeps it in
`extensionsPendingDescriptorRefetch` indefinitely. Both findings are directly
applicable to Nehir.

### Implication for Nehir

Nehir's `package:release` script would have to stop being a pure
`swift build` + hand-wrap flow and gain a real Xcode build step that emits a
properly-linked `.appex`. The existing pure-SPM toolchain (and the
`.swiftpm/xcode/package.xcworkspace` convenience wrapper) is insufficient.

---

## Secondary requirements

### 1. Deployment target (for Control Center *controls*)

`ControlWidget` / `ControlWidgetToggle` / `ControlWidgetButton` require
**macOS 26**. `Package.swift` currently declares `.macOS(.v15)`. Shipping a
Control Center control means either:

- Bump the app deployment target to `.macOS(.v26)`, **dropping macOS 15
  support** (regression for existing users), or
- Gate the control behind availability so the host still runs on 15 but the
  `.appex` is only installed/loaded on 26. This is doable (the extension's own
  `LSMinimumSystemVersion` can be `26.0` independent of the host), but the build
  target still needs the macOS 26 SDK and the control gallery only appears on 26.

Note CI already runs on `macos-26` (`.github/workflows/ci.yml`), so the build
environment is not the constraint — the **shipped minimum OS** is.

### 2. App Group + shared container

A control's `AppIntent.perform()` runs in the **extension's process**, not the
host's. Nehir's window manager lives in the host process. To bridge them you
need a process boundary both can cross:

- Add `com.apple.security.application-groups` to **both** the host and extension
  entitlements (e.g. group `$(TeamID).dev.guria.nehir`).
- The host must **publish the IPC session token** (and a reachable socket/XPC
  endpoint) into the shared container, since the current
  `~/Library/Caches/dev.guria.nehir/ipc.sock` lives outside any sandboxed
  extension's container.

### 3. Host↔extension transport

The widget's `AppIntent` cannot call `WMController` in-process. Options, ranked:

1. **Unix socket into the App Group container.** Move (or symlink) the IPC socket
   and its `.secret` into the shared container; the host already does UID + token
   auth. The extension's `perform()` opens the socket and issues a command. This
   reuses the existing versioned IPC verbatim. Requires the extension's sandbox
   to permit local socket connections (it does, within the app group container).
2. **`NSXPCConnection` over a Mach service** the host advertises
   (`registerMachServices`/launchd). Cleaner type-safety but a new server surface
   to build, version, and test.
3. **File/queue in the shared container** polled by the host. Simplest but
   lossy/laggy; not recommended for interactive controls.

State the widget *renders* (current workspace, column count, focused window,
layout mode) flows the other direction and is trivial: the host already computes
`IPCWorkspaceQuerySnapshot`/`IPCWorkspaceBarProjection`; it can write a small
JSON snapshot to the shared container on change, and the control's
`ControlValueProvider.currentValue()` reads it.

### 4. Entitlements

New entitlements (host **and** extension): App Group, and the extension must be
sandboxed (`App Sandbox = YES`) — un-sandboxed extension bundles are silently
rejected by chronod (CodexBar#1173). The host can remain unsandboxed (it needs
AX), but it now also carries the App Group entitlement.

### 5. Bundle wiring

- A new extension `Info.plist` with `EXAppExtensionAttributes` /
  `NSExtension` pointing at `WidgetKit`, plus `LSMinimumSystemVersion = 26.0`
  for a Control Center control.
- The host `Info.plist` gains nothing special beyond the App Group entitlement,
  but the `WidgetBundle` (`@main … WidgetBundle`) listing the controls lives in
  the extension target.
- The packaging script must `cp -R` the built `.appex` into
  `dist/Nehir.app/Contents/PlugIns/` **before** codesigning the outer bundle,
  and the outer `codesign` must embed the extension (Xcode does this
  automatically; the hand-rolled script must learn it). Notarization then
  covers the nested extension.

---

## Integration design (what a Nehir control would actually do)

Candidate first-party controls, all mappable 1:1 to existing IPC commands in
`Sources/NehirIPC/IPCAutomationManifest.swift`:

| Control | Type | Backing IPC command |
|---|---|---|
| Workspace prev / next | button | `switch-workspace prev` / `next` |
| Jump to workspace N (configurable) | configurable button (`AppIntentControlConfiguration`) | `switch-workspace <n>` |
| Monitor focus prev / next | button | `focus-monitor prev` / `next` |
| Toggle float / column-tabbed | toggle (`SetValueIntent`) | `toggle-column-tabbed`, float toggle |
| Centered workspace switcher | control with `ControlValueProvider` | renders `IPCWorkspaceBarProjection`; tap → `switch-workspace` |

The `ControlValueProvider.currentValue()` reads the shared-container snapshot the
host writes; `perform()` issues the IPC command. This is a thin shell — no
window-management logic in the extension.

---

## Scope options

- **Option A — Control Center controls (full ambition).** Requires everything
  above: Xcode app-extension target, App Group, sandboxed extension, IPC bridge
  via shared-container socket, deployment-target decision, packaging overhaul,
  and a deployment target of macOS 26 for the control to appear. Highest value,
  highest cost. Breaks the pure-SPM packaging invariant the rest of the repo
  relies on.

- **Option B — Notification Center / desktop widget (read-mostly).** Same
  appex/App Group/IPC bridge work, but `Widget` not `ControlWidget`, so the
  macOS 15 target can stay (widgets are macOS 14+). Lower integration ambition
  (display state, limited action via `AppIntent` buttons) but still requires the
  packaging overhaul. Good stepping stone: do B, reuse 100% of it for A later.

- **Option C — No extension; expand `nehirctl` / Shortcuts instead.** Nehir's
  `AppIntent`-equivalent already exists as `nehirctl` commands and they're
  Shortcut/`AppIntents`-exposable from the host app without any `.appex`. Gives
  Control-Center-adjacent reach (Shortcuts, Spotlight, raycast) at near-zero
  cost, but no in-Control-Center toggle and no widget gallery presence.

**Lean: pursue B before A, and only after deciding the deployment-target question
for A.** Option B validates the entire build/IPC bridge without forcing a
minimum-OS regression, and everything built for B (Xcode target, App Group,
shared-container IPC, packaging changes) transfers directly to A. The one thing
B does *not* de-risk is the macOS 26 deployment-target call, which should be a
separate product decision. Option C is worth doing regardless — it's cheap and
broadens the automation surface even if A/B are never taken on.

---

## Work breakdown (if pursued; B as the reference path)

1. **Toolchain/packaging.** Introduce a real Xcode `.xcodeproj` (or an
   Xcode-generated extension target layered over the SPM package) emitting a
   `com.apple.product-type.app-extension` `.appex`. Update
   `.config/mise/tasks/package/release` to build it and embed it into
   `Contents/PlugIns/` before the outer `codesign`. Verify with
   `codesign --verify --deep`.
2. **Entitlements.** Add `com.apple.security.application-groups` to host
   `Nehir.entitlements`; create a sandboxed extension entitlements file with
   App Group + sandbox.
3. **Transport.** Relocate IPC socket (+ `.secret`) into the App Group container
   (parameterize `IPCSocketPath.resolvedPath`) and have the host write a
   lightweight state snapshot there on relevant refresh reasons. Add a tiny
   in-extension IPC client (reuse `NehirIPC` wire codec).
4. **Extension target.** `WidgetBundle` + `Widget`/`ControlWidget` definitions,
   `AppIntent`s wrapping the chosen IPC commands, `ControlValueProvider`
   reading the shared snapshot.
5. **CI/release.** `release.yml` (runs on `macos-26`) already has the SDK; add
   the Xcode build step and ensure notarization/stapling covers the nested
   `.appex`. Update the Homebrew cask only if bundle layout changes
   (it shouldn't — still `Nehir.app`).
6. **Tests.** The IPC layer is already heavily unit-tested; add tests for the
   shared-container socket path resolution and the snapshot writer. Extension UI
   is hard to unit-test; lean on the existing `nehirctl` integration tests as
   the contract the `AppIntent`s must satisfy.

---

## Decisions pending

1. **Which "widget"?** Control Center *control* (Option A) vs. Notification
   Center/desktop *widget* (B) vs. no extension (C). This doc assumes A is the
   goal; confirm before scoping.
2. **Deployment target.** Is dropping macOS 15 acceptable to ship A? If not, A is
   off the table and only B/C remain.
3. **Packaging invariant.** The repo deliberately avoids a real `.xcodeproj`.
   Any widget path breaks that invariant. Confirm willingness to introduce (and
   maintain) an Xcode build step before starting.
4. **Transport.** Shared-container Unix socket (reuse IPC) vs. NSXPC. Lean: socket,
   for minimal new surface.

---

## Files of record

- `Package.swift` — deployment target `.macOS(.v15)`; pure SPM; no extension
  target possible here.
- `Info.plist` — `LSUIElement`, minimal; would need no extension keys (extension
  has its own plist) but host gains App Group via entitlements.
- `Nehir.entitlements` — only `automation.apple-events` today; needs App Group.
- `.config/mise/tasks/package/release` — hand-assembled `.app`, no `PlugIns/`;
  the script that must learn Xcode-built `.appex` embedding.
- `.github/workflows/release.yml` — `runs-on: macos-26`; SDK available.
- `Sources/Nehir/App/AppDelegate.swift`, `Sources/NehirApp/NehirApp.swift` — host
  lifecycle (`.accessory`, `Settings`-only SwiftUI scene).
- `Sources/NehirIPC/IPCSocketPath.swift` — per-user socket + `.secret`; would
  relocate into App Group container.
- `Sources/Nehir/IPC/IPCServer.swift` — UID + token auth the extension must satisfy.
- `Sources/NehirIPC/IPCAutomationManifest.swift` — command/query registry the
  control's `AppIntent`s wrap.
- `Sources/NehirIPC/IPCModels.swift` — snapshot types the control renders.
- `docs/IPC-CLI.md` — documented automation contract; extension intents must not
  diverge from it.

## References

- Apple — *Creating controls to perform actions across the system*
  (developer.apple.com/documentation/WidgetKit).
- Apple — *Adding refinements and configuration to controls* (`AppIntentControlConfiguration`).
- [steipete/CodexBar#1095](https://github.com/steipete/CodexBar/issues/1095) —
  SwiftPM `.executableTarget` hand-wrapped into `.appex` fails on macOS 26
  (`WidgetBundle.main()` returns; no blocking runloop); root cause and fix
  direction. Structurally identical to Nehir.
- [steipete/CodexBar#1173](https://github.com/steipete/CodexBar/issues/1173) —
  un-sandboxed extension bundles silently rejected by chronod; App Group fix.
