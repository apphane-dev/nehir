// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

@testable import NehirCtl
import Testing

@Suite struct CLICompletionGeneratorTests {
    @Test func zshScriptIncludesNestedManifestBackedSuggestions() {
        let script = CLICompletionGenerator.script(for: .zsh)

        #expect(script.contains("query_name"))
        #expect(script.contains("rule-actions"))
        #expect(script.contains("--fields"))
        #expect(script.contains("--display"))
        #expect(!script.contains("--monitor"))
        #expect(script.contains("down left right up"))
        #expect(script.contains("--bundle-id"))
        #expect(script.contains("--title-regex"))
        #expect(script.contains("--focused --pid --window") || script.contains("--focused --window --pid"))
        #expect(script.contains("switch-workspace"))
        #expect(script.contains("prev"))
        #expect(script.contains("back-and-forth"))
        #expect(script.contains("license"))
        #expect(script.contains("attribution"))
    }

    @Test func bashScriptIncludesRuleApplyQueryAndSubscriptionFlags() {
        let script = CLICompletionGenerator.script(for: .bash)

        #expect(script.contains("complete -F _nehirctl nehirctl"))
        #expect(script.contains("query_name"))
        #expect(script.contains("rule-actions"))
        #expect(script.contains("--bundle-id"))
        #expect(script.contains("--title-regex"))
        #expect(script.contains("--pid"))
        #expect(script.contains("--window"))
        #expect(script.contains("--all"))
        #expect(script.contains("--no-send-initial"))
        #expect(script.contains("--exec"))
        #expect(script.contains("focused-monitor"))
    }

    @Test func fishScriptIncludesQueryFieldsAndCommandValueHints() {
        let script = CLICompletionGenerator.script(for: .fish)

        #expect(script.contains("__nehirctl_prev_arg_is"))
        #expect(script.contains("rule-actions"))
        #expect(script.contains("--fields"))
        #expect(script.contains("pid"))
        #expect(script.contains("--display"))
        #expect(!script.contains("--monitor"))
        #expect(script.contains("--bundle-id"))
        #expect(script.contains("--title-regex"))
        #expect(script.contains("--window"))
        #expect(script.contains("--pid"))
    }
}
