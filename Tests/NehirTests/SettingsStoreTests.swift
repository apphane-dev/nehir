import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import Foundation
@testable import Nehir
import Testing

private func makeTestDefaults() -> UserDefaults {
    let suiteName = "dev.guria.nehir.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

struct NehirStoragePathsTests {
    @Test func defaultsUseXDGFallbacksUnderHome() {
        let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = NehirStoragePaths.resolve(environment: [:], homeDirectory: homeDirectory)

        #expect(paths.configDirectory.path == "/Users/example/.config/nehir")
        #expect(paths.stateDirectory.path == "/Users/example/.local/state/nehir")
    }

    @Test func absoluteEnvironmentOverridesWin() {
        let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = NehirStoragePaths.resolve(
            environment: [
                "XDG_CONFIG_HOME": "/Volumes/Profile/config",
                "XDG_STATE_HOME": "/Volumes/Profile/state"
            ],
            homeDirectory: homeDirectory
        )

        #expect(paths.configDirectory.path == "/Volumes/Profile/config/nehir")
        #expect(paths.stateDirectory.path == "/Volumes/Profile/state/nehir")
    }

    @Test func emptyAndRelativeEnvironmentValuesFallBack() {
        let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = NehirStoragePaths.resolve(
            environment: [
                "XDG_CONFIG_HOME": "",
                "XDG_STATE_HOME": "relative/state"
            ],
            homeDirectory: homeDirectory
        )

        #expect(paths.configDirectory.path == "/Users/example/.config/nehir")
        #expect(paths.stateDirectory.path == "/Users/example/.local/state/nehir")
    }
}


private func makeSettingsTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat = 0,
    y: CGFloat = 0,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

private func makePersistedRestoreCatalogFixture(
    workspaceName: String = "1",
    monitor: Monitor = makeSettingsTestMonitor(displayId: 77, name: "Studio Display")
) -> PersistedWindowRestoreCatalog {
    let metadata = ManagedReplacementMetadata(
        bundleId: "com.example.editor",
        workspaceId: UUID(),
        mode: .floating,
        role: "AXWindow",
        subrole: "AXStandardWindow",
        title: "Sprint Notes",
        windowLevel: 0,
        parentWindowId: nil,
        frame: nil
    )
    let key = PersistedWindowRestoreKey(metadata: metadata)!
    return PersistedWindowRestoreCatalog(
        entries: [
            PersistedWindowRestoreEntry(
                key: key,
                identity: nil,
                restoreIntent: PersistedRestoreIntent(
                    workspaceName: workspaceName,
                    topologyProfile: TopologyProfile(monitors: [monitor]),
                    preferredMonitor: DisplayFingerprint(monitor: monitor),
                    floatingFrame: CGRect(x: 120, y: 140, width: 900, height: 600),
                    normalizedFloatingOrigin: CGPoint(x: 0.25, y: 0.35),
                    restoreToFloating: true,
                    rescueEligible: true
                )
            )
        ]
    )
}

private func writeSettingsExport(
    _ export: SettingsExport,
    to url: URL
) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try SettingsTOMLCodec.encode(export).write(to: url, options: .atomic)
}

private func writeSettingsExportInPlace(
    _ export: SettingsExport,
    to url: URL
) throws {
    let data = try SettingsTOMLCodec.encode(export)
    let handle = try FileHandle(forWritingTo: url)
    defer {
        try? handle.close()
    }

    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
}

private func atomicallyReplaceSettingsDataForTests(
    _ data: Data,
    at url: URL,
    preservingModificationDate modificationDate: Date
) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let tempURL = directory.appendingPathComponent(".settings.toml.\(UUID().uuidString).tmp", isDirectory: false)
    try data.write(to: tempURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: tempURL.path)

    let result = tempURL.withUnsafeFileSystemRepresentation { sourcePath -> CInt in
        guard let sourcePath else { return -1 }
        return url.withUnsafeFileSystemRepresentation { destinationPath -> CInt in
            guard let destinationPath else { return -1 }
            return Darwin.rename(sourcePath, destinationPath)
        }
    }

    if result != 0 {
        try? FileManager.default.removeItem(at: tempURL)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private struct SettingsFileSnapshot: Equatable {
    let deviceID: UInt64
    let inode: UInt64
    let modificationTimeNanoseconds: Int64
    let statusChangeTimeNanoseconds: Int64
    let fileSize: UInt64
    let contents: Data
}

private func settingsFileSnapshot(_ url: URL) throws -> SettingsFileSnapshot {
    var statBuffer = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> CInt in
        guard let path else { return -1 }
        return Darwin.fstatat(AT_FDCWD, path, &statBuffer, 0)
    }
    guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    return SettingsFileSnapshot(
        deviceID: UInt64(statBuffer.st_dev),
        inode: UInt64(statBuffer.st_ino),
        modificationTimeNanoseconds: Int64(statBuffer.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(statBuffer.st_mtimespec.tv_nsec),
        statusChangeTimeNanoseconds: Int64(statBuffer.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(statBuffer.st_ctimespec.tv_nsec),
        fileSize: UInt64(statBuffer.st_size),
        contents: try Data(contentsOf: url)
    )
}

struct MonitorSettingsStoreTests {
    @Test func getReturnsNilForUnknownMonitor() {
        let settings = [MonitorNiriSettings(monitorName: "Monitor A")]
        let result = MonitorSettingsStore.get(for: "Monitor B", in: settings)
        #expect(result == nil)
    }

    @Test func updateReplacesExistingAtSameIndex() {
        var settings = [
            MonitorNiriSettings(monitorName: "A", balancedColumnCount: 2),
            MonitorNiriSettings(monitorName: "B", balancedColumnCount: 3)
        ]
        let updated = MonitorNiriSettings(monitorName: "A", balancedColumnCount: 5)
        MonitorSettingsStore.update(updated, in: &settings)
        #expect(settings.count == 2)
        #expect(settings[0].monitorName == "A")
        #expect(settings[0].balancedColumnCount == 5)
        #expect(settings[1].monitorName == "B")
    }

    @Test func updateAppendsWhenNotFound() {
        var settings = [MonitorNiriSettings(monitorName: "A")]
        let newItem = MonitorNiriSettings(monitorName: "B", balancedColumnCount: 4)
        MonitorSettingsStore.update(newItem, in: &settings)
        #expect(settings.count == 2)
        #expect(settings[1].monitorName == "B")
        #expect(settings[1].balancedColumnCount == 4)
    }

    @Test func removeDeletesAllMatches() {
        var settings = [
            MonitorNiriSettings(monitorName: "A"),
            MonitorNiriSettings(monitorName: "A"),
            MonitorNiriSettings(monitorName: "B")
        ]
        MonitorSettingsStore.remove(for: "A", from: &settings)
        #expect(settings.count == 1)
        #expect(settings[0].monitorName == "B")
    }

    @Test func monitorLookupPrefersDisplayIdOverNameFallback() {
        let monitor = makeSettingsTestMonitor(displayId: 42, name: "Studio Display")
        let settings = [
            MonitorNiriSettings(monitorName: "Studio Display", balancedColumnCount: 1),
            MonitorNiriSettings(monitorName: "Studio Display", monitorDisplayId: 42, balancedColumnCount: 3)
        ]

        let result = MonitorSettingsStore.get(for: monitor, in: settings)
        #expect(result?.balancedColumnCount == 3)
    }

    @Test func monitorLookupFallsBackToNameWhenDisplayIdMissing() {
        let monitor = makeSettingsTestMonitor(displayId: 99, name: "Fallback")
        let settings = [
            MonitorNiriSettings(monitorName: "Fallback", balancedColumnCount: 2)
        ]

        let result = MonitorSettingsStore.get(for: monitor, in: settings)
        #expect(result?.balancedColumnCount == 2)
    }

    @Test func updateMigratesNameEntryToDisplayIdEntry() {
        var settings = [
            MonitorNiriSettings(monitorName: "Studio Display", balancedColumnCount: 1)
        ]

        let updated = MonitorNiriSettings(
            monitorName: "Studio Display",
            monitorDisplayId: 77,
            balancedColumnCount: 4
        )
        MonitorSettingsStore.update(updated, in: &settings)

        #expect(settings.count == 1)
        #expect(settings[0].monitorDisplayId == 77)
        #expect(settings[0].balancedColumnCount == 4)
    }
}

@MainActor struct PersistedWindowRestoreCatalogSettingsTests {
    @Test func persistedRestoreCatalogRoundTripsThroughRuntimeStateStore() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let catalog = makePersistedRestoreCatalogFixture()

        settings.savePersistedWindowRestoreCatalog(catalog)

        #expect(settings.loadPersistedWindowRestoreCatalog() == catalog)

        settings.flushNow()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        let fresh = RuntimeStateStore(directory: runtimeStateDirectory)

        #expect(fresh.windowRestoreCatalog == catalog)
        #expect(
            FileManager.default.fileExists(
                atPath: configurationDirectory.appendingPathComponent(RuntimeStateStore.fileName).path
            ) == false
        )
    }

    @Test func persistedRestoreCatalogIsExcludedFromCanonicalSettingsFile() throws {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.hotkeysEnabled = false
        settings.savePersistedWindowRestoreCatalog(makePersistedRestoreCatalogFixture())
        settings.flushNow()

        let rawData = try Data(contentsOf: settings.settingsFileURL)
        let rawText = try #require(String(data: rawData, encoding: .utf8))
        let decoded = try SettingsTOMLCodec.decode(rawData)
        #expect(decoded.hotkeysEnabled == false)
        #expect(rawText.localizedCaseInsensitiveContains("restoreCatalog") == false)
    }

}

struct SettingsExportTests {
    @Test func defaultsReflectPromotedBuiltInValues() {
        let defaults = SettingsExport.defaults()

        #expect(defaults.mouseWarpAxis == MouseWarpAxis.horizontal.rawValue)
        #expect(defaults.mouseWarpMargin == 1)
        #expect(defaults.niriColumnWidthPresets == BuiltInSettingsDefaults.niriColumnWidthPresets)
        #expect(defaults.gapSize == 16)
        #expect(defaults.outerGapLeft == 0)
        #expect(defaults.outerGapRight == 0)
        #expect(defaults.outerGapTop == 0)
        #expect(defaults.outerGapBottom == 0)
        #expect(defaults.revealPartial == RevealPartial.default.rawValue)
        #expect(defaults.niriLoneWindowMaxWidth == nil)
        #expect(defaults.niriDefaultColumnWidth == nil)
        #expect(defaults.workspaceConfigurations == BuiltInSettingsDefaults.workspaceConfigurations)
        #expect(defaults.bordersEnabled == true)
        #expect(defaults.borderWidth == 5.0)
        #expect(defaults.borderColorRed == 0.084585202284378935)
        #expect(defaults.borderColorGreen == 1.0)
        #expect(defaults.borderColorBlue == 0.97930003794467602)
        #expect(defaults.hotkeyBindings == HotkeyBindingRegistry.defaults())
        #expect(defaults.workspaceBarEnabled == true)
        #expect(defaults.workspaceBarShowFloatingWindows == false)
        #expect(defaults.workspaceBarNotchAware == true)
        #expect(defaults.workspaceBarReserveLayoutSpace == false)
        #expect(defaults.appRules == BuiltInSettingsDefaults.appRules)
        #expect(defaults.preventSleepEnabled == false)
        #expect(defaults.ipcEnabled == false)
        #expect(defaults.scrollSensitivity == 5.0)
        #expect(defaults.mouseResizeModifierKey == MouseResizeModifierKey.option.rawValue)
        #expect(defaults.statusBarShowWorkspaceName == false)
        #expect(defaults.statusBarShowAppNames == false)
        #expect(defaults.statusBarUseWorkspaceId == false)
        #expect(defaults.appearanceMode == AppearanceMode.dark.rawValue)
    }
}

@MainActor struct NiriColumnWidthPresetPersistenceTests {
    @Test func validatedPresetsPreserveOrderAndDuplicatesWhileClamping() {
        let presets = SettingsStore.validatedPresets([0.85, 0.02, 0.85, 1.2])

        #expect(presets == [0.85, 0.05, 0.85, 1.0])
    }

    @Test func validatedPresetsFallbackToDefaultsWhenTooShort() {
        let presets = SettingsStore.validatedPresets([0.85])

        #expect(presets == SettingsStore.defaultColumnWidthPresets)
    }

    @Test func settingsStoreRoundTripsOrderedDuplicatePresets() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.niriColumnWidthPresets = [0.85, 0.5, 0.85, 1.0]

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.niriColumnWidthPresets == [0.85, 0.5, 0.85, 1.0])
    }

    @Test func validatedDefaultColumnWidthClampsAndSupportsAuto() {
        #expect(SettingsStore.validatedDefaultColumnWidth(nil) == nil)
        #expect(SettingsStore.validatedDefaultColumnWidth(0.02) == 0.05)
        #expect(SettingsStore.validatedDefaultColumnWidth(1.2) == 1.0)
    }

    @Test func settingsStoreRoundTripsOptionalDefaultColumnWidth() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.niriDefaultColumnWidth = 0.85
        let reloadedCustom = SettingsStore(defaults: defaults)
        #expect(reloadedCustom.niriDefaultColumnWidth == 0.85)

        settings.niriDefaultColumnWidth = nil
        let reloadedAuto = SettingsStore(defaults: defaults)
        #expect(reloadedAuto.niriDefaultColumnWidth == nil)
    }
}

@MainActor struct WorkspaceBarSettingsResolutionTests {
    @Test func monitorOverrideCanEnableReservedLayoutSpaceIndependently() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let monitor = makeLayoutPlanTestMonitor(name: "Reservation Test")

        settings.workspaceBarReserveLayoutSpace = false
        settings.updateBarSettings(
            MonitorBarSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                reserveLayoutSpace: true
            )
        )

        #expect(settings.resolvedBarSettings(for: monitor).reserveLayoutSpace == true)
    }

    @Test func monitorOverrideCanEnableFloatingWindowsIndependently() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let monitor = makeLayoutPlanTestMonitor(name: "Floating Test")

        settings.workspaceBarShowFloatingWindows = false
        settings.updateBarSettings(
            MonitorBarSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                showFloatingWindows: true
            )
        )

        #expect(settings.resolvedBarSettings(for: monitor).showFloatingWindows == true)
    }

    @Test func workspaceBarThemeColorsRoundTripThroughExportAndResolution() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let monitor = makeLayoutPlanTestMonitor(name: "Theme Test")
        let accent = SettingsColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let text = SettingsColor(red: 0.9, green: 0.8, blue: 0.7, alpha: 1)

        settings.workspaceBarAccentColor = accent
        settings.workspaceBarTextColor = text

        let export = settings.toExport()
        #expect(export.workspaceBarAccentColor == accent)
        #expect(export.workspaceBarTextColor == text)

        let reloaded = SettingsStore(defaults: makeTestDefaults())
        reloaded.applyExport(export, monitors: [monitor])

        #expect(reloaded.workspaceBarAccentColor == accent)
        #expect(reloaded.workspaceBarTextColor == text)
        #expect(reloaded.resolvedBarSettings(for: monitor).accentColor == accent)
        #expect(reloaded.resolvedBarSettings(for: monitor).textColor == text)
    }

    @Test func workspaceBarThemeColorDefaultsUseSystemFallbacks() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let monitor = makeLayoutPlanTestMonitor(name: "Default Theme Test")
        let resolved = settings.resolvedBarSettings(for: monitor)

        #expect(settings.workspaceBarAccentColor == nil)
        #expect(settings.workspaceBarTextColor == nil)
        #expect(resolved.accentColor == nil)
        #expect(resolved.textColor == nil)
    }
}

struct KeyBindingCodecTests {
    @Test func humanReadableBindingsRoundTripAsStrings() throws {
        let binding = KeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey) | UInt32(optionKey)
        )

        let output = try encodeSingleHotkeyBinding(binding)

        #expect(output.contains("commandPalette = \"Control+Option+K\""))
    }

    @Test func keypadBindingsUseReadableStringsAndDistinctCompactBadges() throws {
        let binding = KeyBinding(
            keyCode: UInt32(kVK_ANSI_Keypad1),
            modifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        )

        let output = try encodeSingleHotkeyBinding(binding)

        #expect(binding.displayString == "⌃⌥⌘KP1")
        #expect(binding.humanReadableString == "Control+Option+Command+Keypad 1")
        #expect(output.contains("commandPalette = \"Control+Option+Command+Keypad 1\""))
    }

    @Test func keypadActionKeysUseCanonicalReadableNames() {
        let binding = KeyBinding(
            keyCode: UInt32(kVK_ANSI_KeypadEnter),
            modifiers: UInt32(cmdKey)
        )

        #expect(binding.displayString == "⌘KPEnter")
        #expect(binding.humanReadableString == "Command+Keypad Enter")
        #expect(KeySymbolMapper.fromHumanReadable("Command+Keypad Enter") == binding)
    }

    @Test func unknownKeyCodesFallBackToNumericEncoding() throws {
        let binding = KeyBinding(keyCode: 200, modifiers: UInt32(controlKey))

        let output = try encodeSingleHotkeyBinding(binding)

        #expect(output.contains("commandPalette = \"Control+KeyCode 200\""))
    }

    @Test func keypadDigitsRemainDistinctFromTopRowDigits() {
        let modifiers = UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        let topRow = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: modifiers)
        let keypad = KeyBinding(keyCode: UInt32(kVK_ANSI_Keypad1), modifiers: modifiers)

        #expect(topRow != keypad)
        #expect(topRow.displayString == "⌃⌥⌘1")
        #expect(keypad.displayString == "⌃⌥⌘KP1")
        #expect(topRow.humanReadableString == "Control+Option+Command+1")
        #expect(keypad.humanReadableString == "Control+Option+Command+Keypad 1")
    }


    @Test func literalAllModifiersUseHyperAlias() {
        let literal = KeyBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: KeySymbolMapper.realHyperModifiers
        )

        #expect(literal.displayString == "Hyper+Space")
        #expect(literal.humanReadableString == "Hyper+Space")
        #expect(KeySymbolMapper.fromHumanReadable("Hyper+Space") == literal)
    }

    @Test func compactPunctuationBindingsStillDecode() throws {
        #expect(KeySymbolMapper.fromHumanReadable("Option+,") == KeyBinding(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(optionKey)))
        #expect(KeySymbolMapper.fromHumanReadable("Option+.") == KeyBinding(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(optionKey)))
        #expect(KeySymbolMapper.fromHumanReadable("Option+-") == KeyBinding(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey)))
        #expect(KeySymbolMapper.fromHumanReadable("Option+=") == KeyBinding(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(optionKey)))
        #expect(KeySymbolMapper.fromHumanReadable("Option+`") == KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey)))
        #expect(HotkeyTrigger.fromHumanReadable("Option+,") == .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(optionKey))))
    }

    @Test func defaultHotkeysCaptureCurrentConfigShape() throws {
        let output = try #require(String(
            data: HotkeysTOMLCodec.encode(HotkeyBindingRegistry.defaults()),
            encoding: .utf8
        ))

        #expect(output.contains("next = \"Control+Option+Command+Right Arrow\""))
        #expect(output.contains("previous = \"Control+Option+Command+Left Arrow\""))
        #expect(output.contains("windowToWorkspaceUp = \"Hyper+Up Arrow\""))
        #expect(output.contains("windowToWorkspaceDown = \"Hyper+Down Arrow\""))
        #expect(output.contains("columnToWorkspaceUp = \"Unassigned\""))
        #expect(output.contains("columnToWorkspaceDown = \"Unassigned\""))
        #expect(output.contains("columnLeft = \"Hyper+Left Arrow\""))
        #expect(output.contains("columnRight = \"Hyper+Right Arrow\""))
        #expect(output.contains("toggleNativeFullscreen = \"Option+Shift+Command+Return\""))
        #expect(output.contains("toggleColumnTabbed = \"Option+Shift+Command+T\""))
        #expect(output.contains("commandPalette = \"Option+Command+Space\""))
        #expect(output.contains("menuAnywhere = \"Option+Command+M\""))
        #expect(output.contains("toggleOverview = \"Option+Command+O\""))
    }

    private func encodeSingleHotkeyBinding(
        _ binding: KeyBinding,
        id: String = "openCommandPalette"
    ) throws -> String {
        let defaults = HotkeyBindingRegistry.defaults()
        let hotkey = try #require(HotkeyBindingRegistry.makeBinding(id: id, binding: binding))
        let bindings = defaults.map { $0.id == hotkey.id ? hotkey : $0 }

        let data = HotkeysTOMLCodec.encode(bindings)

        return try #require(String(data: data, encoding: .utf8))
    }
}

struct HotkeySurfaceTests {
    @Test func moveIsTheOnlyDirectionalWindowCommandFamily() {
        let ids = Set(HotkeyBindingRegistry.defaults().map(\.id))

        #expect(ids.contains("move.left"))
        #expect(ids.contains("move.right"))
        #expect(ids.contains("move.up"))
        #expect(ids.contains("move.down"))
        #expect(!ids.contains("swap.left"))
        #expect(!ids.contains("consumeWindow.left"))
        #expect(!ids.contains("expelWindow.left"))
        #expect(ids.contains("openCommandPalette"))
        #expect(!ids.contains("openWindowFinder"))
        #expect(!ids.contains("openMenuPalette"))
    }

    @Test func removedDirectionalMonitorBindingsAreAbsent() {
        let ids = Set(HotkeyBindingRegistry.defaults().map(\.id))

        #expect(!ids.contains("moveToMonitor.left"))
        #expect(!ids.contains("moveToMonitor.right"))
        #expect(!ids.contains("moveToMonitor.up"))
        #expect(!ids.contains("moveToMonitor.down"))
        #expect(!ids.contains("focusMonitor.left"))
        #expect(!ids.contains("focusMonitor.right"))
        #expect(!ids.contains("focusMonitor.up"))
        #expect(!ids.contains("focusMonitor.down"))
        #expect(!ids.contains("moveColumnToMonitor.left"))
        #expect(!ids.contains("moveColumnToMonitor.right"))
        #expect(!ids.contains("moveColumnToMonitor.up"))
        #expect(!ids.contains("moveColumnToMonitor.down"))
        #expect(!ids.contains("moveWorkspaceToMonitor.left"))
        #expect(!ids.contains("moveWorkspaceToMonitor.right"))
        #expect(!ids.contains("moveWorkspaceToMonitor.up"))
        #expect(!ids.contains("moveWorkspaceToMonitor.down"))
        #expect(!ids.contains("moveWorkspaceToMonitor.next"))
        #expect(!ids.contains("moveWorkspaceToMonitor.previous"))
        #expect(ids.contains("focusWindowTop"))
        #expect(ids.contains("focusWindowBottom"))
        #expect(!ids.contains("summonWorkspace.0"))
        #expect(!ids.contains("summonWorkspace.1"))
        #expect(!ids.contains("summonWorkspace.2"))
        #expect(!ids.contains("summonWorkspace.3"))
        #expect(!ids.contains("summonWorkspace.4"))
        #expect(!ids.contains("summonWorkspace.5"))
        #expect(!ids.contains("summonWorkspace.6"))
        #expect(!ids.contains("summonWorkspace.7"))
        #expect(!ids.contains("summonWorkspace.8"))
        #expect(ids.contains("focusMonitorNext"))
        #expect(ids.contains("focusMonitorLast"))
    }

    @Test func hotkeyBindingEncodesWithoutSerializedCommand() throws {
        let defaults = HotkeyBindingRegistry.defaults()
        let binding = HotkeyBinding(id: "move.left", command: .move(.left), binding: .unassigned)
        let bindings = defaults.map { $0.id == binding.id ? binding : $0 }
        let output = try #require(String(data: HotkeysTOMLCodec.encode(bindings), encoding: .utf8))
        let decoded = HotkeysTOMLCodec.decode(Data(output.utf8), defaults: defaults)

        #expect(output.contains("left = \"Unassigned\""))
        #expect(output.contains("command = ") == false)
        #expect(decoded.first(where: { $0.id == binding.id }) == binding)
    }
}

@MainActor struct CommandPaletteSettingsTests {
    @Test func commandPaletteLastModePersistsThroughRuntimeStateWithoutRewritingSettingsFile() throws {
        let defaults = makeTestDefaults()

        let settings = SettingsStore(defaults: defaults)
        let beforeSettings = try settingsFileSnapshot(settings.settingsFileURL)
        #expect(settings.commandPaletteLastMode == RuntimeStateStore.defaultCommandPaletteLastMode)

        settings.commandPaletteLastMode = .menu
        settings.flushNow()

        let afterSettings = try settingsFileSnapshot(settings.settingsFileURL)
        let runtimeState = RuntimeStateStore(directory: runtimeStateDirectoryForTests(defaults: defaults))
        #expect(afterSettings == beforeSettings)
        #expect(runtimeState.commandPaletteLastMode == .menu)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.commandPaletteLastMode == .menu)
    }

    @Test func menuStatusHelpersDoNotMentionSettings() {
        #expect(CommandPaletteController.menuModeAvailable(hasMenuFocusTarget: true) == true)
        #expect(CommandPaletteController.menuModeAvailable(hasMenuFocusTarget: false) == false)
        #expect(CommandPaletteController.availableMenuStatusText(for: "Safari") == "Searching menus in Safari")
        #expect(CommandPaletteController.availableMenuStatusText(for: nil) == "Searching menus in Current App")
        #expect(CommandPaletteController
            .unavailableMenuStatusText == "Open the palette while another app is frontmost to search its menus.")
    }
}

@MainActor struct SettingsStoreFileRoundTripTests {
    @Test func tomlSettingsFileRoundTripsNewlyCoveredPersistedState() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.focusFollowsWindowToMonitor = true
        settings.mouseWarpAxis = .vertical
        settings.mouseResizeModifierKey = .controlCommandShift
        settings.statusBarShowWorkspaceName = true
        settings.statusBarShowAppNames = true
        settings.statusBarUseWorkspaceId = true
        settings.scrollGestureEnabled = true
        settings.scrollSensitivity = 33
        settings.flushNow()

        let reloaded = SettingsStore(defaults: defaults)

        #expect(reloaded.focusFollowsWindowToMonitor == true)
        #expect(reloaded.mouseWarpAxis == .vertical)
        #expect(reloaded.mouseResizeModifierKey == .controlCommandShift)
        #expect(reloaded.statusBarShowWorkspaceName == true)
        #expect(reloaded.statusBarShowAppNames == true)
        #expect(reloaded.statusBarUseWorkspaceId == true)
        #expect(reloaded.scrollGestureEnabled == true)
        #expect(reloaded.scrollSensitivity == 33)
    }

    @Test func tomlApplyClearsStaleMonitorDisplayIdWhenNameCannotBeResolved() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let currentMonitor = makeSettingsTestMonitor(displayId: 202, name: "Studio Display")
        var export = SettingsExport.defaults()
        export.monitorBarSettings = [
            MonitorBarSettings(monitorName: "Disconnected Display", monitorDisplayId: 101, enabled: false)
        ]

        settings.applyExport(export, monitors: [currentMonitor])

        #expect(settings.monitorBarSettings.first?.monitorDisplayId == nil)
        #expect(settings.barSettings(for: currentMonitor) == nil)
    }

}

@Suite(.serialized) @MainActor struct SettingsStoreAppearanceApplyTests {
    @Test func persistedSettingsApplyingToControllerUsesSharedAppearancePath() {
        let originalAppearanceApplier = AppearanceModeApplier.apply
        var appliedAppearance: NSAppearance?
        defer { AppearanceModeApplier.apply = originalAppearanceApplier }

        let controller = makeLayoutPlanTestController()
        defer { controller.setEnabled(false) }
        controller.settings.hotkeysEnabled = false
        controller.settings.workspaceBarEnabled = false
        controller.settings.appearanceMode = .light

        AppearanceModeApplier.apply = { mode in
            switch mode {
            case .automatic:
                appliedAppearance = nil
            case .light:
                appliedAppearance = NSAppearance(named: .aqua)
            case .dark:
                appliedAppearance = NSAppearance(named: .darkAqua)
            }
        }

        controller.applyPersistedSettings(controller.settings)

        #expect(controller.settings.appearanceMode == .light)
        #expect(appliedAppearance?.name == .aqua)
    }
}

@MainActor struct SettingsStoreHotkeyPreflightTests {
    @Test func defaultHotkeysDoNotRequireEventTap() {
        let settings = SettingsStore(defaults: makeTestDefaults())

        #expect(settings.hotkeyBindings.allSatisfy { binding in
            binding.binding.isUnassigned || binding.binding.chordBinding != nil
        })
    }

}

struct SettingsSectionTests {
}

@MainActor struct RuntimeStateStoreTests {
    @Test func runtimeStateRoundTripsWindowRestoreCatalog() {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let catalog = makePersistedRestoreCatalogFixture()
        let store = RuntimeStateStore(directory: directory)
        store.windowRestoreCatalog = catalog
        store.flushNow()

        let reloaded = RuntimeStateStore(directory: directory)
        let state = reloaded.load()

        #expect(state.windowRestoreCatalog == catalog)
    }


    @Test func commandPaletteLastModeRoundTripsThroughRuntimeStateStore() {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let store = RuntimeStateStore(directory: directory)

        #expect(store.commandPaletteLastMode == RuntimeStateStore.defaultCommandPaletteLastMode)

        store.commandPaletteLastMode = .menu
        store.flushNow()

        let reloaded = RuntimeStateStore(directory: directory)
        #expect(reloaded.commandPaletteLastMode == .menu)
    }



    @Test func runtimeStatePersistsWithPrivatePermissions() throws {
        let defaults = makeTestDefaults()
        let directory = runtimeStateDirectoryForTests(defaults: defaults)
        let store = RuntimeStateStore(directory: directory, deferSaves: false)

        // Trigger a write so the file is materialized on disk
        store.save(store.load())

        let fileURL = directory.appendingPathComponent(RuntimeStateStore.fileName, isDirectory: false)
        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        ).intValue
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        ).intValue

        #expect(directoryMode & 0o777 == 0o700)
        #expect(fileMode & 0o777 == 0o600)
    }
}



@MainActor struct SettingsFilePersistenceTests {
    @Test func missingFileMaterializesDefaults() {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)

        let export = persistence.load()

        #expect(export == SettingsExport.defaults())
        #expect(FileManager.default.fileExists(atPath: persistence.fileURL.path))
    }

    @Test func sameExportSaveDoesNotRewriteExistingSettingsFile() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        let export = persistence.load()
        let before = try settingsFileSnapshot(persistence.fileURL)

        try persistence.saveImmediately(export)

        let after = try settingsFileSnapshot(persistence.fileURL)
        #expect(after == before)
    }

    @Test func sameExportSaveRecreatesDeletedSettingsFile() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        let export = persistence.load()
        try FileManager.default.removeItem(at: persistence.fileURL)

        try persistence.saveImmediately(export)

        #expect(FileManager.default.fileExists(atPath: persistence.fileURL.path))
    }

    @Test func sameExportSaveOverwritesUnseenExternalReplacement() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        let export = persistence.load()
        var externalExport = export
        externalExport.gapSize = 31
        try writeSettingsExport(externalExport, to: persistence.fileURL)

        try persistence.saveImmediately(export)

        let decoded = try SettingsTOMLCodec.decode(Data(contentsOf: persistence.fileURL))
        #expect(decoded == export)
    }

    @Test func changedExportStillRewritesSettingsFile() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        var export = persistence.load()
        let before = try settingsFileSnapshot(persistence.fileURL)
        export.gapSize = 23

        try persistence.saveImmediately(export)

        let after = try settingsFileSnapshot(persistence.fileURL)
        let decoded = try SettingsTOMLCodec.decode(after.contents)
        #expect(after != before)
        #expect(decoded.gapSize == 23)
    }

    @Test func corruptFileIsRenamedAsideAndReplacedWithDefaults() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let url = directory.appendingPathComponent("settings.toml", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("this is =!==== not valid toml".utf8).write(to: url)

        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        let export = persistence.load()
        let corruptURL = directory.appendingPathComponent("settings.toml.corrupt", isDirectory: false)

        #expect(export == SettingsExport.defaults())
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
    }
}

@Suite(.serialized) @MainActor struct SettingsFileWatcherTests {
    @Test func externalEditsReloadLiveSettings() async throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        var export = settings.toExport()
        export.focusFollowsWindowToMonitor = true
        try writeSettingsExport(export, to: settings.settingsFileURL)

        let reloaded = await waitForConditionForTests(
            timeoutNanoseconds: 20_000_000_000
        ) {
            reloadCount == 1 && settings.focusFollowsWindowToMonitor == true
        }

        #expect(reloaded)
    }

    @Test func externalInPlaceTruncateAndWriteReloadsLiveSettings() async throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        var export = settings.toExport()
        export.focusFollowsWindowToMonitor = true
        try writeSettingsExportInPlace(export, to: settings.settingsFileURL)

        let reloaded = await waitForConditionForTests(
            timeoutNanoseconds: 20_000_000_000
        ) {
            reloadCount == 1 && settings.focusFollowsWindowToMonitor == true
        }

        #expect(reloaded)
    }

    @Test func externalAtomicReplacementReloadsWhenSizeAndModificationDateMatchLastWrite() async throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        let originalData = try Data(contentsOf: settings.settingsFileURL)
        let originalModificationDate = try #require(settings.settingsFileURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        let export = try SettingsTOMLCodec.decode(originalData)
        let sameDigitGapCandidates = Array(10 ... 99).map(Double.init) + Array(0 ... 9).map(Double.init)
        var replacementExport: SettingsExport?
        var replacementData: Data?
        for gapSize in sameDigitGapCandidates where gapSize != export.gapSize {
            var candidate = export
            candidate.gapSize = gapSize
            let candidateData = try SettingsTOMLCodec.encode(candidate)
            guard candidateData.count == originalData.count else { continue }
            replacementExport = candidate
            replacementData = candidateData
            break
        }
        let unwrappedReplacementExport = try #require(replacementExport)
        let unwrappedReplacementData = try #require(replacementData)

        try atomicallyReplaceSettingsDataForTests(
            unwrappedReplacementData,
            at: settings.settingsFileURL,
            preservingModificationDate: originalModificationDate
        )

        let reloaded = await waitForConditionForTests(
            timeoutNanoseconds: 20_000_000_000
        ) {
            reloadCount == 1 && settings.gapSize == unwrappedReplacementExport.gapSize
        }

        #expect(reloaded)
    }

    @Test func atomicReplacementRearmsWatcherForLaterInPlaceEdits() async throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        var replacementExport = settings.toExport()
        replacementExport.gapSize = 7
        try writeSettingsExport(replacementExport, to: settings.settingsFileURL)

        let replaced = await waitForConditionForTests(
            timeoutNanoseconds: 20_000_000_000
        ) {
            reloadCount == 1 && settings.gapSize == replacementExport.gapSize
        }
        #expect(replaced)

        var inPlaceExport = settings.toExport()
        inPlaceExport.focusFollowsWindowToMonitor = true
        try writeSettingsExportInPlace(inPlaceExport, to: settings.settingsFileURL)

        let inPlaceReloaded = await waitForConditionForTests(
            timeoutNanoseconds: 20_000_000_000
        ) {
            reloadCount == 2 && settings.focusFollowsWindowToMonitor == true
        }

        #expect(inPlaceReloaded)
    }

    @Test func invalidExternalEditLeavesCurrentSettingsUnchanged() async throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        let invalidPayload = "this is =!==== not valid toml"
        try Data(invalidPayload.utf8).write(to: settings.settingsFileURL, options: .atomic)
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(settings.focusFollowsWindowToMonitor == SettingsExport.defaults().focusFollowsWindowToMonitor)
        #expect(reloadCount == 0)
        let rawData = try Data(contentsOf: settings.settingsFileURL)
        #expect(String(data: rawData, encoding: .utf8) == invalidPayload)
    }

    @Test func selfWriteThroughSettingsStoreDoesNotFireExternalReload() async {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        // Self-write through the @Observable property's didSet { scheduleSave() } path.
        // scheduleSave -> Task.yield -> persistence.flushNow -> save() ->
        // refreshSettingsFileWatcher updates lastWrittenFingerprint. The subsequent
        // DispatchSource event fires, but the handler at SettingsFilePersistence.swift:211
        // short-circuits because observedFingerprint == lastWrittenFingerprint, so
        // onExternalSettingsReloaded must not fire.
        settings.focusFollowsWindowToMonitor = true
        settings.flushNow()

        // Wait for any pending DispatchSource events to drain. Pattern mirrors
        // `invalidExternalEditLeavesCurrentSettingsUnchanged` which uses the same
        // 200ms drain window before asserting reloadCount == 0.
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(reloadCount == 0)
        #expect(settings.focusFollowsWindowToMonitor == true)
    }
}
