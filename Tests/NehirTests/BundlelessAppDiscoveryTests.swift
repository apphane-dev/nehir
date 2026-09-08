// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir
import Testing

@Suite(.serialized) @MainActor struct BundlelessAppDiscoveryTests {
    @Test func bundledNamesRemainLiteralAndBundlelessNamesRequireText() {
        let bundled = AppInfoCache.AppInfo(
            name: "  Bundled  ", bundleId: "com.example.app", icon: nil, activationPolicy: .regular
        )
        let bundleless = AppInfoCache.AppInfo(
            name: "  QEMU  ", bundleId: nil, icon: nil, activationPolicy: .regular
        )
        let unnamed = AppInfoCache.AppInfo(name: "   ", bundleId: nil, icon: nil, activationPolicy: .regular)

        #expect(WindowActionHandler.runningAppName(for: bundled) == "  Bundled  ")
        #expect(WindowActionHandler.runningAppName(for: bundleless) == "QEMU")
        #expect(WindowActionHandler.runningAppName(for: unnamed) == nil)
    }

    @Test func appsQueryDeduplicatesBundlelessNames() {
        let controller = makeLayoutPlanTestController()
        defer { resetSharedControllerStateForTests() }
        let workspace = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        for (pid, windowID) in [(8_004, 1_104), (8_005, 1_105)] {
            controller.appInfoCache.storeInfoForTests(pid: pid_t(pid), name: "QEMU", bundleId: nil)
            _ = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: windowID), pid: pid_t(pid), windowId: windowID, to: workspace
            )
        }

        let apps = IPCQueryRouter(controller: controller, sessionToken: "bundleless-apps").appsResult().apps
        #expect(apps.filter { $0.bundleId == nil && $0.appName == "QEMU" }.count == 1)
    }
}
