import SwiftUI

struct SettingsPage<Content: View>: View {
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        Form {
            if let subtitle {
                Section {
                    SettingsCaption(subtitle)
                }
            }

            content()
        }
        .formStyle(.grouped)
    }
}

struct SettingsCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct SettingsValueText: View {
    let text: String
    var width: CGFloat = 56

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
            .accessibilityHidden(true)
    }
}

struct SettingsSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatter: (Double) -> String
    var valueWidth: CGFloat = 56
    /// Fired when an edit begins/ends. The row commits its own draft on drag end
    /// regardless, so this is purely for optional side effects.
    var onEditingChanged: ((Bool) -> Void)? = nil

    /// Buffered while dragging so each tick does not write through to `value`
    /// (which would trigger per-tick `didSet` saves and side effects on the main
    /// actor). Committed exactly once when the drag ends.
    @State private var draftValue: Double?

    private var effectiveValue: Double {
        draftValue ?? value
    }

    var body: some View {
        LabeledContent(label) {
            HStack {
                let displayText = formatter(effectiveValue)
                Slider(value: Binding(
                    get: { effectiveValue },
                    set: { newValue in
                        draftValue = newValue
                    }
                ), in: range, step: step, onEditingChanged: { editing in
                    if !editing, let draft = draftValue {
                        value = draft
                        draftValue = nil
                    }
                    onEditingChanged?(editing)
                }) {
                    Text(label)
                }
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(displayText)

                SettingsValueText(text: displayText, width: valueWidth)
            }
        }
    }
}

private struct DraftNumberTextField: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let width: CGFloat
    let onCommit: (Double) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var clampedValue: Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    var body: some View {
        TextField(label, text: $draft)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit(commitDraft)
            .onAppear { restoreDraftFromValue() }
            .onChange(of: value) { _, _ in
                if !isFocused { restoreDraftFromValue() }
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    restoreDraftFromValue()
                } else {
                    commitDraft()
                }
            }
            .accessibilityLabel(label)
    }

    private func restoreDraftFromValue() {
        draft = formatted(clampedValue)
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = numberFormatter.number(from: trimmed)?.doubleValue ?? clampedValue
        let committed = min(max(parsed, range.lowerBound), range.upperBound)
        draft = formatted(committed)
        onCommit(committed)
    }

    private func formatted(_ value: Double) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? ""
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        return formatter
    }
}

struct SettingsNumberStepperRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Stepper(value: $value, in: range, step: step) {
                    EmptyView()
                }
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(valueText)

                DraftNumberTextField(
                    label: label,
                    value: value,
                    range: range,
                    width: 64,
                    onCommit: { value = $0 }
                )
            }
        }
    }
}

struct MonitorScopeSection: View {
    @Binding var selectedMonitor: Monitor.ID?
    let monitors: [Monitor]
    let hasOverrides: (Monitor) -> Bool
    let reset: (Monitor) -> Void

    var body: some View {
        Section("Configuration Scope") {
            Picker("Configure", selection: $selectedMonitor) {
                Text("Global Defaults").tag(nil as Monitor.ID?)
                if !monitors.isEmpty {
                    Divider()
                    ForEach(monitors, id: \.id) { monitor in
                        HStack {
                            Text(monitor.name)
                            if monitor.isMain {
                                Text("(Main)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(monitor.id as Monitor.ID?)
                    }
                }
            }

            if let monitorId = selectedMonitor,
               let monitor = monitors.first(where: { $0.id == monitorId })
            {
                LabeledContent("Overrides") {
                    HStack {
                        Text(hasOverrides(monitor) ? "Custom" : "Using global defaults")
                            .foregroundStyle(.secondary)
                        Button("Reset to Global") {
                            reset(monitor)
                        }
                        .disabled(!hasOverrides(monitor))
                    }
                }
            }
        }
    }
}

struct ResetIconButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.uturn.backward.circle")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .frame(width: OverrideStatusIndicator.width, height: OverrideStatusIndicator.height)
        .contentShape(Rectangle())
        .help(title)
        .accessibilityLabel(title)
    }
}

struct OverrideStatusIndicator: View {
    static let width: CGFloat = 45
    static let height: CGFloat = 44

    let isOverridden: Bool
    let resetTitle: String
    let globalAccessibilityLabel: String
    let onReset: () -> Void

    var body: some View {
        ZStack {
            if isOverridden {
                ResetIconButton(title: resetTitle, action: onReset)
            } else {
                Text("Global")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(globalAccessibilityLabel)
            }
        }
        .frame(width: Self.width, height: Self.height)
    }
}

struct OverridableToggle: View {
    let label: String
    let value: Bool?
    let globalValue: Bool
    let onChange: (Bool) -> Void
    let onReset: () -> Void

    private var effectiveValue: Bool {
        value ?? globalValue
    }

    private var isOverridden: Bool {
        value != nil
    }

    var body: some View {
        LabeledContent {
            HStack {
                Toggle("", isOn: Binding(
                    get: { effectiveValue },
                    set: { onChange($0) }
                ))
                .labelsHidden()
                .accessibilityLabel(label)

                overrideStatus
            }
        } label: {
            Text(label)
        }
    }

    private var overrideStatus: some View {
        OverrideStatusIndicator(
            isOverridden: isOverridden,
            resetTitle: "Reset \(label) to global default",
            globalAccessibilityLabel: "\(label) uses global default",
            onReset: onReset
        )
    }
}

struct OverridablePicker<T: Hashable & Identifiable>: View {
    let label: String
    let value: T?
    let globalValue: T
    let options: [T]
    let displayName: (T) -> String
    let onChange: (T) -> Void
    let onReset: () -> Void

    private var effectiveValue: T {
        value ?? globalValue
    }

    private var isOverridden: Bool {
        value != nil
    }

    var body: some View {
        LabeledContent(label) {
            HStack {
                Picker(label, selection: Binding(
                    get: { effectiveValue },
                    set: { onChange($0) }
                )) {
                    ForEach(options) { option in
                        Text(displayName(option)).tag(option)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(label)

                overrideStatus
            }
        }
    }

    private var overrideStatus: some View {
        OverrideStatusIndicator(
            isOverridden: isOverridden,
            resetTitle: "Reset \(label) to global default",
            globalAccessibilityLabel: "\(label) uses global default",
            onReset: onReset
        )
    }
}

struct OverridableSlider: View {
    let label: String
    let value: Double?
    let globalValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatter: (Double) -> String
    var commitOnEditingEnd = false
    let onChange: (Double) -> Void
    let onReset: () -> Void

    @State private var draftValue: Double?

    private var effectiveValue: Double {
        draftValue ?? value ?? globalValue
    }

    private var isOverridden: Bool {
        draftValue != nil || value != nil
    }

    var body: some View {
        LabeledContent(label) {
            HStack {
                let displayValue = formatter(effectiveValue)
                Slider(value: Binding(
                    get: { effectiveValue },
                    set: { newValue in
                        if commitOnEditingEnd {
                            draftValue = newValue
                        } else {
                            onChange(newValue)
                        }
                    }
                ), in: range, step: step, onEditingChanged: { editing in
                    guard commitOnEditingEnd, !editing, let draftValue else { return }
                    onChange(draftValue)
                    self.draftValue = nil
                }) {
                    Text(label)
                }
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(displayValue)

                SettingsValueText(text: displayValue, width: 48)
                overrideStatus
            }
        }
    }

    private var overrideStatus: some View {
        OverrideStatusIndicator(
            isOverridden: isOverridden,
            resetTitle: "Reset \(label) to global default",
            globalAccessibilityLabel: "\(label) uses global default"
        ) {
            draftValue = nil
            onReset()
        }
    }
}

struct OverridableStepper: View {
    let label: String
    let value: Double?
    let globalValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatter: (Double) -> String
    let onChange: (Double) -> Void
    let onReset: () -> Void

    private var effectiveValue: Double {
        value ?? globalValue
    }

    private var isOverridden: Bool {
        value != nil
    }

    var body: some View {
        LabeledContent(label) {
            HStack {
                let displayValue = formatter(effectiveValue)
                Stepper(value: Binding(
                    get: { effectiveValue },
                    set: { onChange(min(max($0, range.lowerBound), range.upperBound)) }
                ), in: range, step: step) {
                    EmptyView()
                }
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(displayValue)

                DraftNumberTextField(
                    label: label,
                    value: effectiveValue,
                    range: range,
                    width: 64,
                    onCommit: { onChange($0) }
                )

                overrideStatus
            }
        }
    }

    private var overrideStatus: some View {
        OverrideStatusIndicator(
            isOverridden: isOverridden,
            resetTitle: "Reset \(label) to global default",
            globalAccessibilityLabel: "\(label) uses global default",
            onReset: onReset
        )
    }
}
