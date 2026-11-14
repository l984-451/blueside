import CoreLocation
import FlightCore
import Foundation
import Testing
@testable import Blueside

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func location(at time: Date, speed: Double = 50) -> CLLocation {
    CLLocation(coordinate: CLLocationCoordinate2D(latitude: 32.9, longitude: -97.04), altitude: 1000,
               horizontalAccuracy: 5, verticalAccuracy: 5, course: 52, speed: speed, timestamp: time)
}

// Does what the app does at each deadline until `end`, and returns how many looks it took.
@MainActor private func walk(_ provider: LocationProvider, from start: Date, to end: Date,
                             asked: (Date) -> Void = { _ in }) -> Int {
    var t = start
    var looks = 0
    while let next = provider.nextCheck(now: t), next < end {
        t = max(next, t)
        if provider.shouldAskAgain(now: t) {
            provider.askedAgain(now: t)
            asked(t)
        }
        provider.recheck(now: t)
        looks += 1
    }
    return looks
}

@Suite @MainActor struct LocationDeadlineTests {
    @Test func aLiveFixIsLookedAtWhenTheSystemWouldBeQuietOrTheFixStale() throws {
        let provider = LocationProvider()
        provider.receive(location(at: now), now: now)
        #expect(provider.nextCheck(now: now) == now + LocationProvider.quietLimit + NextChange.past)
        // With access off nothing is asked again, so only the fix going stale is waited for.
        provider.report(stationary: false, accessOff: true, now: now)
        let fix = try #require(provider.position)
        #expect(provider.nextCheck(now: now) == fix.staleAt)
        provider.recheck(now: fix.staleAt)
        #expect(provider.isStale)
        #expect(provider.nextCheck(now: fix.staleAt) == nil)
    }

    @Test func aHeldFixStaysLiveWithALookEveryFewSeconds() throws {
        let provider = LocationProvider()
        provider.receive(location(at: now, speed: 0), now: now)
        provider.report(stationary: true, accessOff: false, now: now + 1)
        let looks = walk(provider, from: now + 1, to: now + 61)
        #expect(looks <= 24, "\(looks) looks in a minute")
        #expect(try #require(provider.position).isStale(at: now + 61) == false)
    }

    @Test func aStreamThatBringsNoFixIsAskedLessAndLessOften() {
        let provider = LocationProvider()
        provider.report(stationary: false, accessOff: false, now: now)
        var asks: [Date] = []
        _ = walk(provider, from: now, to: now + 120) { asks.append($0) }
        let gaps = zip([now] + asks, asks).map { $1.timeIntervalSince($0).rounded(.down) }
        #expect(gaps == [2, 4, 8, 16, 30, 30])
        // A fix starts the count again.
        provider.receive(location(at: now + 100), now: now + 100)
        #expect(provider.nextCheck(now: now + 100) == now + 100 + LocationProvider.quietLimit + NextChange.past)
    }

    @Test func aLookOverdueAfterAGapIsDueAtOnce() throws {
        let provider = LocationProvider()
        provider.receive(location(at: now, speed: 0), now: now)
        provider.report(stationary: true, accessOff: false, now: now + 1)
        // The stream ended while the app was away for ten minutes.
        provider.streamEnded(now: now + 600)
        let next = try #require(provider.nextCheck(now: now + 600))
        #expect(next <= now + 600)
        #expect(provider.shouldAskAgain(now: now + 600))
    }
}
