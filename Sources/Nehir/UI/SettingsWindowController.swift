// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    var cliManager: AppCLIManager?

    private var window: NSWindow?
    private nonisolated(unsafe) var willCloseObserverToken: NSObjectProtocol?
    private let navigation = SettingsNavigationModel()
    private let ownedWindowRegistry = OwnedWindowRegistry.shared

    deinit {
        if let willCloseObserverToken {
            NotificationCenter.default.removeObserver(willCloseObserverToken)
        }
    }

    func show(
        settings: SettingsStore,
        controller: WMController,
        section: SettingsSection? = nil,
        pendingAppRuleDraft: AppRuleDraft? = nil
    ) {
        if let section {
            navigation.selectedSection = section
        }
        navigation.pendingAppRuleDraft = pendingAppRuleDraft

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        navigation.selectedSection = section ?? .general
        let settingsView = SettingsView(
            settings: settings,
            controller: controller,
            navigation: navigation,
            cliManager: cliManager
        )

        let hosting = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Nehir Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = false
        window.setContentSize(NSSize(width: 900, height: 680))
        window.minSize = NSSize(width: 760, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        ownedWindowRegistry.register(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let willCloseObserverToken {
            NotificationCenter.default.removeObserver(willCloseObserverToken)
        }
        willCloseObserverToken = NotificationCenter.default
            .addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [
                weak self,
                weak controller
            ] _ in
                MainActor.assumeIsolated {
                    if let willCloseObserverToken = self?.willCloseObserverToken {
                        NotificationCenter.default.removeObserver(willCloseObserverToken)
                        self?.willCloseObserverToken = nil
                    }
                    self?.ownedWindowRegistry.unregister(window)
                    self?.window = nil
                    controller?.handleOwnedFocusSuppressingWindowClosed()
                }
            }
        self.window = window
    }

    var windowForTests: NSWindow? {
        window
    }

    func isPointInside(_ point: CGPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        return window.frame.contains(point)
    }
}
