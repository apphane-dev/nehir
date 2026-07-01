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
///
/// `queryResult` entries are logged on every `getWindowsAsync()` call and can
/// be frequent (e.g. during a `pid_reevaluation`/focus-driven churn burst),
/// while `countMismatch` entries are rare and are the more actionable signal.
/// The two kinds are kept in independently-capped buffers so a burst of
/// query-result logging can never evict a mismatch record.
@MainActor
final class AXWindowsQueryRecorder {
    private static let defaultLimit = 256

    private let queryResultLimit: Int
    private let countMismatchLimit: Int
    private var nextSequence: UInt64 = 1
    private var queryResults: [AXWindowsQueryRecord] = []
    private var countMismatches: [AXWindowsQueryRecord] = []

    init(queryResultLimit: Int = defaultLimit, countMismatchLimit: Int = defaultLimit) {
        self.queryResultLimit = max(1, queryResultLimit)
        self.countMismatchLimit = max(1, countMismatchLimit)
    }

    func append(_ kind: AXWindowsQueryRecord.Kind, timestamp: Date = Date()) {
        let record = AXWindowsQueryRecord(sequence: nextSequence, timestamp: timestamp, kind: kind)
        nextSequence += 1
        switch kind {
        case .queryResult:
            Self.appendBounded(record, to: &queryResults, limit: queryResultLimit)
        case .countMismatch:
            Self.appendBounded(record, to: &countMismatches, limit: countMismatchLimit)
        }
    }

    func dump() -> String {
        let combined = (queryResults + countMismatches).sorted { $0.sequence < $1.sequence }
        if combined.isEmpty {
            return "ax windows query trace empty"
        }
        return combined.map { "\($0.timestamp.ISO8601Format()) \($0.description)" }.joined(separator: "\n")
    }

    func reset() {
        queryResults.removeAll(keepingCapacity: true)
        countMismatches.removeAll(keepingCapacity: true)
        nextSequence = 1
    }

    private static func appendBounded(
        _ record: AXWindowsQueryRecord,
        to records: inout [AXWindowsQueryRecord],
        limit: Int
    ) {
        if records.count == limit {
            records.removeFirst()
        }
        records.append(record)
    }
}
