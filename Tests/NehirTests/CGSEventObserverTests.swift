// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@testable import Nehir
import Testing

@MainActor
private final class RecordingCGSEventDelegate: CGSEventDelegate {
    var events: [CGSWindowEvent] = []

    func cgsEventObserver(_: CGSEventObserver, didReceive event: CGSWindowEvent) {
        events.append(event)
    }
}

private func rawBytes<T>(of value: T) -> [UInt8] {
    withUnsafeBytes(of: value) { Array($0) }
}

private func createdPayload(spaceId: UInt64, windowId: UInt32) -> [UInt8] {
    rawBytes(of: spaceId) + rawBytes(of: windowId)
}

@MainActor
private func waitForMainRunLoopTurn() async {
    await withCheckedContinuation { continuation in
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            continuation.resume()
        }
        CFRunLoopWakeUp(mainRunLoop)
    }
}

@MainActor
private func waitUntilCGSEvents(
    iterations: Int = 100,
    condition: () -> Bool
) async {
    for _ in 0 ..< iterations where !condition() {
        await waitForMainRunLoopTurn()
    }

    if !condition() {
        Issue.record("Timed out waiting for scheduled CGS drain")
    }
}

@Suite(.serialized) struct CGSEventObserverTests {
    @Test @MainActor func malformedAndShortPayloadsAreDroppedSafely() async {
        await withCGSEventObserverIsolationForTests {
            let observer = CGSEventObserver.shared
            let recorder = RecordingCGSEventDelegate()
            observer.resetDebugStateForTests()
            observer.delegate = recorder
            defer {
                observer.delegate = nil
                observer.resetDebugStateForTests()
            }

            observer.ingestRawEventForTests(
                eventType: CGSEventType.windowMoved.rawValue,
                bytes: [0xAA, 0xBB, 0xCC]
            )
            observer.ingestRawEventForTests(
                eventType: CGSEventType.spaceWindowCreated.rawValue,
                bytes: Array(repeating: 0, count: 11)
            )
            observer.flushPendingCGSEventsForTests()

            #expect(recorder.events.isEmpty)
            #expect(observer.cgsDebugSnapshot().malformedPayloadDrops == 2)
        }
    }

    @Test @MainActor func rawPayloadsDecodeIntoTypedEvents() async {
        await withCGSEventObserverIsolationForTests {
            let observer = CGSEventObserver.shared
            let recorder = RecordingCGSEventDelegate()
            observer.resetDebugStateForTests()
            observer.delegate = recorder
            defer {
                observer.delegate = nil
                observer.resetDebugStateForTests()
            }

            observer.ingestRawEventForTests(
                eventType: CGSEventType.windowMoved.rawValue,
                bytes: rawBytes(of: UInt32(71))
            )
            observer.ingestRawEventForTests(
                eventType: CGSEventType.spaceWindowCreated.rawValue,
                bytes: createdPayload(spaceId: 55, windowId: 72)
            )
            observer.flushPendingCGSEventsForTests()

            #expect(recorder.events == [
                .frameChanged(windowId: 71),
                .created(windowId: 72, spaceId: 55)
            ])
        }
    }

    @Test @MainActor func frameChangedBurstCoalescesWhileTopologyRemainsFIFO() async {
        await withCGSEventObserverIsolationForTests {
            let observer = CGSEventObserver.shared
            let recorder = RecordingCGSEventDelegate()
            observer.resetDebugStateForTests()
            observer.delegate = recorder
            defer {
                observer.delegate = nil
                observer.resetDebugStateForTests()
            }

            observer.enqueueEventForTests(.created(windowId: 81, spaceId: 10))
            observer.enqueueEventForTests(.frameChanged(windowId: 81))
            observer.enqueueEventForTests(.frameChanged(windowId: 81))
            observer.enqueueEventForTests(.titleChanged(windowId: 81))
            observer.enqueueEventForTests(.frameChanged(windowId: 82))
            observer.flushPendingCGSEventsForTests()

            #expect(recorder.events == [
                .created(windowId: 81, spaceId: 10),
                .frameChanged(windowId: 81),
                .titleChanged(windowId: 81),
                .frameChanged(windowId: 82)
            ])

            let snapshot = observer.cgsDebugSnapshot()
            #expect(snapshot.coalescedFrameEvents == 1)
            #expect(snapshot.drainRuns == 1)
            #expect(snapshot.drainedEvents == 4)
        }
    }

    @Test @MainActor func closeClearsPendingFrameChangeBeforeDelivery() async {
        await withCGSEventObserverIsolationForTests {
            let observer = CGSEventObserver.shared
            let recorder = RecordingCGSEventDelegate()
            observer.resetDebugStateForTests()
            observer.delegate = recorder
            defer {
                observer.delegate = nil
                observer.resetDebugStateForTests()
            }

            observer.enqueueEventForTests(.frameChanged(windowId: 91))
            observer.enqueueEventForTests(.frameChanged(windowId: 92))
            observer.enqueueEventForTests(.closed(windowId: 91))
            observer.flushPendingCGSEventsForTests()

            #expect(recorder.events == [
                .frameChanged(windowId: 92),
                .closed(windowId: 91)
            ])
            #expect(observer.cgsDebugSnapshot().clearedFrameEventsOnDestroy == 1)
        }
    }

    @Test @MainActor func destroyClearsPendingFrameChangeBeforeDelivery() async {
        await withCGSEventObserverIsolationForTests {
            let observer = CGSEventObserver.shared
            let recorder = RecordingCGSEventDelegate()
            observer.resetDebugStateForTests()
            observer.delegate = recorder
            defer {
                observer.delegate = nil
                observer.resetDebugStateForTests()
            }

            observer.enqueueEventForTests(.frameChanged(windowId: 101))
            observer.enqueueEventForTests(.frameChanged(windowId: 102))
            observer.enqueueEventForTests(.destroyed(windowId: 101, spaceId: 44))
            observer.flushPendingCGSEventsForTests()

            #expect(recorder.events == [
                .frameChanged(windowId: 102),
                .destroyed(windowId: 101, spaceId: 44)
            ])
            #expect(observer.cgsDebugSnapshot().clearedFrameEventsOnDestroy == 1)
        }
    }

    @Test @MainActor func scheduledDrainProcessesOneBurstWithoutManualFlush() async {
        await withCGSEventObserverIsolationForTests {
            let observer = CGSEventObserver.shared
            let recorder = RecordingCGSEventDelegate()
            observer.resetDebugStateForTests()
            observer.delegate = recorder
            defer {
                observer.delegate = nil
                observer.resetDebugStateForTests()
            }

            observer.enqueueEventForTests(.created(windowId: 111, spaceId: 12))
            observer.enqueueEventForTests(.frameChanged(windowId: 111))
            observer.enqueueEventForTests(.frameChanged(windowId: 111))
            observer.enqueueEventForTests(.titleChanged(windowId: 111))

            await waitUntilCGSEvents {
                recorder.events.count == 3
            }

            #expect(recorder.events == [
                .created(windowId: 111, spaceId: 12),
                .frameChanged(windowId: 111),
                .titleChanged(windowId: 111)
            ])

            let snapshot = observer.cgsDebugSnapshot()
            #expect(snapshot.coalescedFrameEvents == 1)
            #expect(snapshot.drainRuns == 1)
            #expect(snapshot.drainedEvents == 3)
        }
    }
}
