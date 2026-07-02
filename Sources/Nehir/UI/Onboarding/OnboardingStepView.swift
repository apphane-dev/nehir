// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

struct OnboardingStepView<Animation: View, Control: View>: View {
    let step: OnboardingStep
    let stepIndex: Int
    let stepCount: Int
    @ViewBuilder let animation: () -> Animation
    @ViewBuilder let control: () -> Control

    let onContinue: () -> Void
    let onBack: () -> Void
    var onOpenSettings: (() -> Void)? = nil

    private var canGoBack: Bool {
        stepIndex > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(step.title)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(step.bodyText)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 24)

            animation()
                .frame(height: step.animationHeight, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 16)

            control()
                .frame(maxWidth: .infinity)

            Spacer(minLength: 16)

            VStack(spacing: 14) {
                HStack(spacing: 7) {
                    ForEach(0 ..< stepCount, id: \.self) { index in
                        Capsule()
                            .fill(index == stepIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: index == stepIndex ? 16 : 6, height: 6)
                            .animation(.easeInOut(duration: 0.25), value: stepIndex)
                    }
                }

                HStack {
                    if canGoBack {
                        Button(action: onBack) {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    } else {
                        Spacer().frame(width: 80)
                    }
                    Spacer()
                    if step == .done, let onOpenSettings {
                        Button("Open Settings", action: onOpenSettings)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                    Button(action: onContinue) {
                        ZStack {
                            // Reserve space for the longest label so the bezel — and its focus
                            // ring — is identical on every step. No resize between "Continue"
                            // and "Start Using Nehir", so the halo can never mismatch.
                            Text("Start Using Nehir").hidden()
                            Text(step.continueButtonTitle)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension OnboardingStepView where Control == EmptyView {
    init(
        step: OnboardingStep,
        stepIndex: Int,
        stepCount: Int,
        @ViewBuilder animation: @escaping () -> Animation,
        onContinue: @escaping () -> Void,
        onBack: @escaping () -> Void
    ) {
        self.step = step
        self.stepIndex = stepIndex
        self.stepCount = stepCount
        self.animation = animation
        self.control = { EmptyView() }
        self.onContinue = onContinue
        self.onBack = onBack
    }
}
