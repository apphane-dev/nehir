// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@testable import Nehir
@testable import NehirCtl
import NehirIPC
import Testing

@Suite struct AppRuleIPCContractTests {
    @Test func cliParsesAppNameOnlyAddAndReplace() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000197")!.uuidString
        let add = try CLIParser.parse(arguments: [
            "nehirctl", "rule", "add", "--app-name-substring", "QEMU", "--layout", "float"
        ])
        let replace = try CLIParser.parse(arguments: [
            "nehirctl", "rule", "replace", id, "--app-name-substring", "QEMU"
        ])

        guard case let .rule(.add(addRule)) = add.request.payload,
              case let .rule(.replace(replaceID, replaceRule)) = replace.request.payload
        else {
            Issue.record("Expected app-name rule requests")
            return
        }
        #expect(addRule.bundleId == nil)
        #expect(addRule.appNameSubstring == "QEMU")
        #expect(replaceID == id)
        #expect(replaceRule.appNameSubstring == "QEMU")
    }

    @Test func optionalSelectorsRoundTripAndManifestShowsIndependentFlags() throws {
        let definition = IPCRuleDefinition(appNameSubstring: "QEMU", layout: .float)
        let data = try IPCWire.makeEncoder().encode(definition)
        #expect(try IPCWire.makeDecoder().decode(IPCRuleDefinition.self, from: data) == definition)
        #expect(IPCRuleValidator.validate(definition).applicationSelectorError == nil)
        #expect(IPCRuleValidator.validate(IPCRuleDefinition()).applicationSelectorError != nil)
        #expect(IPCAutomationManifest.ruleActionDescriptor(for: .add)?.path ==
            "rule add [--bundle-id <bundle-id>] [--app-name-substring <text>] [options]")
    }

    @MainActor
    @Test func ipcRouterAcceptsAppNameOnlyRule() async {
        let controller = makeLayoutPlanTestController()
        defer { resetSharedControllerStateForTests() }
        controller.settings.appRules = []
        let result = await IPCRuleRouter(controller: controller, sessionToken: "app-name-rule")
            .handle(.add(rule: IPCRuleDefinition(appNameSubstring: "QEMU", layout: .float)))

        guard case let .success(rules) = result else {
            Issue.record("Expected app-name-only rule to be accepted")
            return
        }
        #expect(rules.rules.first?.bundleId == nil)
        #expect(rules.rules.first?.appNameSubstring == "QEMU")
    }

    @Test func ruleAndAppRenderingUseNilBundleFallback() throws {
        let rules = IPCResponse.success(
            id: "rules",
            kind: .rule,
            result: IPCResult(rules: IPCRulesQueryResult(rules: [
                IPCRuleSnapshot(
                    id: "rule",
                    position: 1,
                    appNameSubstring: "QEMU",
                    layout: .auto,
                    specificity: 1,
                    isValid: true
                )
            ]))
        )
        let output = try CLIRenderer.responseOutput(rules, format: .tsv)
        #expect(String(decoding: output.data, as: UTF8.self).contains("rule\t-\tQEMU"))
    }
}
