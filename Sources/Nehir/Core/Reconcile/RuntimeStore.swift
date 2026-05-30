import Foundation

@MainActor
final class RuntimeStore {
    private let planner: Planner
    private let traceRecorder: ReconcileTraceRecorder
    private let nowProvider: () -> Date

    init(
        traceRecorder: ReconcileTraceRecorder,
        planner: Planner = Planner(),
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.traceRecorder = traceRecorder
        self.planner = planner
        self.nowProvider = nowProvider
    }

    @discardableResult
    func transact(
        event: WMEvent,
        existingEntry: WindowModel.Entry?,
        monitors: [Monitor],
        snapshot: () -> ReconcileSnapshot,
        applyPlan: (ActionPlan, WindowToken?) -> ActionPlan
    ) -> ReconcileTxn {
        let currentSnapshot = snapshot()
        let normalizedEvent = EventNormalizer.normalize(
            event: event,
            existingEntry: existingEntry,
            monitors: monitors
        )
        let plan = planner.plan(
            event: normalizedEvent,
            existingEntry: existingEntry,
            currentSnapshot: currentSnapshot,
            monitors: monitors
        )
        let resolvedPlan = applyPlan(plan, normalizedEvent.token)
        return record(
            event: event,
            normalizedEvent: normalizedEvent,
            plan: resolvedPlan,
            snapshot: snapshot()
        )
    }

    @discardableResult
    func record(
        event: WMEvent,
        normalizedEvent: WMEvent? = nil,
        plan: ActionPlan,
        snapshot: ReconcileSnapshot
    ) -> ReconcileTxn {
        let invariantViolations = InvariantChecks.validate(snapshot: snapshot)
        var tracedPlan = plan
        if !invariantViolations.isEmpty {
            tracedPlan.notes.append(contentsOf: invariantViolations.map(\.traceNote))
        }

        let txn = ReconcileTxn(
            timestamp: nowProvider(),
            event: event,
            normalizedEvent: normalizedEvent ?? event,
            plan: tracedPlan,
            snapshot: snapshot,
            invariantViolations: invariantViolations
        )
        traceRecorder.append(transaction: txn)
        return txn
    }
}
