import SwiftUI

struct SettingsDetailView: View {
    let section: SettingsSection
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var navigation: SettingsNavigationModel
    var cliManager: AppCLIManager?

    var body: some View {
        contentView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(section.displayName)
            .omniBackgroundExtensionEffect()
    }

    @ViewBuilder
    private var contentView: some View {
        switch section {
        case .general:
            GeneralSettingsTab(
                settings: settings,
                controller: controller,
                cliManager: cliManager
            )
        case .about:
            AboutSettingsTab()
        case .behavior:
            BehaviorSettingsTab(settings: settings, controller: controller)
        case .layout:
            LayoutSettingsTab(settings: settings, controller: controller)
        case .monitors:
            MonitorSettingsTab(settings: settings, controller: controller)
        case .workspaces:
            WorkspacesSettingsTab(settings: settings, controller: controller)
        case .borders:
            BorderSettingsTab(settings: settings, controller: controller)
        case .bar:
            WorkspaceBarSettingsTab(settings: settings, controller: controller)
        case .appRules:
            AppRulesView(settings: settings, controller: controller)
        case .hotkeys:
            HotkeySettingsView(settings: settings, controller: controller, navigation: navigation)
        case .diagnostics:
            DisplayDiagnosticsSettingsTab(settings: settings, controller: controller, navigation: navigation)
        }
    }
}
