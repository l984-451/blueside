import Foundation
import Testing
@testable import FlightCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func fix(course: Double = 90, speed: Double = 50, altitude: Double? = 1000) -> Position? {
    Position(latitude: 30.2, longitude: -97.7, courseDegrees: course,
             speedMetersPerSecond: speed, altitudeMeters: altitude, timestamp: t0)
}

@Test func convertsUnits() throws {
    let p = try #require(fix())
    #expect(p.coordinate == Coordinate(latitude: 30.2, longitude: -97.7))
    #expect(p.trackTrue == 90)
    let speed = try #require(p.groundspeedKt)
    let altitude = try #require(p.altitudeFtMSL)
    #expect(abs(speed - 97.192) < 0.01)
    #expect(abs(altitude - 3280.84) < 0.01)
}

// iOS reports unknown course and speed as -1.
@Test func negativeCourseAndSpeedBecomeNil() throws {
    let p = try #require(fix(course: -1, speed: -1))
    #expect(p.trackTrue == nil)
    #expect(p.groundspeedKt == nil)
}

@Test func missingAltitudeStaysNil() throws {
    let p = try #require(fix(altitude: nil))
    #expect(p.altitudeFtMSL == nil)
}

// The geoid lies below the ellipsoid over Texas, so MSL is the higher number.
@Test func ellipsoidAltitudeGoesThroughTheGeoid() throws {
    func at(_ latitude: Double, _ longitude: Double, msl: Double?, ellipsoid: Double?) -> Position? {
        Position(latitude: latitude, longitude: longitude, courseDegrees: 0, speedMetersPerSecond: 0,
                 altitudeMeters: msl, ellipsoidAltitudeMeters: ellipsoid, timestamp: t0)
    }
    let geoid = try #require(Geoid.height(latitude: 30.2, longitude: -97.7))
    let feet = try #require(at(30.2, -97.7, msl: nil, ellipsoid: 1000)?.altitudeFtMSL)
    #expect(abs(feet - (1000 - geoid) * 3.28084) < 0.001)
    #expect(feet > 1020 * 3.28084)
    #expect(at(30.2, -97.7, msl: 900, ellipsoid: 1000)?.altitudeFtMSL == 900 * 3.28084)
    // Outside the table an ellipsoid height stays unknown rather than passing as MSL.
    let london = try #require(at(51.5, -0.1, msl: nil, ellipsoid: 100))
    #expect(london.altitudeFtMSL == nil)
}

@Test func rejectsUnusableCoordinates() {
    let bad: [(Double, Double)] = [(.nan, 0), (0, .nan), (91, 0), (-91, 0), (0, 181), (0, -181), (.infinity, 0)]
    for (lat, lon) in bad {
        #expect(Position(latitude: lat, longitude: lon, courseDegrees: 0,
                         speedMetersPerSecond: 0, altitudeMeters: nil, timestamp: t0) == nil)
    }
}

@Test func staleAfterFiveSeconds() throws {
    let p = try #require(fix())
    #expect(!p.isStale(at: t0))
    #expect(!p.isStale(at: t0.addingTimeInterval(5)))
    #expect(p.isStale(at: t0.addingTimeInterval(5.1)))
}

// A clock that stepped backwards must not keep a frozen fix looking live.
@Test func fixFarInTheFutureIsStale() throws {
    let p = try #require(fix())
    #expect(!p.isStale(at: t0.addingTimeInterval(-2)))
    #expect(p.isStale(at: t0.addingTimeInterval(-30)))
}
