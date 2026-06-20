// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

enum NehirFocusNotificationKey {
    static let oldWorkspaceId = "oldWorkspaceId"
    static let newWorkspaceId = "newWorkspaceId"
    static let oldWorkspaceName = "oldWorkspaceName"
    static let newWorkspaceName = "newWorkspaceName"
    static let oldMonitorIndex = "oldMonitorIndex"
    static let newMonitorIndex = "newMonitorIndex"
    static let oldMonitorName = "oldMonitorName"
    static let newMonitorName = "newMonitorName"
    static let oldWindowId = "oldWindowId"
    static let newWindowId = "newWindowId"
    static let oldWindowToken = "oldWindowToken"
    static let newWindowToken = "newWindowToken"
    static let oldHandleId = "oldHandleId"
    static let newHandleId = "newHandleId"
}

extension Notification.Name {
    static let nehirFocusChanged = Notification.Name("Nehir.FocusChanged")
    static let nehirFocusedWorkspaceChanged = Notification.Name("Nehir.FocusedWorkspaceChanged")
    static let nehirFocusedMonitorChanged = Notification.Name("Nehir.FocusedMonitorChanged")
}

@MainActor
final class FocusNotificationDispatcher {
    struct ChangeSet: Equatable {
        let focusChanged: Bool
        let workspaceChanged: Bool
        let monitorChanged: Bool
    }

    weak var controller: WMController?

    private var lastNotifiedWorkspaceId: WorkspaceDescriptor.ID?
    private var lastNotifiedMonitorId: Monitor.ID?
    private var lastNotifiedFocusedToken: WindowToken?
    private var lastNotifiedFocusedWindowId: Int?

    init(controller: WMController) {
        self.controller = controller
    }

    @discardableResult
    func notifyFocusChangesIfNeeded() -> ChangeSet {
        guard let controller else {
            return ChangeSet(focusChanged: false, workspaceChanged: false, monitorChanged: false)
        }
        var focusChanged = false

        let currentMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        let currentWorkspaceId = currentMonitorId.flatMap {
            controller.workspaceManager.currentActiveWorkspace(on: $0)?.id
        } ?? controller.interactionWorkspace()?.id

        let currentToken = controller.workspaceManager.confirmedManagedFocusToken
        let currentWindowId = currentToken
            .flatMap { controller.workspaceManager.entry(for: $0)?.windowId }

        if currentToken != lastNotifiedFocusedToken || currentWindowId != lastNotifiedFocusedWindowId {
            var info: [AnyHashable: Any] = [:]
            if let oldToken = lastNotifiedFocusedToken {
                info[NehirFocusNotificationKey.oldWindowToken] = oldToken
                info[NehirFocusNotificationKey.oldHandleId] = oldToken
            }
            if let newToken = currentToken {
                info[NehirFocusNotificationKey.newWindowToken] = newToken
                info[NehirFocusNotificationKey.newHandleId] = newToken
            }
            if let oldWindowId = lastNotifiedFocusedWindowId {
                info[NehirFocusNotificationKey.oldWindowId] = oldWindowId
            }
            if let newWindowId = currentWindowId { info[NehirFocusNotificationKey.newWindowId] = newWindowId }

            NotificationCenter.default.post(
                name: .nehirFocusChanged,
                object: controller,
                userInfo: info.isEmpty ? nil : info
            )
            lastNotifiedFocusedToken = currentToken
            lastNotifiedFocusedWindowId = currentWindowId
            focusChanged = true
        }

        var workspaceInfo: [AnyHashable: Any] = [:]
        if let oldId = lastNotifiedWorkspaceId {
            workspaceInfo[NehirFocusNotificationKey.oldWorkspaceId] = oldId
            if let name = controller.workspaceManager.descriptor(for: oldId)?
                .name { workspaceInfo[NehirFocusNotificationKey.oldWorkspaceName] = name }
        }
        if let newId = currentWorkspaceId {
            workspaceInfo[NehirFocusNotificationKey.newWorkspaceId] = newId
            if let name = controller.workspaceManager.descriptor(for: newId)?
                .name { workspaceInfo[NehirFocusNotificationKey.newWorkspaceName] = name }
        }
        let workspaceChanged = postNotificationIfChanged(
            name: .nehirFocusedWorkspaceChanged,
            current: currentWorkspaceId,
            last: &lastNotifiedWorkspaceId,
            info: workspaceInfo,
            sender: controller
        )

        var monitorInfo: [AnyHashable: Any] = [:]
        if let oldId = lastNotifiedMonitorId {
            monitorInfo[NehirFocusNotificationKey.oldMonitorIndex] = oldId.displayId
            if let name = controller.workspaceManager.monitor(byId: oldId)?
                .name { monitorInfo[NehirFocusNotificationKey.oldMonitorName] = name }
        }
        if let newId = currentMonitorId {
            monitorInfo[NehirFocusNotificationKey.newMonitorIndex] = newId.displayId
            if let name = controller.workspaceManager.monitor(byId: newId)?
                .name { monitorInfo[NehirFocusNotificationKey.newMonitorName] = name }
        }
        let monitorChanged = postNotificationIfChanged(
            name: .nehirFocusedMonitorChanged,
            current: currentMonitorId,
            last: &lastNotifiedMonitorId,
            info: monitorInfo,
            sender: controller
        )

        return ChangeSet(
            focusChanged: focusChanged,
            workspaceChanged: workspaceChanged,
            monitorChanged: monitorChanged
        )
    }

    private func postNotificationIfChanged<T: Equatable>(
        name: Notification.Name,
        current: T?,
        last: inout T?,
        info: [AnyHashable: Any],
        sender: AnyObject
    ) -> Bool {
        guard current != last else { return false }
        NotificationCenter.default.post(
            name: name,
            object: sender,
            userInfo: info.isEmpty ? nil : info
        )
        last = current
        return true
    }
}
