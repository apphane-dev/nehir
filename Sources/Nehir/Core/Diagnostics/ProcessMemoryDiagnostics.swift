// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Darwin
import Foundation

struct ProcessMemoryDiagnostics: Equatable {
    let footprintBytes: UInt64?
    let peakFootprintBytes: UInt64?
    let residentBytes: UInt64?

    static func current() -> Self {
        var info = task_vm_info_data_t()
        // Request the full struct so macOS fills the revision-3 peak-footprint
        // ledger when it is available. Swift does not import the task-info
        // revision-count macros, so calculate the equivalent capacity directly.
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return Self(footprintBytes: nil, peakFootprintBytes: nil, residentBytes: nil)
        }

        return Self(
            footprintBytes: UInt64(info.phys_footprint),
            peakFootprintBytes: UInt64(info.ledger_phys_footprint_peak),
            residentBytes: UInt64(info.resident_size)
        )
    }

    var formattedLine: String {
        guard let footprintBytes, let peakFootprintBytes, let residentBytes else {
            return "footprint=unavailable"
        }
        return "footprint=\(Self.formatMegabytes(footprintBytes)) peak=\(Self.formatMegabytes(peakFootprintBytes)) resident=\(Self.formatMegabytes(residentBytes))"
    }

    private static func formatMegabytes(_ bytes: UInt64) -> String {
        String(format: "%.1fMB", Double(bytes) / (1024 * 1024))
    }
}
