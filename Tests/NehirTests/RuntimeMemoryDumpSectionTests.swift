// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

@testable import Nehir
import Testing

@Suite(.serialized) @MainActor struct RuntimeMemoryDumpSectionTests {
    @Test func runtimeStateDumpIncludesMemorySectionAndSubsystemCounters() {
        let controller = makeLayoutPlanTestController()
        defer { resetSharedControllerStateForTests() }

        let dump = controller.diagnostics.runtimeStateDebugDump(traceLimit: 0)

        #expect(dump.contains("-- Memory --"))
        #expect(dump.contains("footprint="))
        #expect(dump.contains("axEventHandler "))
        #expect(dump.contains("layoutRefresh "))
        #expect(dump.contains("appAXContexts="))
    }
}
