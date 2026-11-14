import Testing
@testable import FlightCore

private let kaus = Coordinate(latitude: 30.1945, longitude: -97.6699)
private let kdfw = Coordinate(latitude: 32.8968, longitude: -97.0380)

@Test func distanceAustinToDallas() {
    #expect(abs(Geo.distanceNM(from: kaus, to: kdfw) - 165.436) < 0.01)
}

@Test func distanceToSamePointIsZero() {
    #expect(Geo.distanceNM(from: kaus, to: kaus) == 0)
}

@Test func distanceAcrossAntimeridianTakesShortWay() {
    let west = Coordinate(latitude: 0, longitude: 179.5)
    let east = Coordinate(latitude: 0, longitude: -179.5)
    #expect(abs(Geo.distanceNM(from: west, to: east) - 60.040) < 0.01)
    #expect(abs(Geo.initialBearing(from: west, to: east) - 90) < 0.001)
}

@Test func bearingAustinToDallas() {
    #expect(abs(Geo.initialBearing(from: kaus, to: kdfw) - 11.106) < 0.01)
}

@Test func bearingCardinalDirections() {
    let a = Coordinate(latitude: 30, longitude: -97)
    #expect(abs(Geo.initialBearing(from: a, to: Coordinate(latitude: 31, longitude: -97)) - 0) < 0.001)
    #expect(abs(Geo.initialBearing(from: Coordinate(latitude: 31, longitude: -97), to: a) - 180) < 0.001)
    #expect(abs(Geo.initialBearing(from: Coordinate(latitude: 0, longitude: 10), to: Coordinate(latitude: 0, longitude: 5)) - 270) < 0.001)
}

@Test func bearingIsNeverNegativeOr360() {
    let a = Coordinate(latitude: 30, longitude: -97)
    let northWest = Coordinate(latitude: 31, longitude: -98)
    let b = Geo.initialBearing(from: a, to: northWest)
    #expect(b >= 0 && b < 360)
}

@Test func nanCoordinateGivesNanDistance() {
    let bad = Coordinate(latitude: .nan, longitude: 0)
    #expect(Geo.distanceNM(from: bad, to: kaus).isNaN)
    #expect(Geo.distanceNM(from: kaus, to: bad).isNaN)
}
