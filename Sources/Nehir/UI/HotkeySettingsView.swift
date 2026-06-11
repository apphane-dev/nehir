import Carbon
import SwiftUI

enum HotkeyCaptureResult {
    case applied
    case conflict(ConflictAlert)
}

struct HotkeyTriggerMapping: Equatable {
    let id: String
    let trigger: HotkeyTrigger
}

@MainActor enum HotkeyBindingEditor {
    static func capture(
        _ newBinding: KeyBinding,
        for actionId: String,
        settings: SettingsStore
    ) -> HotkeyCaptureResult {
        capture(newBinding.isUnassigned ? .unassigned : .chord(newBinding), for: actionId, settings: settings)
    }

    static func capture(
        _ newTrigger: HotkeyTrigger,
        for actionId: String,
        settings: SettingsStore
    ) -> HotkeyCaptureResult {
        let conflicts = settings.findConflicts(for: newTrigger, excluding: actionId)
        guard conflicts.isEmpty else {
            return .conflict(
                ConflictAlert(
                    targetActionId: actionId,
                    newTrigger: newTrigger,
                    conflictingCommands: conflicts.map(\.command.displayName)
                )
            )
        }

        settings.updateTrigger(for: actionId, newTrigger: newTrigger)
        return .applied
    }

    static func capture(
        mappings: [HotkeyTriggerMapping],
        settings: SettingsStore
    ) -> HotkeyCaptureResult {
        let targetIds = Set(mappings.map(\.id))
        let conflictingCommands = mappings.flatMap { mapping in
            settings.findConflicts(for: mapping.trigger, excluding: mapping.id)
                .filter { !targetIds.contains($0.id) }
        }
        let uniqueConflictingCommands = ActionCatalog.uniqueTerms(conflictingCommands.map(\.command.displayName))
        guard uniqueConflictingCommands.isEmpty else {
            return .conflict(
                ConflictAlert(
                    mappings: mappings,
                    conflictingCommands: uniqueConflictingCommands
                )
            )
        }

        apply(mappings: mappings, settings: settings)
        return .applied
    }

    static func applyConflictResolution(_ alert: ConflictAlert, settings: SettingsStore) {
        let targetIds = Set(alert.mappings.map(\.id))
        let conflicts = alert.mappings.flatMap { mapping in
            settings.findConflicts(for: mapping.trigger, excluding: mapping.id)
                .filter { !targetIds.contains($0.id) }
        }
        for conflict in conflicts {
            settings.clearBinding(for: conflict.id)
        }
        apply(mappings: alert.mappings, settings: settings)
    }

    static func apply(mappings: [HotkeyTriggerMapping], settings: SettingsStore) {
        for mapping in mappings {
            settings.updateTrigger(for: mapping.id, newTrigger: mapping.trigger)
        }
    }
}

private enum HotkeyRecordingTarget: Equatable {
    case chord(String)
    case numberedGroup(String)
}

private struct HotkeyNumberedGroupRowModel: Identifiable {
    let id: String
    let title: String
    let group: HotkeyConfigMapping.NumberedGroup
    let bindings: [HotkeyBinding]
}

private struct HotkeySettingsSection: Identifiable {
    let id: String
    let title: String
}

enum HotkeySettingsDisplayModel {
    static func isVisible(bindingId: String, developerModeEnabled: Bool) -> Bool {
        guard let spec = ActionCatalog.spec(for: bindingId) else { return false }
        return !spec.requiresDeveloperMode || developerModeEnabled
    }

    static func matchesSearch(_ query: String, binding: HotkeyBinding) -> Bool {
        let normalizedQuery = ActionCatalog.normalizedSearchTerm(query)
        guard !normalizedQuery.isEmpty else { return true }
        let actionTerms = ActionCatalog.spec(for: binding.id)?.searchTerms ?? [
            binding.command.displayName
        ]
        let searchTerms = actionTerms + [
            displayString(for: binding.binding),
            humanReadableString(for: binding.binding)
        ]
        return searchTerms.contains {
            ActionCatalog.normalizedSearchTerm($0).contains(normalizedQuery)
        }
    }

    static func matchesSearch(
        _ query: String,
        groupTitle: String,
        bindings: [HotkeyBinding]
    ) -> Bool {
        let normalizedQuery = ActionCatalog.normalizedSearchTerm(query)
        guard !normalizedQuery.isEmpty else { return true }
        let searchTerms = [
            groupTitle,
            numberedGroupDisplayString(for: bindings),
            numberedGroupHumanReadableString(for: bindings)
        ] + bindings.flatMap { binding in
            ActionCatalog.spec(for: binding.id)?.searchTerms ?? [binding.command.displayName]
        }
        return searchTerms.contains {
            ActionCatalog.normalizedSearchTerm($0).contains(normalizedQuery)
        }
    }

    static func displayString(for binding: KeyBinding) -> String {
        binding.displayString
    }

    static func displayString(for trigger: HotkeyTrigger) -> String {
        trigger.displayString
    }

    static func humanReadableString(for binding: KeyBinding) -> String {
        binding.humanReadableString
    }

    static func humanReadableString(for trigger: HotkeyTrigger) -> String {
        trigger.humanReadableString
    }

    static func numberedGroupDisplayString(for bindings: [HotkeyBinding]) -> String {
        numberedGroupPattern(for: bindings, format: displayString(for:))
    }

    static func numberedGroupHumanReadableString(for bindings: [HotkeyBinding]) -> String {
        numberedGroupPattern(for: bindings, format: humanReadableString(for:))
    }

    private static func numberedGroupPattern(
        for bindings: [HotkeyBinding],
        format: (KeyBinding) -> String
    ) -> String {
        guard bindings.count == 9 else { return "Custom per-number" }
        if bindings.allSatisfy(\.binding.isUnassigned) {
            return "Unassigned"
        }

        let triggers = bindings.map(\.binding)
        guard case let .chord(firstBinding) = triggers[0] else { return "Custom per-number" }
        guard !firstBinding.isUnassigned else { return "Custom per-number" }

        for (idx, trigger) in triggers.enumerated() {
            guard case let .chord(binding) = trigger,
                  binding.keyCode == HotkeyConfigMapping.digitKeyCodes[idx],
                  binding.modifiers == firstBinding.modifiers
            else {
                return "Custom per-number"
            }
        }

        let sample = KeyBinding(
            keyCode: HotkeyConfigMapping.digitKeyCodes[0],
            modifiers: firstBinding.modifiers
        )
        return format(sample).replacingOccurrences(of: "1", with: "{N}", options: .backwards)
    }
}

struct HotkeySettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var recordingTarget: HotkeyRecordingTarget?
    @State private var conflictAlert: ConflictAlert?
    @State private var noticeAlert: HotkeyNoticeAlert?
    @State private var searchText: String = ""
    @State private var confirmsResetToDefaults = false

    var body: some View {
        SettingsPage {
            Section {
                HStack(spacing: 8) {
                    TextField("Search commands or shortcuts", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search hotkeys")

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Label("Clear search", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear search")
                        .accessibilityLabel("Clear hotkey search")
                    }
                }

                SettingsCaption("Shortcuts are stored as physical key combinations. Hyper+… means Ctrl+Option+Shift+Command.")

                if !hasSearchMatches {
                    Text("No matching hotkeys.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(hotkeySettingsSections) { section in
                let groups = numberedGroupsForSection(section.id)
                let actions = actionsForSection(section.id)
                if !groups.isEmpty || !actions.isEmpty {
                    Section {
                        ForEach(groups) { group in
                            HotkeyNumberedGroupRow(
                                group: group,
                                recordingTarget: $recordingTarget,
                                onStartRecording: startNumberedGroupRecording,
                                onCaptured: handleNumberedGroupCaptured,
                                onCancel: cancelRecording,
                                onClearBindings: clearNumberedGroup,
                                onResetBindings: resetNumberedGroup
                            )
                        }

                        ForEach(actions) { binding in
                            HotkeyBindingRow(
                                binding: binding,
                                recordingTarget: $recordingTarget,
                                failureReason: controller.hotkeyRegistrationFailures[binding.command],
                                onStartRecording: startChordRecording,
                                onCaptured: handleChordCaptured,
                                onCancel: cancelRecording,
                                onClearBinding: clearBinding,
                                onResetBindings: resetBindings
                            )
                        }
                    } header: {
                        if section.id == "debugging" {
                            HStack(spacing: 6) {
                                Text(section.title)
                                DeveloperBadge()
                            }
                        } else {
                            Text(section.title)
                        }
                    }
                }
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    confirmsResetToDefaults = true
                }
            }
        }
        .onChange(of: recordingTarget) { _, _ in
            syncHotkeyRecordingState()
        }
        .onDisappear {
            guard recordingTarget != nil else { return }
            cancelRecording()
            controller.setHotkeysEnabled(settings.hotkeysEnabled)
        }
        .alert(item: $conflictAlert) { alert in
            Alert(
                title: Text("Hotkey Conflict"),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Replace")) {
                    HotkeyBindingEditor.applyConflictResolution(alert, settings: settings)
                    controller.updateHotkeyBindings(settings.hotkeyBindings)
                    cancelRecording()
                },
                secondaryButton: .cancel {
                    cancelRecording()
                }
            )
        }
        .alert(item: $noticeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    cancelRecording()
                }
            )
        }
        .confirmationDialog("Reset all hotkeys?", isPresented: $confirmsResetToDefaults) {
            Button("Reset Hotkeys", role: .destructive) {
                settings.resetHotkeysToDefaults()
                controller.updateHotkeyBindings(settings.hotkeyBindings)
                cancelRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All hotkey bindings will be restored to Nehir defaults.")
        }
    }

    private var hasSearchMatches: Bool {
        visibleHotkeyBindings.contains {
            !isNumberedGroupMember($0.id) && HotkeySettingsDisplayModel.matchesSearch(searchText, binding: $0)
        } || !visibleNumberedGroups.isEmpty
    }

    private var visibleHotkeyBindings: [HotkeyBinding] {
        settings.hotkeyBindings.filter {
            HotkeySettingsDisplayModel.isVisible(bindingId: $0.id, developerModeEnabled: settings.developerModeEnabled)
        }
    }

    private var visibleNumberedGroups: [HotkeyNumberedGroupRowModel] {
        HotkeyConfigMapping.numberedGroups.compactMap { group in
            let bindings = bindingsForNumberedGroup(group)
            guard !bindings.isEmpty else { return nil }
            let id = numberedGroupID(group)
            let title = numberedGroupTitle(group)
            guard HotkeySettingsDisplayModel.matchesSearch(searchText, groupTitle: title, bindings: bindings) else {
                return nil
            }
            return HotkeyNumberedGroupRowModel(id: id, title: title, group: group, bindings: bindings)
        }
    }

    private var hotkeySettingsSections: [HotkeySettingsSection] {
        HotkeyConfigMapping.sectionOrder.map { section in
            HotkeySettingsSection(id: section, title: sectionTitle(section))
        }
    }

    private func actionsForSection(_ section: String) -> [HotkeyBinding] {
        visibleHotkeyBindings.filter { binding in
            !isNumberedGroupMember(binding.id) &&
                HotkeyConfigMapping.section(forInternalId: binding.id) == section &&
                HotkeySettingsDisplayModel.matchesSearch(searchText, binding: binding)
        }
    }

    private func numberedGroupsForSection(_ section: String) -> [HotkeyNumberedGroupRowModel] {
        visibleNumberedGroups.filter { group in
            group.group.section == section
        }
    }

    private func startChordRecording(for actionId: String) {
        recordingTarget = .chord(actionId)
    }

    private func startNumberedGroupRecording(_ groupId: String) {
        recordingTarget = .numberedGroup(groupId)
    }

    private func handleChordCaptured(actionId: String, newBinding: KeyBinding) {
        handleTriggerCaptured(actionId: actionId, newTrigger: newBinding.isUnassigned ? .unassigned : .chord(newBinding))
    }


    private func handleNumberedGroupCaptured(groupId: String, newBinding: KeyBinding) {
        guard let group = groupForNumberedGroupID(groupId) else { return }
        if newBinding.isUnassigned {
            applyNumberedGroupMappings(group, triggerForDigit: { _ in .unassigned })
            return
        }

        guard HotkeyConfigMapping.digitKeyCodes.contains(newBinding.keyCode) else {
            noticeAlert = HotkeyNoticeAlert(
                title: "Number Key Required",
                message: "Numbered shortcut groups use one pattern for keys 1–9. Press a number key such as Option+Command+1."
            )
            cancelRecording()
            return
        }

        let mappings = numberedGroupMappings(group) { digitIndex in
            .chord(
                KeyBinding(
                    keyCode: HotkeyConfigMapping.digitKeyCodes[digitIndex],
                    modifiers: newBinding.modifiers
                )
            )
        }
        handleNumberedGroupMappingsCaptured(mappings)
    }

    private func handleTriggerCaptured(actionId: String, newTrigger: HotkeyTrigger) {
        switch HotkeyBindingEditor.capture(newTrigger, for: actionId, settings: settings) {
        case .applied:
            controller.updateHotkeyBindings(settings.hotkeyBindings)
            cancelRecording()
        case let .conflict(alert):
            conflictAlert = alert
            cancelRecording()
        }
    }

    private func clearBinding(actionId: String) {
        settings.clearBinding(for: actionId)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        cancelRecording()
    }

    private func resetBindings(actionId: String) {
        settings.resetBindings(for: actionId)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        cancelRecording()
    }

    private func clearNumberedGroup(groupId: String) {
        guard let group = groupForNumberedGroupID(groupId) else { return }
        applyNumberedGroupMappings(group, triggerForDigit: { _ in .unassigned })
    }

    private func resetNumberedGroup(groupId: String) {
        guard let group = groupForNumberedGroupID(groupId) else { return }
        let defaults = Dictionary(uniqueKeysWithValues: HotkeyBindingRegistry.defaults().map { ($0.id, $0.binding) })
        let mappings = numberedGroupMappings(group) { digitIndex in
            let id = internalID(for: group, digitIndex: digitIndex)
            return defaults[id] ?? .unassigned
        }
        handleNumberedGroupMappingsCaptured(mappings)
    }

    private func applyNumberedGroupMappings(
        _ group: HotkeyConfigMapping.NumberedGroup,
        triggerForDigit: (Int) -> HotkeyTrigger
    ) {
        let mappings = numberedGroupMappings(group, triggerForDigit: triggerForDigit)
        HotkeyBindingEditor.apply(mappings: mappings, settings: settings)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        cancelRecording()
    }

    private func handleNumberedGroupMappingsCaptured(_ mappings: [HotkeyTriggerMapping]) {
        switch HotkeyBindingEditor.capture(mappings: mappings, settings: settings) {
        case .applied:
            controller.updateHotkeyBindings(settings.hotkeyBindings)
            cancelRecording()
        case let .conflict(alert):
            conflictAlert = alert
            cancelRecording()
        }
    }

    private func numberedGroupMappings(
        _ group: HotkeyConfigMapping.NumberedGroup,
        triggerForDigit: (Int) -> HotkeyTrigger
    ) -> [HotkeyTriggerMapping] {
        (0..<9).map { digitIndex in
            HotkeyTriggerMapping(
                id: internalID(for: group, digitIndex: digitIndex),
                trigger: triggerForDigit(digitIndex)
            )
        }
    }

    private func cancelRecording() {
        recordingTarget = nil
        syncHotkeyRecordingState()
    }

    private func syncHotkeyRecordingState() {
        controller.setHotkeysEnabled(recordingTarget != nil ? false : settings.hotkeysEnabled)
    }

    private func bindingsForNumberedGroup(_ group: HotkeyConfigMapping.NumberedGroup) -> [HotkeyBinding] {
        (0..<9).compactMap { digitIndex in
            let id = internalID(for: group, digitIndex: digitIndex)
            return visibleHotkeyBindings.first { $0.id == id }
        }
    }

    private func isNumberedGroupMember(_ bindingId: String) -> Bool {
        HotkeyConfigMapping.numberedGroups.contains { group in
            (0..<9).contains { digitIndex in
                internalID(for: group, digitIndex: digitIndex) == bindingId
            }
        }
    }

    private func groupForNumberedGroupID(_ groupId: String) -> HotkeyConfigMapping.NumberedGroup? {
        HotkeyConfigMapping.numberedGroups.first { numberedGroupID($0) == groupId }
    }

    private func numberedGroupID(_ group: HotkeyConfigMapping.NumberedGroup) -> String {
        "\(group.section).\(group.key)"
    }

    private func internalID(for group: HotkeyConfigMapping.NumberedGroup, digitIndex: Int) -> String {
        String(format: group.internalIdPattern, digitIndex + 1 + group.indexOffset)
    }

    private func sectionTitle(_ section: String) -> String {
        switch section {
        case "workspace":
            return "Workspace"
        case "focus":
            return "Focus"
        case "move":
            return "Move"
        case "layout":
            return "Layout"
        case "debugging":
            return "Debugging & Tracing"
        case "ui":
            return "UI"
        default:
            return section.capitalized
        }
    }

    private func numberedGroupTitle(_ group: HotkeyConfigMapping.NumberedGroup) -> String {
        switch numberedGroupID(group) {
        case "workspace.switch":
            return "Switch Workspace {N}"
        case "workspace.moveTo":
            return "Move Window to Workspace {N}"
        case "workspace.moveColumnTo":
            return "Move Column to Workspace {N}"
        case "workspace.focusAnywhere":
            return "Focus Workspace Anywhere {N}"
        case "focus.column":
            return "Focus Column {N}"
        case "focus.windowInColumn":
            return "Focus Window in Column {N}"
        case "move.columnToIndex":
            return "Move Column to Index {N}"
        default:
            return group.key
        }
    }
}

struct ConflictAlert: Identifiable {
    let mappings: [HotkeyTriggerMapping]
    let conflictingCommands: [String]

    init(targetActionId: String, newTrigger: HotkeyTrigger, conflictingCommands: [String]) {
        mappings = [HotkeyTriggerMapping(id: targetActionId, trigger: newTrigger)]
        self.conflictingCommands = conflictingCommands
    }

    init(mappings: [HotkeyTriggerMapping], conflictingCommands: [String]) {
        self.mappings = mappings
        self.conflictingCommands = conflictingCommands
    }

    var targetActionId: String {
        mappings.first?.id ?? ""
    }

    var newTrigger: HotkeyTrigger {
        mappings.first?.trigger ?? .unassigned
    }

    var id: String {
        [
            mappings.map { "\($0.id)=\($0.trigger.humanReadableString)" }.joined(separator: "|"),
            conflictingCommands.joined(separator: "|")
        ].joined(separator: ":")
    }

    var message: String {
        if conflictingCommands.count == 1 {
            return "This key combination is already used by \"\(conflictingCommands[0])\". Do you want to replace it?"
        } else {
            let commandList = conflictingCommands.joined(separator: ", ")
            return "This key combination is used by: \(commandList). Do you want to replace all?"
        }
    }
}

struct HotkeyNoticeAlert: Identifiable {
    let title: String
    let message: String

    var id: String {
        title + ":" + message
    }
}

private struct HotkeyNumberedGroupRow: View {
    let group: HotkeyNumberedGroupRowModel
    @Binding var recordingTarget: HotkeyRecordingTarget?
    let onStartRecording: (String) -> Void
    let onCaptured: (String, KeyBinding) -> Void
    let onCancel: () -> Void
    let onClearBindings: (String) -> Void
    let onResetBindings: (String) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                HotkeyBindingControl(
                    binding: representativeBinding,
                    commandName: group.title,
                    displayText: HotkeySettingsDisplayModel.numberedGroupDisplayString(
                        for: group.bindings,
                    ),
                    accessibilityText: HotkeySettingsDisplayModel.numberedGroupHumanReadableString(
                        for: group.bindings,
                    ),
                    canRemove: !group.bindings.allSatisfy(\.binding.isUnassigned),
                    isRecording: recordingTarget == .numberedGroup(group.id),
                    onStartRecording: { onStartRecording(group.id) },
                    onCaptured: { onCaptured(group.id, $0) },
                    onCancel: onCancel,
                    onRemove: { onClearBindings(group.id) }
                )

                ResetIconButton(title: "Reset \(group.title) to default") {
                    recordingTarget = nil
                    onResetBindings(group.id)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.body)
                Text("One pattern for 1–9; press any number key while recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityValue("Shortcut \(HotkeySettingsDisplayModel.numberedGroupHumanReadableString(for: group.bindings))")
    }

    private var representativeBinding: HotkeyTrigger {
        guard let first = group.bindings.first?.binding else { return .unassigned }
        if HotkeySettingsDisplayModel.numberedGroupDisplayString(for: group.bindings) == "Custom per-number" {
            return .unassigned
        }
        return first
    }
}

private struct HotkeyBindingRow: View {
    let binding: HotkeyBinding
    @Binding var recordingTarget: HotkeyRecordingTarget?
    let failureReason: HotkeyRegistrationFailureReason?
    let onStartRecording: (String) -> Void
    let onCaptured: (String, KeyBinding) -> Void
    let onCancel: () -> Void
    let onClearBinding: (String) -> Void
    let onResetBindings: (String) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let failureReason {
                    Label("Registration issue", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .help(failureMessage(for: failureReason))
                        .accessibilityLabel("Registration issue")
                        .accessibilityValue(failureMessage(for: failureReason))
                }

                HotkeyBindingControl(
                    binding: binding.binding,
                    commandName: binding.command.displayName,
                    isRecording: recordingTarget == .chord(binding.id),
                    onStartRecording: { onStartRecording(binding.id) },
                    onCaptured: { onCaptured(binding.id, $0) },
                    onCancel: onCancel,
                    onRemove: { onClearBinding(binding.id) }
                )

                ResetIconButton(title: "Reset \(binding.command.displayName) to default") {
                    recordingTarget = nil
                    onResetBindings(binding.id)
                }
            }
        } label: {
            if let failureReason {
                VStack(alignment: .leading, spacing: 4) {
                    Text(binding.command.displayName)
                        .font(.body)
                    Text(failureMessage(for: failureReason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(binding.command.displayName)
                    .font(.body)
            }
        }
        .accessibilityValue("Shortcut \(HotkeySettingsDisplayModel.humanReadableString(for: binding.binding))")
    }

    private func failureMessage(for reason: HotkeyRegistrationFailureReason) -> String {
        switch reason {
        case .duplicateBinding:
            return "Failed to register: this key combination is already assigned to another Nehir command"
        case .systemReserved:
            return "Failed to register: this key combination may be reserved by the system"
        }
    }
}

private struct HotkeyBindingControl: View {
    let binding: HotkeyTrigger
    let commandName: String
    var displayText: String? = nil
    var accessibilityText: String? = nil
    var canRemove: Bool? = nil
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onCaptured: (KeyBinding) -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isRecording {
                KeyRecorderView(
                    accessibilityLabel: "Recording hotkey for \(commandName)",
                    onCapture: onCaptured,
                    onCancel: onCancel
                )
                .frame(minWidth: 180, idealWidth: 210, minHeight: 34)
                .accessibilityHint("Press Escape to cancel recording")
            } else {
                Button {
                    onStartRecording()
                } label: {
                    Text(displayText ?? HotkeySettingsDisplayModel.displayString(for: binding))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .frame(minWidth: 112, alignment: .center)
                }
                .buttonStyle(.bordered)
                .help("Change hotkey for \(commandName)")
                .accessibilityLabel("Change hotkey for \(commandName)")
                .accessibilityValue(accessibilityText ?? HotkeySettingsDisplayModel.humanReadableString(for: binding))

                let showRemove = canRemove ?? !binding.isUnassigned
                Button {
                    onRemove()
                } label: {
                    Label("Clear hotkey for \(commandName)", systemImage: "xmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Clear this hotkey")
                .accessibilityLabel("Clear hotkey for \(commandName)")
                .opacity(showRemove ? 1 : 0)
                .allowsHitTesting(showRemove)
                .accessibilityHidden(!showRemove)
            }
        }
    }
}
