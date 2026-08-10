// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir
import Testing

private func appNameRuleFacts(bundleId: String?, appName: String, title: String?) -> WindowRuleFacts {
    WindowRuleFacts(
        appName: appName,
        ax: AXWindowFacts(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: title,
            hasCloseButton: true,
            hasFullscreenButton: true,
            fullscreenButtonEnabled: true,
            hasZoomButton: true,
            hasMinimizeButton: true,
            appPolicy: .regular,
            bundleId: bundleId,
            attributeFetchSucceeded: true
        ),
        sizeConstraints: nil,
        windowServer: nil
    )
}

@Suite @MainActor struct AppNameRuleMatchingTests {
    @Test func bundlelessRuleMatchesAndRequestsItsRequiredTitle() {
        let rule = AppRule(appNameSubstring: "qemu-system-aarch64", titleSubstring: "QEMU", layout: .float)
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [rule])

        let decision = engine.decision(
            for: appNameRuleFacts(bundleId: nil, appName: "qemu-system-aarch64", title: "QEMU console"),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.source == .userRule(rule.id))
        #expect(engine.requiresTitle(for: nil, appName: "qemu-system-aarch64"))
        #expect(!engine.requiresTitle(for: nil, appName: "other"))
    }

    @Test func bundleAndAppNameSelectorsAreConjunctive() {
        let rule = AppRule(bundleId: "com.example.qemu", appNameSubstring: "QEMU", layout: .float)
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [rule])

        let match = engine.decision(
            for: appNameRuleFacts(bundleId: "com.example.qemu", appName: "QEMU", title: nil),
            token: nil,
            appFullscreen: false
        )
        let wrongBundle = engine.decision(
            for: appNameRuleFacts(bundleId: "com.example.other", appName: "QEMU", title: nil),
            token: nil,
            appFullscreen: false
        )

        #expect(match.source == .userRule(rule.id))
        #expect(wrongBundle.source != .userRule(rule.id))
    }
}
