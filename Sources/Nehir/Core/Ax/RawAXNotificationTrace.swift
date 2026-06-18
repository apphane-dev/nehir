import Foundation

/// One entry in the raw AX notification trace ring.
///
/// Records every AX notification the per-app observers deliver, *before* the
/// `destroyed`/`miniaturized` filter discards anything. Exists to diagnose
/// close/hide/order-out sequences where the triggering event is otherwise
/// invisible — see
/// the `plans` branch: `completed/20260615-quick-terminal-close-switches-workspace.md`.
struct RawAXNotificationRecord: Equatable {
    let sequence: UInt64
    let timestamp: Date
    /// Bare notification name as delivered by the observer, e.g.
    /// `FocusedWindowChanged`, `UIElementDestroyed`, `WindowMiniaturized`.
    let name: String
    let pid: pid_t
    /// Window id when recoverable (window observer encodes it in its refcon).
    /// `nil` for app-level notifications such as `FocusedWindowChanged`, whose
    /// observer carries no refcon.
    let windowId: Int?
}

extension RawAXNotificationRecord: CustomStringConvertible {
    var description: String {
        let window = windowId.map(String.init) ?? "nil"
        return "\(timestamp.ISO8601Format()) ax=\(name) pid=\(pid) window=\(window)"
    }
}

/// Bounded ring of raw AX notifications, mirroring `ReconcileTraceRecorder`.
///
/// Always records (human-paced, bounded) so the ring is populated whenever a
/// runtime trace capture is taken; `dump()` is only emitted into a capture on
/// demand. The reference is constant; `append`/`reset` mutate internal state.
@MainActor
final class RawAXNotificationRecorder {
    private static let defaultLimit = 256

    private let limit: Int
    private var nextSequence: UInt64 = 1
    private var records: [RawAXNotificationRecord] = []

    init(limit: Int = defaultLimit) {
        self.limit = max(1, limit)
    }

    func append(name: String, pid: pid_t, windowId: Int?, timestamp: Date = Date()) {
        let record = RawAXNotificationRecord(
            sequence: nextSequence,
            timestamp: timestamp,
            name: name,
            pid: pid,
            windowId: windowId
        )
        nextSequence += 1
        if records.count == limit {
            records.removeFirst()
        }
        records.append(record)
    }

    func dump() -> String {
        if records.isEmpty {
            return "ax notification trace empty"
        }
        return records.map(\.description).joined(separator: "\n")
    }

    func reset() {
        records.removeAll(keepingCapacity: true)
        nextSequence = 1
    }
}
