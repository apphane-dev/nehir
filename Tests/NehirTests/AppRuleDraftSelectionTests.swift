// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

@testable import Nehir
import Testing

private func bundlelessDraftSnapshot() -> WindowDecisionDebugSnapshot {
    WindowDecisionDebugSnapshot(
        token: nil,
        appName: "QEMU",
        bundleId: nil,
        title: nil,
        axRole: nil,
        axSubrole: nil,
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
}

@Suite struct AppRuleDraftSelectionTests {
    @Test func guidedBundlelessDraftSeedsGeneratedAppName() throws {
        let draft = try #require(AppRuleDraft.guided(from: bundlelessDraftSnapshot()))

        #expect(draft.bundleId.isEmpty)
        #expect(draft.appNameMatcherEnabled)
        #expect(draft.appNameSubstring == "QEMU")
        #expect(draft.generatedAppNameSeed == "QEMU")
    }

    @Test func runningAppSelectionClearsOnlyUnchangedGeneratedName() {
        var draft = AppRuleDraft()
        draft.applyRunningAppSelection(bundleId: nil, appName: "QEMU")
        #expect(draft.generatedAppNameSeed == "QEMU")

        draft.applyRunningAppSelection(bundleId: "com.example.qemu", appName: "QEMU")
        #expect(draft.bundleId == "com.example.qemu")
        #expect(!draft.appNameMatcherEnabled)

        draft.applyRunningAppSelection(bundleId: nil, appName: "QEMU")
        draft.appNameSubstring = "User refinement"
        draft.generatedAppNameSeed = nil
        draft.applyRunningAppSelection(bundleId: "com.example.qemu", appName: "QEMU")
        #expect(draft.appNameMatcherEnabled)
        #expect(draft.appNameSubstring == "User refinement")
    }

    @Test func persistedBundlelessRuleRoundTripsThroughDraft() {
        let rule = AppRule(appNameSubstring: "qemu-system-aarch64")
        let draft = AppRuleDraft(rule: rule)

        #expect(draft.bundleId.isEmpty)
        #expect(draft.appNameMatcherEnabled)
        #expect(draft.generatedAppNameSeed == nil)
        #expect(draft.makeRule(id: rule.id) == rule)
    }
}
