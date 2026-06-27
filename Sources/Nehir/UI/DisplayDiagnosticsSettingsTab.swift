// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftUI

struct DisplayDiagnosticsSettingsTab: View {
    @Bindable var settings: SettingsStore
    var controller: WMController
    @Bindable var navigation: SettingsNavigationModel

    @State private var diagnostics = DisplayEnvironmentDiagnostics.current()
    @State private var displaySpacesMode: DisplaySpacesMode = .unavailable
    @State private var monitors = Monitor.current()
    @State private var axGranted = AccessibilityPermissionMonitor.shared.isGranted
    @State private var applicableSettingsIssues: [SettingsDiagnosticsIssue] = []
    @State private var migrationConfirmation: String?
    @State private var migrationError: String?
    @State private var unknownKeysConfirmation: String?
    @State private var unknownKeysError: String?
    @State private var traceCaptureStatus: WMController.RuntimeTraceCaptureStatus = .init(
        isActive: false,
        startedAt: nil
    )
    @State private var backgroundTraceStatus: BackgroundTraceBufferStatus = .init(
        isEnabled: false,
        retainedStart: nil,
        retainedEnd: nil,
        eventCount: 0,
        estimatedBytes: 0,
        maxBytes: 64 * 1024 * 1024,
        retentionSeconds: 0
    )
    private let traceStatusRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var recentTraces: [TraceFile] = []
    @State private var traceCopyStatus: String?
    @State private var runtimeActionStatus: String?

    private let configDirectory: URL
    private let migrationStateStore: SettingsMigrationStateStore
    private let appVersion: String

    init(
        settings: SettingsStore,
        controller: WMController,
        navigation: SettingsNavigationModel,
        configDirectory: URL = SettingsFilePersistence.defaultDirectoryURL,
        migrationStateStore: SettingsMigrationStateStore = SettingsMigrationStateStore(),
        appVersion: String = Bundle.main.appVersion ?? "dev"
    ) {
        self.settings = settings
        self.controller = controller
        self.navigation = navigation
        self.configDirectory = configDirectory
        self.migrationStateStore = migrationStateStore
        self.appVersion = appVersion
    }

    var body: some View {
        Form {
            Section("Accessibility") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: axGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(axGranted ? .green : .red)
                        .font(.title3)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(axGranted ? "Accessibility access granted" : "Accessibility access not granted")
                            .font(.headline)
                        Text("Nehir needs Accessibility access to observe and manage windows.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !axGranted {
                    Button("Open System Settings") {
                        if let url =
                            URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                            )
                        {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            if !applicableSettingsIssues
                .isEmpty || migrationConfirmation != nil || migrationError != nil || unknownKeysConfirmation != nil ||
                unknownKeysError != nil
            {
                Section("Settings Configuration") {
                    ForEach(applicableSettingsIssues) { issue in
                        switch issue {
                        case .softMigration(let migration):
                            SettingsMigrationWarningView(
                                migration: migration,
                                isPostponed: isPostponed(migration),
                                confirmation: migrationConfirmation,
                                error: migrationError,
                                onMigrate: { migrate(migration) },
                                onPostpone: { postpone(migration) }
                            )
                        case .unknownKeys(let issue):
                            UnknownSettingsKeysWarningView(
                                issue: issue,
                                isPostponed: isUnknownKeysPostponed(issue),
                                confirmation: unknownKeysConfirmation,
                                error: unknownKeysError,
                                onCopyPrompt: { copyUnknownKeysPrompt(issue) },
                                onPostpone: { postponeUnknownKeys(issue) },
                                onClean: { cleanUnknownKeys(issue) }
                            )
                        case .hotkeyConflict(let issue):
                            HotkeyConflictWarningView(conflict: issue)
                        case .hotkeyAdvisory(let issue):
                            HotkeyConflictWarningView(advisory: issue)
                        }
                    }

                    if applicableSettingsIssues.isEmpty {
                        if let migrationConfirmation {
                            Label(migrationConfirmation, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        if let migrationError {
                            Label(migrationError, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                        if let unknownKeysConfirmation {
                            Label(unknownKeysConfirmation, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        if let unknownKeysError {
                            Label(unknownKeysError, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Section("Status") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: diagnostics
                        .hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(diagnostics.hasWarnings ? .yellow : .green)
                        .font(.title3)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(diagnostics
                            .hasWarnings ? "Recommendations need attention" : "Display environment looks good")
                            .font(.headline)
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Refresh Diagnostics") {
                    refresh()
                }
            }

            Section("Display and Dock Recommendations") {
                SettingsCaption(
                    "Nehir currently supports an auto-hide Dock and display arrangements with no vertical overlap: vertical or diagonal layouts in macOS System Settings. A diagonal arrangement is recommended when you want to avoid macOS' native cross-display edge warp and rely only on Nehir's configured Mouse Warp."
                )
                Label(
                    "Displays have separate Spaces: \(displaySpacesMode.displayName)",
                    systemImage: displaySpacesMode.systemImage
                )
                .foregroundStyle(.secondary)
                SettingsCaption(
                    "Separate Spaces is detected for visibility only; Nehir does not enforce it or change display-arrangement recommendations based on it yet."
                )

                if diagnostics.issues.isEmpty {
                    Label(
                        "No fixed Dock or unsupported vertical display overlap detected.",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.green)
                } else {
                    ForEach(diagnostics.issues) { issue in
                        DiagnosticIssueView(issue: issue)
                    }
                }
            }

            Section("Detected Displays") {
                if monitors.isEmpty {
                    Text("No displays detected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(monitors, id: \.id) { monitor in
                        DisplayDiagnosticMonitorRow(monitor: monitor)
                    }
                }
            }

            Section("Developer") {
                Toggle(isOn: $settings.developerModeEnabled) {
                    HStack(spacing: 8) {
                        Text("Developer Mode")
                        DeveloperBadge()
                    }
                }
                .onChange(of: settings.developerModeEnabled) { _, _ in
                    controller.updateWorkspaceBarSettings()
                    controller.updateBackgroundTraceBufferConfiguration()
                    refresh()
                }
                SettingsCaption(
                    "Shows debug commands in the palette, hotkey settings, and enables IPC debug endpoints."
                )
            }

            if settings.developerModeEnabled {
                runtimeStateSection
                backgroundTraceSection
                recentTracesSection
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification))
        { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsMigrationStateDidChange)) { _ in
            refreshSettingsIssues()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSettingsIssues()
            refreshTraceState()
        }
        .onReceive(traceStatusRefreshTimer) { _ in
            guard settings.developerModeEnabled else { return }
            refreshTraceStatusOnly()
        }
        .onChange(of: settings.hotkeyBindings) { _, _ in
            refreshSettingsIssues()
        }
    }

    @ViewBuilder
    private var backgroundTraceSection: some View {
        Section("Trace Buffer") {
            Picker("Retain recent events for", selection: $settings.backgroundTraceRetentionSeconds) {
                Text("Unlimited").tag(TimeInterval(0))
                Text("30 sec").tag(TimeInterval(30))
                Text("1 min").tag(TimeInterval(60))
                Text("2 min").tag(TimeInterval(120))
            }
            .onChange(of: settings.backgroundTraceRetentionSeconds) { _, _ in
                controller.updateBackgroundTraceBufferConfiguration()
                refresh()
            }

            Picker("Maximum buffer size", selection: $settings.backgroundTraceMaxBytes) {
                Text("16 MB").tag(16 * 1024 * 1024)
                Text("64 MB").tag(64 * 1024 * 1024)
                Text("128 MB").tag(128 * 1024 * 1024)
            }
            .onChange(of: settings.backgroundTraceMaxBytes) { _, _ in
                controller.updateBackgroundTraceBufferConfiguration()
                refresh()
            }

            LabeledContent("Status") {
                Text(backgroundTraceStatusText)
                    .foregroundStyle(.secondary)
            }

            SettingsCaption(
                "The existing Trace Capture toggle starts recording. While it is running, Nehir keeps a bounded local buffer for recent-clip exports. Old events are discarded automatically based on the retention window and size limit. Reset Buffer clears retained events without stopping the running trace capture."
            )
        }
    }

    @ViewBuilder
    private var runtimeStateSection: some View {
        Section {
            DebugCommandRow(
                title: "Dump Runtime State",
                hotkey: hotkey(for: "debug.dumpRuntimeState"),
                buttonTitle: "Copy State",
                run: {
                    controller.dumpRuntimeState()
                    runtimeActionStatus = "Runtime state copied to clipboard."
                    traceCopyStatus = nil
                }
            )

            DebugCommandRow(
                title: "Trace Capture",
                hotkey: hotkey(for: "debug.toggleTraceCapture"),
                buttonTitle: traceCaptureStatus.isActive ? "Stop" : "Start",
                run: {
                    _ = controller.toggleRuntimeTraceCapture()
                    runtimeActionStatus = nil
                    traceCopyStatus = nil
                    refresh()
                }
            )

            Picker("Viewport Trace Verbosity", selection: $settings.viewportTraceVerbosity) {
                ForEach(ViewportTraceVerbosity.allCases) { verbosity in
                    Text(verbosity.displayName).tag(verbosity)
                }
            }
            .onChange(of: settings.viewportTraceVerbosity) { _, _ in
                controller.applyViewportTraceVerbosity()
            }
            SettingsCaption(
                "Controls how much viewport trace captures record. "
                    + "Lean omits the per-line layout dump; Standard (default) adds it; "
                    + "Verbose also records per-frame gesture updates and per-mutation provenance."
            )

            DebugCommandRow(
                title: "Reset Runtime State",
                hotkey: hotkey(for: "debug.resetRuntimeState"),
                buttonTitle: "Reset",
                role: .destructive,
                run: { resetRuntimeState() }
            )

            DebugCommandRow(
                title: "Restart Clearing State",
                hotkey: hotkey(for: "debug.restartClearingRuntimeState"),
                buttonTitle: "Restart",
                role: .destructive,
                run: { restartClearingRuntimeState() }
            )

            Button("Assign in Hotkeys") {
                navigation.hotkeySearchSeed = "debug"
                navigation.selectedSection = .hotkeys
            }

            if let runtimeActionStatus {
                ActionStatusLabel(runtimeActionStatus)
            }

            SettingsCaption(
                "Reset rebuilds runtime state from a fresh rescan. Restart Clearing State relaunches Nehir after the same cleanup and can enable tracing from startup."
            )
        } header: {
            HStack(spacing: 6) {
                Text("Debug Actions")
                DeveloperBadge()
            }
        }
    }

    @ViewBuilder
    private var recentTracesSection: some View {
        Section("Recent Traces") {
            if recentTraces.isEmpty {
                Text("No trace captures yet. Start a trace, then stop it to export a log file.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentTraces) { trace in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(trace.url.lastPathComponent)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(formatFileSize(trace.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text(formatDate(trace.modificationDate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy Path") {
                                copyTracePath(trace)
                            }
                            .buttonStyle(.borderless)
                            Button("Copy File") {
                                copyTraceFile(trace)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                Button("Refresh Traces") {
                    refresh()
                }
                Button("Reveal Traces Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([WMController.traceCaptureDirectory])
                }
            }

            if let traceCopyStatus {
                Label(
                    traceCopyStatus,
                    systemImage: traceCopyFailed ? "xmark.circle.fill" : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(traceCopyFailed ? .red : .green)
            }
        }
    }

    private func hotkey(for actionId: String) -> HotkeyTrigger {
        settings.hotkeyBindings.first { $0.id == actionId }?.binding ?? .unassigned
    }

    private var statusMessage: String {
        guard diagnostics.hasWarnings else {
            return "Auto-hide Dock and vertical display arrangement are the expected low-artifact configuration."
        }
        return "Nehir can still run, but parked offscreen windows may leave visible strips or bleed onto neighboring displays."
    }

    /// `traceCopyStatus` follows the convention that failure messages start
    /// with "Couldn't"; everything else is a success. Used to switch the
    /// status label's icon and color instead of always showing a green check.
    private var traceCopyFailed: Bool {
        traceCopyStatus?.hasPrefix("Couldn't") ?? false
    }

    private var backgroundTraceStatusText: String {
        guard backgroundTraceStatus.isEnabled else { return "Disabled" }
        let rangeText: String
        if let start = backgroundTraceStatus.retainedStart, let end = backgroundTraceStatus.retainedEnd {
            rangeText = " • \(formatDuration(end.timeIntervalSince(start))) retained"
        } else {
            rangeText = ""
        }
        return "Buffering \(backgroundTraceStatus.eventCount) events • \(formatFileSize(Int64(backgroundTraceStatus.estimatedBytes))) of \(formatFileSize(Int64(backgroundTraceStatus.maxBytes)))\(rangeText)"
    }

    private func resetRuntimeState() {
        let confirmed = DestructiveConfirmationAlert.confirm(
            title: "Reset Runtime State",
            message: "This will clear all runtime state and rebootstrap from a rescan. Continue?",
            confirmTitle: "Reset"
        )
        guard confirmed else { return }

        _ = controller.commandHandler.performCommand(.debugResetRuntimeState)
        runtimeActionStatus = "Runtime state reset."
        traceCopyStatus = nil
        refresh()
    }

    private func restartClearingRuntimeState() {
        let result = DestructiveConfirmationAlert.confirmRestart(
            title: "Restart Clearing Runtime State",
            message: "This will clear runtime state and relaunch the app. Continue?",
            confirmTitle: "Restart"
        )
        guard result.confirmed else { return }

        _ = controller.commandHandler.performRestartClearingRuntimeState(enableTracing: result.enableTracing)
    }

    private func copyTracePath(_ trace: TraceFile) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(trace.url.path, forType: .string) {
            traceCopyStatus = "Copied trace path."
        } else {
            traceCopyStatus = "Couldn't copy trace path."
        }
        runtimeActionStatus = nil
    }

    private func copyTraceFile(_ trace: TraceFile) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([trace.url as NSURL]) {
            traceCopyStatus = "Copied trace file."
        } else {
            traceCopyStatus = "Couldn't copy trace file."
        }
        runtimeActionStatus = nil
    }

    private func loadRecentTraces() -> [TraceFile] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: WMController.traceCaptureDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        let traces = contents
            .filter { $0.pathExtension.lowercased() == "log" }
            .compactMap { url -> TraceFile? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                return TraceFile(
                    url: url,
                    modificationDate: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                    size: Int64(values.fileSize ?? 0)
                )
            }
            .sorted { $0.modificationDate > $1.modificationDate }

        return Array(traces.prefix(10))
    }

    private func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refresh() {
        monitors = Monitor.current()
        displaySpacesMode = SkyLight.shared.displaySpacesMode(monitors: monitors)
        diagnostics = DisplayEnvironmentDiagnostics.evaluate(monitors: monitors, spacesMode: displaySpacesMode)
        axGranted = AccessibilityPermissionMonitor.shared.isGranted
        refreshSettingsIssues()
        refreshTraceState()
    }

    private func refreshTraceState() {
        traceCaptureStatus = controller.runtimeTraceCaptureStatus
        backgroundTraceStatus = controller.backgroundTraceBufferStatus
        recentTraces = loadRecentTraces()
    }

    /// Lightweight status-only refresh used by the 1s timer; avoids scanning
    /// the traces directory on every tick.
    private func refreshTraceStatusOnly() {
        traceCaptureStatus = controller.runtimeTraceCaptureStatus
        backgroundTraceStatus = controller.backgroundTraceBufferStatus
    }

    private func refreshSettingsIssues() {
        applicableSettingsIssues = SettingsDiagnosticsDetector.applicableIssues(
            configDirectory: configDirectory,
            hotkeyFailures: controller.hotkeyRegistrationFailures,
            hotkeyBindings: settings.hotkeyBindings
        )
    }

    private func isPostponed(_ migration: PendingSettingsMigration) -> Bool {
        migrationStateStore.isPostponed(migrationID: migration.id, currentAppVersion: appVersion)
    }

    private func migrate(_ migration: PendingSettingsMigration) {
        migrationConfirmation = nil
        migrationError = nil

        do {
            switch migration.id {
            case SettingsMigrationRegistry.workspacesArrayToKeyedTables.id:
                let backupURL = try WorkspacesConfigMigration.migrate(fileURL: migration.fileURL)
                try migrationStateStore.clearPostpone(migrationID: migration.id)
                migrationConfirmation = "Migrated workspaces.toml. Backup: \(backupURL.lastPathComponent)"
            default:
                migrationError = "No migration action is registered for \(migration.id)."
            }
            refreshSettingsIssues()
            NotificationCenter.default.post(name: .settingsMigrationStateDidChange, object: nil)
        } catch {
            migrationError = error.localizedDescription
        }
    }

    private func postpone(_ migration: PendingSettingsMigration) {
        migrationConfirmation = nil
        migrationError = nil

        do {
            try migrationStateStore.postpone(migrationID: migration.id, currentAppVersion: appVersion)
            migrationConfirmation = "Reminder hidden until the next Nehir update. You can still migrate now."
            refreshSettingsIssues()
            NotificationCenter.default.post(name: .settingsMigrationStateDidChange, object: nil)
        } catch {
            migrationError = error.localizedDescription
        }
    }

    private func isUnknownKeysPostponed(_ issue: UnknownSettingsKeysIssue) -> Bool {
        migrationStateStore.isPostponed(migrationID: issue.id, currentAppVersion: appVersion)
    }

    private func copyUnknownKeysPrompt(_ issue: UnknownSettingsKeysIssue) {
        unknownKeysConfirmation = nil
        unknownKeysError = nil

        let prompt = ConfigAssistancePrompt.prompt(
            kind: .unknownKeys,
            appVersion: appVersion,
            affectedFile: issue.fileURL,
            details: issue.keyPaths
        )
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(prompt, forType: .string) {
            unknownKeysConfirmation = "Prompt copied to clipboard"
        } else {
            unknownKeysError = "Couldn't copy prompt to clipboard."
        }
    }

    private func postponeUnknownKeys(_ issue: UnknownSettingsKeysIssue) {
        unknownKeysConfirmation = nil
        unknownKeysError = nil

        do {
            try migrationStateStore.postpone(migrationID: issue.id, currentAppVersion: appVersion)
            unknownKeysConfirmation = "Reminder hidden until the next Nehir update."
            refreshSettingsIssues()
            NotificationCenter.default.post(name: .settingsMigrationStateDidChange, object: nil)
        } catch {
            unknownKeysError = error.localizedDescription
        }
    }

    private func cleanUnknownKeys(_ issue: UnknownSettingsKeysIssue) {
        unknownKeysConfirmation = nil
        unknownKeysError = nil

        do {
            let backupURL = try cleanUnknownSettingsKeys(fileURL: issue.fileURL)
            try migrationStateStore.clearPostpone(migrationID: issue.id)
            unknownKeysConfirmation = "Removed unknown keys. Backup: \(backupURL.lastPathComponent)"
            refreshSettingsIssues()
            NotificationCenter.default.post(name: .settingsMigrationStateDidChange, object: nil)
        } catch {
            unknownKeysError = error.localizedDescription
        }
    }
}

private struct TraceFile: Identifiable {
    let url: URL
    let modificationDate: Date
    let size: Int64

    var id: URL {
        url
    }
}

/// A single debug command rendered as a row: its title, the currently
/// assigned shortcut, and a button that runs the command directly. Joins the
/// "what hotkey is bound" info with the run action in one place.
private struct DebugCommandRow: View {
    let title: String
    let hotkey: HotkeyTrigger
    let buttonTitle: String
    var role: ButtonRole?
    let run: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(hotkey.displayString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(hotkey.isUnassigned ? .tertiary : .secondary)
                    .lineLimit(1)
                runButton
                    .frame(width: 104, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private var runButton: some View {
        if let role {
            Button(buttonTitle, role: role, action: run)
        } else {
            Button(buttonTitle, action: run)
        }
    }
}

private struct ActionStatusLabel: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    private var isFailure: Bool {
        message.hasPrefix("Couldn't") || message.hasPrefix("Failed")
    }

    var body: some View {
        Label(message, systemImage: isFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(isFailure ? .red : .green)
    }
}

private struct SettingsMigrationWarningView: View {
    let migration: PendingSettingsMigration
    let isPostponed: Bool
    let confirmation: String?
    let error: String?
    let onMigrate: () -> Void
    let onPostpone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                migration.descriptor.title,
                systemImage: isPostponed ? "info.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(isPostponed ? Color.secondary : Color.yellow)

            if isPostponed {
                Text("Reminder hidden until the next Nehir update. You can still migrate now.")
                    .foregroundStyle(.secondary)
            }

            Text(migration.descriptor.warningBody)
                .foregroundStyle(.secondary)

            Text(migration.descriptor.enforcementWarning)
                .font(.callout.weight(.semibold))

            Text("File: \(migration.fileURL.path)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Button("Migrate") {
                    onMigrate()
                }
                .buttonStyle(.borderedProminent)

                if isPostponed {
                    Button("Postponed") {}
                        .buttonStyle(.bordered)
                        .disabled(true)
                } else {
                    Button("Postpone Warning") {
                        onPostpone()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let error {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct UnknownSettingsKeysWarningView: View {
    let issue: UnknownSettingsKeysIssue
    let isPostponed: Bool
    let confirmation: String?
    let error: String?
    let onCopyPrompt: () -> Void
    let onPostpone: () -> Void
    let onClean: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Unrecognized settings keys",
                systemImage: isPostponed ? "info.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(isPostponed ? Color.secondary : Color.yellow)

            if isPostponed {
                Text("Reminder hidden until the next Nehir update. The keys are still preserved in settings.toml.")
                    .foregroundStyle(.secondary)
            }

            Text(
                "settings.toml contains valid TOML keys that this Nehir version does not use. Nehir will keep them in the file when saving, but they do not affect current behavior."
            )
            .foregroundStyle(.secondary)

            Text("File: \(issue.fileURL.path)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(issue.keyPaths, id: \.self) { key in
                    Label(key, systemImage: "questionmark.circle")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            HStack {
                Button("Copy AI Prompt") {
                    onCopyPrompt()
                }
                .buttonStyle(.borderedProminent)

                Button("Remove Unknown Keys") {
                    onClean()
                }
                .buttonStyle(.bordered)

                if isPostponed {
                    Button("Postponed") {}
                        .buttonStyle(.bordered)
                        .disabled(true)
                } else {
                    Button("Postpone Warning") {
                        onPostpone()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let error {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Advisory-only diagnostics rows for global-hotkey conflicts and curated default-chord
/// advisories. Remediation is manual (reassign the chord in the Hotkeys tab or clear the
/// conflicting macOS shortcut), so these rows have no action buttons.
private struct HotkeyConflictWarningView: View {
    private enum Content {
        case conflict(HotkeyConflictIssue)
        case advisory(HotkeyAdvisoryIssue)
    }

    private let content: Content

    init(conflict: HotkeyConflictIssue) {
        content = .conflict(conflict)
    }

    init(advisory: HotkeyAdvisoryIssue) {
        content = .advisory(advisory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch content {
            case .conflict(let issue):
                Label("\(issue.commandDisplayName) hotkey conflict", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.yellow)
                Text(
                    "The chord \(issue.chordDisplayString) for \(issue.commandDisplayName) could not be registered: \(reasonPhrase(issue.reason))."
                )
                .foregroundStyle(.secondary)
                Text(issue.remediation)
                    .font(.callout.weight(.semibold))
            case .advisory(let issue):
                Label(
                    "\(issue.commandDisplayName) hotkey may overlap a system shortcut",
                    systemImage: "exclamationmark.bubble.fill"
                )
                .font(.headline)
                .foregroundStyle(Color.yellow)
                Text(issue.advisoryText)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func reasonPhrase(_ reason: HotkeyRegistrationFailureReason) -> String {
        switch reason {
        case .systemReserved:
            return "reserved by macOS or another app"
        case .duplicateBinding:
            return "another Nehir command uses the same chord"
        }
    }
}

private struct DiagnosticIssueView: View {
    let issue: DisplayEnvironmentDiagnostics.Issue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.yellow)
            Text(issue.message)
                .foregroundStyle(.secondary)
            Text(issue.recommendation)
        }
        .padding(.vertical, 4)
    }
}

private struct DisplayDiagnosticMonitorRow: View {
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(monitor.name)
                .font(.headline)
            Text("Frame: \(format(monitor.frame))")
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
            Text("Visible: \(format(monitor.visibleFrame))")
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
        }
        .padding(.vertical, 2)
    }

    private func format(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX.rounded())) y=\(Int(rect.minY.rounded())) w=\(Int(rect.width.rounded())) h=\(Int(rect.height.rounded()))"
    }
}
