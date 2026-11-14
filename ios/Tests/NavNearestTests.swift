import FlightCore
import Foundation
import Testing
@testable import Blueside

// 2027-01-15T08:00:00Z
private let fixTime = Date(timeIntervalSince1970: 1_800_000_000)
private let dallas = Coordinate(latitude: 32.8968, longitude: -97.0380)

private func fix(_ latitude: Double, _ longitude: Double) -> Position {
    Position(latitude: latitude, longitude: longitude, courseDegrees: -1, speedMetersPerSecond: -1,
             altitudeMeters: nil, timestamp: fixTime)!
}

@MainActor private func openModel() async throws -> NavModel {
    let model = NavModel()
    await model.use(NavFiles.bundledTest).value
    try #require(model.database != nil, "\(model.problem ?? "no reason given")")
    return model
}

@Suite @MainActor struct NavNearestTests {
    @Test func directToIsMagneticFromTheAircraft() {
        let here = fix(30.1945, -97.6699)
        let now = fixTime.addingTimeInterval(1)
        let direct = NavText.directTo(from: here, to: dallas, now: now)
        #expect(direct.distance == "165.4 NM")
        #expect(direct.bearing == NavText.bearing(Geo.initialBearing(from: here.coordinate, to: dallas),
                                                  from: here.coordinate, date: now))
        #expect(direct.bearing.hasSuffix("°M"))
    }

    @Test func directToShowsDashesWithNoFixOrAStaleOne() {
        let here = fix(30.1945, -97.6699)
        let none = NavText.directTo(from: nil, to: dallas, now: fixTime)
        #expect(none.distance == "---")
        #expect(none.bearing == "---")
        let stale = NavText.directTo(from: here, to: dallas, now: fixTime.addingTimeInterval(6))
        #expect(stale.distance == "---")
        #expect(stale.bearing == "---")
        // Five seconds is still live, as it is for the data strip.
        let edge = NavText.directTo(from: here, to: dallas, now: fixTime.addingTimeInterval(5))
        #expect(edge.bearing.hasSuffix("°M"))
    }

    @Test func bearingsAreMagneticWithNorthAs360() {
        let east = MagneticModel.declination(at: dallas, altitudeFt: 0, date: fixTime)
        #expect(east > 0 && east < 6)
        // A true bearing equal to the variation points at magnetic north, which is written 360.
        #expect(NavText.bearing(east, from: dallas, date: fixTime) == "360°M")
        #expect(NavText.bearing(east - 0.4, from: dallas, date: fixTime) == "360°M")
        #expect(NavText.bearing(east + 7.2, from: dallas, date: fixTime) == "007°M")
        #expect(NavText.bearing(east + 90, from: dallas, date: fixTime) == "090°M")
        #expect(NavText.bearing(.nan, from: dallas, date: fixTime) == "---")
        #expect(NavText.distance(.nan) == "---")
        #expect(NavText.distance(0.64) == "0.6 NM")
        #expect(NavText.clock(fixTime) == "08:00:00Z")
    }

    @Test func outsideTheModelYearsTheBearingIsTrueAndSaysSo() {
        let late = ISO8601DateFormatter().date(from: "2031-06-01T00:00:00Z")!
        #expect(NavText.bearing(270, from: dallas, date: late) == "270°T")
        #expect(NavText.bearing(359.6, from: dallas, date: late) == "360°T")
    }

    @Test func anApproximateFixGivesNoNumbers() async throws {
        let here = fix(30.20, -97.66)
        let direct = NavText.directTo(from: here, to: dallas, approximate: true, now: fixTime)
        #expect(direct.distance == "---" && direct.bearing == "---")
        let target = RouteWaypoint(kind: .airport, ident: "KDFW", name: "", coordinate: dallas)
        #expect(RouteLine.drawn(.direct(to: target, navCycle: ""), position: here, approximate: true, now: fixTime) == nil)
        let model = try await openModel()
        model.updateNearest(from: here, approximate: true, now: fixTime)
        let none = model.nearestList(position: here, approximate: true, now: fixTime)
        #expect(none.header == "Position is approximate: nearest airports not shown")
        #expect(none.rows.isEmpty)
        model.updateNearest(from: here, now: fixTime)
        // A rough fix far away must not reorder the list or give numbers.
        let rough = fix(32.9, -97.0)
        model.updateNearest(from: rough, approximate: true, now: fixTime)
        let kept = model.nearestList(position: rough, approximate: true, now: fixTime)
        #expect(kept.header == "Position is approximate. Order from 30°12.00′N 097°39.60′W at 15 Jan 08:00:00Z")
        #expect(kept.rows.map(\.airport.ident) == ["AUS", "EDC", "T82", "ANC"])
        #expect(kept.rows.allSatisfy { $0.distance == "---" && $0.bearing == "---" })
    }

    @Test func nearestKeepsItsLastOrderUnderALastKnownHeaderWhenTheFixGoesStale() async throws {
        let model = try await openModel()
        let here = fix(30.20, -97.66)
        model.updateNearest(from: here, now: fixTime)
        let live = model.nearestList(position: here, now: fixTime.addingTimeInterval(1))
        #expect(live.header == "Nearest airports from 30°12.00′N 097°39.60′W at 08:00:00Z")
        // Private fields, the heliport and the closed field are left out.
        #expect(live.rows.map(\.airport.ident) == ["AUS", "EDC", "T82", "ANC"])
        #expect(live.rows.allSatisfy { $0.distance.hasSuffix(" NM") && $0.bearing.hasSuffix("°M") })

        let later = fixTime.addingTimeInterval(6)
        model.updateNearest(from: here, now: later)
        let stale = model.nearestList(position: here, now: later)
        #expect(stale.header == "From last known position, 30°12.00′N 097°39.60′W at 15 Jan 08:00:00Z")
        #expect(stale.rows.map(\.airport.ident) == ["AUS", "EDC", "T82", "ANC"])
        #expect(stale.rows.allSatisfy { $0.distance == "---" && $0.bearing == "---" })

        model.updateNearest(from: nil, now: later)
        let gone = model.nearestList(position: nil, now: later)
        #expect(gone.header == "From last known position, 30°12.00′N 097°39.60′W at 15 Jan 08:00:00Z")
        #expect(gone.rows.map(\.airport.ident) == ["AUS", "EDC", "T82", "ANC"])
        #expect(gone.rows.allSatisfy { $0.distance == "---" && $0.bearing == "---" })
    }

    @Test func nearestWithNoFixEverSaysNoPosition() async throws {
        let model = try await openModel()
        model.updateNearest(from: nil, now: fixTime)
        let list = model.nearestList(position: nil, now: fixTime)
        #expect(list.header == "No position")
        #expect(list.rows.isEmpty)
    }

    @Test func aLiveFixDoesNotBorrowNumbersFromAnOldList() async throws {
        let model = try await openModel()
        model.updateNearest(from: fix(30.20, -97.66), now: fixTime)
        // A fix six seconds newer than the list, which never reached it, must not show the old distances.
        let moved = Position(latitude: 31, longitude: -97, courseDegrees: -1, speedMetersPerSecond: -1,
                             altitudeMeters: nil, timestamp: fixTime.addingTimeInterval(6))!
        let list = model.nearestList(position: moved, now: fixTime.addingTimeInterval(6))
        #expect(list.header == "From last known position, 30°12.00′N 097°39.60′W at 15 Jan 08:00:00Z")
        #expect(list.rows.allSatisfy { $0.distance == "---" })
    }

    @Test func theArrowTurnsFromTheAircraftsTrack() async throws {
        let model = try await openModel()
        let heading90 = Position(latitude: 30.20, longitude: -97.66, courseDegrees: 90, speedMetersPerSecond: 50,
                                 altitudeMeters: nil, timestamp: fixTime)!
        model.updateNearest(from: heading90, now: fixTime)
        let row = try #require(model.nearestList(position: heading90, now: fixTime).rows.first)
        let still = try #require(model.nearestList(position: fix(30.20, -97.66), now: fixTime).rows.first)
        // Flying east, an airport due north sits 90 degrees to the left of the nose.
        #expect(abs(try #require(row.turn) - (try #require(still.turn) - 90)) < 0.001)
        let stale = model.nearestList(position: nil, now: fixTime.addingTimeInterval(600)).rows
        #expect(stale.allSatisfy { $0.turn == nil })
    }

    @Test func placeAndStampReadPlainly() {
        #expect(NavText.degreesMinutes(Coordinate(latitude: 30.2, longitude: -97.66)) == "30°12.00′N 097°39.60′W")
        #expect(NavText.degreesMinutes(Coordinate(latitude: -5.004, longitude: 9.5)) == "05°00.24′S 009°30.00′E")
        #expect(NavText.stamp(fixTime) == "15 Jan 08:00:00Z")
    }

    @Test func aLiveFixBeforeAnyListSaysSoOnlyWhenThereIsNoFix() throws {
        let model = NavModel()
        // No database: nothing can be listed, and the header must not blame the position.
        let list = model.nearestList(position: fix(30.20, -97.66), now: fixTime)
        #expect(list.header == "Nearest airports not available")
        #expect(model.nearestList(position: nil, now: fixTime).header == "No position")
    }
}
