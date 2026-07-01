// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

// Reverse-engineered byte offsets into the private MultitouchSupport framework's
// per-touch ("Finger") record. These are not part of any stable ABI; the struct
// layout has drifted across macOS releases and these offsets are only known to
// produce correct centroids/touch state on the macOS version observed during
// development (macOS 26.5, build 25F80). If raw multitouch gestures stop firing
// or report garbage positions after an OS update, re-derive these offsets and
// `multitouchTouchingState` against the current MultitouchSupport binary before
// anything else — the `load(fromByteOffset:as:)` calls below silently read the
// wrong fields when the layout shifts.
private let multitouchTouchStride = 96
private let multitouchStateByteOffset = 20
private let multitouchPositionXByteOffset = 32
private let multitouchPositionYByteOffset = 36
private let multitouchTouchingState: Int32 = 4

@MainActor
final class MultitouchGestureSource {
    struct RawTouch: Sendable {
        let x: Float
        let y: Float
    }

    struct RawFrame: Sendable {
        let touches: [RawTouch]
        let timestamp: Double
    }

    @MainActor weak static var shared: MultitouchGestureSource?

    var onSnapshot: ((MouseEventHandler.GestureEventSnapshot) -> Void)?

    private let binding = MultitouchBinding()
    private var devices: [MultitouchBinding.DeviceRef] = []
    private var deviceList: CFArray?
    private var isRunning = false
    private var previousActiveCount = 0

    func start() {
        guard let binding, !isRunning else { return }
        MultitouchGestureSource.shared = self
        guard let discovered = binding.devices() else { return }
        for device in discovered.refs {
            binding.register(device, callback: MultitouchGestureSource.contactCallback)
            binding.start(device)
        }
        devices = discovered.refs
        deviceList = discovered.list
        isRunning = true
    }

    func stop() {
        guard let binding else { return }
        isRunning = false
        for device in devices {
            binding.unregister(device, callback: MultitouchGestureSource.contactCallback)
            binding.stop(device)
        }
        devices = []
        deviceList = nil
        previousActiveCount = 0
    }

    func restart() {
        stop()
        start()
    }

    func handleRawFrame(_ frame: RawFrame) {
        guard isRunning else { return }
        let localFrame = RawFrame(
            touches: frame.touches,
            timestamp: CACurrentMediaTime()
        )
        let result = MultitouchGestureSource.makeSnapshot(
            frame: localFrame,
            location: NSEvent.mouseLocation,
            modifiers: MouseEventHandler.cgEventFlags(from: NSEvent.modifierFlags),
            previousActiveCount: previousActiveCount
        )
        previousActiveCount = result.activeCount
        if let snapshot = result.snapshot {
            onSnapshot?(snapshot)
        }
    }

    static func makeSnapshot(
        frame: RawFrame,
        location: CGPoint,
        modifiers: CGEventFlags = [],
        previousActiveCount: Int
    ) -> (snapshot: MouseEventHandler.GestureEventSnapshot?, activeCount: Int) {
        let activeCount = frame.touches.count
        if activeCount == 0 {
            guard previousActiveCount > 0 else { return (nil, 0) }
            let snapshot = MouseEventHandler.GestureEventSnapshot(
                location: location,
                phaseRawValue: NSEvent.Phase.ended.rawValue,
                timestamp: frame.timestamp,
                modifiers: modifiers,
                previousRawActiveCount: previousActiveCount,
                touches: []
            )
            return (snapshot, 0)
        }

        // A contact-count increase (including a 1→2→3 ramp toward the configured
        // finger count) is the start of a gesture, so emit `.began`; a same-count or
        // decreasing frame stays `.changed`. This lets the handler require `.began`
        // for idle admission without rejecting legitimate ramps. The active-count-0
        // case above already emits `.ended`.
        let phase: NSEvent.Phase = activeCount > previousActiveCount ? .began : .changed
        let touches = frame.touches.map { touch in
            MouseEventHandler.GestureTouchSample(
                phase: .moved,
                normalizedPosition: normalizedPosition(x: touch.x, y: touch.y)
            )
        }
        let snapshot = MouseEventHandler.GestureEventSnapshot(
            location: location,
            phaseRawValue: phase.rawValue,
            timestamp: frame.timestamp,
            modifiers: modifiers,
            previousRawActiveCount: previousActiveCount,
            touches: touches
        )
        return (snapshot, activeCount)
    }

    private static func normalizedPosition(x: Float, y: Float) -> CGPoint? {
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    private static let contactCallback: MultitouchBinding.ContactCallback = { _, fingers, count, timestamp, _ in
        let frame = MultitouchGestureSource.buildRawFrame(fingers: fingers, count: count, timestamp: timestamp)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                MultitouchGestureSource.shared?.handleRawFrame(frame)
            }
        }
        return 0
    }

    private nonisolated static func buildRawFrame(
        fingers: UnsafeMutableRawPointer?,
        count: Int32,
        timestamp: Double
    ) -> RawFrame {
        guard let fingers, count > 0 else { return RawFrame(touches: [], timestamp: timestamp) }
        var touches: [RawTouch] = []
        touches.reserveCapacity(Int(count))
        for index in 0 ..< Int(count) {
            let base = index * multitouchTouchStride
            let state = fingers.load(fromByteOffset: base + multitouchStateByteOffset, as: Int32.self)
            guard state == multitouchTouchingState else { continue }
            let x = fingers.load(fromByteOffset: base + multitouchPositionXByteOffset, as: Float.self)
            let y = fingers.load(fromByteOffset: base + multitouchPositionYByteOffset, as: Float.self)
            touches.append(RawTouch(x: x, y: y))
        }
        return RawFrame(touches: touches, timestamp: timestamp)
    }
}
