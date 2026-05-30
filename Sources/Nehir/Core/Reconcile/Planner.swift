import Foundation

struct Planner {
    func plan(
        event: WMEvent,
        existingEntry: WindowModel.Entry?,
        currentSnapshot: ReconcileSnapshot,
        monitors: [Monitor]
    ) -> ActionPlan {
        StateReducer.reduce(
            event: event,
            existingEntry: existingEntry,
            currentSnapshot: currentSnapshot,
            monitors: monitors
        )
    }
}
