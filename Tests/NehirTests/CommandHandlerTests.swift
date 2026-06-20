import CoreGraphics
@testable import Nehir
import Testing

@Suite @MainActor struct CommandHandlerTests {
    @Test func commandPaletteDisplayNameReflectsToggleBehavior() {
        #expect(HotkeyCommand.openCommandPalette.displayName == "Toggle Command Palette")
    }

    @Test func debugTraceToggleIsStateful() {
        let controller = makeLayoutPlanTestController()
        defer {
            if controller.isRuntimeTraceCaptureActive {
                _ = controller.toggleRuntimeTraceCapture(desiredState: .inactive)
            }
            resetSharedControllerStateForTests()
        }

        // toggle with no desiredState flips state
        #expect(!controller.isRuntimeTraceCaptureActive)
        #expect(controller.toggleRuntimeTraceCapture() == .executed)
        #expect(controller.isRuntimeTraceCaptureActive)
        #expect(controller.toggleRuntimeTraceCapture() == .executed)
        #expect(!controller.isRuntimeTraceCaptureActive)

        // desiredState .active is idempotent
        #expect(controller.toggleRuntimeTraceCapture(desiredState: .active) == .executed)
        #expect(controller.isRuntimeTraceCaptureActive)
        #expect(controller.toggleRuntimeTraceCapture(desiredState: .active) == .executed)
        #expect(controller.isRuntimeTraceCaptureActive)

        // desiredState .inactive is idempotent
        #expect(controller.toggleRuntimeTraceCapture(desiredState: .inactive) == .executed)
        #expect(!controller.isRuntimeTraceCaptureActive)
        #expect(controller.toggleRuntimeTraceCapture(desiredState: .inactive) == .executed)
        #expect(!controller.isRuntimeTraceCaptureActive)
    }

    @Test func overviewIgnoresNonOverviewHotkeys() {
        #expect(CommandHandler.shouldIgnoreCommand(.switchWorkspace(1), isOverviewOpen: true) == true)
        #expect(CommandHandler.shouldIgnoreCommand(.move(.left), isOverviewOpen: true) == true)
    }

    @Test func overviewHotkeyFocusDirectionsMoveOverviewSelection() {
        let controller = makeLayoutPlanTestController()
        let workspaceId = try! #require(controller.interactionWorkspace()?.id)
        let monitorId = try! #require(controller.workspaceManager.monitors.first?.id)
        let firstToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 6101,
            pid: 6101
        )
        let secondToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 6102,
            pid: 6102
        )
        let firstHandle = try! #require(controller.workspaceManager.handle(for: firstToken))
        let secondHandle = try! #require(controller.workspaceManager.handle(for: secondToken))
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitorId)
        AXWindowService.fastFrameProviderForTests = { window in
            switch window.windowId {
            case firstToken.windowId:
                CGRect(x: 100, y: 100, width: 300, height: 200)
            case secondToken.windowId:
                CGRect(x: 500, y: 100, width: 300, height: 200)
            default:
                nil
            }
        }
        defer {
            if controller.isOverviewOpen() {
                controller.toggleOverview()
            }
            AXWindowService.fastFrameProviderForTests = nil
            resetSharedControllerStateForTests()
        }
        controller.toggleOverview()

        #expect(controller.selectedOverviewWindowForTests() == firstHandle)
        #expect(controller.commandHandler.handleHotkeyCommand(.focus(.right)) == .executed)
        #expect(controller.selectedOverviewWindowForTests() == secondHandle)
        #expect(controller.commandHandler.handleHotkeyCommand(.focus(.left)) == .executed)
        #expect(controller.selectedOverviewWindowForTests() == firstHandle)

        #expect(controller.isOverviewOpen())
    }

    @Test func overviewHotkeyHandlerStillBlocksOtherCommands() {
        let controller = makeLayoutPlanTestController()
        defer {
            if controller.isOverviewOpen() {
                controller.toggleOverview()
            }
            resetSharedControllerStateForTests()
        }
        controller.toggleOverview()

        for command in [HotkeyCommand.focusPrevious, .focusDownOrLeft, .move(.left), .switchWorkspace(2)] {
            #expect(controller.commandHandler.handleHotkeyCommand(command) == .ignoredOverview)
        }
    }

    @Test func overviewStillAllowsOverviewAndDebuggingHotkeys() {
        #expect(CommandHandler.shouldIgnoreCommand(.toggleOverview, isOverviewOpen: true) == false)
        #expect(CommandHandler.shouldIgnoreCommand(.toggleOverview, isOverviewOpen: false) == false)

        for command in [
            HotkeyCommand.debugDumpRuntimeState,
            .debugResetRuntimeState,
            .debugRestartClearingRuntimeState,
            .debugToggleTraceCapture
        ] {
            #expect(CommandHandler.shouldIgnoreCommand(command, isOverviewOpen: true) == false)
        }
    }
}
