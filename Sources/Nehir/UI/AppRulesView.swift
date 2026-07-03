// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

struct RunningAppInfo: Identifiable {
    let id: String
    let bundleId: String
    let appName: String
    let icon: NSImage?
    let windowSize: CGSize
}

struct AppRulesView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var navigation: SettingsNavigationModel

    @State private var selectedRuleId: AppRule.ID?
    @State private var addDraft: AppRuleDraft?
    @State private var pendingDeleteRule: AppRule?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(settings.appRules, id: \.id, selection: $selectedRuleId) { rule in
                    AppRuleSidebarRow(rule: rule)
                        .tag(rule.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDeleteRule = rule
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 0) {
                    Button {
                        addDraft = AppRuleDraft()
                        selectedRuleId = nil
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("Add app rule")
                    .accessibilityLabel("Add app rule")

                    Divider().frame(height: 16)

                    Button {
                        if let ruleId = selectedRuleId,
                           let rule = settings.appRules.first(where: { $0.id == ruleId })
                        {
                            pendingDeleteRule = rule
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove selected rule")
                    .accessibilityLabel("Remove selected rule")
                    .disabled(selectedRuleId == nil)

                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .frame(minWidth: 160, maxWidth: 240)

            Divider()

            Group {
                if let draft = addDraft {
                    AppRuleAddPane(
                        initialDraft: draft,
                        workspaceNames: workspaceNames,
                        controller: controller,
                        onSave: { newRule in
                            settings.appRules.append(newRule)
                            controller.updateAppRules()
                            selectedRuleId = newRule.id
                            addDraft = nil
                        },
                        onCancel: { addDraft = nil }
                    )
                    .id(draft.id)
                } else if let ruleId = selectedRuleId,
                          let ruleIndex = settings.appRules.firstIndex(where: { $0.id == ruleId })
                {
                    AppRuleDetailView(
                        rule: $settings.appRules[ruleIndex],
                        workspaceNames: workspaceNames,
                        controller: controller,
                        onDelete: {
                            pendingDeleteRule = settings.appRules[ruleIndex]
                        }
                    )
                    .id(ruleId)
                } else {
                    AppRulesEmptyState(
                        controller: controller,
                        onAdd: {
                            addDraft = AppRuleDraft()
                            selectedRuleId = nil
                        },
                        onCreateRuleFromSnapshot: presentNewRule(from:)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .omniBackgroundExtensionEffect()
        }
        .onKeyPress(.escape) {
            if addDraft != nil {
                addDraft = nil
                return .handled
            }
            if selectedRuleId != nil {
                selectedRuleId = nil
                return .handled
            }
            return .ignored
        }
        .confirmationDialog(
            "Delete app rule?",
            isPresented: isConfirmingDelete,
            presenting: pendingDeleteRule
        ) { rule in
            Button("Delete Rule", role: .destructive) {
                deleteRule(rule)
            }
            Button("Cancel", role: .cancel) {}
        } message: { rule in
            Text("Delete the rule for \(rule.bundleId)?")
        }
        .onAppear {
            consumePendingAppRuleDraft()
        }
        .onChange(of: navigation.pendingAppRuleDraft) { _, _ in
            consumePendingAppRuleDraft()
        }
    }

    private var workspaceNames: [String] {
        settings.workspaceConfigurations.map(\.name)
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDeleteRule != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteRule = nil
                }
            }
        )
    }

    private func deleteRule(_ rule: AppRule) {
        settings.appRules.removeAll { $0.id == rule.id }
        controller.updateAppRules()
        if selectedRuleId == rule.id {
            selectedRuleId = nil
        }
    }

    private func presentNewRule(from snapshot: WindowDecisionDebugSnapshot) {
        guard let draft = AppRuleDraft.guided(from: snapshot) else { return }
        addDraft = draft
        selectedRuleId = nil
    }

    /// Consumes a one-shot app-rule draft handed over by another surface (e.g.
    /// the "Create App Rule for Focused Window…" command via
    /// `SettingsNavigationModel.pendingAppRuleDraft`) and opens the add editor
    /// on it. Mirrors how the Hotkeys tab consumes `hotkeySearchSeed`: it runs
    /// on appear (fresh navigation) and on change (command re-fired while the
    /// App Rules tab is already visible, so the explicit command replaces any
    /// in-flight draft), and clears the seed after consuming so it fires once.
    private func consumePendingAppRuleDraft() {
        guard let pending = navigation.pendingAppRuleDraft else { return }
        addDraft = pending
        selectedRuleId = nil
        navigation.pendingAppRuleDraft = nil
    }
}

struct AppRulesSidebar: View {
    let rules: [AppRule]
    @Binding var selection: AppRule.ID?
    let onAdd: () -> Void
    let onDelete: (AppRule) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(rules) { rule in
                AppRuleSidebarRow(rule: rule)
                    .tag(rule.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(rule)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("App Rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAdd) {
                    Label("Add app rule", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("Add app rule")
                .accessibilityLabel("Add app rule")
            }
        }
    }
}

struct AppRuleSidebarRow: View {
    let rule: AppRule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.bundleId)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            HStack(spacing: 4) {
                if rule.effectiveManageAction == .ignore {
                    RuleBadge(text: "Ignore", color: .red)
                }
                if rule.effectiveManageAction != .ignore {
                    if rule.sticky == true {
                        RuleBadge(text: "Sticky", color: .yellow)
                    }
                    switch rule.effectiveLayoutAction {
                    case .float:
                        RuleBadge(text: "Float", color: .blue)
                    case .tile:
                        RuleBadge(text: "Tile", color: .teal)
                    case .auto:
                        EmptyView()
                    }
                    if rule.assignToWorkspace != nil {
                        RuleBadge(text: "WS", color: .green)
                    }
                    if rule.minWidth != nil || rule.minHeight != nil {
                        RuleBadge(text: "Size", color: .orange)
                    }
                }
                if rule.hasAdvancedMatchers {
                    RuleBadge(text: "Advanced", color: .purple)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct AppRulesEmptyState: View {
    let controller: WMController
    let onAdd: () -> Void
    let onCreateRuleFromSnapshot: (WindowDecisionDebugSnapshot) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No App Rule Selected")
                    .font(.headline)
                Text("Select an app rule from the sidebar to edit it,\nor add a new rule to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Add Rule", action: onAdd)
                    .buttonStyle(.borderedProminent)

                FocusedWindowInspectorView(
                    controller: controller,
                    onCreateRuleFromSnapshot: onCreateRuleFromSnapshot
                )
                .frame(maxWidth: 560)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AppRuleDetailView: View {
    @Binding var rule: AppRule
    let workspaceNames: [String]
    let controller: WMController
    let onDelete: () -> Void

    @State private var draft: AppRuleDraft
    @State private var isAdvancedMatchersExpanded: Bool

    init(
        rule: Binding<AppRule>,
        workspaceNames: [String],
        controller: WMController,
        onDelete: @escaping () -> Void
    ) {
        _rule = rule
        self.workspaceNames = workspaceNames
        self.controller = controller
        self.onDelete = onDelete

        let initialRule = rule.wrappedValue
        _draft = State(initialValue: AppRuleDraft(rule: initialRule))
        _isAdvancedMatchersExpanded = State(
            initialValue: initialRule.hasAdvancedMatchers ||
                controller.windowRuleEngine.invalidRegexMessagesByRuleId[initialRule.id] != nil
        )
    }

    var body: some View {
        Form {
            Section("Application") {
                LabeledContent("Bundle ID") {
                    Text(draft.bundleId)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Window Behavior") {
                Picker("Manage", selection: $draft.manageAction) {
                    ForEach(WindowRuleManageAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }

                if ignoresWindows {
                    SettingsCaption(
                        "Ignored windows are left out of Nehir's managed model. Layout, Sticky, workspace, and size effects will not apply."
                    )
                }

                Picker("Layout", selection: $draft.layoutAction) {
                    ForEach(WindowRuleLayoutAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .disabled(ignoresWindows)

                Toggle("Sticky", isOn: $draft.stickyEnabled)
                    .disabled(ignoresWindows)

                Toggle("Assign to Workspace", isOn: $draft.assignToWorkspaceEnabled)
                    .disabled(ignoresWindows)
                    .onChange(of: draft.assignToWorkspaceEnabled) { _, enabled in
                        guard enabled else { return }
                        seedWorkspaceIfNeeded()
                    }

                if draft.assignToWorkspaceEnabled {
                    Picker("Workspace", selection: $draft.assignToWorkspace) {
                        ForEach(workspaceNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .disabled(workspaceNames.isEmpty || ignoresWindows)

                    if workspaceNames.isEmpty {
                        SettingsCaption("No workspaces configured. Add workspaces in Settings.")
                    }
                }
            }

            Section("Minimum Size (Layout Constraint)") {
                Toggle("Minimum Width", isOn: $draft.minWidthEnabled)

                if draft.minWidthEnabled {
                    HStack {
                        TextField("Width", value: $draft.minWidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("px")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Minimum Height", isOn: $draft.minHeightEnabled)

                if draft.minHeightEnabled {
                    HStack {
                        TextField("Height", value: $draft.minHeight, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("px")
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsCaption("Prevents layout engine from sizing window smaller than these values.")
            }

            Section {
                DisclosureGroup(isExpanded: $isAdvancedMatchersExpanded) {
                    AdvancedMatchersEditor(
                        draft: $draft,
                        regexError: titleRegexError
                    )
                } label: {
                    Text("Advanced Matchers")
                }
            }

            Section {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Rule", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: draft) { _, newValue in
            rule = newValue.makeRule(id: rule.id)
            controller.updateAppRules()
        }
    }

    private var ignoresWindows: Bool {
        draft.manageAction == .ignore
    }

    private var titleRegexError: String? {
        guard draft.titleMatcherMode == .regex else { return nil }
        return controller.windowRuleEngine.invalidRegexMessagesByRuleId[rule.id]
            ?? AppRuleDraftValidation.titleRegexError(for: draft.titleRegex)
    }

    private func seedWorkspaceIfNeeded() {
        if draft.assignToWorkspace.isEmpty, let first = workspaceNames.first {
            draft.assignToWorkspace = first
        }
    }
}

struct AppRuleAddPane: View {
    let workspaceNames: [String]
    let controller: WMController
    let onSave: (AppRule) -> Void
    let onCancel: () -> Void

    @State private var draft: AppRuleDraft
    @State private var runningApps: [RunningAppInfo] = []
    @State private var isPickerExpanded = true
    @State private var isAdvancedMatchersExpanded: Bool
    @State private var selectedAppInfo: RunningAppInfo?

    init(
        initialDraft: AppRuleDraft,
        workspaceNames: [String],
        controller: WMController,
        onSave: @escaping (AppRule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.workspaceNames = workspaceNames
        self.controller = controller
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initialDraft)
        _isAdvancedMatchersExpanded = State(initialValue: initialDraft.hasActiveAdvancedMatchers)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Application") {
                    TextField("Bundle ID", text: $draft.bundleId)
                        .textFieldStyle(.roundedBorder)
                    if let error = bundleIdError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    DisclosureGroup(isExpanded: $isPickerExpanded) {
                        if runningApps.isEmpty {
                            Text("No apps with windows found")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(runningApps) { app in
                                        RunningAppRow(
                                            app: app,
                                            isSelected: draft.bundleId == app.bundleId,
                                            onSelect: { selectApp(app) }
                                        )
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                        }
                    } label: {
                        Text("Pick from running apps")
                    }
                    .onAppear {
                        runningApps = controller.runningAppsWithWindows()
                    }

                    if let appInfo = selectedAppInfo {
                        Button {
                            useCurrentWindowSize(appInfo.windowSize)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.doc")
                                Text(
                                    "Use current size: \(Int(appInfo.windowSize.width)) x \(Int(appInfo.windowSize.height)) px"
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Examples: com.apple.finder or dentalplus-air")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Window Behavior") {
                    Picker("Manage", selection: $draft.manageAction) {
                        ForEach(WindowRuleManageAction.allCases) { action in
                            Text(action.displayName).tag(action)
                        }
                    }

                    if ignoresWindows {
                        Text(
                            "Ignored windows are left out of Nehir's managed model. Layout, Sticky, workspace, and size effects will not apply."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Picker("Layout", selection: $draft.layoutAction) {
                        ForEach(WindowRuleLayoutAction.allCases) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                    .disabled(ignoresWindows)

                    Toggle("Sticky", isOn: $draft.stickyEnabled)
                        .disabled(ignoresWindows)

                    Toggle("Assign to Workspace", isOn: $draft.assignToWorkspaceEnabled)
                        .disabled(ignoresWindows)
                        .onChange(of: draft.assignToWorkspaceEnabled) { _, enabled in
                            guard enabled else { return }
                            seedWorkspaceIfNeeded()
                        }

                    if draft.assignToWorkspaceEnabled {
                        Picker("Workspace", selection: $draft.assignToWorkspace) {
                            ForEach(workspaceNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .disabled(workspaceNames.isEmpty || ignoresWindows)

                        if workspaceNames.isEmpty {
                            Text("No workspaces configured. Add workspaces in Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Minimum Size (Layout Constraint)") {
                    Toggle("Minimum Width", isOn: $draft.minWidthEnabled)

                    if draft.minWidthEnabled {
                        HStack {
                            TextField("Width", value: $draft.minWidth, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("px")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Minimum Height", isOn: $draft.minHeightEnabled)

                    if draft.minHeightEnabled {
                        HStack {
                            TextField("Height", value: $draft.minHeight, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("px")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Prevents layout engine from sizing window smaller than these values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup(isExpanded: $isAdvancedMatchersExpanded) {
                        AdvancedMatchersEditor(
                            draft: $draft,
                            regexError: titleRegexError
                        )
                    } label: {
                        Text("Advanced Matchers")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { isAdvancedMatchersExpanded.toggle() }
                    }
                }

                Section {
                    Button("Add Rule") {
                        onSave(draft.makeRule())
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)

                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .formStyle(.grouped)
        }
    }

    private var bundleIdError: String? {
        AppRuleDraftValidation.bundleIdError(for: draft.bundleId)
    }

    private var titleRegexError: String? {
        guard draft.titleMatcherMode == .regex else { return nil }
        return AppRuleDraftValidation.titleRegexError(for: draft.titleRegex)
    }

    private var ignoresWindows: Bool {
        draft.manageAction == .ignore
    }

    private var isValid: Bool {
        let trimmedBundleId = draft.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedBundleId.isEmpty &&
            bundleIdError == nil &&
            titleRegexError == nil &&
            draft.hasAnyRule
    }

    private func seedWorkspaceIfNeeded() {
        if draft.assignToWorkspace.isEmpty, let first = workspaceNames.first {
            draft.assignToWorkspace = first
        }
    }

    private func selectApp(_ app: RunningAppInfo) {
        draft.bundleId = app.bundleId
        selectedAppInfo = app
        isPickerExpanded = false
    }

    private func useCurrentWindowSize(_ size: CGSize) {
        draft.minWidth = size.width
        draft.minHeight = size.height
        draft.minWidthEnabled = true
        draft.minHeightEnabled = true
    }
}

struct AdvancedMatchersEditor: View {
    @Binding var draft: AppRuleDraft
    let regexError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use advanced matchers when bundle-level rules are too broad.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("App Name Contains", isOn: $draft.appNameMatcherEnabled)
            if draft.appNameMatcherEnabled {
                TextField("e.g. Preview", text: $draft.appNameSubstring)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Title Match", selection: $draft.titleMatcherMode) {
                ForEach(TitleMatcherMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            switch draft.titleMatcherMode {
            case .none:
                EmptyView()
            case .substring:
                TextField("Title contains", text: $draft.titleSubstring)
                    .textFieldStyle(.roundedBorder)
            case .regex:
                TextField("Title regex", text: $draft.titleRegex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let regexError {
                    Text("Title regex is invalid: \(regexError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Toggle("AX Role", isOn: $draft.axRoleEnabled)
            if draft.axRoleEnabled {
                TextField("e.g. AXWindow", text: $draft.axRole)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Toggle("AX Subrole", isOn: $draft.axSubroleEnabled)
            if draft.axSubroleEnabled {
                TextField("e.g. AXStandardWindow", text: $draft.axSubrole)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding(.vertical, 4)
    }
}

struct FocusedWindowInspectorView: View {
    let controller: WMController
    let onCreateRuleFromSnapshot: (WindowDecisionDebugSnapshot) -> Void

    @State private var snapshot: WindowDecisionDebugSnapshot?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Focused Window Inspector")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") {
                        refreshSnapshot()
                    }
                }

                if let snapshot {
                    ScrollView(.vertical) {
                        Text(snapshot.formattedDump())
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 140, maxHeight: 220)

                    HStack {
                        Button("New Rule from Focused Window") {
                            onCreateRuleFromSnapshot(snapshot)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(AppRuleDraft.guided(from: snapshot) == nil)

                        Button("Copy Debug Dump") {
                            controller.diagnostics.copyDebugDump(snapshot)
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("No focused window is available for inspection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                refreshSnapshot()
            }
        }
    }

    private func refreshSnapshot() {
        snapshot = controller.diagnostics.focusedWindowDecisionDebugSnapshot()
    }
}

struct RuleBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct RunningAppRow: View {
    let app: RunningAppInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app")
                        .frame(width: 20, height: 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.appName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(app.bundleId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(Int(app.windowSize.width))x\(Int(app.windowSize.height))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
