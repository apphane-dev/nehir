import Foundation

struct ReconcileInvariantViolation: Equatable {
    let code: String
    let message: String

    var traceNote: String {
        "invariant[\(code)]=\(message)"
    }
}

struct ReconcileTxn: Equatable {
    let timestamp: Date
    let event: WMEvent
    let normalizedEvent: WMEvent
    let plan: ActionPlan
    let snapshot: ReconcileSnapshot
    let invariantViolations: [ReconcileInvariantViolation]
    /// `interactionMonitorId` as it was *before* `applyPlan` ran. The recorded
    /// `snapshot.interactionMonitorId` is post-apply, so without this the trace
    /// cannot observe a transient nil that reconcile immediately recovers —
    /// which is exactly the signal needed to locate the new-window placement
    /// nil-writer. See the `plans` branch: `completed/20260615-new-window-placement-investigation.md`.
    let preInteractionMonitorId: Monitor.ID?
}
