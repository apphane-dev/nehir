import AppKit
import Foundation
@testable import Nehir

private actor AXFrameProviderIsolationForTests {
    static let shared = AXFrameProviderIsolationForTests()

    private var acquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !acquired {
            acquired = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            acquired = false
            return
        }

        waiters.removeFirst().resume()
    }
}

private actor CGSEventObserverIsolationForTests {
    static let shared = CGSEventObserverIsolationForTests()

    private var acquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !acquired {
            acquired = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            acquired = false
            return
        }

        waiters.removeFirst().resume()
    }
}

private actor AppAXContextIsolationForTests {
    static let shared = AppAXContextIsolationForTests()

    private var acquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !acquired {
            acquired = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            acquired = false
            return
        }

        waiters.removeFirst().resume()
    }
}

@MainActor
func withAXFrameProviderIsolationForTests<T>(
    _ operation: @MainActor () async throws -> T
) async rethrows -> T {
    await AXFrameProviderIsolationForTests.shared.acquire()
    do {
        let result = try await operation()
        await AXFrameProviderIsolationForTests.shared.release()
        return result
    } catch {
        await AXFrameProviderIsolationForTests.shared.release()
        throw error
    }
}

@MainActor
func withCGSEventObserverIsolationForTests<T>(
    _ operation: @MainActor () async throws -> T
) async rethrows -> T {
    await CGSEventObserverIsolationForTests.shared.acquire()
    do {
        let result = try await operation()
        await CGSEventObserverIsolationForTests.shared.release()
        return result
    } catch {
        await CGSEventObserverIsolationForTests.shared.release()
        throw error
    }
}

@MainActor
func withAppAXContextIsolationForTests<T>(
    _ operation: @MainActor () async throws -> T
) async rethrows -> T {
    await AppAXContextIsolationForTests.shared.acquire()
    do {
        let result = try await operation()
        await AppAXContextIsolationForTests.shared.release()
        return result
    } catch {
        await AppAXContextIsolationForTests.shared.release()
        throw error
    }
}

private let testConfigurationDirectoryKey = "__nehir.test.configurationDirectory"
private let testRuntimeStateDirectoryKey = "__nehir.test.runtimeStateDirectory"

func configurationDirectoryForTests(defaults: UserDefaults) -> URL {
    if let path = defaults.string(forKey: testConfigurationDirectoryKey) {
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nehir-config-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defaults.set(directory.path, forKey: testConfigurationDirectoryKey)
    return directory
}

func runtimeStateDirectoryForTests(defaults: UserDefaults) -> URL {
    if let path = defaults.string(forKey: testRuntimeStateDirectoryKey) {
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nehir-state-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defaults.set(directory.path, forKey: testRuntimeStateDirectoryKey)
    return directory
}

@MainActor
func runtimeStateStoreForTests(defaults: UserDefaults) -> RuntimeStateStore {
    RuntimeStateStore(
        directory: runtimeStateDirectoryForTests(defaults: defaults),
        deferSaves: false
    )
}

@MainActor
extension SettingsStore {
    convenience init(defaults: UserDefaults) {
        let directory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        self.init(
            persistence: SettingsFilePersistence(
                directory: directory,
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: runtimeStateDirectory,
                deferSaves: false
            )
        )
    }
}

@MainActor
func fallbackFastFrameForTests(_ window: AXWindowRef) -> CGRect? {
    guard let frame = SkyLight.shared.getWindowBounds(UInt32(AXWindowService.windowId(window))) else {
        return nil
    }
    return ScreenCoordinateSpace.toAppKit(rect: frame)
}

@MainActor
func resetSharedControllerStateForTests() {
    SettingsWindowController.shared.windowForTests?.close()
    AppRulesWindowController.shared.windowForTests?.close()
    OwnedWindowRegistry.shared.resetForTests()
    NativeFullscreenPlaceholderManager.materializesWindowsForTests = false

    AppAXContext.contextFactoryForTests = nil
    AppAXContext.onWindowDestroyed = nil
    AppAXContext.onWindowMiniaturized = nil
    AppAXContext.onFocusedWindowChanged = nil

    SkyLight.orderedStateProviderForTests = nil
}
