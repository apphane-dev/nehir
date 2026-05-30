import AppKit
import SwiftUI

struct MonitorSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    private var warpAxis: MouseWarpAxis {
        settings.mouseWarpAxis
    }

    private var sortedMonitors: [Monitor] {
        MonitorSettingsTabModel.sortedMonitors(connectedMonitors, axis: warpAxis)
    }

    private var displayLabels: [Monitor.ID: MonitorDisplayLabel] {
        MonitorSettingsTabModel.displayLabels(for: sortedMonitors, axis: warpAxis)
    }

    private var warpOrderEntries: [MonitorOrderEntry] {
        MonitorSettingsTabModel.orderEntries(
            for: sortedMonitors,
            orderedNames: settings.effectiveMouseWarpMonitorOrder(for: sortedMonitors, axis: warpAxis),
            axis: warpAxis
        )
    }

    private var effectiveSelectedMonitorID: Monitor.ID? {
        MonitorSettingsTabModel.normalizedSelection(selectedMonitor, entries: warpOrderEntries)
    }

    private var selectedConnectedMonitor: Monitor? {
        guard let monitorID = effectiveSelectedMonitorID else { return nil }
        return sortedMonitors.first(where: { $0.id == monitorID })
    }

    var body: some View {
        SettingsPage(
            subtitle: "Configure mouse warp order and per-monitor orientation without changing macOS display arrangement."
        ) {
            Section("Mouse Warp") {
                LabeledContent("Warp Axis") {
                    Picker("Warp Axis", selection: Binding(
                        get: { settings.mouseWarpAxis },
                        set: { settings.mouseWarpAxis = $0 }
                    )) {
                        ForEach(MouseWarpAxis.allCases, id: \.self) { axis in
                            Text(axis.displayName).tag(axis)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }

                LabeledContent("Trigger Margin") {
                    Stepper(value: Binding(
                        get: { settings.mouseWarpMargin },
                        set: { settings.mouseWarpMargin = $0 }
                    ), in: 1 ... 10) {
                        Text("\(settings.mouseWarpMargin) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                SettingsCaption(
                    "Horizontal mode uses left and right edges. Vertical mode uses top and bottom edges."
                )
            }

            Section("Warp Order") {
                if warpOrderEntries.isEmpty {
                    Text("No monitors detected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(warpOrderEntries.enumerated()), id: \.element.id) { index, entry in
                        MonitorOrderRow(
                            position: index + 1,
                            entry: entry,
                            axis: warpAxis,
                            isSelected: effectiveSelectedMonitorID == entry.id,
                            canMoveLeft: MonitorSettingsTabModel.canMove(
                                entries: warpOrderEntries,
                                moving: entry.id,
                                direction: .left
                            ),
                            canMoveRight: MonitorSettingsTabModel.canMove(
                                entries: warpOrderEntries,
                                moving: entry.id,
                                direction: .right
                            ),
                            onSelect: { selectedMonitor = entry.id },
                            onMoveLeft: {
                                selectedMonitor = entry.id
                                moveMonitor(entry.id, .left)
                            },
                            onMoveRight: {
                                selectedMonitor = entry.id
                                moveMonitor(entry.id, .right)
                            }
                        )
                    }

                    SettingsCaption(
                        "This is the \(warpAxis.orderDescription) order Nehir uses when the pointer crosses a monitor edge."
                    )
                }
            }

            Section("Monitor Orientation") {
                if let monitor = selectedConnectedMonitor,
                   let displayLabel = displayLabels[monitor.id]
                {
                    SelectedMonitorDetails(
                        settings: settings,
                        controller: controller,
                        monitor: monitor,
                        displayLabel: displayLabel
                    )
                } else if sortedMonitors.isEmpty {
                    Text("No monitors detected.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select a monitor in Warp Order to configure its orientation.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: refreshConnectedMonitors)
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification))
        { _ in
            refreshConnectedMonitors()
        }
    }

    private func refreshConnectedMonitors() {
        let monitors = Monitor.current()
        connectedMonitors = monitors
        selectedMonitor = MonitorSettingsTabModel.normalizedSelection(
            selectedMonitor,
            entries: MonitorSettingsTabModel.orderEntries(
                for: MonitorSettingsTabModel.sortedMonitors(monitors, axis: warpAxis),
                orderedNames: settings.effectiveMouseWarpMonitorOrder(for: monitors, axis: warpAxis),
                axis: warpAxis
            )
        )
    }

    private func moveMonitor(_ monitorID: Monitor.ID, _ direction: MonitorOrderMoveDirection) {
        guard let reordered = MonitorSettingsTabModel.reorderedNames(
            entries: warpOrderEntries,
            moving: monitorID,
            direction: direction
        ) else {
            return
        }
        settings.mouseWarpMonitorOrder = reordered
    }
}

private struct MonitorOrderRow: View {
    let position: Int
    let entry: MonitorOrderEntry
    let axis: MouseWarpAxis
    let isSelected: Bool
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onSelect: () -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(position)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
                .accessibilityHidden(true)

            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: "display")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(entry.displayLabel.name)
                                .font(.body)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            MonitorBadgeRow(displayLabel: entry.displayLabel, isMain: entry.isMain)
                        }

                        Text(isSelected ? "Selected for orientation settings" : "Select to edit orientation")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.displayLabel.accessibilityName)
            .accessibilityValue(isSelected ? "Selected, position \(position)" : "Position \(position)")
            .accessibilityHint("Selects this monitor for orientation settings")

            HStack(spacing: 6) {
                MonitorMoveButton(
                    symbolName: axis.leadingSymbolName,
                    accessibilityLabel: axis.leadingAccessibilityLabel(
                        for: entry.displayLabel.accessibilityName,
                        position: position
                    ),
                    isEnabled: canMoveLeft,
                    action: onMoveLeft
                )

                MonitorMoveButton(
                    symbolName: axis.trailingSymbolName,
                    accessibilityLabel: axis.trailingAccessibilityLabel(
                        for: entry.displayLabel.accessibilityName,
                        position: position
                    ),
                    isEnabled: canMoveRight,
                    action: onMoveRight
                )
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MonitorMoveButton: View {
    let symbolName: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(accessibilityLabel, systemImage: symbolName)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!isEnabled)
        .help(isEnabled ? accessibilityLabel : "\(accessibilityLabel) unavailable")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isEnabled ? "Available" : "Unavailable")
    }
}

private struct MonitorBadgeRow: View {
    let displayLabel: MonitorDisplayLabel
    let isMain: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let duplicateBadge = displayLabel.badgeText {
                MonitorBadge(text: duplicateBadge)
            }

            if isMain {
                MonitorBadge(text: "Main")
            }
        }
    }
}

private struct MonitorBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

private struct SelectedMonitorDetails: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor
    let displayLabel: MonitorDisplayLabel

    private var orientationOverride: Monitor.Orientation? {
        settings.orientationSettings(for: monitor)?.orientation
    }

    private var effectiveOrientation: Monitor.Orientation {
        settings.effectiveOrientation(for: monitor)
    }

    var body: some View {
        LabeledContent("Monitor") {
            HStack(spacing: 8) {
                Text(displayLabel.name)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)

                MonitorBadgeRow(displayLabel: displayLabel, isMain: monitor.isMain)
            }
        }

        LabeledContent("Auto-detected") {
            Text(monitor.autoOrientation.displayName)
                .foregroundStyle(.secondary)
        }

        LabeledContent("Current") {
            Text(effectiveOrientation.displayName)
                .fontWeight(.medium)
        }

        Picker("Orientation Override", selection: Binding(
            get: { orientationOverride },
            set: { newValue in
                updateOrientation(newValue)
            }
        )) {
            Text("Auto").tag(nil as Monitor.Orientation?)
            Text("Horizontal").tag(Monitor.Orientation.horizontal as Monitor.Orientation?)
            Text("Vertical").tag(Monitor.Orientation.vertical as Monitor.Orientation?)
        }
        .pickerStyle(.segmented)

        if orientationOverride != nil {
            Button("Reset to Auto") {
                updateOrientation(nil)
            }
        }

        SettingsCaption(
            "Vertical monitors scroll windows top-to-bottom instead of left-to-right."
        )
    }

    private func updateOrientation(_ orientation: Monitor.Orientation?) {
        let newSettings = MonitorOrientationSettings(
            monitorName: monitor.name,
            monitorDisplayId: monitor.displayId,
            orientation: orientation
        )

        if orientation == nil {
            settings.removeOrientationSettings(for: monitor)
        } else {
            settings.updateOrientationSettings(newSettings)
        }

        controller.updateMonitorOrientations()
    }
}

struct MonitorDisplayLabel: Equatable {
    let name: String
    let duplicateIndex: Int?

    var badgeText: String? {
        duplicateIndex.map { "#\($0)" }
    }

    var accessibilityName: String {
        if let duplicateIndex {
            return "\(name), duplicate \(duplicateIndex)"
        }
        return name
    }
}

struct MonitorOrderEntry: Identifiable, Equatable {
    let monitor: Monitor
    let displayLabel: MonitorDisplayLabel

    var id: Monitor.ID {
        monitor.id
    }

    var name: String {
        monitor.name
    }

    var isMain: Bool {
        monitor.isMain
    }
}

enum MonitorOrderMoveDirection {
    case left
    case right
}

enum MonitorSettingsTabModel {
    static func sortedMonitors(_ monitors: [Monitor], axis: MouseWarpAxis = .horizontal) -> [Monitor] {
        axis.sortedMonitors(monitors)
    }

    static func normalizedSelection(_ selectedMonitor: Monitor.ID?, entries: [MonitorOrderEntry]) -> Monitor.ID? {
        guard !entries.isEmpty else { return nil }

        if let selectedMonitor,
           entries.contains(where: { $0.id == selectedMonitor })
        {
            return selectedMonitor
        }

        return entries.first?.id
    }

    static func displayLabels(
        for monitors: [Monitor],
        axis: MouseWarpAxis = .horizontal
    ) -> [Monitor.ID: MonitorDisplayLabel] {
        let sorted = sortedMonitors(monitors, axis: axis)
        let totals = sorted.reduce(into: [String: Int]()) { counts, monitor in
            counts[monitor.name, default: 0] += 1
        }
        var nextIndexByName: [String: Int] = [:]
        var labels: [Monitor.ID: MonitorDisplayLabel] = [:]

        for monitor in sorted {
            nextIndexByName[monitor.name, default: 0] += 1
            let total = totals[monitor.name, default: 0]
            let duplicateIndex = total > 1 ? nextIndexByName[monitor.name] : nil
            labels[monitor.id] = MonitorDisplayLabel(name: monitor.name, duplicateIndex: duplicateIndex)
        }

        return labels
    }

    static func orderEntries(
        for monitors: [Monitor],
        orderedNames: [String],
        axis: MouseWarpAxis = .horizontal
    ) -> [MonitorOrderEntry] {
        let sorted = sortedMonitors(monitors, axis: axis)
        let labels = displayLabels(for: sorted, axis: axis)
        let monitorsByName = Dictionary(grouping: sorted, by: \.name)
        var usedCounts: [String: Int] = [:]
        var entries: [MonitorOrderEntry] = []

        for name in orderedNames {
            let usedCount = usedCounts[name, default: 0]
            guard let monitor = monitorsByName[name]?[usedCount],
                  let displayLabel = labels[monitor.id]
            else {
                continue
            }

            entries.append(MonitorOrderEntry(monitor: monitor, displayLabel: displayLabel))
            usedCounts[name] = usedCount + 1
        }

        return entries
    }

    static func canMove(
        entries: [MonitorOrderEntry],
        moving selectedMonitor: Monitor.ID?,
        direction: MonitorOrderMoveDirection
    ) -> Bool {
        guard let currentIndex = entries.firstIndex(where: { $0.id == selectedMonitor }) else {
            return false
        }

        switch direction {
        case .left:
            return currentIndex > 0
        case .right:
            return currentIndex < entries.count - 1
        }
    }

    static func reorderedNames(
        entries: [MonitorOrderEntry],
        moving selectedMonitor: Monitor.ID?,
        direction: MonitorOrderMoveDirection
    ) -> [String]? {
        guard let currentIndex = entries.firstIndex(where: { $0.id == selectedMonitor }) else {
            return nil
        }

        let targetIndex: Int
        switch direction {
        case .left:
            targetIndex = currentIndex - 1
        case .right:
            targetIndex = currentIndex + 1
        }

        guard entries.indices.contains(targetIndex) else { return nil }

        var reorderedEntries = entries
        reorderedEntries.swapAt(currentIndex, targetIndex)
        return reorderedEntries.map(\.name)
    }
}

extension Monitor.Orientation {
    var displayName: String {
        switch self {
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        }
    }
}

private extension MouseWarpAxis {
    func leadingAccessibilityLabel(for monitorName: String, position: Int) -> String {
        switch self {
        case .horizontal: "Move \(monitorName), position \(position), left"
        case .vertical: "Move \(monitorName), position \(position), up"
        }
    }

    func trailingAccessibilityLabel(for monitorName: String, position: Int) -> String {
        switch self {
        case .horizontal: "Move \(monitorName), position \(position), right"
        case .vertical: "Move \(monitorName), position \(position), down"
        }
    }
}
