import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var settings: SettingsStore?
    private var onboardingStore: OnboardingStateStore?

    private var window: NSWindow?
    private var whatsNewWindow: NSWindow?
    private var migrationWindow: NSWindow?
    private var onboardingWindowOnClose: (@MainActor () -> Void)?

    private nonisolated(unsafe) var observerTokens: [ObjectIdentifier: NSObjectProtocol] = [:]
    private let ownedWindowRegistry = OwnedWindowRegistry.shared

    deinit {
        for token in observerTokens.values {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Registers the stores so `rerun()` works even when the wizard does not auto-show
    /// (i.e. onboarding was already completed on a previous launch).
    func configure(settings: SettingsStore, onboardingStore: OnboardingStateStore) {
        self.settings = settings
        self.onboardingStore = onboardingStore
    }

    func show(settings: SettingsStore, onboardingStore: OnboardingStateStore) {
        configure(settings: settings, onboardingStore: onboardingStore)
        if let window {
            showWizard(in: window, settings: settings, onboardingStore: onboardingStore)
            return
        }

        // Suppress the layout engine + global hotkeys while the wizard is on screen.
        AppDelegate.sharedBootstrap?.controller?.setOnboardingActive(true)
        resetOnboardingWindowCloseAction()
        let view = makeOnboardingView(settings: settings, onboardingStore: onboardingStore)
        present(existing: nil, rootView: view, title: "Welcome to Nehir", size: NSSize(width: 480, height: 640)) {
            self.window = $0
        } onClose: { [weak self] in
            self?.onboardingWindowOnClose?()
            self?.onboardingWindowOnClose = nil
        }
    }

    /// Re-opens the wizard from Settings. Uses the stores registered via `configure`/`show`.
    func rerun() {
        guard let settings, let onboardingStore else { return }
        show(settings: settings, onboardingStore: onboardingStore)
    }

    func showWhatsNew(version: String, sections: [WhatsNewContent.Section]) {
        let store = onboardingStore ?? OnboardingStateStore()
        let view = WhatsNewView(
            version: version,
            sections: sections,
            onDismiss: { [weak self] in self?.whatsNewWindow?.close() },
            onRerunOnboarding: { [weak self] in
                self?.whatsNewWindow?.close()
                self?.rerun()
            }
        )
        present(existing: whatsNewWindow, rootView: view, title: "What's New", size: NSSize(width: 480, height: 640)) {
            self.whatsNewWindow = $0
        } onClose: {
            // Treat traffic-light close and "Got it" the same: mark acknowledged.
            store.record(version: version)
            store.flushNow()
        }
    }

    /// Shows What's New for the current release (used by the status-bar menu and the
    /// onboarding final screen).
    func showWhatsNewForCurrentVersion() {
        guard !WhatsNewContent.isEmpty else { return }
        showWhatsNew(version: Bundle.main.appVersion ?? "dev", sections: WhatsNewContent.sections)
    }

    /// Replaces the onboarding wizard window with What's New (Done-step "See What's New").
    func showWhatsNewReplacingOnboarding() {
        guard !WhatsNewContent.isEmpty else { return }
        guard let window, let settings, let onboardingStore else {
            showWhatsNewForCurrentVersion()
            return
        }

        let version = Bundle.main.appVersion ?? "dev"
        onboardingWindowOnClose = {
            onboardingStore.record(version: version)
            onboardingStore.flushNow()
            AppDelegate.sharedBootstrap?.controller?.setOnboardingActive(false)
        }
        let view = WhatsNewView(
            version: version,
            sections: WhatsNewContent.sections,
            onDismiss: { [weak self] in
                onboardingStore.record(version: version)
                onboardingStore.flushNow()
                self?.window?.close()
            },
            onRerunOnboarding: { [weak self] in
                self?.showWizard(in: window, settings: settings, onboardingStore: onboardingStore)
            }
        )
        replaceContent(
            in: window,
            rootView: view,
            title: "What's New",
            size: NSSize(width: 480, height: 640)
        )
    }

    func showConfigRecovery(
        affectedFile: URL,
        details: [String],
        backupURL: URL? = nil,
        onClose: @escaping @MainActor () -> Void
    ) {
        let view = ConfigRecoveryView(
            affectedFile: affectedFile,
            details: details,
            backupURL: backupURL,
            onDismiss: { [weak self] in self?.migrationWindow?.close() }
        )
        present(existing: migrationWindow, rootView: view, title: "Settings Recovery", size: NSSize(width: 500, height: 580)) {
            self.migrationWindow = $0
        } onClose: {
            onClose()
        }
    }

    func dismiss() {
        window?.close()
    }

    /// Opens the Settings window. Resolves the controller from the app bootstrap state
    /// (Settings needs both settings + controller).
    func showSettings() {
        guard let settings,
              let controller = AppDelegate.sharedBootstrap?.controller else { return }
        SettingsWindowController.shared.show(settings: settings, controller: controller)
    }

    private func makeOnboardingView(
        settings: SettingsStore,
        onboardingStore: OnboardingStateStore
    ) -> OnboardingView {
        OnboardingView(
            settings: settings,
            onboardingStore: onboardingStore,
            onFinish: { [weak self] in self?.dismiss() }
        )
    }

    private func showWizard(
        in window: NSWindow,
        settings: SettingsStore,
        onboardingStore: OnboardingStateStore
    ) {
        AppDelegate.sharedBootstrap?.controller?.setOnboardingActive(true)
        resetOnboardingWindowCloseAction()
        replaceContent(
            in: window,
            rootView: makeOnboardingView(settings: settings, onboardingStore: onboardingStore),
            title: "Welcome to Nehir",
            size: NSSize(width: 480, height: 640)
        )
    }

    private func resetOnboardingWindowCloseAction() {
        onboardingWindowOnClose = {
            AppDelegate.sharedBootstrap?.controller?.setOnboardingActive(false)
        }
    }

    private func replaceContent<V: View>(
        in window: NSWindow,
        rootView: V,
        title: String,
        size: NSSize
    ) {
        let preservedTop = window.frame.maxY

        window.contentViewController = NSHostingController(rootView: rootView)
        window.title = title
        window.setContentSize(size)

        var frame = window.frame
        frame.origin.y = preservedTop - frame.height
        window.setFrame(frame, display: true)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present(
        existing: NSWindow?,
        rootView: some View,
        title: String,
        size: NSSize,
        assign: @escaping @MainActor (NSWindow?) -> Void,
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        if let existing {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: rootView)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = title
        newWindow.styleMask = [.titled, .closable, .fullSizeContentView]
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.setContentSize(size)
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        ownedWindowRegistry.register(newWindow)
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let key = ObjectIdentifier(newWindow)
        if let token = observerTokens[key] {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow,
            queue: .main
        ) { [weak self, weak newWindow] _ in
            MainActor.assumeIsolated {
                guard let closingWindow = newWindow else { return }
                let closeKey = ObjectIdentifier(closingWindow)
                if let token = self?.observerTokens[closeKey] {
                    NotificationCenter.default.removeObserver(token)
                    self?.observerTokens[closeKey] = nil
                }
                self?.ownedWindowRegistry.unregister(closingWindow)
                assign(nil)
                onClose()
            }
        }
        assign(newWindow)
    }
}
