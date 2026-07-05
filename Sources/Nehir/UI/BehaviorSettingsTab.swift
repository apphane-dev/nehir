// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

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
                SettingsCaption(
                    "Moves keyboard focus to whichever window is under the cursor. Hover focus does not reveal clipped or offscreen targets; hold the Manual Override modifier and click a window to use normal focus and reveal it."
                )

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
                SettingsCaption(
                    "When moving a window to another workspace, switches your active workspace to follow it."
                )

                Picker("Reveal Style", selection: $settings.revealStyle) {
                    ForEach(RevealStyle.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .onChange(of: settings.revealStyle) { _, newValue in
                    controller.updateNiriConfig(revealStyle: newValue)
                }
                SettingsCaption(
                    "Controls where reveals place clipped or offscreen targets. Fully visible targets never scroll. Viewport Scroll Lock blocks background automatic reveals; direct navigation and manual scrolling still work."
                )
            }

            Section("Scroll Gestures") {
                Toggle("Enable Scroll Gestures", isOn: $settings.scrollGestureEnabled)

                SettingsSliderRow(
                    label: "Scroll Sensitivity",
                    value: $settings.scrollSensitivity,
                    range: 0.5 ... 20.0,
                    step: 0.5,
                    formatter: { String(format: "%.1f", $0) + "x" }
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

                SettingsCaption(settings
                    .gestureInvertDirection ? "Swipe right = scroll right" : "Swipe right = scroll left")

                Picker("Mouse Scroll Modifier", selection: $settings.scrollModifierKey) {
                    ForEach(ScrollModifierKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .disabled(!settings.scrollGestureEnabled)

                SettingsCaption("Hold this key + scroll wheel to navigate workspaces")
            }

            Section("Manual Override") {
                Picker("Modifier", selection: $settings.overrideModifier) {
                    ForEach(OverrideModifierKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }

                SettingsCaption(
                    "Hold this modifier to take manual control: resize the tiled window under the pointer with a right-mouse drag, scroll the viewport freely past column snapping, and — while Focus Follows Mouse is on — keep focus on the current window as the pointer passes over others."
                )
            }
        }
        .formStyle(.grouped)
    }
}
