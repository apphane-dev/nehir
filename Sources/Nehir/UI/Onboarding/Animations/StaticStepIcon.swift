// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

struct StaticStepIcon: View {
    let step: OnboardingStep

    var body: some View {
        ZStack {
            Image(systemName: symbolName)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .opacity(0.5)
        }
    }

    private var symbolName: String {
        switch step {
        case .experimental: "flask"
        case .done: "checkmark.seal"
        default: "rectangle.3.group"
        }
    }
}
