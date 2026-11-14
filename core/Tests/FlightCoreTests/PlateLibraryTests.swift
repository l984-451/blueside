import Foundation
import Testing
@testable import FlightCore

@Test func chartCodesFallIntoTheirGroups() {
    func group(_ code: String) -> Plate.Group {
        Plate(airport: "", icao: "", name: "", code: code, file: "", pages: 1).group
    }
    #expect(["IAP", "DP", "ODP", "STR", "MIN", "HOT"].map(group)
            == [.approaches, .departures, .departures, .arrivals, .other, .other])
}

@Test func aMissingPackOrFileGivesNothing() {
    #expect(PlateLibrary.index(URL(fileURLWithPath: "/nonexistent.sqlite")).isEmpty)
    #expect(PlateLibrary.pdf(Plate(airport: "AUS", icao: "", name: "", code: "APD", file: "NONE.PDF", pages: 1,
                                   pack: URL(fileURLWithPath: "/nonexistent.sqlite"))) == nil)
}

@Test func theSpecialUseAirspaceDateIsReadWhenTheFileCarriesIt() throws {
    #expect(try NavDatabase(path: makeNavDatabase()).metadata.suaSnapshot == nil)
    let dated = try NavDatabase(path: makeNavDatabase(extraSQL: "INSERT INTO meta VALUES ('sua_snapshot', '2026-09-28T13:54:26Z')"))
    #expect(dated.metadata.suaSnapshot == Date(timeIntervalSince1970: 1_790_603_666))
}

@Test func aGeoreferencedPlateDecodesItsPlanViewSketchAndInsets() throws {
    let json = #"""
    [{"airport":"BHM","icao":"KBHM","name":"ILS OR LOC RWY 06","code":"IAP","file":"00050IL6.PDF","pages":1,
      "geo":{"corners":[[-87.2,33.8],[-86.6,33.8],[-86.6,33.3],[-87.2,33.3]],"plan":[0.05,0.2,0.95,0.7],"sketch":[0.65,0.6,0.95,0.7],"insets":[[0.7,0.2,0.95,0.3]]}},
     {"airport":"BHM","icao":"KBHM","name":"AIRPORT DIAGRAM","code":"APD","file":"00050AD.PDF","pages":1}]
    """#
    let plates = try JSONDecoder().decode([Plate].self, from: Data(json.utf8))
    #expect(plates[1].geo == nil)
    let geo = try #require(plates[0].geo)
    #expect(geo.corners[0] == [-87.2, 33.8])
    let masks = geo.masksInPlan
    #expect(masks.count == 2)
    #expect(zip(masks[0], [2.0 / 3, 0.8, 1, 1]).allSatisfy { abs($0 - $1) < 1e-9 })
    #expect(zip(masks[1], [13.0 / 18, 0, 1, 0.2]).allSatisfy { abs($0 - $1) < 1e-9 })
}

@Test func aPagePointRoundTripsThroughTheEarthAndSkipsTheMasks() throws {
    // A slightly skewed quad so the inverse cannot lean on an axis-aligned shortcut.
    let geo = PlateGeo(corners: [[-87.2, 33.8], [-86.6, 33.82], [-86.58, 33.3], [-87.21, 33.28]],
                       plan: [0.05, 0.2, 0.95, 0.7], sketch: [0.65, 0.6, 0.95, 0.7], insets: [[0.7, 0.2, 0.95, 0.3]])
    for (x, y) in [(0.1, 0.25), (0.5, 0.45), (0.9, 0.55), (0.3, 0.68)] {
        let at = try #require(geo.coordinate(pageX: x, pageY: y))
        let back = try #require(geo.pagePoint(at))
        #expect(abs(back[0] - x) < 1e-9 && abs(back[1] - y) < 1e-9)
    }
    #expect(geo.pagePoint(try #require(geo.coordinate(pageX: 0.8, pageY: 0.65))) == nil)
    #expect(geo.pagePoint(try #require(geo.coordinate(pageX: 0.8, pageY: 0.25))) == nil)
    #expect(geo.coordinate(pageX: 0.5, pageY: 0.1) == nil)
    #expect(geo.pagePoint(Coordinate(latitude: 34.5, longitude: -86.9)) == nil)
}
