import AppKit
import Observation

@MainActor @Observable
final class AppBootstrapState {
    var settings: SettingsStore?
    var controller: WMController?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) weak static var sharedBootstrap: AppBootstrapState?
    static var ipcServerFactoryForTests: ((WMController) -> IPCServerLifecycle)?

    private var statusBarController: StatusBarController?
    private var ipcServer: IPCServerLifecycle?
    private var cliManager: AppCLIManager?
    private var runtimeStateStore: RuntimeStateStore?
    private var onboardingStateStore: OnboardingStateStore?

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        bootstrapApplication()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        if let controller = AppDelegate.sharedBootstrap?.controller {
            controller.restoreHiddenWindowsForGracefulTermination()
            controller.serviceLifecycleManager.stop()
            controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
        }
        AppDelegate.sharedBootstrap?.settings?.flushNow()
        stopIPCServer()
        runtimeStateStore?.flushNow()
        onboardingStateStore?.flushNow()
    }

    func bootstrapApplication() {
        switch AppBootstrapPlanner.decision() {
        case .boot:
            finishBootstrap(
                enableTracing: ProcessInfo.processInfo.arguments.contains(WMController.traceLaunchArgument)
            )
        }
    }

    func finishBootstrap(enableTracing: Bool = false) {
        let storagePaths = NehirStoragePaths.live

        // Startup recovery is reserved for invalid / unsupported config that cannot be
        // decoded safely. Valid but unrecognized keys are preserved and surfaced later in
        // Diagnostics; they never block launch and are never stripped here.
        let settingsURL = storagePaths.configDirectory.appendingPathComponent("settings.toml", isDirectory: false)
        if let recoveryDetails = settingsLoadFailureDetails(settingsURL: settingsURL) {
            OnboardingWindowController.shared.showConfigRecovery(
                affectedFile: settingsURL,
                details: recoveryDetails,
                onClose: { [weak self] in
                    self?.continueBootstrap(storagePaths: storagePaths, enableTracing: enableTracing)
                }
            )
            return
        }

        continueBootstrap(storagePaths: storagePaths, enableTracing: enableTracing)
    }

    private func continueBootstrap(storagePaths: NehirStoragePaths, enableTracing: Bool) {
        // Guard against duplicate continuation if a close notification is delivered twice.
        if AppDelegate.sharedBootstrap?.controller != nil {
            return
        }

        let runtimeState = RuntimeStateStore(directory: storagePaths.stateDirectory)
        self.runtimeStateStore = runtimeState

        let onboardingStore = OnboardingStateStore(directory: storagePaths.stateDirectory)
        self.onboardingStateStore = onboardingStore

        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: storagePaths.configDirectory),
            runtimeState: runtimeState
        )
        OnboardingWindowController.shared.configure(settings: settings, onboardingStore: onboardingStore)
        let controller = WMController(
            settings: settings
        )
        let willShowOnboarding = !onboardingStore.hasCompletedOnboarding
        if willShowOnboarding {
            // Suppress tiling + global hotkeys before the engine starts so the wizard
            // never moves real windows or intercepts the shortcuts it demonstrates.
            controller.setOnboardingActive(true)
        }
        if enableTracing {
            _ = controller.toggleRuntimeTraceCapture(desiredState: .active)
        }
        controller.applyPersistedSettings(settings)
        let cliManager = AppCLIManager()
        self.cliManager = cliManager
        SettingsWindowController.shared.cliManager = cliManager

        AppDelegate.sharedBootstrap?.settings = settings
        AppDelegate.sharedBootstrap?.controller = controller

        statusBarController = StatusBarController(
            settings: settings,
            controller: controller,
            cliManager: cliManager
        )
        controller.statusBarController = statusBarController
        settings.onIPCEnabledChanged = { [weak self, weak controller] isEnabled in
            guard let self, let controller else { return }
            do {
                try self.setIPCEnabled(isEnabled, controller: controller)
            } catch {
                self.presentInfoAlert(
                    title: "IPC Failed to Start",
                    message: error.localizedDescription
                )
                if isEnabled {
                    settings.ipcEnabled = false
                }
            }
            self.statusBarController?.refreshMenu()
        }
        settings.onExternalSettingsReloaded = { [weak controller, weak self] in
            guard let controller else { return }
            controller.applyPersistedSettings(settings)
            self?.statusBarController?.refreshMenu()
        }
        statusBarController?.setup()
        do {
            try setIPCEnabled(settings.ipcEnabled, controller: controller)
        } catch {
            presentInfoAlert(
                title: "IPC Failed to Start",
                message: error.localizedDescription
            )
            settings.ipcEnabled = false
        }

        if willShowOnboarding {
            DispatchQueue.main.async {
                OnboardingWindowController.shared.show(settings: settings, onboardingStore: onboardingStore)
            }
        } else {
            // Auto-show What's New once per major/minor release. The running build must
            // be a release version (dev's `0.0.0` placeholder and prereleases like
            // `0.5.0-rc.1` stay silent), newer in major/minor than the version the user
            // last acknowledged, and there must be content to show. Patch releases reuse
            // current content but do not auto-show it again.
            if let appVersion = Bundle.main.appVersion,
               Self.shouldAutoShowWhatsNew(
                   appVersion: appVersion,
                   lastSeenVersion: onboardingStore.lastSeenVersion,
                   hasContent: !WhatsNewContent.isEmpty
               )
            {
                DispatchQueue.main.async {
                    OnboardingWindowController.shared.showWhatsNew(
                        version: appVersion,
                        sections: WhatsNewContent.sections
                    )
                }
            }
        }
    }

    private func settingsLoadFailureDetails(settingsURL: URL) -> [String]? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: settingsURL)
            _ = try SettingsTOMLCodec.decode(data)
            return nil
        } catch {
            return [error.localizedDescription]
        }
    }

    /// A "release" version is `MAJOR.MINOR.PATCH` with no prerelease tag and not the `0.0.0`
    /// dev placeholder. Prereleases (`0.5.0-rc.1`) and dev builds stay silent.
    private static func isReleaseVersion(_ version: String) -> Bool {
        if version.contains("-") { return false }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 && parts != [0, 0, 0]
    }

    static func shouldAutoShowWhatsNew(
        appVersion: String,
        lastSeenVersion: String?,
        hasContent: Bool
    ) -> Bool {
        guard isReleaseVersion(appVersion),
              hasContent,
              let lastSeenVersion
        else {
            return false
        }
        return isMajorMinorVersion(appVersion, newerThan: lastSeenVersion)
    }

    /// Numeric `MAJOR.MINOR` ordering. Patch releases reuse the current What's New
    /// content but do not auto-show it again for users who already acknowledged the
    /// same major/minor release.
    private static func isMajorMinorVersion(_ currentVersion: String, newerThan previousVersion: String) -> Bool {
        func tuple(_ versionString: String) -> (Int, Int) {
            let core = versionString.split(separator: "-").first.map(String.init) ?? versionString
            let parts = core.split(separator: ".").compactMap { Int($0) }
            return parts.count == 3 ? (parts[0], parts[1]) : (-1, -1)
        }
        let (current, previous) = (tuple(currentVersion), tuple(previousVersion))
        if current.0 != previous.0 { return current.0 > previous.0 }
        return current.1 > previous.1
    }

    func startIPCServer(controller: WMController) throws {
        if ipcServer != nil {
            stopIPCServer()
        }
        let server = Self.ipcServerFactoryForTests?(controller) ?? IPCServer(controller: controller)
        try server.start()
        ipcServer = server
    }

    func setIPCEnabled(_ enabled: Bool, controller: WMController) throws {
        if enabled {
            try startIPCServer(controller: controller)
        } else {
            stopIPCServer()
        }
    }

    private func stopIPCServer() {
        ipcServer?.stop()
        ipcServer = nil
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }
}
