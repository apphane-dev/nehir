# OmniWM PR #323 — "Restore floating panel classification + bar filter" — Discovery

Source PR: https://github.com/BarutSRB/OmniWM/pull/323
Merge state: **closed without merge** upstream — evaluate the concept, not a
verbatim patch.
Scope of this doc: determine whether the proposed PR fix applies to nehir,
and whether the suggested fix is safe to port.

All file/line references were verified against worktree `worktree-calm-meadow-6229` at
`7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace"). Line
numbers drift — re-verify before implementing.

---

## TL;DR

- **Partial applies: nehir already restored non-standard AX subrole floating and automatic fallback mode preservation, but it still lacks PR #323's workspace-bar `layoutReason == .standard` filter and still does not admit titled `AXDialog`/`AXPanel` elements by role during top-level AX enumeration.**
- **Verdict:** 🟡 **Partial.** Do not port the diff blindly, but adapt the missing bar filter and re-evaluate titled dialog/panel admission against nehir's stricter managed-replacement/transient safeguards.

## Upstream change

The closed PR is a three-commit fix for the popup-induced floating regression linked to #306.
The final commit says it restores floating panel classification and bar filtering. The diff:

- re-adds `AXWindowService.shouldTreatAsTopLevelWindow(role:subrole:)`;
- admits top-level AX windows plus titled `AXDialog`/`AXPanel` elements in `AppAXContext`;
- re-adds the non-standard-subrole heuristic that classifies dialogs/panels as floating;
- stores `parentWindowId` in managed-replacement metadata;
- adds a `WindowRuleEngine` structural parent rule: any non-zero window-server `parentId` returns explicit floating via `childWindowStructuralAnchor`;
- filters workspace-bar floating entries to scratchpad-excluded **and** `layoutReason == .standard`;
- adds tests for child-window structural anchoring, automatic fallback preservation, and hiding non-standard floating entries from the bar.

## Provenance: is this nehir's code?

Yes. The relevant renamed paths exist in nehir:

- AX enumeration and heuristics: `Sources/Nehir/Core/Ax/AppAXContext.swift:421`, `Sources/Nehir/Core/Ax/AXWindow.swift:312`, `Sources/Nehir/Core/Ax/AXWindow.swift:667`.
- Rule evaluation: `Sources/Nehir/Core/Rules/WindowRuleEngine.swift:369`, `Sources/Nehir/Core/Rules/WindowRuleEngine.swift:427`.
- Automatic reevaluation mode preservation: `Sources/Nehir/Core/Controller/WMController.swift:1920`.
- Managed-replacement metadata persistence: `Sources/Nehir/Core/Controller/WMController.swift:3091`, `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1311`.
- Workspace-bar projection: `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2548`, `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift:70`.

`ffgrep childWindowStructuralAnchor Sources` returned no matches: nehir does not have the PR's explicit `parentId != 0` built-in rule.

## The code in question

nehir's top-level AX enumeration is still stricter than the PR: it only admits elements accepted by `shouldTreatAsTopLevelWindow`, and it does not fetch title or accept `AXDialog`/`AXPanel` by role here.

```swift
// Sources/Nehir/Core/Ax/AppAXContext.swift:421
var subrole: String?
if role != kAXWindowRole as String {
    var subroleValue: CFTypeRef?
    let subroleResult = AXUIElementCopyAttributeValue(
        element,
        kAXSubroleAttribute as CFString,
        &subroleValue
    )
    if subroleResult == .success {
        subrole = subroleValue as? String
    }
}

// Sources/Nehir/Core/Ax/AppAXContext.swift:434
guard AXWindowService.shouldTreatAsTopLevelWindow(role: role, subrole: subrole) else {
    continue
}
```

```swift
// Sources/Nehir/Core/Ax/AXWindow.swift:312
static func shouldTreatAsTopLevelWindow(role: String?, subrole: String?) -> Bool {
    role == kAXWindowRole as String || subrole == kAXStandardWindowSubrole as String
}
```

The floating classification half is already present once a window reaches rule evaluation.

```swift
// Sources/Nehir/Core/Ax/AXWindow.swift:667
if let subrole = facts.subrole,
   subrole != (kAXStandardWindowSubrole as String)
{
    return AXWindowHeuristicDisposition(
        disposition: .floating,
        reasons: [.nonStandardSubrole]
    )
}
```

Rule evaluation has no structural-parent branch between CleanShot and the generic fallback path; parented windows fall through to title/app-fullscreen/attribute/heuristic logic.

```swift
// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:369
if let cleanShotDecision = cleanShotRecordingOverlayDecision(
    for: facts,
    workspaceName: workspaceName,
    effects: effects
) {
    return cleanShotDecision
}

// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:377
if facts.ax.title == nil,
   requiresTitle(for: facts.ax.bundleId)
{
    return WindowDecision(...)
}

// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:427
let heuristic = AXWindowService.heuristicDisposition(
    for: facts.ax,
    sizeConstraints: facts.sizeConstraints
)
```

nehir already has the automatic fallback preservation concept, and it is broader than the PR's first commit: any automatic `fallbackLayout` that would flip an existing tiled entry to floating is preserved as tiled.

```swift
// Sources/Nehir/Core/Controller/WMController.swift:1920
func trackedModePreservingAutomaticFallbackState(
    decision: WindowDecision,
    existingEntry: WindowModel.Entry?,
    context: WindowRuleReevaluationContext
) -> TrackedWindowMode? {
    ...
    guard context == .automatic,
          let existingEntry,
          decision.layoutDecisionKind == .fallbackLayout
    else {
        return trackedMode
    }
    ...
    if existingEntry.mode == .tiling,
       trackedMode == .floating
    {
        return .tiling
    }
```

Parent metadata is also already preserved in both reevaluation/update paths.

```swift
// Sources/Nehir/Core/Controller/WMController.swift:3091
if let updatedEntry = workspaceManager.entry(for: token) {
    let parentWindowId = if let windowServer = evaluation.facts.windowServer {
        windowServer.parentId == 0 ? nil : windowServer.parentId
    } else {
        updatedEntry.managedReplacementMetadata?.parentWindowId
    }
    _ = workspaceManager.setManagedReplacementMetadata(
        ManagedReplacementMetadata(
            ...
            parentWindowId: parentWindowId,
```

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1311
let parentWindowId = if let windowServer = evaluation.facts.windowServer {
    windowServer.parentId == 0 ? nil : windowServer.parentId
} else {
    existingEntry?.managedReplacementMetadata?.parentWindowId
}
```

The workspace-bar filtering half is missing. `WorkspaceBarDataSource` consumes `barVisibleEntries`, and `barVisibleFloatingEntries` excludes scratchpad windows only; it does not require `.standard` layout reason.

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift:70
let projectedEntries = workspaceManager.barVisibleEntries(
    in: workspace.id,
    showFloatingWindows: options.showFloatingWindows
)
```

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2548
func barVisibleEntries(
    in workspace: WorkspaceDescriptor.ID,
    showFloatingWindows: Bool = false
) -> [WindowModel.Entry] {
    var entries = tiledEntries(in: workspace)
    if showFloatingWindows {
        entries.append(contentsOf: barVisibleFloatingEntries(in: workspace))
    }
    return entries
}

// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2574
private func barVisibleFloatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
    floatingEntries(in: workspace).filter {
        !isScratchpadToken($0.token) && hiddenState(for: $0.token)?.isScratchpad != true
    }
}
```

## Why this partially applies

The triage note is directionally correct, but the PR is not a clean one-shot port.

What nehir already has:

- Non-standard subroles classify as floating via `AXWindowService.heuristicDisposition` at `Sources/Nehir/Core/Ax/AXWindow.swift:667`-`Sources/Nehir/Core/Ax/AXWindow.swift:673`; tests cover this at `Tests/NehirTests/AXWindowServiceTests.swift:150`-`Tests/NehirTests/AXWindowServiceTests.swift:168` and `Tests/NehirTests/WindowRuleEngineTests.swift:467`-`Tests/NehirTests/WindowRuleEngineTests.swift:481`.
- Automatic fallback mode preservation already guards tiled entries from fallback-floating churn at `Sources/Nehir/Core/Controller/WMController.swift:1932`-`Sources/Nehir/Core/Controller/WMController.swift:1949`.
- Parent-window metadata is already retained during reevaluation/layout-refresh at `Sources/Nehir/Core/Controller/WMController.swift:3091`-`Sources/Nehir/Core/Controller/WMController.swift:3108` and `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1311`-`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1327`.
- nehir has narrower structural child handling: parent workspace inheritance is restricted to AX sheets/dialog subroles or degraded modal/transient window-server evidence at `Sources/Nehir/Core/Controller/WMController.swift:1141`-`Sources/Nehir/Core/Controller/WMController.swift:1165`, and managed replacement only treats direct floating children as structural replacements when there is AX/degraded child evidence at `Sources/Nehir/Core/Controller/AXEventHandler.swift:3193`-`Sources/Nehir/Core/Controller/AXEventHandler.swift:3228`.

What still applies:

- Titled dialog/panel **admission** is absent. `AppAXContext` does not read `kAXTitleAttribute` during enumeration and does not accept `role == "AXDialog"` or `role == "AXPanel"` by role/title; it only asks `shouldTreatAsTopLevelWindow`, whose predicate is `AXWindow` role or `AXStandardWindow` subrole (`Sources/Nehir/Core/Ax/AppAXContext.swift:421`-`Sources/Nehir/Core/Ax/AppAXContext.swift:434`, `Sources/Nehir/Core/Ax/AXWindow.swift:312`-`Sources/Nehir/Core/Ax/AXWindow.swift:314`). Existing tests intentionally reject a non-window role with `AXDialog` subrole at `Tests/NehirTests/AXWindowServiceTests.swift:34`-`Tests/NehirTests/AXWindowServiceTests.swift:40`, so changing this is a real behavior decision.
- The workspace bar can still show non-standard floating/lifecycle entries when `showFloatingWindows` is true. The PR's filter would add `layoutReason(for: token) == .standard`; nehir's filter lacks that clause at `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2574`-`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2577`.
- The exact `childWindowStructuralAnchor` built-in rule is absent (`ffgrep childWindowStructuralAnchor Sources` returned no matches). However, porting `parentId != 0 => explicit floating` verbatim may be too broad for nehir because the current code deliberately narrows parent inheritance/replacement to AX child or transient evidence (`Sources/Nehir/Core/Controller/WMController.swift:1149`-`Sources/Nehir/Core/Controller/WMController.swift:1165`, `Sources/Nehir/Core/Controller/AXEventHandler.swift:3205`-`Sources/Nehir/Core/Controller/AXEventHandler.swift:3213`).

## Recommendation

Own a nehir follow-up, but **do not port PR #323 verbatim**:

1. Add the workspace-bar guard equivalent to `layoutReason(for: token) == .standard` in `barVisibleFloatingEntries`.
2. Evaluate a narrow AX enumeration change for titled `AXDialog`/`AXPanel` elements, with tests that prove tooltips/untitled panels remain excluded.
3. Treat the PR's `parentId != 0` rule as design input only; prefer nehir's existing transient/AX-child evidence model unless a reproducer proves parent-id-only child windows are missed.

## Suggested tests

- Workspace bar: a floating entry with `layoutReason == .nativeFullscreen` (or another non-standard reason) is absent from `WorkspaceBarDataSource.workspaceBarItems` when `showFloatingWindows == true`.
- AX enumeration: a titled `AXDialog`/`AXPanel` role is admitted, while an untitled panel/tooltip-like element remains rejected.
- Rule/replacement safety: a parented standard document window with no AX child/transient evidence is not auto-floated solely because `parentId != 0`.
