// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// One recorded assignment to the interaction-monitor session state.
///
/// `WorkspaceManager` has multiple write sites for
/// `sessionState.interactionMonitorId` (and `previousInteractionMonitorId`).
/// This recorder captures each write directly (old→new + call-site reason) so
/// runtime traces can distinguish a real state write from a missing/stale
/// placement context. See
/// the `plans` branch: `completed/20260615-new-window-placement-investigation.md`.
struct InteractionMonitorWriteRecord: Equatable {
    let sequence: UInt64
    let timestamp: Date
    let field: Field
    let oldValue: Monitor.ID?
    let newValue: Monitor.ID?
    let reason: String

    enum Field: String {
        case interaction
        case previous
    }
}

extension InteractionMonitorWriteRecord: CustomStringConvertible {
    var description: String {
        let old = oldValue.map(String.init(describing:)) ?? "nil"
        let new = newValue.map(String.init(describing:)) ?? "nil"
        let arrow = oldValue == newValue ? "" : "→\(new)"
        return "\(timestamp.ISO8601Format()) \(field.rawValue)=\(old)\(arrow) reason=\(reason)"
    }
}

/// Bounded ring of interaction-monitor writes. Mirrors `ReconcileTraceRecorder`.
@MainActor
final class InteractionMonitorWriteRecorder {
    private static let defaultLimit = 256

    private let limit: Int
    private var nextSequence: UInt64 = 1
    private var records: [InteractionMonitorWriteRecord] = []

    init(limit: Int = defaultLimit) {
        self.limit = max(1, limit)
    }

    func append(
        field: InteractionMonitorWriteRecord.Field,
        oldValue: Monitor.ID?,
        newValue: Monitor.ID?,
        reason: String,
        timestamp: Date = Date()
    ) {
        let record = InteractionMonitorWriteRecord(
            sequence: nextSequence,
            timestamp: timestamp,
            field: field,
            oldValue: oldValue,
            newValue: newValue,
            reason: reason
        )
        nextSequence += 1
        if records.count == limit {
            records.removeFirst()
        }
        records.append(record)
    }

    func dump() -> String {
        if records.isEmpty {
            return "interaction monitor writes empty"
        }
        return records.map(\.description).joined(separator: "\n")
    }

    func reset() {
        records.removeAll(keepingCapacity: true)
        nextSequence = 1
    }
}
