// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

enum DefaultFloatingApps {
    static let bundleIds: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.SystemPreferences",
        "com.apple.iphonesimulator",
        "com.apple.PhotoBooth",
        "com.apple.calculator",
        "com.apple.ScreenSharing",
        "com.apple.remotedesktop",
        "com.itoolab.unlockgo"
    ]

    static func shouldFloat(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return bundleIds.contains(bundleId)
    }
}
