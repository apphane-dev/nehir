import SwiftUI

struct BehaviorSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        Form {
            Section("Focus") {
                Toggle(isOn: $settings.focusFollowsMouse) {
                    HStack(spacing: 8) {
                        Text("Focus Follows Mouse")
                        ExperimentalBadge()
                    }
                }
                .onChange(of: settings.focusFollowsMouse) { _, newValue in
                    controller.setFocusFollowsMouse(newValue)
                }
                SettingsCaption("Moves keyboard focus to whichever window is under the cursor.")

                Toggle(isOn: $settings.moveMouseToFocusedWindow) {
                    HStack(spacing: 8) {
                        Text("Move Cursor to Focused Window")
                        ExperimentalBadge()
                    }
                }
                    .onChange(of: settings.moveMouseToFocusedWindow) { _, newValue in
                        controller.setMoveMouseToFocusedWindow(newValue)
                    }
                SettingsCaption("Warps the cursor to the center of a window when it receives keyboard focus.")
            }

            Section("Navigation") {
                Toggle("Wrap Navigation at Edges", isOn: $settings.niriInfiniteLoop)
                    .onChange(of: settings.niriInfiniteLoop) { _, newValue in
                        controller.updateNiriConfig(infiniteLoop: newValue)
                    }
                SettingsCaption("When navigating past the last column, wrap around to the first.")

                Toggle("Follow Window to Workspace", isOn: $settings.focusFollowsWindowToMonitor)
                SettingsCaption("When moving a window to another workspace, switches your active workspace to follow it.")

                Picker("Reveal Partial", selection: $settings.revealPartial) {
                    ForEach(RevealPartial.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .onChange(of: settings.revealPartial) { _, newValue in
                    controller.updateNiriConfig(revealPartial: newValue)
                }
                SettingsCaption("Default uses closest snap only when that snap aligns both viewport edges and visible columns fill the viewport; otherwise it centers.")
            }

            Section("Scroll Gestures") {
                Toggle("Enable Scroll Gestures", isOn: $settings.scrollGestureEnabled)

                SettingsSliderRow(
                    label: "Scroll Sensitivity",
                    value: $settings.scrollSensitivity,
                    range: 0.5 ... 20.0,
                    step: 0.5,
                    valueText: String(format: "%.1f", settings.scrollSensitivity) + "x"
                )
                .disabled(!settings.scrollGestureEnabled)

                Picker("Trackpad Gesture Fingers", selection: $settings.gestureFingerCount) {
                    ForEach(GestureFingerCount.allCases, id: \.self) { count in
                        Text(count.displayName).tag(count)
                    }
                }
                .disabled(!settings.scrollGestureEnabled)

                Toggle("Invert Direction (Natural)", isOn: $settings.gestureInvertDirection)
                    .disabled(!settings.scrollGestureEnabled)

                SettingsCaption(settings.gestureInvertDirection ? "Swipe right = scroll right" : "Swipe right = scroll left")

                Picker("Mouse Scroll Modifier", selection: $settings.scrollModifierKey) {
                    ForEach(ScrollModifierKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .disabled(!settings.scrollGestureEnabled)

                SettingsCaption("Hold this key + scroll wheel to navigate workspaces")
            }

            Section("Mouse Resize") {
                Picker("Mouse Modifier", selection: $settings.mouseResizeModifierKey) {
                    ForEach(MouseResizeModifierKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }

                SettingsCaption("Hold this modifier combo to resize with right mouse drag, or during a trackpad scroll gesture to bypass snap.")
            }
        }
        .formStyle(.grouped)
    }
}
