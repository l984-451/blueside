import Foundation
import Testing
@testable import FlightCore

private let downtownAustin = Coordinate(latitude: 30.2672, longitude: -97.7431)

private func nearestIdents(_ count: Int, publicAirportsOnly: Bool) throws -> [String] {
    try navFixture.nearest(to: downtownAustin, count: count, publicAirportsOnly: publicAirportsOnly)
        .map(\.airport.ident)
}

private func detail(_ ident: String) throws -> AirportDetail {
    let airport = try #require(try navFixture.airport(identifier: ident))
    return try #require(try navFixture.detail(airportID: airport.id))
}

private func syntheticAirport(_ id: Int, _ ident: String, _ lat: Double, _ lon: Double) -> String {
    """
    INSERT INTO airports(id, site_no, ident, name, city, state, type, use, lat, lon, twr, status)
    VALUES (\(id), 'X\(id)', '\(ident)', 'TEST FIELD', 'NOWHERE', 'ZZ', 'A', 'PU', \(lat), \(lon), 'NON-ATCT', 'O');
    """
}

@Test func nearestIsOrderedByDistanceWithBearing() throws {
    // Every facility type is asked for here, so the hospital helipad comes first.
    let found = try navFixture.nearest(to: downtownAustin, count: 3, publicAirportsOnly: false)
    #expect(found.map(\.airport.ident) == ["68TX", "AUS", "TX05"])
    #expect(abs(found[0].distanceNM - 0.692) < 0.01)
    #expect(abs(found[0].bearingTrue - 41.88) < 0.1)
    #expect(abs(found[1].distanceNM - 5.785) < 0.01)
    #expect(found[1].distanceNM == Geo.distanceNM(from: downtownAustin, to: found[1].airport.coordinate))
    #expect(found[1].bearingTrue == Geo.initialBearing(from: downtownAustin, to: found[1].airport.coordinate))
}

@Test func nearestWidensUntilEnoughAreFound() throws {
    // T82 is 60 NM west, outside the first box.
    #expect(try nearestIdents(5, publicAirportsOnly: false) == ["68TX", "AUS", "TX05", "EDC", "T82"])
    #expect(try nearestIdents(6, publicAirportsOnly: false) == ["68TX", "AUS", "TX05", "EDC", "T82", "ANC"])
}

@Test func nearestLeavesOutClosedFacilities() throws {
    // TS01 is 27 NM north and closed indefinitely.
    let all = try nearestIdents(10, publicAirportsOnly: false)
    #expect(all.count == 6)
    #expect(!all.contains("TS01"))
}

@Test func nearestCanBeLimitedToPublicAirports() throws {
    #expect(try nearestIdents(10, publicAirportsOnly: true) == ["AUS", "EDC", "T82", "ANC"])
    // The helipad half a mile away and the private strip are passed over.
    #expect(try nearestIdents(1, publicAirportsOnly: true) == ["AUS"])
}

@Test func nearestIsNotFooledByABoxCorner() throws {
    // ZZ1 sits in the corner of the first box, 38 NM away. ZZ2 is 33 NM due north, just outside it.
    let path = try makeNavDatabase(extraSQL:
        syntheticAirport(101, "ZZ1", 0.45, -139.55) + syntheticAirport(102, "ZZ2", 0.55, -140.0))
    let found = try NavDatabase(path: path)
        .nearest(to: Coordinate(latitude: 0, longitude: -140), count: 1, publicAirportsOnly: true)
    #expect(found.map(\.airport.ident) == ["ZZ2"])
    #expect(abs(found[0].distanceNM - 33.022) < 0.01)
}

@Test func nearestWorksAcrossTheAntimeridian() throws {
    let path = try makeNavDatabase(extraSQL: syntheticAirport(103, "ZZ3", 51.9, 179.5))
    let found = try NavDatabase(path: path)
        .nearest(to: Coordinate(latitude: 51.9, longitude: -179.5), count: 1, publicAirportsOnly: true)
    #expect(found.map(\.airport.ident) == ["ZZ3"])
    #expect(abs(found[0].distanceNM - 37.047) < 0.01)
}

@Test func nearestWithNothingToAskForReturnsNothing() throws {
    #expect(try navFixture.nearest(to: downtownAustin, count: 0, publicAirportsOnly: false) == [])
    #expect(try navFixture.nearest(to: Coordinate(latitude: .nan, longitude: 0), count: 3, publicAirportsOnly: false) == [])
}

@Test func detailListsRunwaysLongestFirstWithTheirEnds() throws {
    let aus = try detail("AUS")
    #expect(aus.airport.ident == "AUS")
    #expect(aus.runways.map(\.id) == ["18R/36L", "18L/36R"])
    let long = aus.runways[0]
    #expect(long.lengthFt == 12250)
    #expect(long.widthFt == 150)
    #expect(long.surface == "CONC")
    #expect(long.condition == "GOOD")
    #expect(long.lights == "HIGH")
    #expect(long.ends.map(\.id) == ["18R", "36L"])
    let end = long.ends[0]
    #expect(end.trueHeading == 179)
    #expect(end.rightTraffic == true)
    #expect(long.ends[1].rightTraffic == false)
    let position = try #require(end.coordinate)
    #expect(abs(position.latitude - 30.21361613) < 1e-9)
    #expect(abs(position.longitude - -97.67936477) < 1e-9)
    #expect(end.elevationFt.map { abs($0 - 541.4) < 1e-9 } == true)
    #expect(end.displacedThresholdFt == nil)
    #expect(end.vgsi == "P4L")
    #expect(end.approachLights == "MALS")
    #expect(end.toraFt == 12250)
    #expect(end.ldaFt == 12250)
}

@Test func detailOrdersFrequenciesForAnAirportPage() throws {
    let aus = try detail("AUS")
    #expect(aus.frequencies.map { "\($0.kind.rawValue) \($0.frequency)" } == [
        "tower 121.0", "tower 118.225", "ground 121.9", "clearance 125.5", "atis 124.4",
        "approach 119.0", "approach 127.225", "unicom 122.95", "other 126.225",
    ])
    let tower = try #require(aus.frequencies.first)
    #expect(tower.use == "LCL/P")
    #expect(tower.callSign == "AUSTIN")
    #expect(tower.sector == nil)
    #expect(aus.frequencies[5].sector == "WEST")

    let t82 = try detail("T82")
    #expect(t82.frequencies.map { "\($0.kind.rawValue) \($0.frequency)" } == [
        "ctaf 122.7", "weather 120.0", "unicom 122.7", "other 134.2",
    ])
    #expect(t82.frequencies[0].remark == "RWY 14/32 MIRL PRESET LOW INTST; TO INCR INTST ACTVT - CTAF.")
    #expect(t82.frequencies[1].use == "T82 AWOS-3")
}

@Test func detailKeepsRemarksInPublishedOrder() throws {
    let aus = try detail("AUS")
    #expect(aus.remarks.map(\.seq) == [1, 8, 14])
    #expect(aus.remarks[0].text == "BIRD ACTIVITY ON & INVOF ARPT.")
    #expect(aus.remarks[0].tab == "AIRPORT")
    #expect(aus.remarks[0].field == "GENERAL_REMARK")
    #expect(aus.remarks[0].element == nil)

    let t82 = try detail("T82")
    #expect(t82.remarks.map(\.tab) == ["AIRPORT", "FUEL_TYPE", "RUNWAY_END"])
    #expect(t82.remarks[2].element == "14")
}

@Test func detailCopesWithMissingRunwayData() throws {
    let strip = try detail("TX05")
    #expect(strip.runways.map(\.id) == ["01/19"])
    #expect(strip.runways[0].condition == nil)
    #expect(strip.runways[0].lights == nil)
    #expect(strip.runways[0].ends.map(\.id) == ["01", "19"])
    #expect(strip.runways[0].ends[0].coordinate == nil)
    #expect(strip.runways[0].ends[0].trueHeading == nil)
    #expect(strip.runways[0].ends[0].rightTraffic == nil)
    #expect(strip.runways[0].ends[1].displacedThresholdFt == 200)
    #expect(strip.frequencies == [])

    let closed = try detail("TS01")
    #expect(closed.runways.map(\.id) == ["18/36"])
    #expect(closed.runways[0].ends == [])
    #expect(closed.remarks == [])

    let helipad = try detail("68TX")
    #expect(helipad.runways.map(\.id) == ["H1"])
    #expect(helipad.runways[0].lengthFt == 43)
}

@Test func frequencyKindFromANewerBuildReadsAsOther() throws {
    let path = try makeNavDatabase(extraSQL: """
        PRAGMA ignore_check_constraints = ON;
        INSERT INTO frequencies(airport_id, use, kind, freq) VALUES (4, 'NEW USE', 'not-known-yet', '123.0');
        """)
    let database = try NavDatabase(path: path)
    let strip = try #require(try database.airport(identifier: "TX05"))
    let frequencies = try #require(try database.detail(airportID: strip.id)).frequencies
    #expect(frequencies.map(\.kind) == [.other])
    #expect(frequencies.map(\.use) == ["NEW USE"])
}

@Test func detailForAnUnknownAirportIsNil() throws {
    #expect(try navFixture.detail(airportID: 9999) == nil)
}

@Test func directToUsesGeoOnAirportCoordinates() throws {
    let from = try #require(try navFixture.airport(identifier: "T82"))
    let to = try #require(try navFixture.airport(identifier: "AUS"))
    #expect(abs(Geo.distanceNM(from: from.coordinate, to: to.coordinate) - 64.363) < 0.01)
    #expect(abs(Geo.initialBearing(from: from.coordinate, to: to.coordinate) - 92.29) < 0.01)
}
