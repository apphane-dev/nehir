// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// One entry in the AX windows-query trace ring.
///
/// Diagnostic only — records every raw `kAXWindowsAttribute` result and any
/// AX-vs-WindowServer window-count mismatch detected during a full rescan, so
/// a capture can show directly whether a per-app AX windows query returned an
/// incomplete list. See
/// `plans/discovery/20260701-startup-full-rescan-under-enumerates-multi-window-app.md`
/// and `plans/discovery/20260630-visible-unmanaged-windows-admitted-late-as-columns.md`.
struct AXWindowsQueryRecord: Equatable {
    enum Kind: Equatable {
        /// The raw result of an `AppAXContext.getWindowsAsync()` call.
        /// `newContext` is `true` only for the first `getWindowsAsync()` call
        /// made against a given `AppAXContext` instance — the call most
        /// likely to race a still-settling app/AX bookkeeping state.
        case queryResult(pid: pid_t, windowIds: [Int], newContext: Bool)
        /// A full-rescan per-pid AX window count fell short of the
        /// WindowServer/CGWindowList on-screen window count for that pid.
        case countMismatch(pid: pid_t, axCount: Int, windowServerCount: Int)
    }

    let sequence: UInt64
    let timestamp: Date
    let kind: Kind
}

extension AXWindowsQueryRecord: CustomStringConvertible {
    var description: String {
        switch kind {
        case let .queryResult(pid, windowIds, newContext):
            "ax_windows_query pid=\(pid) newContext=\(newContext) count=\(windowIds.count) windowIds=\(windowIds)"
        case let .countMismatch(pid, axCount, windowServerCount):
            "ax_window_count_mismatch pid=\(pid) ax=\(axCount) windowServer=\(windowServerCount)"
        }
    }
}

/// Bounded ring of AX windows-query trace records, mirroring
/// `RawAXNotificationRecorder`.
@MainActor
final class AXWindowsQueryRecorder {
    private static let defaultLimit = 256

    private let limit: Int
    private var nextSequence: UInt64 = 1
    private var records: [AXWindowsQueryRecord] = []

    init(limit: Int = defaultLimit) {
        self.limit = max(1, limit)
    }

    func append(_ kind: AXWindowsQueryRecord.Kind, timestamp: Date = Date()) {
        let record = AXWindowsQueryRecord(sequence: nextSequence, timestamp: timestamp, kind: kind)
        nextSequence += 1
        if records.count == limit {
            records.removeFirst()
        }
        records.append(record)
    }

    func dump() -> String {
        if records.isEmpty {
            return "ax windows query trace empty"
        }
        return records.map { "\($0.timestamp.ISO8601Format()) \($0.description)" }.joined(separator: "\n")
    }

    func reset() {
        records.removeAll(keepingCapacity: true)
        nextSequence = 1
    }
}
