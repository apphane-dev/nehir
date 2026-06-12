import Foundation

enum ReconcileDebugDump {
    private static var versionHeader: String {
        "nehir v\(BuildVersion.display)"
    }

    static func snapshot(_ snapshot: ReconcileSnapshot) -> String {
        var lines: [String] = [
            versionHeader,
            "topology displays=\(snapshot.topologyProfile.displays.count)",
            "focused=\(snapshot.focusedToken.map(String.init(describing:)) ?? "nil")",
            "pending-focus=\(snapshot.focusSession.pendingManagedFocus.token.map(String.init(describing:)) ?? "nil")",
            "focus-lease=\(snapshot.focusSession.focusLease?.owner.rawValue ?? "nil")",
            "non-managed-focus=\(snapshot.focusSession.isNonManagedFocusActive)",
            "app-fullscreen=\(snapshot.focusSession.isAppFullscreenActive)",
            "interaction-monitor=\(snapshot.interactionMonitorId.map(String.init(describing:)) ?? "nil")",
            "previous-interaction-monitor=\(snapshot.previousInteractionMonitorId.map(String.init(describing:)) ?? "nil")"
        ]

        for window in snapshot.windows {
            lines.append(
                "\(window.token) workspace=\(window.workspaceId.uuidString) mode=\(window.mode) phase=\(window.lifecyclePhase.rawValue) observed=\(describe(window.observedState)) desired=\(describe(window.desiredState))"
            )
        }

        return lines.joined(separator: "\n")
    }

    static func trace(_ records: [ReconcileTraceRecord], limit: Int? = nil) -> String {
        let truncated = limit.map { Array(records.suffix(max(0, $0))) } ?? records
        if truncated.isEmpty {
            return "trace empty"
        }

        var output = [versionHeader]
        output += truncated.map { record in
            var parts = [
                "#\(record.sequence)",
                record.timestamp.ISO8601Format(),
                "event=\(record.event.summary)"
            ]
            if record.normalizedEvent != record.event {
                parts.append("normalized=\(record.normalizedEvent.summary)")
            }
            if !record.plan.summary.isEmpty {
                parts.append("plan=\(record.plan.summary)")
            }
            if !record.invariantViolations.isEmpty {
                parts.append(
                    "violations=\(record.invariantViolations.map(\.code).joined(separator: ","))"
                )
            }
            return parts.joined(separator: " ")
        }
        return output.joined(separator: "\n")
    }

    private static func describe(_ state: ObservedWindowState) -> String {
        [
            "frame=\(describe(state.frame))",
            "workspace=\(state.workspaceId?.uuidString ?? "nil")",
            "monitor=\(state.monitorId.map(String.init(describing:)) ?? "nil")",
            "visible=\(state.isVisible)",
            "focused=\(state.isFocused)",
            "hasAX=\(state.hasAXReference)",
            "fullscreen=\(state.isNativeFullscreen)"
        ]
        .joined(separator: ",")
    }

    private static func describe(_ state: DesiredWindowState) -> String {
        [
            "workspace=\(state.workspaceId?.uuidString ?? "nil")",
            "monitor=\(state.monitorId.map(String.init(describing:)) ?? "nil")",
            "mode=\(state.disposition.map(String.init(describing:)) ?? "nil")",
            "floatingFrame=\(describe(state.floatingFrame))",
            "rescue=\(state.rescueEligible)"
        ]
        .joined(separator: ",")
    }

    private static func describe(_ frame: CGRect?) -> String {
        guard let frame else { return "nil" }
        return String(
            format: "{{%.1f, %.1f}, {%.1f, %.1f}}",
            frame.origin.x,
            frame.origin.y,
            frame.size.width,
            frame.size.height
        )
    }
}
