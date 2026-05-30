import AppKit
import ApplicationServices
@testable import Nehir
import Testing

private func makeWindowRuleFacts(
    bundleId: String = "com.example.app",
    appName: String? = nil,
    title: String? = nil,
    role: String? = kAXWindowRole as String,
    subrole: String? = kAXStandardWindowSubrole as String,
    hasCloseButton: Bool = true,
    hasFullscreenButton: Bool = true,
    fullscreenButtonEnabled: Bool? = true,
    hasZoomButton: Bool = true,
    hasMinimizeButton: Bool = true,
    appPolicy: NSApplication.ActivationPolicy? = .regular,
    attributeFetchSucceeded: Bool = true,
    sizeConstraints: WindowSizeConstraints? = nil,
    windowServer: WindowServerInfo? = nil
) -> WindowRuleFacts {
    WindowRuleFacts(
        appName: appName,
        ax: AXWindowFacts(
            role: role,
            subrole: subrole,
            title: title,
            hasCloseButton: hasCloseButton,
            hasFullscreenButton: hasFullscreenButton,
            fullscreenButtonEnabled: fullscreenButtonEnabled,
            hasZoomButton: hasZoomButton,
            hasMinimizeButton: hasMinimizeButton,
            appPolicy: appPolicy,
            bundleId: bundleId,
            attributeFetchSucceeded: attributeFetchSucceeded
        ),
        sizeConstraints: sizeConstraints,
        windowServer: windowServer
    )
}

@Suite @MainActor struct WindowRuleEngineTests {
    @Test func titleMatchersRequireTitleAndEnableReevaluation() {
        let engine = WindowRuleEngine()
        engine.rebuild(
            rules: [
                AppRule(
                    bundleId: "com.example.app",
                    titleSubstring: "Chooser",
                    layout: .float
                )
            ]
        )

        #expect(engine.requiresTitle)
        #expect(engine.requiresTitle(for: "com.example.app"))
        #expect(engine.requiresTitle(for: "com.unmatched.app") == false)
        #expect(engine.hasDynamicReevaluationRules)
        #expect(engine.needsWindowReevaluation)
    }

    @Test func explicitFloatRuleProducesFloatingDecision() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            bundleId: "com.example.floater",
            layout: .float
        )
        engine.rebuild(rules: [rule])

        let decision = engine.decision(
            for: makeWindowRuleFacts(bundleId: "com.example.floater"),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == WindowDecisionDisposition.floating)
        #expect(decision.heuristicReasons.isEmpty)
        if case .userRule(rule.id) = decision.source {
        } else {
            Issue.record("Expected float rule to remain a user rule decision")
        }
    }

    @Test func forceTileRuleOverridesMissingFullscreenButtonHeuristic() {
        let engine = WindowRuleEngine()
        engine.rebuild(
            rules: [
                AppRule(
                    bundleId: "com.adobe.illustrator",
                    layout: .tile
                )
            ]
        )

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.adobe.illustrator",
                appName: "Adobe Illustrator",
                title: "Untitled-1",
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.heuristicReasons.isEmpty)
    }

    @Test func moreSpecificTitleRuleBeatsGenericBundleRule() {
        let engine = WindowRuleEngine()
        let genericRule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000121")!,
            bundleId: "com.adobe.illustrator",
            layout: .float,
            assignToWorkspace: "1"
        )
        let specificRule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000122")!,
            bundleId: "com.adobe.illustrator",
            titleSubstring: "Document",
            layout: .tile,
            assignToWorkspace: "2",
            minWidth: 900
        )
        engine.rebuild(rules: [genericRule, specificRule])

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.adobe.illustrator",
                appName: "Adobe Illustrator",
                title: "Document 1"
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.workspaceName == "2")
        #expect(decision.ruleEffects.minWidth == 900)
        #expect(decision.ruleEffects.matchedRuleId == specificRule.id)
    }

    @Test func attributeFetchFailureReturnsUndecided() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.partial-ax",
                attributeFetchSucceeded: false
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .undecided)
        #expect(decision.layoutDecisionKind == .fallbackLayout)
        #expect(decision.deferredReason == .attributeFetchFailed)
        #expect(decision.trackedMode == nil)
        #expect(decision.heuristicReasons == [.attributeFetchFailed])
    }

    @Test func degradedAxParentedWindowServerTransientRemainsUndecided() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000164")!,
            bundleId: "com.example.transient",
            assignToWorkspace: "2"
        )
        engine.rebuild(rules: [rule])
        var windowServer = WindowServerInfo(id: 3201, pid: 3201, level: 0, frame: .zero)
        windowServer.parentId = 44

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.transient",
                role: kAXWindowRole as String,
                subrole: "AXUnknown",
                attributeFetchSucceeded: false,
                windowServer: windowServer
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .undecided)
        #expect(decision.layoutDecisionKind == .fallbackLayout)
        #expect(decision.workspaceName == "2")
        #expect(decision.source == .userRule(rule.id))
        #expect(decision.deferredReason == .attributeFetchFailed)
        #expect(decision.trackedMode == nil)
        #expect(decision.heuristicReasons == [.attributeFetchFailed])
    }

    @Test func degradedAxFloatingTaggedWindowServerTransientRemainsUndecided() {
        let engine = WindowRuleEngine()
        var windowServer = WindowServerInfo(id: 3202, pid: 3202, level: 0, frame: .zero)
        windowServer.tags = 0x2

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                role: kAXWindowRole as String,
                subrole: "AXUnknown",
                attributeFetchSucceeded: false,
                windowServer: windowServer
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .undecided)
        #expect(decision.source == .heuristic)
        #expect(decision.deferredReason == .attributeFetchFailed)
        #expect(decision.trackedMode == nil)
        #expect(decision.heuristicReasons == [.attributeFetchFailed])
    }

    @Test func degradedAxAuxiliaryLevelWithoutParentOrFloatingTagRemainsUndecided() {
        let engine = WindowRuleEngine()
        let windowServer = WindowServerInfo(id: 3205, pid: 3205, level: 103, frame: .zero)

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                role: kAXWindowRole as String,
                subrole: "AXUnknown",
                attributeFetchSucceeded: false,
                windowServer: windowServer
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .undecided)
        #expect(decision.deferredReason == .attributeFetchFailed)
    }

    @Test func degradedAxDocumentAndHelpTagSurfacesRemainUndecided() {
        let engine = WindowRuleEngine()
        var documentWindowServer = WindowServerInfo(id: 3203, pid: 3203, level: 0, frame: .zero)
        documentWindowServer.tags = 0x1
        let documentDecision = engine.decision(
            for: makeWindowRuleFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                attributeFetchSucceeded: false,
                windowServer: documentWindowServer
            ),
            token: nil,
            appFullscreen: false
        )

        var helpWindowServer = WindowServerInfo(id: 3204, pid: 3204, level: 103, frame: .zero)
        helpWindowServer.parentId = 44
        let helpDecision = engine.decision(
            for: makeWindowRuleFacts(
                role: "AXHelpTag",
                subrole: kAXStandardWindowSubrole as String,
                attributeFetchSucceeded: false,
                windowServer: helpWindowServer
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(documentDecision.disposition == .undecided)
        #expect(documentDecision.deferredReason == .attributeFetchFailed)
        #expect(helpDecision.disposition == .undecided)
        #expect(helpDecision.deferredReason == .attributeFetchFailed)
    }

    @Test func tileRuleDefersWhenAttributeFetchFails() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000162")!,
            bundleId: "dentalplus-air",
            assignToWorkspace: "2"
        )
        engine.rebuild(rules: [rule])

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "dentalplus-air",
                appName: "DentalPlus Client",
                attributeFetchSucceeded: false
            ),
            token: nil,
            appFullscreen: false
        )

        // Tile/auto rules defer when AX attributes are unavailable to prevent
        // tooltips and auxiliary windows from being tiled and destabilizing layout.
        #expect(decision.disposition == .undecided)
        #expect(decision.deferredReason == .attributeFetchFailed)
    }

    @Test func floatRuleAppliesDespiteAttributeFetchFailure() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000163")!,
            bundleId: "dentalplus-air",
            layout: .float
        )
        engine.rebuild(rules: [rule])

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "dentalplus-air",
                appName: "DentalPlus Client",
                attributeFetchSucceeded: false
            ),
            token: nil,
            appFullscreen: false
        )

        // Float rules still apply with degraded AX since they don't affect tiling layout.
        #expect(decision.disposition == .floating)
        #expect(decision.source == .userRule(rule.id))
        #expect(decision.deferredReason == nil)
    }

    @Test func defaultFloatingRuleAppliesDespiteAttributeFetchFailure() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.itoolab.unlockgo",
                appName: "UnlockGo",
                attributeFetchSucceeded: false
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .floating)
        #expect(decision.layoutDecisionKind == .explicitLayout)
        #expect(decision.trackedMode == .floating)
        #expect(decision.admissionOutcome == .trackedFloating)
        #expect(decision.deferredReason == nil)
        if case .builtInRule("defaultFloatingApp") = decision.source {
        } else {
            Issue.record("Expected UnlockGo to use the built-in floating rule")
        }
    }

    @Test func explicitUserFloatRuleWithAttributeFetchFailureStaysExplicit() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000165")!,
            bundleId: "com.example.degraded-float",
            layout: .float
        )
        engine.rebuild(rules: [rule])

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.degraded-float",
                attributeFetchSucceeded: false
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .floating)
        #expect(decision.source == .userRule(rule.id))
        #expect(decision.layoutDecisionKind == .explicitLayout)
        #expect(decision.trackedMode == .floating)
    }

    @Test func missingFullscreenButtonFallsBackToTrackedFloating() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.standard",
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .floating)
        #expect(decision.layoutDecisionKind == .fallbackLayout)
        #expect(decision.trackedMode == .floating)
        #expect(decision.admissionOutcome == .trackedFloating)
        #expect(decision.heuristicReasons == [.missingFullscreenButton])
    }

    @Test func cleanShotCaptureLevelStandardWindowDefaultsToTrackedFloating() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: WindowRuleEngine.cleanShotBundleId,
                subrole: kAXStandardWindowSubrole as String,
                appPolicy: .accessory,
                windowServer: WindowServerInfo(id: 1, pid: 41, level: 103, frame: .zero)
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .floating)
        #expect(decision.trackedMode == .floating)
        if case .builtInRule("cleanShotRecordingOverlay") = decision.source {
        } else {
            Issue.record("Expected CleanShot capture overlays to use the built-in floating rule")
        }
    }

    @Test func cleanShotDialogAtCaptureLevelStillFloats() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: WindowRuleEngine.cleanShotBundleId,
                subrole: "AXDialog",
                appPolicy: .accessory,
                windowServer: WindowServerInfo(id: 2, pid: 41, level: 103, frame: .zero)
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .floating)
        #expect(decision.trackedMode == .floating)
        #expect(decision.heuristicReasons == [.nonStandardSubrole])
    }

    @Test func cleanShotStandardWindowAtNormalLevelKeepsExistingHeuristic() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: WindowRuleEngine.cleanShotBundleId,
                subrole: kAXStandardWindowSubrole as String,
                fullscreenButtonEnabled: nil,
                appPolicy: .accessory,
                windowServer: WindowServerInfo(id: 3, pid: 41, level: 0, frame: .zero)
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == WindowDecisionDisposition.floating)
        #expect(decision.heuristicReasons == [AXWindowHeuristicReason.disabledFullscreenButton])
    }

    @Test func fixedSizeStandardWindowNoLongerAutoFloats() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.dialog",
                sizeConstraints: .fixed(size: CGSize(width: 420, height: 320))
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.heuristicReasons.isEmpty)
    }

    @Test func nonStandardSubroleFallsBackToTrackedFloating() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.weird",
                subrole: "AXWeirdTransientWindow"
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .floating)
        #expect(decision.trackedMode == .floating)
        #expect(decision.heuristicReasons == [.nonStandardSubrole])
    }

    @Test func systemTextInputPanelBundlesAreUnmanagedBeforeFloatingHeuristics() {
        let engine = WindowRuleEngine()
        let bundleIds = [
            "com.apple.CharacterPaletteIM",
            "com.apple.EmojiFunctionRowItem-Container",
            "com.apple.TextInputMenuAgent",
            "com.apple.TextInputSwitcher"
        ]

        for bundleId in bundleIds {
            let decision = engine.decision(
                for: makeWindowRuleFacts(
                    bundleId: bundleId,
                    subrole: "AXTextInputTransientPanel",
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: nil,
                    hasZoomButton: false,
                    hasMinimizeButton: false,
                    appPolicy: .accessory,
                    windowServer: WindowServerInfo(id: 7, pid: 41, level: 3, frame: .zero)
                ),
                token: nil,
                appFullscreen: false
            )

            #expect(decision.disposition == .unmanaged)
            #expect(decision.trackedMode == nil)
            #expect(decision.admissionOutcome == .ignored)
            #expect(decision.heuristicReasons.isEmpty)
            if case let .builtInRule(name) = decision.source {
                #expect(name == WindowRuleEngine.systemTextInputPanelRuleName)
            } else {
                Issue.record("Expected system text input panel built-in rule for \(bundleId)")
            }
        }
    }

    @Test func builtInPictureInPictureRuleEnablesTitleReevaluation() {
        let engine = WindowRuleEngine()

        #expect(engine.requiresTitle)
        #expect(engine.requiresTitle(for: "org.mozilla.firefox"))
        #expect(engine.hasDynamicReevaluationRules)
        #expect(engine.needsWindowReevaluation)

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "org.mozilla.firefox",
                title: "Picture-in-Picture"
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .floating)
        #expect(decision.layoutDecisionKind == .explicitLayout)
        #expect(decision.trackedMode == .floating)
        if case .builtInRule("browserPictureInPicture") = decision.source {
        } else {
            Issue.record("Expected built-in browser PiP rule to classify the window")
        }
    }

    @Test func builtInFloatingRulePreservesMatchedUserWorkspaceAndEffects() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000132")!,
            bundleId: "com.apple.calculator",
            assignToWorkspace: "2",
            minWidth: 510,
            minHeight: 410
        )
        engine.rebuild(rules: [rule])

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.apple.calculator",
                appName: "Calculator",
                title: "Calculator"
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .floating)
        #expect(decision.layoutDecisionKind == .explicitLayout)
        #expect(decision.workspaceName == "2")
        #expect(decision.ruleEffects.minWidth == 510)
        #expect(decision.ruleEffects.minHeight == 410)
        // The built-in rule supplies disposition, but the matched user rule still
        // owns workspace assignment and sizing metadata.
        #expect(decision.ruleEffects.matchedRuleId == rule.id)
        if case .builtInRule("defaultFloatingApp") = decision.source {
        } else {
            Issue.record("Expected Calculator to use the built-in floating rule")
        }
    }

    @Test func invalidRegexIsTrackedAndExcludedFromCompiledRules() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000131")!,
            bundleId: "com.example.invalid-regex",
            titleRegex: "(",
            layout: .float
        )
        engine.rebuild(rules: [rule])

        #expect(engine.invalidRegexMessagesByRuleId[rule.id] != nil)

        let decision = engine.decision(
            for: makeWindowRuleFacts(bundleId: "com.example.invalid-regex"),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.source == .heuristic)
    }

    @Test func advancedOnlyRuleCompilesAndMatchesWithoutExplicitLayout() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000141")!,
            bundleId: "com.example.chooser",
            titleSubstring: "Chooser",
            axRole: kAXWindowRole as String,
            axSubrole: kAXStandardWindowSubrole as String
        )
        engine.rebuild(rules: [rule])

        #expect(engine.requiresTitle)
        #expect(engine.requiresTitle(for: "com.example.chooser"))
        #expect(engine.hasDynamicReevaluationRules)
        #expect(engine.needsWindowReevaluation)

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.chooser",
                appName: "Chooser App",
                title: "Project Chooser",
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.source == .userRule(rule.id))
        #expect(decision.layoutDecisionKind == .fallbackLayout)
        #expect(decision.ruleEffects.matchedRuleId == rule.id)
    }

    @Test func autoRuleWithWorkspaceAssignmentKeepsTrackedHeuristicFloatingFallback() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000161")!,
            bundleId: "com.example.illustrator",
            assignToWorkspace: "2"
        )
        engine.rebuild(rules: [rule])

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.illustrator",
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.source == .userRule(rule.id))
        #expect(decision.layoutDecisionKind == .fallbackLayout)
        #expect(decision.disposition == .floating)
        #expect(decision.trackedMode == .floating)
        #expect(decision.workspaceName == "2")
    }

    @Test func titleSensitiveFallbackDefersUntilTitleArrives() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "org.mozilla.firefox",
                title: nil
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .undecided)
        #expect(decision.deferredReason == .requiredTitleMissing)
        #expect(decision.trackedMode == nil)
    }

    @Test func invalidRegexOnlyRuleIsTrackedAndExcludedFromCompiledRules() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000151")!,
            bundleId: "com.example.invalid-regex-only",
            titleRegex: "("
        )
        engine.rebuild(rules: [rule])

        #expect(engine.invalidRegexMessagesByRuleId[rule.id] != nil)
        #expect(engine.requiresTitle(for: "com.example.invalid-regex-only") == false)

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.invalid-regex-only",
                title: "Anything"
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.source == .heuristic)
    }
}
