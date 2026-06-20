// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class MenuAnywhereFetcher {
    private let menuExtractor = MenuExtractor()

    func fetchMenuItemsSync(for pid: pid_t) -> [MenuItemModel] {
        guard let menuBar = menuExtractor.getMenuBar(for: pid) else {
            return []
        }
        return menuExtractor.flattenMenuItems(from: menuBar, appName: nil, excludeAppleMenu: true)
    }
}
