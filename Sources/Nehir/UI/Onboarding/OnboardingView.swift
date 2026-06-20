// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

struct OnboardingView: View {
    @Bindable var settings: SettingsStore
    let onboardingStore: OnboardingStateStore
    let onFinish: () -> Void

    @State private var currentIndex: Int = 0
    @State private var isAccessibilityGranted: Bool = AccessibilityPermissionMonitor.shared.isGranted

    private let steps = OnboardingStep.allCases

    private var currentStep: OnboardingStep {
        steps.indices.contains(currentIndex) ? steps[currentIndex] : .done
    }

    var body: some View {
        OnboardingStepView(
            step: currentStep,
            stepIndex: min(currentIndex, steps.count - 1),
            stepCount: steps.count,
            animation: { animationView(for: currentStep) },
            control: { controlView(for: currentStep) },
            onContinue: { advance() },
            onBack: { goBack() },
            onOpenSettings: OnboardingWindowController.shared.showSettings
        )
        // No step-change animation: an animated morph of the Continue button's frame
        // (label grows to "Start Using Nehir") left the focus-ring halo stuck at the
        // previous size, and rebuilding via `.id(currentStep)` lost keyboard focus.
        // Instant swap keeps the button's identity stable (focus preserved) and lets
        // the focus ring redraw at the correct size.
        .frame(width: 480, height: 640)
        .background(.thickMaterial)
        .onAppear { isAccessibilityGranted = AccessibilityPermissionMonitor.shared.isGranted }
        .task(id: "accessibility") {
            for await granted in AccessibilityPermissionMonitor.shared.stream(initial: false) {
                isAccessibilityGranted = granted
            }
        }
    }

    @ViewBuilder
    private func animationView(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            VStack(spacing: 12) {
                NehirLogo()
                    .frame(maxWidth: 200)
                WelcomeAnimation()
                    .frame(maxHeight: 110)
            }
        case .navigation:
            InteractiveMoveDemo()
        case .workspaceBar:
            WorkspaceBarAnimation(
                showLabels: settings.workspaceBarShowLabels,
                showFloatingWindows: settings.workspaceBarShowFloatingWindows,
                deduplicateAppIcons: settings.workspaceBarDeduplicateAppIcons,
                hideEmptyWorkspaces: settings.workspaceBarHideEmptyWorkspaces
            )
        default:
            StaticStepIcon(step: step)
        }
    }

    @ViewBuilder
    private func controlView(for step: OnboardingStep) -> some View {
        switch step {
        case .navigation:
            NavigationStepControl()
        case .workspaceBar:
            WorkspaceBarStepControl(settings: settings)
        case .experimental:
            ExperimentalStepControl(settings: settings)
        case .done:
            DoneStepControl(
                isGranted: isAccessibilityGranted,
                onShowWhatsNew: { OnboardingWindowController.shared.showWhatsNewReplacingOnboarding() }
            )
        case .welcome:
            AccessibilityStepControl(isGranted: isAccessibilityGranted)
        }
    }

    private func advance() {
        if currentStep == .done {
            onboardingStore.record(version: Bundle.main.appVersion ?? "dev")
            onboardingStore.flushNow()
            onFinish()
            return
        }
        currentIndex += 1
    }

    private func goBack() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }
}
