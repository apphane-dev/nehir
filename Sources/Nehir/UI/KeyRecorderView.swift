// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Carbon
import SwiftUI

struct KeyRecorderView: NSViewRepresentable {
    let accessibilityLabel: String
    var allowsBareKeys: Bool = false
    let onCapture: (KeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context _: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.recordingAccessibilityLabel = accessibilityLabel
        view.allowsBareKeys = allowsBareKeys
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.updateAccessibility()
        return view
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context _: Context) {
        nsView.recordingAccessibilityLabel = accessibilityLabel
        nsView.allowsBareKeys = allowsBareKeys
        nsView.updateAccessibility()
    }
}

class KeyRecorderNSView: NSView {
    var onCapture: ((KeyBinding) -> Void)?
    var onCancel: (() -> Void)?
    var recordingAccessibilityLabel = "Recording hotkey"
    var allowsBareKeys = false

    private let label = NSTextField(labelWithString: "Press keys...")
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var didFinishRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        layer?.cornerRadius = 4
        focusRingType = .exterior

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        addSubview(label)

        updateAccessibility()

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func updateAccessibility() {
        setAccessibilityRole(.group)
        setAccessibilityLabel(recordingAccessibilityLabel)
        setAccessibilityValue("Recording. Press a key combination.")
        setAccessibilityHelp("Press a key combination. Press Escape to cancel recording.")
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startRecording()
        } else {
            stopRecording()
        }
    }

    private func startRecording() {
        guard let window else { return }
        guard localEventMonitor == nil, globalEventMonitor == nil else { return }
        didFinishRecording = false
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            _ = self?.handleKeyEvent(event)
        }

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            if window.makeFirstResponder(self) {
                NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
            }
        }
    }

    private func stopRecording() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard !didFinishRecording else { return true }
        if event.keyCode == UInt16(kVK_Escape) {
            didFinishRecording = true
            stopRecording()
            onCancel?()
            return true
        }

        guard let binding = binding(from: event) else { return false }

        didFinishRecording = true
        stopRecording()
        onCapture?(binding)
        return true
    }

    private func binding(from event: NSEvent) -> KeyBinding? {
        let carbonModifiers = carbonModifiersFromNSEvent(event)
        let requiresModifier = !isSpecialKey(Int(event.keyCode))
        guard allowsBareKeys || !requiresModifier || carbonModifiers != 0 else { return nil }

        return KeyBinding(
            keyCode: UInt32(event.keyCode),
            modifiers: normalizedHyperModifiers(carbonModifiers)
        )
    }

    private func normalizedHyperModifiers(_ modifiers: UInt32) -> UInt32 {
        modifiers == KeySymbolMapper.realHyperModifiers ? KeySymbolMapper.realHyperModifiers : modifiers
    }

    private func carbonModifiersFromNSEvent(_ event: NSEvent) -> UInt32 {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags

        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        return modifiers
    }

    private func isSpecialKey(_ keyCode: Int) -> Bool {
        (keyCode >= kVK_F1 && keyCode <= kVK_F12) ||
            keyCode == kVK_F13 || keyCode == kVK_F14 ||
            keyCode == kVK_F15 || keyCode == kVK_F16 ||
            keyCode == kVK_F17 || keyCode == kVK_F18 ||
            keyCode == kVK_F19 || keyCode == kVK_F20
    }

    override func keyDown(with event: NSEvent) {
        guard !handleKeyEvent(event) else { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        return handleKeyEvent(event)
    }

    override var acceptsFirstResponder: Bool {
        true
    }
}
