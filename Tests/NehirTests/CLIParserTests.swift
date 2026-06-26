// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@testable import NehirCtl
import NehirIPC
import Testing

private func representativeCommandToken(for kind: IPCCommandArgumentKind) -> String {
    switch kind {
    case .direction:
        "left"
    case .workspaceNumber:
        "2"
    case .columnIndex:
        "3"
    case .windowIndex:
        "4"
    case .resizeOperation:
        "grow"
    case .sizeChange:
        "+10%"
    case .traceDesiredState:
        "active"
    }
}

private func representativeCommandValue(for kind: IPCCommandArgumentKind) -> IPCCommandArgumentValue {
    switch kind {
    case .direction:
        .direction(.left)
    case .workspaceNumber:
        .integer(2)
    case .columnIndex:
        .integer(3)
    case .windowIndex:
        .integer(4)
    case .resizeOperation:
        .resizeOperation(.grow)
    case .sizeChange:
        .sizeChange(.adjustProportion(10))
    case .traceDesiredState:
        .traceDesiredState(.active)
    }
}

private func sampleRuleOptionValue(for flag: String) -> String {
    switch flag {
    case "--bundle-id":
        "com.example.terminal"
    case "--app-name-substring":
        "Terminal"
    case "--title-substring":
        "Shell"
    case "--title-regex":
        "Docs.*"
    case "--ax-role":
        "AXWindow"
    case "--ax-subrole":
        "AXStandardWindow"
    case "--manage":
        "ignore"
    case "--layout":
        "float"
    case "--sticky":
        "true"
    case "--assign-to-workspace":
        "2"
    case "--min-width":
        "640"
    case "--min-height":
        "480"
    default:
        "value"
    }
}

@Suite struct CLIParserTests {
    @Test func manifestCommandDescriptorsAreParseableAndWireRoundTrip() throws {
        for descriptor in IPCAutomationManifest.commandDescriptors {
            let argumentTokens = descriptor.arguments.map { representativeCommandToken(for: $0.kind) }
            let parsed = try CLIParser.parse(
                arguments: ["nehirctl", "command"] + descriptor.commandWords + argumentTokens
            )

            guard case let .command(command) = parsed.request.payload else {
                Issue.record("Expected command payload for \(descriptor.path)")
                continue
            }

            let expectedCommand = try IPCCommandRequest(
                name: descriptor.name,
                argumentValues: descriptor.arguments.map { representativeCommandValue(for: $0.kind) }
            )
            let encoded = try IPCWire.encodeRequestLine(parsed.request)
            let decoded = try IPCWire.decodeRequest(from: Data(encoded.dropLast()))

            #expect(command.name == descriptor.name)
            #expect(command == expectedCommand)
            #expect(decoded == parsed.request)
        }
    }

    @Test func parsesFocusCommand() throws {
        let parsed = try CLIParser.parse(arguments: ["nehirctl", "command", "focus", "left"])

        #expect(parsed.request.kind == .command)
        #expect(parsed.prefersJSON == false)
        #expect(parsed.expectsEventStream == false)

        guard case let .command(command) = parsed.request.payload else {
            Issue.record("Expected a command payload")
            return
        }

        #expect(command == .focus(direction: .left))
    }

    @Test func parsesGroupedFocusPreviousCommand() throws {
        let parsed = try CLIParser.parse(arguments: ["nehirctl", "command", "focus", "previous"])

        guard case let .command(command) = parsed.request.payload else {
            Issue.record("Expected a command payload")
            return
        }

        #expect(command == .focusPrevious)
    }

    @Test func parsesNiriWindowFocusCommands() throws {
        let indexed = try CLIParser.parse(arguments: ["nehirctl", "command", "focus-window-in-column", "3"])
        let top = try CLIParser.parse(arguments: ["nehirctl", "command", "focus-window", "top"])
        let wrap = try CLIParser.parse(arguments: ["nehirctl", "command", "focus-window", "down-or-top"])
        let workspaceDown = try CLIParser.parse(arguments: ["nehirctl", "command", "focus-window-or-workspace-down"])
        let workspaceUp = try CLIParser.parse(arguments: ["nehirctl", "command", "focus-window-or-workspace-up"])

        guard case let .command(indexedCommand) = indexed.request.payload,
              case let .command(topCommand) = top.request.payload,
              case let .command(wrapCommand) = wrap.request.payload,
              case let .command(workspaceDownCommand) = workspaceDown.request.payload,
              case let .command(workspaceUpCommand) = workspaceUp.request.payload
        else {
            Issue.record("Expected command payloads")
            return
        }

        #expect(indexedCommand == .focusWindowInColumn(windowIndex: 3))
        #expect(topCommand == .focusWindowTop)
        #expect(wrapCommand == .focusWindowDownOrTop)
        #expect(workspaceDownCommand == .focusWindowOrWorkspaceDown)
        #expect(workspaceUpCommand == .focusWindowOrWorkspaceUp)
    }

    @Test func parsesNiriViewportCommands() throws {
        let left = try CLIParser.parse(arguments: ["nehirctl", "command", "scroll-viewport", "left"])
        let right = try CLIParser.parse(arguments: ["nehirctl", "command", "scroll-viewport", "right"])

        guard case let .command(leftCommand) = left.request.payload,
              case let .command(rightCommand) = right.request.payload
        else {
            Issue.record("Expected command payloads")
            return
        }

        #expect(leftCommand == .scrollViewportLeft)
        #expect(rightCommand == .scrollViewportRight)
    }

    @Test func parsesNiriColumnMoveCommands() throws {
        let first = try CLIParser.parse(arguments: ["nehirctl", "command", "move-column-to-first"])
        let last = try CLIParser.parse(arguments: ["nehirctl", "command", "move-column-to-last"])
        let indexed = try CLIParser.parse(arguments: ["nehirctl", "command", "move-column-to-index", "3"])

        guard case let .command(firstCommand) = first.request.payload,
              case let .command(lastCommand) = last.request.payload,
              case let .command(indexedCommand) = indexed.request.payload
        else {
            Issue.record("Expected command payloads")
            return
        }

        #expect(firstCommand == .moveColumnToFirst)
        #expect(lastCommand == .moveColumnToLast)
        #expect(indexedCommand == .moveColumnToIndex(columnIndex: 3))
    }

    @Test func parsesNiriWindowMoveCommands() throws {
        let down = try CLIParser.parse(arguments: ["nehirctl", "command", "move-window-down"])
        let up = try CLIParser.parse(arguments: ["nehirctl", "command", "move-window-up"])
        let downFallback = try CLIParser.parse(arguments: [
            "nehirctl",
            "command",
            "move-window-down-or-to-workspace-down"
        ])
        let upFallback = try CLIParser.parse(arguments: ["nehirctl", "command", "move-window-up-or-to-workspace-up"])
        let consumeLeft = try CLIParser.parse(arguments: ["nehirctl", "command", "consume-or-expel-window-left"])
        let consumeRight = try CLIParser.parse(arguments: ["nehirctl", "command", "consume-or-expel-window-right"])
        let consumeInto = try CLIParser.parse(arguments: ["nehirctl", "command", "consume-window-into-column"])
        let expelFrom = try CLIParser.parse(arguments: ["nehirctl", "command", "expel-window-from-column"])

        guard case let .command(downCommand) = down.request.payload,
              case let .command(upCommand) = up.request.payload,
              case let .command(downFallbackCommand) = downFallback.request.payload,
              case let .command(upFallbackCommand) = upFallback.request.payload,
              case let .command(consumeLeftCommand) = consumeLeft.request.payload,
              case let .command(consumeRightCommand) = consumeRight.request.payload,
              case let .command(consumeIntoCommand) = consumeInto.request.payload,
              case let .command(expelFromCommand) = expelFrom.request.payload
        else {
            Issue.record("Expected command payloads")
            return
        }

        #expect(downCommand == .moveWindowDown)
        #expect(upCommand == .moveWindowUp)
        #expect(downFallbackCommand == .moveWindowDownOrToWorkspaceDown)
        #expect(upFallbackCommand == .moveWindowUpOrToWorkspaceUp)
        #expect(consumeLeftCommand == .consumeOrExpelWindowLeft)
        #expect(consumeRightCommand == .consumeOrExpelWindowRight)
        #expect(consumeIntoCommand == .consumeWindowIntoColumn)
        #expect(expelFromCommand == .expelWindowFromColumn)
    }

    @Test func parsesNiriSizeChangeCommands() throws {
        let column = try CLIParser.parse(arguments: ["nehirctl", "command", "set-column-width", "+10%"])
        let height = try CLIParser.parse(arguments: ["nehirctl", "command", "set-window-height", "600"])

        guard case let .command(columnCommand) = column.request.payload,
              case let .command(heightCommand) = height.request.payload
        else {
            Issue.record("Expected command payloads")
            return
        }

        #expect(columnCommand == .setColumnWidth(change: .adjustProportion(10)))
        #expect(heightCommand == .setWindowHeight(change: .setFixed(600)))
    }

    @Test func parsesWorkspaceCommandsWithHighWorkspaceIds() throws {
        let parsed = try CLIParser.parse(arguments: ["nehirctl", "command", "switch-workspace", "10"])

        guard case let .command(command) = parsed.request.payload else {
            Issue.record("Expected a command payload")
            return
        }

        #expect(command == .switchWorkspace(workspaceNumber: 10))
    }

    @Test func parsesWorkspaceFocusNameNumericInputAsRawWorkspaceIDTarget() throws {
        let parsed = try CLIParser.parse(arguments: ["nehirctl", "workspace", "focus-name", "10"])

        guard case let .workspace(request) = parsed.request.payload else {
            Issue.record("Expected a workspace payload")
            return
        }

        #expect(request == IPCWorkspaceRequest(name: .focusName, target: .rawID("10")))
    }

    @Test func queriesDefaultToJSONOutput() throws {
        let parsed = try CLIParser.parse(arguments: ["nehirctl", "query", "workspace-bar"])

        #expect(parsed.request.kind == .query)
        #expect(parsed.prefersJSON)
        guard case let .query(query) = parsed.request.payload else {
            Issue.record("Expected a query payload")
            return
        }
        #expect(query.name == .workspaceBar)
    }

    @Test func parsesSubscribeChannelsAsEventStream() throws {
        let parsed = try CLIParser.parse(arguments: ["nehirctl", "subscribe", "focus,workspace-bar"])

        #expect(parsed.request.kind == .subscribe)
        #expect(parsed.prefersJSON)
        #expect(parsed.expectsEventStream)

        guard case let .subscribe(subscribe) = parsed.request.payload else {
            Issue.record("Expected a subscribe payload")
            return
        }
        #expect(subscribe.channels == [.focus, .workspaceBar])
    }

    @Test func parsesWindowQuerySelectorsAndFields() throws {
        let parsed = try CLIParser.parse(
            arguments: [
                "nehirctl",
                "query",
                "windows",
                "--workspace", "2",
                "--visible",
                "--fields", "id,title,workspace"
            ]
        )

        #expect(parsed.request.kind == .query)
        #expect(parsed.prefersJSON)

        guard case let .query(query) = parsed.request.payload else {
            Issue.record("Expected a query payload")
            return
        }

        #expect(query.name == .windows)
        #expect(query.selectors.workspace == "2")
        #expect(query.selectors.visible == true)
        #expect(query.fields == ["id", "title", "workspace"])
    }

    @Test func parsesQueryRegistryDiscoverySurface() throws {
        let parsed = try CLIParser.parse(arguments: ["nehirctl", "query", "queries", "--format", "table"])

        #expect(parsed.request.kind == .query)
        #expect(parsed.outputFormat == .table)

        guard case let .query(query) = parsed.request.payload else {
            Issue.record("Expected a query payload")
            return
        }

        #expect(query.name == .queries)
        #expect(query.fields.isEmpty)
        #expect(query.selectors == IPCQuerySelectors())
    }

    @Test func parsesRuleActionRegistryQuery() throws {
        let parsed = try CLIParser.parse(arguments: ["nehirctl", "query", "rule-actions"])

        #expect(parsed.request.kind == .query)
        #expect(parsed.prefersJSON)

        guard case let .query(query) = parsed.request.payload else {
            Issue.record("Expected a query payload")
            return
        }

        #expect(query.name == .ruleActions)
        #expect(query.fields.isEmpty)
        #expect(query.selectors == IPCQuerySelectors())
    }

    @Test func parsesSubscribeAllWithoutInitialSnapshot() throws {
        let parsed = try CLIParser.parse(
            arguments: ["nehirctl", "subscribe", "--all", "--no-send-initial"]
        )

        #expect(parsed.request.kind == .subscribe)
        #expect(parsed.prefersJSON)
        #expect(parsed.expectsEventStream)

        guard case let .subscribe(subscribe) = parsed.request.payload else {
            Issue.record("Expected a subscribe payload")
            return
        }

        #expect(subscribe.allChannels)
        #expect(subscribe.channels.isEmpty)
        #expect(subscribe.sendInitial == false)
    }

    @Test func parsesWatchCommandAndPreservesChildArguments() throws {
        let parsed = try CLIParser.parse(
            arguments: [
                "nehirctl",
                "watch",
                "focused-monitor",
                "--no-send-initial",
                "--exec",
                "/bin/echo",
                "--json"
            ]
        )

        #expect(parsed.request.kind == .subscribe)
        #expect(parsed.prefersJSON == false)
        #expect(parsed.expectsEventStream == false)
        #expect(parsed.watchConfiguration?.childArguments == ["/bin/echo", "--json"])

        guard case let .subscribe(subscribe) = parsed.request.payload else {
            Issue.record("Expected a subscribe payload")
            return
        }

        #expect(subscribe.channels == [.focusedMonitor])
        #expect(subscribe.sendInitial == false)
    }

    @Test func parsesWatchAllWithTopLevelFormatFlag() throws {
        let parsed = try CLIParser.parse(
            arguments: [
                "nehirctl",
                "--format",
                "json",
                "watch",
                "--all",
                "--exec",
                "/bin/echo"
            ]
        )

        #expect(parsed.request.kind == .subscribe)
        #expect(parsed.prefersJSON)
        #expect(parsed.expectsEventStream == false)
        #expect(parsed.watchConfiguration?.childArguments == ["/bin/echo"])

        guard case let .subscribe(subscribe) = parsed.request.payload else {
            Issue.record("Expected a subscribe payload")
            return
        }

        #expect(subscribe.allChannels)
        #expect(subscribe.channels.isEmpty)
        #expect(subscribe.sendInitial)
    }

    @Test func rejectsWatchWithoutExecCommand() {
        do {
            _ = try CLIParser.parse(arguments: ["nehirctl", "watch", "focused-monitor", "--exec"])
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func rejectsWatchWithoutChannelsOrAll() {
        do {
            _ = try CLIParser.parse(arguments: ["nehirctl", "watch", "--exec", "/bin/echo"])
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func rejectsUnknownWindowQueryField() {
        do {
            _ = try CLIParser.parse(
                arguments: ["nehirctl", "query", "windows", "--fields", "id,unknown"]
            )
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func parsesZeroPaddedWorkspaceNumbersAsCanonicalTargets() throws {
        let parsed = try CLIParser.parse(arguments: ["nehirctl", "command", "switch-workspace", "01"])

        guard case let .command(command) = parsed.request.payload else {
            Issue.record("Expected a command payload")
            return
        }

        #expect(command == .switchWorkspace(workspaceNumber: 1))
    }

    @Test func rejectsZeroWorkspaceNumber() {
        do {
            _ = try CLIParser.parse(arguments: ["nehirctl", "command", "switch-workspace", "0"])
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func rejectsInvalidResizeOperation() {
        do {
            _ = try CLIParser.parse(arguments: ["nehirctl", "command", "resize", "left", "bigger"])
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func rejectsInvalidLayoutValue() {
        do {
            _ = try CLIParser.parse(arguments: ["nehirctl", "command", "set-workspace-layout", "grid"])
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func parsesDisplayQuerySelector() throws {
        let parsed = try CLIParser.parse(
            arguments: ["nehirctl", "query", "displays", "--display", "Built-in Retina Display"]
        )

        #expect(parsed.outputFormat == .json)
        guard case let .query(query) = parsed.request.payload else {
            Issue.record("Expected a query payload")
            return
        }

        #expect(query.name == .displays)
        #expect(query.selectors.display == "Built-in Retina Display")
    }

    @Test func rejectsRemovedCompatibilityAliases() {
        let removedCompatibilityArgv = [
            ["nehirctl", "query", "monitors", "--display", "Built-in Retina Display"],
            ["nehirctl", "query", "displays", "--monitor", "Built-in Retina Display"],
            ["nehirctl", "command", "focus-monitor", "previous"],
            ["nehirctl", "command", "switch-workspace", "previous"],
            ["nehirctl", "command", "switch-workspace", "back"]
        ]

        for arguments in removedCompatibilityArgv {
            do {
                _ = try CLIParser.parse(arguments: arguments)
                Issue.record("Expected parser failure for \(arguments.joined(separator: " "))")
            } catch let error as CLIParseError {
                #expect(error == .usage(CLIParser.usageText))
            } catch {
                Issue.record("Unexpected parser error: \(error)")
            }
        }
    }

    @Test func parsesRuleCommandsAndExplicitOutputFormats() throws {
        let add = try CLIParser.parse(
            arguments: [
                "nehirctl",
                "--format", "table",
                "rule",
                "add",
                "--bundle-id", "com.example.terminal",
                "--title-substring", "Shell",
                "--layout", "float"
            ]
        )
        let moveId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!.uuidString
        let replace = try CLIParser.parse(
            arguments: [
                "nehirctl",
                "rule",
                "replace",
                moveId,
                "--bundle-id", "com.example.browser",
                "--title-regex", "Docs.*",
                "--layout", "tile"
            ]
        )
        let remove = try CLIParser.parse(arguments: ["nehirctl", "rule", "remove", moveId])
        let move = try CLIParser.parse(arguments: ["nehirctl", "rule", "move", moveId, "2"])

        #expect(add.outputFormat == .table)
        guard case let .rule(addRule) = add.request.payload else {
            Issue.record("Expected a rule payload")
            return
        }
        guard case let .add(definition) = addRule else {
            Issue.record("Expected add rule request")
            return
        }
        #expect(definition.bundleId == "com.example.terminal")
        #expect(definition.titleSubstring == "Shell")
        #expect(definition.layout == .float)

        guard case let .rule(replaceRule) = replace.request.payload else {
            Issue.record("Expected a replace rule payload")
            return
        }
        guard case let .replace(replaceId, replaceDefinition) = replaceRule else {
            Issue.record("Expected replace rule request")
            return
        }
        #expect(replaceId == moveId)
        #expect(replaceDefinition.bundleId == "com.example.browser")
        #expect(replaceDefinition.titleRegex == "Docs.*")
        #expect(replaceDefinition.layout == .tile)

        guard case let .rule(removeRule) = remove.request.payload else {
            Issue.record("Expected a remove rule payload")
            return
        }
        #expect(removeRule == .remove(id: moveId))

        guard case let .rule(moveRule) = move.request.payload else {
            Issue.record("Expected a move rule payload")
            return
        }
        #expect(moveRule == .move(id: moveId, position: 2))
    }

    @Test func parsesRuleApplyTargets() throws {
        let bare = try CLIParser.parse(arguments: ["nehirctl", "rule", "apply"])
        let focused = try CLIParser.parse(arguments: ["nehirctl", "rule", "apply", "--focused"])
        let window = try CLIParser.parse(arguments: ["nehirctl", "rule", "apply", "--window", "ow_window"])
        let pid = try CLIParser.parse(arguments: ["nehirctl", "rule", "apply", "--pid", "42"])

        guard case let .rule(bareRule) = bare.request.payload else {
            Issue.record("Expected a bare rule payload")
            return
        }
        guard case let .rule(focusedRule) = focused.request.payload else {
            Issue.record("Expected a focused rule payload")
            return
        }
        guard case let .rule(windowRule) = window.request.payload else {
            Issue.record("Expected a window rule payload")
            return
        }
        guard case let .rule(pidRule) = pid.request.payload else {
            Issue.record("Expected a pid rule payload")
            return
        }

        #expect(bareRule == .apply(target: .focused))
        #expect(focusedRule == .apply(target: .focused))
        #expect(windowRule == .apply(target: .window(windowId: "ow_window")))
        #expect(pidRule == .apply(target: .pid(42)))
    }

    @Test func parsesEveryRuleDefinitionOptionForAddAndReplace() throws {
        let ruleId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!.uuidString

        for descriptor in IPCAutomationManifest.ruleDefinitionOptionDescriptors {
            let extraOption: [String]
            if descriptor.flag == "--bundle-id" {
                extraOption = []
            } else {
                extraOption = [descriptor.flag, sampleRuleOptionValue(for: descriptor.flag)]
            }

            let add = try CLIParser.parse(
                arguments: [
                    "nehirctl",
                    "rule",
                    "add",
                    "--bundle-id",
                    sampleRuleOptionValue(for: "--bundle-id")
                ] + extraOption
            )
            let replace = try CLIParser.parse(
                arguments: [
                    "nehirctl",
                    "rule",
                    "replace",
                    ruleId,
                    "--bundle-id",
                    sampleRuleOptionValue(for: "--bundle-id")
                ] + extraOption
            )

            guard case let .rule(addRule) = add.request.payload,
                  case .add = addRule
            else {
                Issue.record("Expected add rule payload for \(descriptor.flag)")
                continue
            }

            guard case let .rule(replaceRule) = replace.request.payload,
                  case .replace = replaceRule
            else {
                Issue.record("Expected replace rule payload for \(descriptor.flag)")
                continue
            }
        }
    }

    @Test func rejectsDuplicateAndUnknownRuleDefinitionOptions() {
        let invalidArgv = [
            [
                "nehirctl",
                "rule",
                "add",
                "--bundle-id",
                "com.example.terminal",
                "--bundle-id",
                "com.example.browser"
            ],
            [
                "nehirctl",
                "rule",
                "add",
                "--bundle-id",
                "com.example.terminal",
                "--unknown",
                "value"
            ]
        ]

        for arguments in invalidArgv {
            do {
                _ = try CLIParser.parse(arguments: arguments)
                Issue.record("Expected parser failure for \(arguments.joined(separator: " "))")
            } catch let error as CLIParseError {
                #expect(error == .usage(CLIParser.usageText))
            } catch {
                Issue.record("Unexpected parser error: \(error)")
            }
        }
    }

    @Test func rejectsMixedRuleApplySelectors() {
        do {
            _ = try CLIParser.parse(
                arguments: ["nehirctl", "rule", "apply", "--focused", "--pid", "42"]
            )
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func parsesCompletionAsLocalInvocation() throws {
        let parsed = try CLIParser.parse(arguments: ["nehirctl", "completion", "bash"])

        #expect(parsed.outputFormat == .text)
        #expect(parsed.expectsEventStream == false)
        #expect(parsed.watchConfiguration == nil)
        #expect(parsed.invocation == .local(.completion(.bash)))
    }

    @Test func parsesLegalAttributionAliasesAsLocalInvocation() throws {
        for command in ["about", "attribution", "legal", "license"] {
            let parsed = try CLIParser.parse(arguments: ["nehirctl", command])

            #expect(parsed.outputFormat == .text)
            #expect(parsed.expectsEventStream == false)
            #expect(parsed.watchConfiguration == nil)
            #expect(parsed.invocation == .local(.legalNotice))
        }
    }

    @Test func usageIncludesLegalAttribution() {
        #expect(CLIParser.usageText.contains("nehirctl license"))
        #expect(CLIParser.usageText.contains("GPL-2.0-only"))
        #expect(CLIParser.usageText.contains("OmniWM by BarutSRB"))
        #expect(CLILegalNotice.text.contains("GNU General Public License v2.0 only"))
        #expect(CLILegalNotice.text.contains("OmniWM by BarutSRB"))
        #expect(CLILegalNotice.text.contains("NO WARRANTY"))
    }
}
