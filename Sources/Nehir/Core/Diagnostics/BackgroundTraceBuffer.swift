// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

enum BackgroundTraceCategory: String, CaseIterable, Sendable {
    case viewport
    case resize
    case insertion
    case mouse
    case runtime
}

struct BackgroundTraceBufferStatus: Equatable, Sendable {
    var isEnabled: Bool
    var retainedStart: Date?
    var retainedEnd: Date?
    var eventCount: Int
    var estimatedBytes: Int
    var maxBytes: Int
    var retentionSeconds: TimeInterval
}

struct BackgroundTraceEvent: Sendable {
    let timestamp: Date
    let monotonicNanos: UInt64
    let category: BackgroundTraceCategory
    let estimatedBytes: Int
    let text: String
}

struct BackgroundTraceDraft: Identifiable, Sendable {
    typealias ID = UUID

    let id: ID
    let createdAt: Date
    let retainedStart: Date?
    let retainedEnd: Date?
    let retainedEstimatedBytes: Int
    let events: [BackgroundTraceEvent]
    let sourceHadTimeEviction: Bool
    let sourceHadByteEviction: Bool
}

struct BackgroundTraceClip: Sendable {
    let draft: BackgroundTraceDraft
    let marker: Date
    let requestedLookback: TimeInterval
    let requestedTail: TimeInterval
    let selectedStart: Date
    let selectedEnd: Date
    let events: [BackgroundTraceEvent]
    let truncatedByTimeRetention: Bool
    let truncatedByByteCap: Bool
    let estimatedBytes: Int

    var categoryCounts: [BackgroundTraceCategory: Int] {
        Dictionary(grouping: events, by: \.category).mapValues(\.count)
    }
}

struct BackgroundTraceBuffer {
    private(set) var events: [BackgroundTraceEvent] = []
    private(set) var estimatedBytes: Int = 0
    private(set) var maxBytes: Int
    private(set) var retentionSeconds: TimeInterval
    private(set) var hasEvictedForTime = false
    private(set) var hasEvictedForByteCap = false

    private let perEventMaxBytes: Int

    init(
        maxBytes: Int = 64 * 1024 * 1024,
        retentionSeconds: TimeInterval = 0,
        perEventMaxBytes: Int = 16 * 1024
    ) {
        self.maxBytes = max(1, maxBytes)
        self.retentionSeconds = max(0, retentionSeconds)
        self.perEventMaxBytes = max(128, perEventMaxBytes)
    }

    var retainedStart: Date? {
        events.first?.timestamp
    }

    var retainedEnd: Date? {
        events.last?.timestamp
    }

    mutating func configure(maxBytes: Int, retentionSeconds: TimeInterval, now: Date = Date()) {
        self.maxBytes = max(1, maxBytes)
        self.retentionSeconds = max(0, retentionSeconds)
        evictIfNeeded(now: now)
    }

    mutating func clear(keepingCapacity: Bool = true) {
        events.removeAll(keepingCapacity: keepingCapacity)
        estimatedBytes = 0
        hasEvictedForTime = false
        hasEvictedForByteCap = false
    }

    mutating func append(
        category: BackgroundTraceCategory,
        text: String,
        timestamp: Date = Date(),
        monotonicNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let normalized = normalizedEventText(text)
        let byteCount = max(1, normalized.utf8.count + 1)
        let event = BackgroundTraceEvent(
            timestamp: timestamp,
            monotonicNanos: monotonicNanos,
            category: category,
            estimatedBytes: byteCount,
            text: normalized
        )
        events.append(event)
        estimatedBytes += byteCount
        evictIfNeeded(now: timestamp)
    }

    func status(isEnabled: Bool) -> BackgroundTraceBufferStatus {
        BackgroundTraceBufferStatus(
            isEnabled: isEnabled,
            retainedStart: retainedStart,
            retainedEnd: retainedEnd,
            eventCount: events.count,
            estimatedBytes: estimatedBytes,
            maxBytes: maxBytes,
            retentionSeconds: retentionSeconds
        )
    }

    func makeDraft(now: Date = Date()) -> BackgroundTraceDraft? {
        guard !events.isEmpty else { return nil }
        return BackgroundTraceDraft(
            id: UUID(),
            createdAt: now,
            retainedStart: retainedStart,
            retainedEnd: retainedEnd,
            retainedEstimatedBytes: estimatedBytes,
            events: events,
            sourceHadTimeEviction: hasEvictedForTime,
            sourceHadByteEviction: hasEvictedForByteCap
        )
    }

    static func selectClip(
        from draft: BackgroundTraceDraft,
        marker: Date,
        lookback: TimeInterval,
        tail: TimeInterval
    ) -> BackgroundTraceClip {
        let requestedStart = marker.addingTimeInterval(-max(0, lookback))
        let requestedEnd = marker.addingTimeInterval(max(0, tail))
        let selectedEvents = draft.events.filter { event in
            event.timestamp >= requestedStart && event.timestamp <= requestedEnd
        }
        let selectedStart = selectedEvents.first?.timestamp ?? maxDate(
            requestedStart,
            draft.retainedStart ?? requestedStart
        )
        let selectedEnd = selectedEvents.last?.timestamp ?? minDate(requestedEnd, draft.retainedEnd ?? requestedEnd)
        let selectedBytes = selectedEvents.reduce(0) { $0 + $1.estimatedBytes }
        let retainedStart = draft.retainedStart ?? requestedStart
        let truncatedByTime = draft.sourceHadTimeEviction && requestedStart < retainedStart
        let truncatedByByte = draft.sourceHadByteEviction && requestedStart <= retainedStart

        return BackgroundTraceClip(
            draft: draft,
            marker: marker,
            requestedLookback: max(0, lookback),
            requestedTail: max(0, tail),
            selectedStart: selectedStart,
            selectedEnd: selectedEnd,
            events: selectedEvents,
            truncatedByTimeRetention: truncatedByTime,
            truncatedByByteCap: truncatedByByte,
            estimatedBytes: selectedBytes
        )
    }

    private mutating func evictIfNeeded(now: Date) {
        if retentionSeconds > 0 {
            let cutoff = now.addingTimeInterval(-retentionSeconds)
            var removedAny = false
            while let first = events.first, first.timestamp < cutoff {
                estimatedBytes -= first.estimatedBytes
                events.removeFirst()
                removedAny = true
            }
            if removedAny { hasEvictedForTime = true }
        }

        var removedForBytes = false
        while estimatedBytes > maxBytes, let first = events.first {
            estimatedBytes -= first.estimatedBytes
            events.removeFirst()
            removedForBytes = true
        }
        if removedForBytes { hasEvictedForByteCap = true }
        estimatedBytes = max(0, estimatedBytes)
    }

    private func normalizedEventText(_ text: String) -> String {
        let byteCount = text.utf8.count
        guard byteCount > perEventMaxBytes else { return text }
        return "[background trace event truncated: \(byteCount) bytes > \(perEventMaxBytes) bytes]"
    }

    private static func maxDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs >= rhs ? lhs : rhs
    }

    private static func minDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs <= rhs ? lhs : rhs
    }
}
