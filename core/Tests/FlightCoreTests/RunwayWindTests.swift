import Foundation
import Testing
@testable import FlightCore

private func report(direction: Int?, speed: Int?, gust: Int? = nil, variable: Bool = false) -> Metar {
    Metar(station: "KXXX", coordinate: Coordinate(latitude: 0, longitude: 0), category: .unknown,
          ceilingFtAGL: nil, visibilityMiles: nil, visibilityOrMore: false,
          windDirection: direction, windVariable: variable, windSpeedKt: speed, windGustKt: gust,
          temperatureC: nil, dewpointC: nil, altimeterInHg: nil,
          observed: Date(timeIntervalSince1970: 0), raw: "")
}

/// A runway named like 18/36, with a true heading for each end in the order named.
private func runway(_ id: String, lengthFt: Int?, headings: [Int?]) -> Runway {
    let ends = zip(id.split(separator: "/"), headings).map { name, heading in
        RunwayEnd(id: String(name), trueHeading: heading, rightTraffic: nil, coordinate: nil, elevationFt: nil,
                  displacedThresholdFt: nil, vgsi: nil, approachLights: nil, toraFt: nil, ldaFt: nil)
    }
    return Runway(id: id, lengthFt: lengthFt, widthFt: nil, surface: nil, condition: nil, lights: nil, ends: ends)
}

private func near(_ value: Double?, _ expected: Double) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 0.01
}

private func realMetar(_ station: String) throws -> Metar {
    try #require(try Metar.decode(WeatherFixture.data("metars.json.gz")).first { $0.station == station })
}

private let crossing = [runway("09/27", lengthFt: 5000, headings: [90, 270]),
                        runway("18/36", lengthFt: 7000, headings: [180, 360])]

@Test func windIsSplitAlongAndAcrossTheRunwayInTrueDegrees() {
    let cases: [(wind: Int, speed: Int, heading: Int, head: Double, right: Double)] = [
        (180, 10, 180, 10, 0), (210, 20, 180, 17.32, 10), (150, 20, 180, 17.32, -10), (270, 15, 180, 0, 15),
        (360, 12, 180, -12, 0), (20, 20, 350, 17.32, 10), (350, 20, 20, 17.32, -10),
    ]
    for item in cases {
        let wind = report(direction: item.wind, speed: item.speed).runwayWind(trueHeading: item.heading)
        #expect(near(wind?.steady.headwindKt, item.head), "\(item)")
        #expect(near(wind?.steady.crosswindFromRightKt, item.right), "\(item)")
    }
}

@Test func realReportsGiveComponentsOnRealRunways() throws {
    // KAUS 13011KT on runway 18L, true heading 179.
    let kaus = try realMetar("KAUS")
    let airport = try #require(try navFixture.airport(identifier: "AUS"))
    let runways = try #require(try navFixture.detail(airportID: airport.id)).runways
    let end = try #require(runways.flatMap(\.ends).first { $0.id == "18L" })
    #expect(end.trueHeading == 179)
    let wind = try #require(kaus.runwayWind(trueHeading: end.trueHeading))
    #expect(near(wind.steady.headwindKt, 7.22) && near(wind.steady.crosswindFromRightKt, -8.30))
    #expect(wind.gust == nil)
    // Both 18s have the same wind, so the longer runway is picked.
    let best = try #require(kaus.bestRunwayEnd(of: runways))
    #expect(best.end.id == "18R" && best.runway.id == "18R/36L" && best.wind == wind)
}

@Test func aGustComponentIsGivenOnlyWhenTheReportHasAGust() throws {
    // KDEN 19018G26KT on a runway heading 170 true.
    let kden = try realMetar("KDEN")
    #expect(kden.windDirection == 190 && kden.windSpeedKt == 18 && kden.windGustKt == 26)
    let wind = try #require(kden.runwayWind(trueHeading: 170))
    #expect(near(wind.steady.headwindKt, 16.91) && near(wind.steady.crosswindFromRightKt, 6.16))
    #expect(near(wind.gust?.headwindKt, 24.43) && near(wind.gust?.crosswindFromRightKt, 8.89))
    let steadyOnly = try #require(report(direction: 190, speed: 18).runwayWind(trueHeading: 170))
    #expect(steadyOnly.gust == nil && steadyOnly.steady == wind.steady)
}

@Test func windWithoutOneDirectionGivesNoComponents() throws {
    let kgwb = try realMetar("KGWB")
    #expect(kgwb.windVariable && kgwb.runwayWind(trueHeading: 180) == nil)
    #expect(report(direction: nil, speed: 8, variable: true).runwayWind(trueHeading: 180) == nil)
    #expect(report(direction: nil, speed: 8).runwayWind(trueHeading: 180) == nil)
    #expect(report(direction: 200, speed: nil).runwayWind(trueHeading: 180) == nil)
    #expect(report(direction: 200, speed: -3).runwayWind(trueHeading: 180) == nil)
    #expect(report(direction: 200, speed: 8).runwayWind(trueHeading: nil) == nil)
    // Calm is known, so it has components, and both are zero.
    let calm = report(direction: 0, speed: 0).runwayWind(trueHeading: 180)
    #expect(calm?.steady.headwindKt == 0 && calm?.steady.crosswindFromRightKt == 0)
    #expect(calm != nil && calm?.gust == nil)
}

@Test func bestRunwayEndHasTheMostHeadwindThenTheLeastCrosswindThenTheMostLength() throws {
    #expect(report(direction: 200, speed: 10).bestRunwayEnd(of: crossing)?.end.id == "18")
    #expect(report(direction: 280, speed: 10).bestRunwayEnd(of: crossing)?.end.id == "27")
    #expect(report(direction: 20, speed: 10).bestRunwayEnd(of: crossing)?.end.id == "36")
    // Headwinds equal to a tenth of a knot: the smaller crosswind wins over the longer runway.
    let close = [runway("08/26", lengthFt: 9000, headings: [88, 268]),
                 runway("09/27", lengthFt: 4000, headings: [91, 271])]
    #expect(report(direction: 90, speed: 20).bestRunwayEnd(of: close)?.end.id == "09")
    // Equal wind on parallel runways: the longer one.
    let parallel = [runway("18L/36R", lengthFt: 9000, headings: [179, 359]),
                    runway("18R/36L", lengthFt: 12250, headings: [179, 359])]
    #expect(report(direction: 150, speed: 12).bestRunwayEnd(of: parallel)?.end.id == "18R")
    // A pad with one end is not a choice, and does not stop one.
    let withPad = crossing + [runway("H1", lengthFt: 40, headings: [nil])]
    #expect(report(direction: 200, speed: 10).bestRunwayEnd(of: withPad)?.end.id == "18")
    let pick = try #require(report(direction: 200, speed: 10, gust: 20).bestRunwayEnd(of: crossing))
    #expect(pick.runway.id == "18/36")
    #expect(near(pick.wind.steady.headwindKt, 9.40) && near(pick.wind.gust?.headwindKt, 18.79))
}

@Test func noRunwayIsPickedOnAGuess() {
    #expect(report(direction: 0, speed: 0).bestRunwayEnd(of: crossing) == nil)
    #expect(report(direction: nil, speed: 6, variable: true).bestRunwayEnd(of: crossing) == nil)
    #expect(report(direction: nil, speed: nil).bestRunwayEnd(of: crossing) == nil)
    #expect(report(direction: 200, speed: nil).bestRunwayEnd(of: crossing) == nil)
    #expect(report(direction: nil, speed: 10).bestRunwayEnd(of: crossing) == nil)
    // One runway without headings could be the better one, so nothing is picked.
    let partly = crossing + [runway("13/31", lengthFt: 6025, headings: [nil, nil])]
    #expect(report(direction: 200, speed: 10).bestRunwayEnd(of: partly) == nil)
    let half = [runway("13/31", lengthFt: 6025, headings: [130, nil])]
    #expect(report(direction: 130, speed: 10).bestRunwayEnd(of: half) == nil)
    #expect(report(direction: 200, speed: 10).bestRunwayEnd(of: [runway("H1", lengthFt: 40, headings: [nil])]) == nil)
    #expect(report(direction: 200, speed: 10).bestRunwayEnd(of: []) == nil)
    // A wind square across one runway favours neither end, whichever is listed first.
    let across = report(direction: 90, speed: 10)
    #expect(across.bestRunwayEnd(of: [runway("18/36", lengthFt: 5000, headings: [180, 360])]) == nil)
    #expect(across.bestRunwayEnd(of: [runway("36/18", lengthFt: 5000, headings: [360, 180])]) == nil)
    // A wind halfway between two equal runways favours neither, in either order.
    let equal = [runway("09/27", lengthFt: 5000, headings: [90, 270]),
                 runway("18/36", lengthFt: 5000, headings: [180, 360])]
    #expect(report(direction: 45, speed: 10).bestRunwayEnd(of: equal) == nil)
    #expect(report(direction: 45, speed: 10).bestRunwayEnd(of: equal.reversed()) == nil)
}

@Test func aTieStopsAPickOnlyWhenTheTiedEndsHaveDifferentWind() {
    let equal = [runway("09/27", lengthFt: 5000, headings: [90, 270]),
                 runway("18/36", lengthFt: 5000, headings: [180, 360])]
    // A third runway into the wind beats the two that tie.
    let into = runway("04/22", lengthFt: 3000, headings: [45, 225])
    #expect(report(direction: 45, speed: 10).bestRunwayEnd(of: equal + [into])?.end.id == "04")
    #expect(report(direction: 45, speed: 10).bestRunwayEnd(of: [into] + equal)?.end.id == "04")
    // Equal parallel runways have the same wind on both, so either is a sound answer.
    let twins = [runway("18L/36R", lengthFt: 9000, headings: [179, 359]),
                 runway("18R/36L", lengthFt: 9000, headings: [179, 359])]
    let pick = report(direction: 150, speed: 12).bestRunwayEnd(of: twins)
    #expect(pick?.end.id == "18L" && near(pick?.wind.steady.crosswindFromRightKt, -5.82))
    // The same pair with the wind square across still has no better end.
    #expect(report(direction: 89, speed: 12).bestRunwayEnd(of: twins) == nil)
}
