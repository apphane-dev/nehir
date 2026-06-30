// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

@testable import Nehir
import Testing

/// Covers the "Create App Rule for Focused Window…" command surface added for
/// backlog #26: its action-spec registration (palette and workspace-bar
/// window-icon right-click surfacing), title, TOML config-key mapping, search
/// findability, no-IPC status, and the one-shot `pendingAppRuleDraft` plumbing
/// that carries a pre-filled draft from the command into the App Rules editor.
///
/// The command-handler happy path (focused window -> draft -> Settings opens on
/// the App Rules editor) is exercised at runtime via the same
/// `focusedWindowDecisionDebugSnapshot()` + `AppRuleDraft.guided(from:)` +
/// `presentNewRule(from:)` path the in-tab "New Rule from Focused Window" button
/// already drives (see AppRuleDraftTests for the seed mapping); it is not
/// unit-tested here because resolving a real focused-window bundle id requires
/// live AX fixtures, and the success path opens the `SettingsWindowController`
/// singleton window.
@Suite @MainActor struct CreateAppRuleForFocusedWindowTests {
    @Test func actionSpecIsRegisteredForPaletteSurfacing() throws {
        let spec = try #require(ActionCatalog.spec(for: "createAppRuleForFocusedWindow"))

        #expect(spec.command == .createAppRuleForFocusedWindow)
        #expect(spec.category == .focus)
        #expect(spec.requiresDeveloperMode == false)
        #expect(spec.defaultBinding.isUnassigned, "v1 ships with no default hotkey")
    }

    @Test func titleUsesEllipsisSuffixIndicatingEditorDialog() throws {
        let spec = try #require(ActionCatalog.spec(for: "createAppRuleForFocusedWindow"))

        #expect(spec.title == "Create App Rule for Focused Window…")
        #expect(ActionCatalog.title(for: .createAppRuleForFocusedWindow) == "Create App Rule for Focused Window…")
        #expect(HotkeyCommand.createAppRuleForFocusedWindow.displayName == "Create App Rule for Focused Window…")
    }

    @Test func specIsSurfacedThroughDefaultBindingsRegistry() throws {
        // The palette and hotkey registry are built from ActionCatalog.allSpecs();
        // ensure the new command is reachable there too (mirrors openSettings).
        let binding = try #require(
            HotkeyBindingRegistry.defaults().first { $0.id == "createAppRuleForFocusedWindow" }
        )

        #expect(binding.command == .createAppRuleForFocusedWindow)
        #expect(binding.binding.isUnassigned)
    }

    @Test func configKeyIsMappedForPersistence() {
        // Required so the binding is assignable/persistable like every other
        // catalogued action (enforced by allCatalogActionsAreAssignable…).
        #expect(
            HotkeyConfigMapping.configKey(forInternalId: "createAppRuleForFocusedWindow")
                == "ui.createAppRuleForFocusedWindow"
        )
        #expect(
            HotkeyConfigMapping.internalId(forConfigKey: "ui.createAppRuleForFocusedWindow")
                == "createAppRuleForFocusedWindow"
        )
    }

    @Test func searchTermsFindCommandByRuleKeywords() throws {
        let binding = try #require(
            HotkeyBindingRegistry.defaults().first { $0.id == "createAppRuleForFocusedWindow" }
        )

        #expect(ActionCatalog.matchesSearch("rule", binding: binding))
        #expect(ActionCatalog.matchesSearch("app rule", binding: binding))
        #expect(ActionCatalog.matchesSearch("create rule", binding: binding))
        #expect(ActionCatalog.matchesSearch("bundle", binding: binding))
    }

    @Test func commandHasNoIpcName() throws {
        // Decision D: v1 has no headless IPC/CLI surface, so the spec carries
        // no ipcCommandName (the NehirIPC module is intentionally untouched).
        // See the discovery's Step 5 deferral.
        let spec = try #require(ActionCatalog.spec(for: "createAppRuleForFocusedWindow"))

        #expect(spec.ipcCommandName == nil)
        #expect(spec.ipcDescriptor == nil)
    }

    @Test func settingsNavigationModelCarriesOneShotAppRuleDraft() {
        let navigation = SettingsNavigationModel(selectedSection: .appRules)

        // Defaults to nil (no pending draft).
        #expect(navigation.pendingAppRuleDraft == nil)

        // A command handler hands a pre-filled draft over to the App Rules tab.
        let draft = AppRuleDraft(bundleId: "com.example.focused")
        navigation.pendingAppRuleDraft = draft
        #expect(navigation.pendingAppRuleDraft?.bundleId == "com.example.focused")

        // AppRulesView consumes it and clears the seed so it fires exactly once
        // (mirrors how the Hotkeys tab consumes hotkeySearchSeed).
        navigation.pendingAppRuleDraft = nil
        #expect(navigation.pendingAppRuleDraft == nil)
    }

    @Test func guidedDraftFromFocusedSnapshotIsBundleLevelWithAvailableMatchers() {
        // Confirms Decision B: the command reuses AppRuleDraft.guided(from:)
        // unchanged, seeding the bundle id plus title/AX matchers when present.
        let snapshot = WindowDecisionDebugSnapshot(
            token: nil,
            appName: "Example",
            bundleId: "com.example.focused",
            title: "Main Window",
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            appFullscreen: false,
            manualOverride: nil,
            disposition: .managed,
            source: .heuristic,
            layoutDecisionKind: .fallbackLayout,
            deferredReason: nil,
            admissionOutcome: .trackedTiling,
            workspaceName: nil,
            minWidth: nil,
            minHeight: nil,
            matchedRuleId: nil,
            heuristicReasons: [],
            attributeFetchSucceeded: true
        )

        let draft = AppRuleDraft.guided(from: snapshot)

        #expect(draft?.bundleId == "com.example.focused")
        #expect(draft?.titleMatcherMode == .substring)
        #expect(draft?.axRoleEnabled == true)
    }
}
