// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

struct SettingInfo: View {
    let text: String
    var consequence: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let consequence {
                Text(consequence)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
