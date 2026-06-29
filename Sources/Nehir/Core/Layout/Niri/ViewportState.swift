// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

final class ViewGesture {
    let tracker: SwipeTracker
    let isTrackpad: Bool

    var currentViewOffset: Double
    var animation: SpringAnimation?
    var stationaryViewOffset: Double
    var deltaFromTracker: Double

    init(currentViewOffset: Double, isTrackpad: Bool) {
        self.tracker = SwipeTracker()
        self.currentViewOffset = currentViewOffset
        self.stationaryViewOffset = currentViewOffset
        self.deltaFromTracker = currentViewOffset
        self.isTrackpad = isTrackpad
    }

    func applyDelta(_ delta: Double) {
        currentViewOffset += delta
        stationaryViewOffset += delta
        deltaFromTracker += delta
    }

    func current() -> Double {
        if let anim = animation {
            return currentViewOffset + (anim.value(at: CACurrentMediaTime()) - anim.from)
        }
        return currentViewOffset
    }

    func value(at time: TimeInterval) -> Double {
        if let anim = animation {
            return currentViewOffset + (anim.value(at: time) - anim.from)
        }
        return currentViewOffset
    }

    func currentVelocity() -> Double {
        if let anim = animation {
            return anim.velocity(at: CACurrentMediaTime())
        }
        return tracker.velocity()
    }

    func velocity(at time: TimeInterval) -> Double {
        if let anim = animation {
            return anim.velocity(at: time)
        }
        return tracker.velocity()
    }
}

enum ViewOffset {
    case `static`(CGFloat)
    case gesture(ViewGesture)
    case spring(SpringAnimation)

    var mutationKind: String {
        switch self {
        case .static:
            "static"
        case .gesture:
            "gesture"
        case .spring:
            "spring"
        }
    }

    func current() -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        case let .gesture(g):
            CGFloat(g.current())
        case let .spring(anim):
            CGFloat(anim.value(at: CACurrentMediaTime()))
        }
    }

    func value(at time: TimeInterval) -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        case let .gesture(g):
            CGFloat(g.value(at: time))
        case let .spring(anim):
            CGFloat(anim.value(at: time))
        }
    }

    func target() -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        case let .gesture(g):
            CGFloat(g.currentViewOffset)
        case let .spring(anim):
            CGFloat(anim.target)
        }
    }

    var isAnimating: Bool {
        switch self {
        case .spring:
            return true
        case let .gesture(g):
            return g.animation != nil
        case .static:
            return false
        }
    }

    var isGesture: Bool {
        if case .gesture = self { return true }
        return false
    }

    var gestureRef: ViewGesture? {
        if case let .gesture(g) = self { return g }
        return nil
    }

    mutating func offset(delta: Double) {
        switch self {
        case .static(let offset):
            self = .static(CGFloat(Double(offset) + delta))
        case .spring(let anim):
            anim.offsetBy(delta)
        case .gesture(let g):
            g.applyDelta(delta)
        }
    }

    func currentVelocity(at time: TimeInterval = CACurrentMediaTime()) -> Double {
        switch self {
        case .static:
            0
        case let .gesture(g):
            g.currentVelocity()
        case let .spring(anim):
            anim.velocity(at: time)
        }
    }

    func velocity(at time: TimeInterval) -> Double {
        switch self {
        case .static:
            0
        case let .gesture(g):
            g.velocity(at: time)
        case let .spring(anim):
            anim.velocity(at: time)
        }
    }
}

struct ViewportState {
    struct ViewportMutationSnapshot: Equatable {
        let activeColumnIndex: Int
        let currentOffset: CGFloat
        let targetOffset: CGFloat
        let offsetKind: String

        static func == (lhs: ViewportMutationSnapshot, rhs: ViewportMutationSnapshot) -> Bool {
            // Keep currentOffset in trace output, but exclude its animated,
            // time-sensitive value from change detection.
            lhs.activeColumnIndex == rhs.activeColumnIndex
                && lhs.targetOffset == rhs.targetOffset
                && lhs.offsetKind == rhs.offsetKind
        }
    }

    var activeColumnIndex: Int = 0

    var viewOffsetPixels: ViewOffset = .static(0.0)

    var selectionProgress: CGFloat = 0.0

    var selectedNodeId: NodeId?

    var viewOffsetToRestore: CGFloat?

    var preservesUnsnappedGestureOffset = false

    var activatePrevColumnOnRemoval: CGFloat?

    var pendingFFMFocusToken: WindowToken?
    var pendingFFMFocusTimestamp: Date?
    var recentFFMFocusToken: WindowToken?
    var recentFFMFocusTimestamp: Date?

    var isViewportMutationAuditEnabled = false
    var lastViewportMutationReason: String?
    var lastViewportMutationCaller: String?
    var lastViewportMutationTimestamp: TimeInterval?
    var lastViewportMutationBefore: ViewportMutationSnapshot?
    var lastViewportMutationAfter: ViewportMutationSnapshot?

    let springConfig: SpringConfig = .niriHorizontalViewMovement

    var animationClock: AnimationClock?

    var displayRefreshRate: Double = 60.0

    func viewportMutationSnapshot() -> ViewportMutationSnapshot {
        ViewportMutationSnapshot(
            activeColumnIndex: activeColumnIndex,
            currentOffset: viewOffsetPixels.current(),
            targetOffset: viewOffsetPixels.target(),
            offsetKind: viewOffsetPixels.mutationKind
        )
    }

    mutating func clearViewportMutationAudit() {
        lastViewportMutationReason = nil
        lastViewportMutationCaller = nil
        lastViewportMutationTimestamp = nil
        lastViewportMutationBefore = nil
        lastViewportMutationAfter = nil
    }

    mutating func withRecordedViewportMutation(
        reason: String,
        caller: String = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        _ mutate: (inout ViewportState) -> Void
    ) {
        guard isViewportMutationAuditEnabled else {
            mutate(&self)
            return
        }

        let before = viewportMutationSnapshot()
        mutate(&self)
        let after = viewportMutationSnapshot()
        guard before != after else { return }

        lastViewportMutationReason = reason
        lastViewportMutationCaller = "\(fileID):\(line) \(caller)"
        lastViewportMutationTimestamp = Date().timeIntervalSince1970
        lastViewportMutationBefore = before
        lastViewportMutationAfter = after
    }

    mutating func offsetViewOffsetPixels(
        delta: Double,
        reason: String,
        caller: String = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        withRecordedViewportMutation(reason: reason, caller: caller, fileID: fileID, line: line) { state in
            state.viewOffsetPixels.offset(delta: delta)
        }
    }

    mutating func setStaticViewOffsetPixels(
        _ offset: CGFloat,
        reason: String,
        caller: String = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        withRecordedViewportMutation(reason: reason, caller: caller, fileID: fileID, line: line) { state in
            state.viewOffsetPixels = .static(offset)
        }
    }

    mutating func setGestureViewOffsetPixels(
        _ gesture: ViewGesture,
        reason: String,
        caller: String = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        withRecordedViewportMutation(reason: reason, caller: caller, fileID: fileID, line: line) { state in
            state.viewOffsetPixels = .gesture(gesture)
        }
    }

    mutating func setSpringViewOffsetPixels(
        _ animation: SpringAnimation,
        reason: String,
        caller: String = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        withRecordedViewportMutation(reason: reason, caller: caller, fileID: fileID, line: line) { state in
            state.viewOffsetPixels = .spring(animation)
        }
    }
}
