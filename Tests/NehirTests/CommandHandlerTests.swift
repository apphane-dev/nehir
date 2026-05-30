@testable import Nehir
import CoreGraphics
import Testing

@Suite @MainActor struct CommandHandlerTests {
    @Test func commandPaletteDisplayNameReflectsToggleBehavior() {
        #expect(HotkeyCommand.openCommandPalette.displayName == "Toggle Command Palette")
    }

    @Test func overviewIgnoresNonOverviewHotkeys() {
        #expect(CommandHandler.shouldIgnoreCommand(.switchWorkspace(1), isOverviewOpen: true) == true)
        #expect(CommandHandler.shouldIgnoreCommand(.move(.left), isOverviewOpen: true) == true)
    }

    @Test func overviewHotkeyFocusDirectionsMoveOverviewSelection() {
        let controller = makeLayoutPlanTestController()
        controller.motionPolicy.animationsEnabled = false
        let workspaceId = try! #require(controller.activeWorkspace()?.id)
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
        controller.motionPolicy.animationsEnabled = false
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

    @Test func overviewStillAllowsOverviewToggleHotkey() {
        #expect(CommandHandler.shouldIgnoreCommand(.toggleOverview, isOverviewOpen: true) == false)
        #expect(CommandHandler.shouldIgnoreCommand(.toggleOverview, isOverviewOpen: false) == false)
    }
}
