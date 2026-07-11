// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import ApplicationServices
import CoreGraphics
import Foundation

enum ManagedBorderReapplyPhase: String, Equatable {
    case postLayout
    case animationSettled
    case retryExhaustedFallback
}

enum BorderFrameSource: Equatable {
    case layout
    case observed
}

@MainActor
final class FocusBorderController {
    private enum RenderEligibility {
        case clear
        case hide
        case update
    }

    weak var controller: WMController?
    var observedFrameProviderForTests: ((AXWindowRef) -> CGRect?)?
    var windowRoleProviderForTests: ((AXWindowRef) -> (role: String?, subrole: String?))?
    var suppressNextRenderForTests: ((KeyboardFocusTarget) -> Bool)?
    var suppressNextFrameHintForTests: ((WindowToken) -> Bool)?

    private let borderManager: BorderManager
    private var visualFocusTarget: KeyboardFocusTarget?
    private var requiresFocusValidationBeforeRender = false
    private var suppressedManagedTargets: Set<WindowToken> = []
    private var isScreenshotCaptureSuppressed = false

    init(
        controller: WMController,
        borderManager: BorderManager = .init()
    ) {
        self.controller = controller
        self.borderManager = borderManager
    }

    @discardableResult
    func focusChanged(
        to target: KeyboardFocusTarget?,
        preferredFrame: CGRect? = nil,
        preferredFrameSource: BorderFrameSource = .layout,
        forceOrdering: Bool = true
    ) -> Bool {
        visualFocusTarget = target
        requiresFocusValidationBeforeRender = false
        if let target {
            suppressedManagedTargets.remove(target.token)
        }
        return refresh(
            preferredFrame: preferredFrame,
            preferredFrameSource: preferredFrameSource,
            forceOrdering: forceOrdering
        )
    }

    @discardableResult
    func refresh(
        preferredFrame: CGRect? = nil,
        preferredFrameSource: BorderFrameSource = .layout,
        forceOrdering: Bool = false
    ) -> Bool {
        if isScreenshotCaptureSuppressed {
            borderManager.hideBorder()
            return false
        }

        guard let target = visualFocusTarget else {
            borderManager.hideBorder()
            return false
        }

        if requiresFocusValidationBeforeRender {
            guard isStillKeyboardFocused(target) else {
                clear()
                return false
            }
            requiresFocusValidationBeforeRender = false
        }

        return render(
            target: target,
            preferredFrame: preferredFrame,
            preferredFrameSource: preferredFrameSource,
            forceOrdering: forceOrdering
        )
    }

    @discardableResult
    func updateFrameHint(
        for token: WindowToken,
        frame: CGRect,
        source: BorderFrameSource = .layout,
        forceOrdering: Bool = false
    ) -> Bool {
        guard visualFocusTarget?.token == token else { return false }
        if suppressNextFrameHintForTests?(token) == true {
            suppressNextFrameHintForTests = nil
            return false
        }
        return refresh(
            preferredFrame: frame,
            preferredFrameSource: source,
            forceOrdering: forceOrdering
        )
    }

    func hide() {
        requiresFocusValidationBeforeRender = visualFocusTarget != nil
        borderManager.hideBorder()
    }

    func clear() {
        visualFocusTarget = nil
        requiresFocusValidationBeforeRender = false
        borderManager.hideBorder()
    }

    func clear(
        matching token: WindowToken? = nil,
        pid: pid_t? = nil
    ) {
        clearSuppressedManagedTargets(matching: token, pid: pid)
        guard let target = visualFocusTarget else { return }
        let matchesToken = token.map { target.token == $0 } ?? true
        let matchesPid = pid.map { target.pid == $0 } ?? true
        guard matchesToken, matchesPid else { return }
        clear()
    }

    @discardableResult
    func clearCurrentTarget(
        matching pid: pid_t,
        where shouldClear: (KeyboardFocusTarget) -> Bool
    ) -> KeyboardFocusTarget? {
        guard let target = visualFocusTarget,
              target.pid == pid,
              shouldClear(target)
        else { return nil }
        clear()
        return target
    }

    func rekeyFocusedTarget(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        if suppressedManagedTargets.remove(oldToken) != nil {
            suppressedManagedTargets.insert(newToken)
        }
        guard let target = visualFocusTarget,
              target.token == oldToken
        else { return }
        visualFocusTarget = KeyboardFocusTarget(
            token: newToken,
            axRef: axRef,
            workspaceId: workspaceId,
            isManaged: target.isManaged
        )
        requiresFocusValidationBeforeRender = true
    }

    func updateFocusedTargetWorkspace(
        matching token: WindowToken,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let target = visualFocusTarget,
              target.token == token
        else { return }
        visualFocusTarget = KeyboardFocusTarget(
            token: token,
            axRef: axRef,
            workspaceId: workspaceId,
            isManaged: workspaceId != nil
        )
    }

    func setScreenshotCaptureSuppressed(_ suppressed: Bool) {
        guard isScreenshotCaptureSuppressed != suppressed else {
            if suppressed {
                borderManager.hideBorder()
            }
            return
        }

        isScreenshotCaptureSuppressed = suppressed
        if suppressed {
            borderManager.hideBorder()
            return
        }

        if visualFocusTarget != nil {
            _ = refresh(forceOrdering: true)
            return
        }
        guard let controller,
              !controller.workspaceManager.isNonManagedFocusActive,
              let token = controller.workspaceManager.confirmedManagedFocusToken,
              let target = controller.managedKeyboardFocusTarget(for: token)
        else { return }
        _ = focusChanged(to: target, forceOrdering: true)
    }

    func setEnabled(_ enabled: Bool) {
        borderManager.setEnabled(enabled)
        if enabled {
            _ = refresh(forceOrdering: true)
        }
    }

    func updateConfig(_ config: BorderConfig) {
        borderManager.updateConfig(config)
        if config.enabled {
            _ = refresh(forceOrdering: true)
        }
    }

    func cleanup() {
        visualFocusTarget = nil
        requiresFocusValidationBeforeRender = false
        suppressedManagedTargets.removeAll()
        isScreenshotCaptureSuppressed = false
        borderManager.cleanup()
    }

    func suppressManagedTarget(_ token: WindowToken) {
        suppressedManagedTargets.insert(token)
    }

    func isManagedTargetSuppressed(_ token: WindowToken) -> Bool {
        suppressedManagedTargets.contains(token)
    }

    var currentBorderTarget: KeyboardFocusTarget? {
        visualFocusTarget
    }

    var lastAppliedFocusedWindowIdForTests: Int? {
        borderManager.lastAppliedFocusedWindowIdForTests
    }

    var lastAppliedFocusedFrameForTests: CGRect? {
        borderManager.lastAppliedFocusedFrameForTests
    }

    @discardableResult
    private func render(
        target: KeyboardFocusTarget,
        preferredFrame: CGRect?,
        preferredFrameSource: BorderFrameSource,
        forceOrdering: Bool
    ) -> Bool {
        guard controller != nil else { return false }

        if suppressNextRenderForTests?(target) == true {
            suppressNextRenderForTests = nil
            return false
        }

        switch renderEligibility(for: target) {
        case .clear:
            clear()
            return false
        case .hide:
            borderManager.hideBorder()
            return false
        case .update:
            break
        }

        guard let frame = resolveFrame(
            for: target,
            preferredFrame: preferredFrame,
            preferredFrameSource: preferredFrameSource
        ) else {
            borderManager.hideBorder()
            return false
        }

        return borderManager.updateFocusedWindow(
            frame: frame,
            windowId: target.windowId,
            forceOrdering: forceOrdering,
            order: borderOrdering(for: target),
            placement: borderPlacement(for: target)
        )
    }

    private func renderEligibility(for target: KeyboardFocusTarget) -> RenderEligibility {
        guard let controller else { return .clear }

        if controller.isOwnedWindow(windowNumber: target.windowId) {
            return .clear
        }

        if target.isManaged,
           controller.workspaceManager.entry(for: target.token) == nil
        {
            suppressedManagedTargets.remove(target.token)
            return .clear
        }

        if target.isManaged,
           suppressedManagedTargets.contains(target.token)
        {
            return .hide
        }

        if controller.workspaceManager.hasPendingNativeFullscreenTransition {
            return .hide
        }

        if isSystemModalSurface(target) {
            return .hide
        }

        if target.isManaged,
           (controller.workspaceManager.isAppFullscreenActive || isManagedWindowFullscreen(target.token))
        {
            return .hide
        }

        if target.isManaged,
           let entry = controller.workspaceManager.entry(for: target.token),
           !controller.isManagedWindowDisplayable(entry.handle)
        {
            return .hide
        }

        return .update
    }

    private func isStillKeyboardFocused(_ target: KeyboardFocusTarget) -> Bool {
        guard let controller else { return false }
        guard controller.hasStartedServices else { return true }
        return controller.axEventHandler.focusedWindowToken(for: target.pid) == target.token
    }

    private func borderOrdering(for target: KeyboardFocusTarget) -> SkyLightWindowOrder {
        let attributes = windowRoleProviderForTests?(target.axRef) ?? (
            role: AXWindowService.role(target.axRef),
            subrole: AXWindowService.subrole(target.axRef)
        )
        return isQutebrowserFramelessTopLevelWindow(target, attributes: attributes) ? .above : .below
    }

    private func borderPlacement(for target: KeyboardFocusTarget) -> BorderPlacement {
        let attributes = windowRoleProviderForTests?(target.axRef) ?? (
            role: AXWindowService.role(target.axRef),
            subrole: AXWindowService.subrole(target.axRef)
        )
        return isQutebrowserFramelessTopLevelWindow(target, attributes: attributes) ? .inside : .outside
    }

    private func isSystemModalSurface(_ target: KeyboardFocusTarget) -> Bool {
        let attributes = windowRoleProviderForTests?(target.axRef) ?? (
            role: AXWindowService.role(target.axRef),
            subrole: AXWindowService.subrole(target.axRef)
        )

        if isQutebrowserFramelessTopLevelWindow(target, attributes: attributes) {
            return false
        }

        return attributes.role == kAXSheetRole as String
            || attributes.subrole == kAXDialogSubrole as String
            || attributes.subrole == kAXSystemDialogSubrole as String
    }

    private func isQutebrowserFramelessTopLevelWindow(
        _ target: KeyboardFocusTarget,
        attributes: (role: String?, subrole: String?)
    ) -> Bool {
        guard attributes.role == kAXWindowRole as String,
              attributes.subrole == kAXDialogSubrole as String,
              let metadata = controller?.workspaceManager.entry(for: target.token)?.managedReplacementMetadata,
              metadata.bundleId == "org.qutebrowser.qutebrowser"
        else {
            return false
        }

        if metadata.windowLevel == 0, metadata.parentWindowId == 0 {
            return true
        }

        if let info = SkyLight.shared.queryWindowInfo(UInt32(target.windowId)) {
            return info.level == 0 && info.parentId == 0
        }

        return false
    }

    private func clearSuppressedManagedTargets(
        matching token: WindowToken?,
        pid: pid_t?
    ) {
        if let token {
            suppressedManagedTargets.remove(token)
            return
        }
        if let pid {
            suppressedManagedTargets = suppressedManagedTargets.filter { $0.pid != pid }
        }
    }

    private func resolveFrame(
        for target: KeyboardFocusTarget,
        preferredFrame: CGRect?,
        preferredFrameSource: BorderFrameSource
    ) -> CGRect? {
        guard let controller else { return nil }
        let preferred = preferredFrame

        if target.isManaged,
           let entry = controller.workspaceManager.entry(for: target.token)
        {
            if let pendingFrame = controller.axManager.pendingFrameWrite(for: entry.windowId) {
                return pendingFrame
            }

            if preferredFrameSource == .observed, let preferred {
                return preferred
            }

            if entry.managedReplacementMetadata != nil, let observed = observedFrame(for: entry.axRef) {
                return observed
            }

            let hasRecentFrameWriteFailure = controller.axManager.recentFrameWriteFailure(for: entry.windowId) != nil

            if !hasRecentFrameWriteFailure, let preferred {
                return preferred
            }

            if hasRecentFrameWriteFailure, let observed = observedFrame(for: entry.axRef) {
                return observed
            }

            if let preferred {
                return preferred
            }

            if let frame = controller.axManager.lastAppliedFrame(for: entry.windowId) {
                return frame
            }

            if let frame = controller.preferredKeyboardFocusFrame(for: target.token) {
                return frame
            }

            if let observed = observedFrame(for: entry.axRef) {
                return observed
            }

            return nil
        }

        if preferredFrameSource == .observed, let preferred {
            return preferred
        }

        if let observed = observedFrame(for: target.axRef) {
            return observed
        }

        return preferred
    }

    private func observedFrame(for axRef: AXWindowRef) -> CGRect? {
        if let observedFrameProviderForTests {
            return observedFrameProviderForTests(axRef)
        }

        if let frame = AXWindowService.framePreferFast(axRef) {
            return frame
        }

        return try? AXWindowService.frame(axRef)
    }

    private func isManagedWindowFullscreen(_ token: WindowToken) -> Bool {
        guard let controller else { return false }

        return controller.focusCoordinator.isFocusedWindowFullscreen(token)
    }
}
