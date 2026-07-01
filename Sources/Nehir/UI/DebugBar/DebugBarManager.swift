// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftUI

struct DebugBarSnapshot: Equatable {
    var traceCaptureStatus: RuntimeTraceCaptureStatus
    var backgroundTraceStatus: BackgroundTraceBufferStatus
    var retentionSeconds: TimeInterval
    var exportCopiesFile: Bool
    var viewportTraceVerbosity: ViewportTraceVerbosity
}

@MainActor
final class DebugBarManager {
    private weak var controller: WMController?
    private weak var settings: SettingsStore?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<DebugBarView>?
    private var moveObserver: NSObjectProtocol?
    private var isPositioningPanel = false
    private let surfaceCoordinator = SurfaceCoordinator.shared

    func setup(controller: WMController, settings: SettingsStore) {
        self.controller = controller
        self.settings = settings
        update()
    }

    func update() {
        guard let controller, let settings, settings.developerModeEnabled, settings.debugBarEnabled else {
            cleanup()
            return
        }

        let snapshot = DebugBarSnapshot(
            traceCaptureStatus: controller.diagnostics.runtimeTraceCaptureStatus,
            backgroundTraceStatus: controller.diagnostics.backgroundTraceBufferStatus,
            retentionSeconds: settings.backgroundTraceRetentionSeconds,
            exportCopiesFile: settings.debugTraceExportCopiesFile,
            viewportTraceVerbosity: settings.viewportTraceVerbosity
        )
        let view = DebugBarView(
            snapshot: snapshot,
            onToggleTraceCapture: { [weak controller, weak self] in
                _ = controller?.diagnostics.toggleRuntimeTraceCapture()
                self?.update()
            },
            onResetBuffer: { [weak controller, weak self] in
                controller?.diagnostics.resetBackgroundTraceBuffer()
                self?.update()
            },
            onCycleRetention: { [weak controller, weak settings, weak self] in
                guard let controller, let settings else { return }
                settings.backgroundTraceRetentionSeconds = Self
                    .nextRetention(after: settings.backgroundTraceRetentionSeconds)
                controller.diagnostics.updateBackgroundTraceBufferConfiguration()
                self?.update()
            },
            onToggleCopyMode: { [weak settings, weak self] in
                guard let settings else { return }
                settings.debugTraceExportCopiesFile.toggle()
                self?.update()
            },
            onCycleViewportTraceVerbosity: { [weak controller, weak settings, weak self] in
                guard let settings else { return }
                settings.viewportTraceVerbosity = Self
                    .nextViewportVerbosity(after: settings.viewportTraceVerbosity)
                controller?.diagnostics.applyViewportTraceVerbosity()
                self?.update()
            }
        )

        if let hostingView {
            hostingView.rootView = view
        } else {
            let hostingView = NSHostingView(rootView: view)
            let container = DebugBarContainerView(frame: .zero)
            hostingView.frame = container.bounds
            hostingView.autoresizingMask = [.width, .height]
            container.addSubview(hostingView)
            self.hostingView = hostingView

            let panel = Self.makePanel()
            panel.contentView = container
            panel.orderFrontRegardless()
            self.panel = panel
            observePanelMove(panel)
            surfaceCoordinator.register(
                window: panel,
                id: "debug-bar",
                policy: SurfacePolicy(
                    kind: .utility,
                    hitTestPolicy: .interactive,
                    capturePolicy: .excluded,
                    suppressesManagedFocusRecovery: false
                )
            )
        }

        positionPanel()
    }

    func cleanup() {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        if let panel {
            surfaceCoordinator.unregister(window: panel)
            panel.orderOut(nil)
        }
        panel = nil
        hostingView = nil
    }

    private func positionPanel() {
        guard let panel, let hostingView else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let fitting = hostingView.fittingSize
        let width = max(360, fitting.width + 8)
        let height = max(36, fitting.height)
        let defaultOrigin = CGPoint(x: screen.visibleFrame.maxX - width - 12, y: screen.visibleFrame.maxY - height - 8)
        let origin = clampedOrigin(
            settings?.debugBarOrigin ?? defaultOrigin,
            size: CGSize(width: width, height: height),
            in: screen.frame
        )
        let frame = NSRect(origin: origin, size: CGSize(width: width, height: height))
        guard panel.frame != frame else { return }
        isPositioningPanel = true
        panel.setFrame(frame, display: true)
        isPositioningPanel = false
    }

    private func observePanelMove(_ panel: NSPanel) {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPositioningPanel, let panel = self.panel else { return }
                self.settings?.debugBarOrigin = panel.frame.origin
            }
        }
    }

    private func clampedOrigin(_ origin: CGPoint, size: CGSize, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, frame.minX), frame.maxX - size.width),
            y: min(max(origin.y, frame.minY), frame.maxY - size.height)
        )
    }

    private static func makePanel() -> NSPanel {
        let panel = DebugBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private static func nextRetention(after value: TimeInterval) -> TimeInterval {
        let presets: [TimeInterval] = [0, 30, 60, 120]
        guard let index = presets.firstIndex(of: value) else { return 0 }
        return presets[(index + 1) % presets.count]
    }

    private static func nextViewportVerbosity(after value: ViewportTraceVerbosity) -> ViewportTraceVerbosity {
        let order: [ViewportTraceVerbosity] = [.standard, .lean, .verbose]
        guard let index = order.firstIndex(of: value) else { return .standard }
        return order[(index + 1) % order.count]
    }
}

struct DebugBarView: View {
    let snapshot: DebugBarSnapshot
    let onToggleTraceCapture: () -> Void
    let onResetBuffer: () -> Void
    let onCycleRetention: () -> Void
    let onToggleCopyMode: () -> Void
    let onCycleViewportTraceVerbosity: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggleTraceCapture) {
                Label(
                    snapshot.traceCaptureStatus.isActive ? "Stop" : "Record",
                    systemImage: snapshot.traceCaptureStatus.isActive ? "stop.circle.fill" : "record.circle"
                )
                .labelStyle(.titleAndIcon)
                .foregroundStyle(snapshot.traceCaptureStatus.isActive ? .red : .primary)
            }
            .buttonStyle(DebugBarActionButtonStyle())
            .help(snapshot.traceCaptureStatus.isActive ? "Stop and export trace capture" : "Start trace capture")

            Button(action: onResetBuffer) {
                Label("Reset", systemImage: "arrow.counterclockwise.circle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(DebugBarActionButtonStyle())
            .disabled(!snapshot.backgroundTraceStatus.isEnabled)
            .help("Reset trace buffer without stopping capture")

            DebugBarDivider()

            Button(action: onCycleViewportTraceVerbosity) {
                Label(snapshot.viewportTraceVerbosity.displayName, systemImage: "chart.bar.doc.horizontal")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(snapshot.viewportTraceVerbosity == .verbose ? .yellow : .primary)
            }
            .buttonStyle(DebugBarInlineControlStyle())
            .help(
                "Viewport trace verbosity (Lean / Standard / Verbose). Verbose adds per-frame gesture updates and per-mutation provenance."
            )

            Button(action: onCycleRetention) {
                Label(retentionLabel, systemImage: "timer")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.monospacedDigit())
            }
            .buttonStyle(DebugBarInlineControlStyle())
            .help("Cycle trace buffer retention")

            Button(action: onToggleCopyMode) {
                Label(copyModeLabel, systemImage: snapshot.exportCopiesFile ? "doc.on.doc" : "link")
                    .labelStyle(.titleAndIcon)
                    .frame(width: 54, alignment: .center)
            }
            .buttonStyle(DebugBarInlineControlStyle())
            .help(snapshot.exportCopiesFile ? "Stop/export copies the trace file" : "Stop/export copies the trace path")
        }
        .frame(height: 26)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var copyModeLabel: String {
        snapshot.exportCopiesFile ? "File" : "Path"
    }

    private var retentionLabel: String {
        switch snapshot.retentionSeconds {
        case 0: "∞"
        case 30: "30s"
        case 60: "1m"
        case 120: "2m"
        default: "\(Int(snapshot.retentionSeconds))s"
        }
    }
}

/// Filled capsule look for one-shot action buttons (Record/Stop, Reset).
struct DebugBarActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(height: 20)
            .background(
                Capsule().fill(.tertiary.opacity(isEnabled ? (configuration.isPressed ? 0.7 : 0.45) : 0.18))
            )
            .opacity(isEnabled ? 1 : 0.42)
            .contentShape(Capsule())
    }
}

/// Plain inline look for stateful controls (retention cycle, copy-mode toggle),
/// visually lighter than fire-once action buttons.
struct DebugBarInlineControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 4)
            .opacity(configuration.isPressed ? 0.55 : 0.82)
    }
}

private struct DebugBarDivider: View {
    var body: some View {
        Rectangle()
            .fill(.tertiary.opacity(0.5))
            .frame(width: 1, height: 14)
    }
}

private final class DebugBarContainerView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        true
    }
}

private final class DebugBarPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen else { return frameRect }
        let screenFrame = screen.frame
        var constrained = frameRect
        constrained.origin.x = max(screenFrame.minX, min(constrained.origin.x, screenFrame.maxX - constrained.width))
        constrained.origin.y = max(screenFrame.minY, min(constrained.origin.y, screenFrame.maxY - constrained.height))
        return constrained
    }
}
