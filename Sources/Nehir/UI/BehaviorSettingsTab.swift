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

                Toggle("Follow Window to Monitor", isOn: $settings.focusFollowsWindowToMonitor)
                SettingsCaption("When a window moves to another monitor, keyboard focus follows it there.")

                Toggle("Move Cursor to Focused Window", isOn: $settings.moveMouseToFocusedWindow)
                    .onChange(of: settings.moveMouseToFocusedWindow) { _, newValue in
                        controller.setMoveMouseToFocusedWindow(newValue)
                    }
                SettingsCaption("Warps the cursor to the center of a window when it receives keyboard focus.")
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

                Toggle("Snap to Column", isOn: $settings.gestureScrollSnap)
                    .disabled(!settings.scrollGestureEnabled)

                Picker("Mouse Scroll Modifier", selection: $settings.scrollModifierKey) {
                    ForEach(ScrollModifierKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .disabled(!settings.scrollGestureEnabled)

                SettingsCaption("Hold this key + scroll wheel to navigate workspaces")
            }

            Section("Mouse Resize") {
                Picker("Right Mouse Resize Modifier", selection: $settings.mouseResizeModifierKey) {
                    ForEach(MouseResizeModifierKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }

                SettingsCaption("Hold this modifier combo + right mouse drag to resize tiled windows")
            }
        }
        .formStyle(.grouped)
    }
}
