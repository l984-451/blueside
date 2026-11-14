import Foundation
import os
import Testing
import UIKit
@testable import Blueside

/// A session made at launch can finish its events before the system hands over the handler, or after.
@MainActor @Test func aSessionsHandlerIsCalledOnceWhicheverArrivesFirst() {
    let calls = OSAllocatedUnfairLock(initialState: [String]())
    let events = BackgroundEvents()
    let (first, second) = (UUID().uuidString, UUID().uuidString)

    events.application(.shared, handleEventsForBackgroundURLSession: first) { calls.withLock { $0.append(first) } }
    #expect(calls.withLock { $0 }.isEmpty)
    BackgroundEvents.finish(first)
    #expect(calls.withLock { $0 } == [first])

    BackgroundEvents.finish(second)
    events.application(.shared, handleEventsForBackgroundURLSession: second) { calls.withLock { $0.append(second) } }
    #expect(calls.withLock { $0 } == [first, second])

    // A finish from an earlier run, with no handler then, does not answer a later wake before its events.
    let third = UUID().uuidString
    BackgroundEvents.finish(third, at: Date() - BackgroundEvents.finishKept)
    events.application(.shared, handleEventsForBackgroundURLSession: third) { calls.withLock { $0.append(third) } }
    #expect(calls.withLock { $0 } == [first, second])
    BackgroundEvents.finish(third)
    #expect(calls.withLock { $0 } == [first, second, third])
}
