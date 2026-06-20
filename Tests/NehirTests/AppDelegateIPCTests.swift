// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation
@testable import Nehir
@testable import NehirCtl
import NehirIPC
import Testing

private func makeAppDelegateIPCTestSocketPath() -> String {
    "/tmp/owm-ad-\(UUID().uuidString.prefix(8)).sock"
}

private enum AppDelegateIPCTestError: Error {
    case timedOut
}

private func withAppDelegateIPCTestTimeout<T: Sendable>(
    _ timeout: Duration = .seconds(3),
    onTimeout: @escaping @Sendable () -> Void = {},
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            onTimeout()
            throw AppDelegateIPCTestError.timedOut
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

@MainActor
private final class TestIPCServer: IPCServerLifecycle {
    private let onStart: @MainActor () -> Void
    private let onStop: @MainActor () -> Void

    init(
        onStart: @escaping @MainActor () -> Void = {},
        onStop: @escaping @MainActor () -> Void = {}
    ) {
        self.onStart = onStart
        self.onStop = onStop
    }

    func start() throws {
        onStart()
    }

    func stop() {
        onStop()
    }
}

@MainActor
private func resetAppDelegateTestFactories() {
    AppDelegate.sharedBootstrap = nil
    AppDelegate.ipcServerFactoryForTests = nil
}

@Suite(.serialized) @MainActor struct AppDelegateIPCTests {
    @Test func applicationShouldTerminateApprovesImmediateTermination() {
        let appDelegate = AppDelegate()

        let reply = appDelegate.applicationShouldTerminate(.shared)

        #expect(reply == .terminateNow)
    }

    @Test func applicationWillTerminateStopsWMServices() {
        let bootstrap = AppBootstrapState()
        let controller = makeLayoutPlanTestController()
        let appDelegate = AppDelegate()
        controller.hasStartedServices = true
        bootstrap.controller = controller
        AppDelegate.sharedBootstrap = bootstrap
        defer {
            resetAppDelegateTestFactories()
        }

        appDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        #expect(controller.hasStartedServices == false)
    }

    @Test func setIPCDisabledDoesNotStartServer() throws {
        let controller = makeLayoutPlanTestController()
        let appDelegate = AppDelegate()
        var observedStart = false
        AppDelegate.ipcServerFactoryForTests = { _ in
            TestIPCServer {
                observedStart = true
            }
        }
        defer {
            resetAppDelegateTestFactories()
        }

        try appDelegate.setIPCEnabled(false, controller: controller)

        #expect(observedStart == false)
    }

    @Test func setIPCEnabledStartsAndStopsInjectedServer() throws {
        let controller = makeLayoutPlanTestController()
        let appDelegate = AppDelegate()
        var observedStart = false
        var observedStop = false
        AppDelegate.ipcServerFactoryForTests = { _ in
            TestIPCServer(
                onStart: {
                    observedStart = true
                },
                onStop: {
                    observedStop = true
                }
            )
        }
        defer {
            resetAppDelegateTestFactories()
        }

        try appDelegate.setIPCEnabled(true, controller: controller)
        try appDelegate.setIPCEnabled(false, controller: controller)

        #expect(observedStart)
        #expect(observedStop)
    }

    @Test func startIPCServerMakesSocketReachableAndTerminateUnlinksSocket() async throws {
        let socketPath = makeAppDelegateIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let appDelegate = AppDelegate()
        var didTerminate = false
        AppDelegate.ipcServerFactoryForTests = { controller in
            return IPCServer(
                controller: controller,
                socketPath: socketPath,
                sessionToken: "app-delegate-ipc-tests",
                authorizationToken: "app-delegate-ipc-tests"
            )
        }
        defer {
            if !didTerminate {
                appDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            }
            resetAppDelegateTestFactories()
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: IPCSocketPath.secretPath(forSocketPath: socketPath))
        }

        #expect(!FileManager.default.fileExists(atPath: socketPath))

        try appDelegate.startIPCServer(controller: controller)

        #expect(FileManager.default.fileExists(atPath: socketPath))

        let client = IPCClient(socketPath: socketPath, authorizationToken: "app-delegate-ipc-tests")
        let connection = try client.openConnection()
        defer {
            connection.interrupt()
        }

        try await connection.send(IPCRequest(id: "ping-after-bootstrap", kind: .ping))
        let response = try await withAppDelegateIPCTestTimeout(
            onTimeout: {
                connection.interrupt()
            },
            operation: {
                try await connection.readResponse()
            }
        )

        #expect(response.ok)
        #expect(response.kind == .ping)
        #expect(response.result?.kind == .pong)

        await connection.close()
        appDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        didTerminate = true

        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }
}
