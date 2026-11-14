import FlightCore
import Foundation
import Testing
@testable import Blueside

@MainActor @Suite struct SavedRoutesListTests {
    @Test func aFlightAfterTheClockChangeReadsInTheOffsetThen() throws {
        let chicago = try #require(TimeZone(identifier: "America/Chicago"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z"))
        let offset = SavedRoutesList.localOffset(chicago, now: now)
        #expect(offset.seconds == -5 * 3600 && offset.secondsAfter == -6 * 3600)
        #expect(offset.nextChange == ISO8601DateFormatter().date(from: "2026-11-01T07:00:00Z"))
        let after = try #require(ISO8601DateFormatter().date(from: "2026-11-10T15:00:00Z"))
        #expect(offset.seconds(at: after) == -6 * 3600)
    }
}
