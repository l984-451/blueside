import Foundation
import Testing
@testable import FlightCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func fix(knots: Double?, at time: Date = t0) -> Position? {
    Position(latitude: 30.2, longitude: -97.7, courseDegrees: 90,
             speedMetersPerSecond: knots.map { $0 / 1.943844 } ?? -1, altitudeMeters: nil, timestamp: time)
}

private func rule(_ position: Position?, lastFast: Date? = nil, heard: Date? = nil,
                  now: Date = t0) -> (until: Date?, lastFast: Date?) {
    BackgroundPolicy.runsUntil(position: position, lastFast: lastFast, receiverHeard: heard, now: now)
}

@Suite struct BackgroundPolicyTests {
    @Test func onTheGroundWithNoReceiverTheAppSleeps() {
        #expect(rule(nil).until == nil)
        #expect(rule(fix(knots: 29.9)).until == nil)
        #expect(rule(fix(knots: nil)).until == nil)
        #expect(rule(fix(knots: 29.9)).lastFast == nil)
    }

    @Test func aFixAtFlyingSpeedKeepsItRunningFiveMinutes() {
        let first = rule(fix(knots: 30))
        #expect(first.lastFast == t0)
        #expect(first.until == t0 + 300)
        // An old fix seen only now, such as a cached one at launch, does not count.
        #expect(rule(fix(knots: 120, at: t0 - 600)).until == nil)
    }

    @Test func aGapInTheFixesKeepsItRunning() throws {
        let fast = rule(fix(knots: 120))
        // Thirty seconds later the same fix is stale, or the receiver's fix is gone.
        for position in [fix(knots: 120), nil] {
            let later = rule(position, lastFast: fast.lastFast, now: t0 + 30)
            #expect(later.until == t0 + 300)
            #expect(try #require(later.until) > t0 + 30)
        }
    }

    @Test func slowingDownLetsItSleepFiveMinutesAfterTheLastFastFix() {
        let fast = rule(fix(knots: 120))
        let slow = rule(fix(knots: 12, at: t0 + 60), lastFast: fast.lastFast, now: t0 + 60)
        #expect(slow.lastFast == t0)
        #expect(slow.until == t0 + 300)
    }

    @Test func aReceiverKeepsItRunningForAMinuteAfterItIsLastHeard() {
        #expect(rule(fix(knots: 0), heard: t0).until == t0 + 60)
        // The later of the two holds.
        #expect(rule(fix(knots: 120), heard: t0 - 300).until == t0 + 300)
        #expect(rule(fix(knots: 0), lastFast: t0 - 290, heard: t0).until == t0 + 60)
    }
}
