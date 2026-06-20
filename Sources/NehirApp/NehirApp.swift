// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir
import SwiftUI

@main
struct NehirApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var bootstrap: AppBootstrapState

    init() {
        let bootstrap = AppBootstrapState()
        _bootstrap = State(wrappedValue: bootstrap)
        AppDelegate.sharedBootstrap = bootstrap
    }

    var body: some Scene {
        Settings {
            SettingsSceneRedirectView(bootstrap: bootstrap)
        }
    }
}
