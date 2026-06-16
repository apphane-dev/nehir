import AppKit
import SwiftUI

struct BorderSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var pendingColorSync: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Borders") {
                Toggle(isOn: $settings.bordersEnabled) {
                    HStack(spacing: 8) {
                        Text("Enable Window Borders")
                        ExperimentalBadge()
                    }
                }
                .onChange(of: settings.bordersEnabled) { _, newValue in
                    controller.setBordersEnabled(newValue)
                }

                SettingsCaption("Highlights the currently focused window with a colored border.")

                if settings.bordersEnabled {
                    SettingsSliderRow(
                        label: "Border Width",
                        value: $settings.borderWidth,
                        range: 1 ... 12,
                        step: 0.5,
                        formatter: { String(format: "%.1f px", $0) },
                        valueWidth: 56
                    )
                    .onChange(of: settings.borderWidth) { _, _ in
                        syncBorderConfig()
                    }

                    ColorPicker("Border Color", selection: colorBinding, supportsOpacity: true)
                        .onChange(of: settings.borderColorRed) { _, _ in debouncedColorSync() }
                        .onChange(of: settings.borderColorGreen) { _, _ in debouncedColorSync() }
                        .onChange(of: settings.borderColorBlue) { _, _ in debouncedColorSync() }
                        .onChange(of: settings.borderColorAlpha) { _, _ in debouncedColorSync() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: settings.borderColorRed,
                    green: settings.borderColorGreen,
                    blue: settings.borderColorBlue,
                    opacity: settings.borderColorAlpha
                )
            },
            set: { newColor in
                if let cgColor = NSColor(newColor).usingColorSpace(.deviceRGB)?.cgColor,
                   let components = cgColor.components, components.count >= 3
                {
                    settings.borderColorRed = Double(components[0])
                    settings.borderColorGreen = Double(components[1])
                    settings.borderColorBlue = Double(components[2])
                    if components.count >= 4 {
                        settings.borderColorAlpha = Double(components[3])
                    }
                }
            }
        )
    }

    private func syncBorderConfig() {
        controller.updateBorderConfig(BorderConfig.from(settings: settings))
    }

    private func debouncedColorSync() {
        pendingColorSync?.cancel()
        pendingColorSync = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            syncBorderConfig()
        }
    }
}
