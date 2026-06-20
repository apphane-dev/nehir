// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct ReconcileTraceRecord: Equatable {
    let sequence: UInt64
    let timestamp: Date
    let event: WMEvent
    let normalizedEvent: WMEvent
    let plan: ActionPlan
    let snapshot: ReconcileSnapshot
    let invariantViolations: [ReconcileInvariantViolation]
    /// `interactionMonitorId` as it was *before* the reconcile transaction was
    /// applied. See `ReconcileTxn.preInteractionMonitorId` for why this exists.
    let preInteractionMonitorId: Monitor.ID?
}

@MainActor
final class ReconcileTraceRecorder {
    private static let defaultLimit = 256

    private let limit: Int
    private var nextSequence: UInt64 = 1
    private var records: [ReconcileTraceRecord] = []

    init(limit: Int = defaultLimit) {
        self.limit = max(1, limit)
    }

    func append(
        event: WMEvent,
        normalizedEvent: WMEvent? = nil,
        plan: ActionPlan,
        snapshot: ReconcileSnapshot,
        invariantViolations: [ReconcileInvariantViolation] = [],
        timestamp: Date = Date(),
        preInteractionMonitorId: Monitor.ID? = nil
    ) {
        let record = ReconcileTraceRecord(
            sequence: nextSequence,
            timestamp: timestamp,
            event: event,
            normalizedEvent: normalizedEvent ?? event,
            plan: plan,
            snapshot: snapshot,
            invariantViolations: invariantViolations,
            preInteractionMonitorId: preInteractionMonitorId
        )
        nextSequence += 1
        if records.count == limit {
            records.removeFirst()
        }
        records.append(record)
    }

    func append(transaction: ReconcileTxn) {
        append(
            event: transaction.event,
            normalizedEvent: transaction.normalizedEvent,
            plan: transaction.plan,
            snapshot: transaction.snapshot,
            invariantViolations: transaction.invariantViolations,
            timestamp: transaction.timestamp,
            preInteractionMonitorId: transaction.preInteractionMonitorId
        )
    }

    func snapshot() -> [ReconcileTraceRecord] {
        records
    }

    func reset() {
        records.removeAll(keepingCapacity: true)
        nextSequence = 1
    }
}
