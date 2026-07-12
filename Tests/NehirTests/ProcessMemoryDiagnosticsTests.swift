// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@testable import Nehir
import Testing

@Suite struct ProcessMemoryDiagnosticsTests {
    @Test func currentProcessReportsFootprintAndResidentMemory() {
        let diagnostics = ProcessMemoryDiagnostics.current()

        #expect((diagnostics.footprintBytes ?? 0) > 0)
        #expect((diagnostics.residentBytes ?? 0) > 0)
    }

    @Test func formattedLineIncludesMemoryKeys() {
        let formatted = ProcessMemoryDiagnostics.current().formattedLine

        #expect(formatted.contains("footprint="))
        #expect(formatted.contains("peak="))
        #expect(formatted.contains("resident="))
    }

    @Test func unavailableMemoryRendersUnavailableFootprint() {
        let diagnostics = ProcessMemoryDiagnostics(
            footprintBytes: nil,
            peakFootprintBytes: nil,
            residentBytes: nil
        )

        #expect(diagnostics.formattedLine == "footprint=unavailable")
    }

    @Test func formatsKnownByteValuesInMegabytes() {
        let diagnostics = ProcessMemoryDiagnostics(
            footprintBytes: 55_574_528,
            peakFootprintBytes: 55_574_528,
            residentBytes: 55_574_528
        )

        #expect(diagnostics.formattedLine == "footprint=53.0MB peak=53.0MB resident=53.0MB")
    }
}
