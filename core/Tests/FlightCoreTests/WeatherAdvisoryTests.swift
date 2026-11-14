import Foundation
import Testing
@testable import FlightCore

private let now = WeatherFixture.date("2026-10-13T00:35:00Z")

@Test func decodesSigmetsAsAreasWithTheirPeriod() throws {
    let sigmets = try Sigmet.decode(WeatherFixture.data("sigmets.geojson.gz"))
    #expect(sigmets.count == 6)
    let first = sigmets[0]
    #expect(first.hazard == "CONVECTIVE" && first.severity == "SEV" && first.kind == "SIGMET")
    #expect(first.topFtMSL == 28000 && first.baseFtMSL == nil)
    #expect(first.raw.contains("CONVECTIVE SIGMET 54W"))
    guard case .polygon(let ring) = first.shape else {
        Issue.record("a SIGMET must be an area")
        return
    }
    #expect(ring.count == 5 && ring.first == ring.last)
    #expect(abs(ring[0].latitude - 41.894) < 0.0001 && abs(ring[0].longitude + 112.275) < 0.0001)
    #expect(first.age(at: now) == 40 * 60)
}

@Test func decodesCwasAsAreasShownInsideTheirPeriod() throws {
    let cwas = try Cwa.decode(WeatherFixture.data("cwas.geojson.gz"))
    #expect(cwas.count == 2)
    let first = cwas[0]
    #expect(first.center == "ZAB" && first.series == "107" && first.hazard == "IFR" && first.qualifier == "WDSPRD LIFR")
    #expect(first.raw.hasPrefix("FAUS21 KZAB 130023") && first.baseFtMSL == nil)
    guard case .polygon(let ring) = first.shape else {
        Issue.record("a CWA must be an area")
        return
    }
    #expect(ring.count == 7 && ring.first == ring.last)
    #expect(cwas.valid(at: now).map(\.center) == ["ZAB"])
    #expect(cwas.valid(at: WeatherFixture.date("2026-10-13T02:15:00Z")).map(\.center) == ["ZME"])
    #expect(try Cwa.decode(Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)).isEmpty)
    #expect(throws: WeatherError.unreadable("cwas")) { try Cwa.decode(Data("[]".utf8)) }
    let geo = String(decoding: WeatherGeoJSON.cwas(cwas, now: now), as: UTF8.self)
    #expect(geo.contains(#""title":"ZAB CWA 107""#) && geo.contains(#""label":"ZAB CWA 107 IFR\nto 0215Z""#))
}

@Test func sigmetsAreShownOnlyInsideTheirPeriod() throws {
    let sigmets = try Sigmet.decode(WeatherFixture.data("sigmets.geojson.gz"))
    #expect(sigmets.valid(at: now).count == 6)
    #expect(sigmets.valid(at: WeatherFixture.date("2026-10-12T23:54:59Z")).isEmpty)
    #expect(sigmets.valid(at: WeatherFixture.date("2026-10-13T01:54:59Z")).count == 6)
    #expect(sigmets.valid(at: WeatherFixture.date("2026-10-13T01:55:00Z")).isEmpty)
}

@Test func noSigmetsIsAnEmptyListAndABrokenFileIsAnError() throws {
    #expect(try Sigmet.decode(Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)).isEmpty)
    #expect(throws: WeatherError.unreadable("sigmets")) { try Sigmet.decode(Data("Bad Gateway".utf8)) }
    #expect(throws: WeatherError.unreadable("sigmets")) { try Sigmet.decode(Data(#"{"type":"Feature","features":[]}"#.utf8)) }
    #expect(throws: WeatherError.unreadable("sigmets")) { try Sigmet.decode(Data("[]".utf8)) }
    let point = #"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[-100,40]},"properties":{"hazard":"CONVECTIVE","from":"2026-10-12T23:55:00Z","to":"2026-10-13T01:55:00Z","raw":"x"}}]}"#
    #expect(throws: WeatherError.unreadable("sigmets")) { try Sigmet.decode(Data(point.utf8)) }
    let undrawn = point.replacingOccurrences(of: #"{"type":"Point","coordinates":[-100,40]}"#, with: "null")
    #expect(throws: WeatherError.unreadable("sigmets")) { try Sigmet.decode(Data(undrawn.utf8)) }
}

@Test func decodesGAirmetsKeepingLinesAsLines() throws {
    let all = try GAirmet.decode(WeatherFixture.data("gairmets.geojson.gz"))
    #expect(all.count == 148)
    let lines = all.filter { if case .line = $0.shape { true } else { false } }
    #expect(lines.count == 31)
    let line = try #require(lines.first)
    #expect(line.hazard == "FZLVL" && line.level == "16000" && line.base == nil && line.severity == nil)
    guard case .line(let points) = line.shape else { return }
    #expect(points.count == 15 && points.first != points.last)
    let area = all[0]
    #expect(area.product == "TANGO" && area.tag == "4W" && area.hazard == "TURB-HI" && area.severity == "MOD")
    #expect(area.base == "34000" && area.top == "45000" && area.dueTo == "MTN WAVE")
    #expect(area.issued == WeatherFixture.date("2026-10-12T22:18:00Z"))
    #expect(area.age(at: now) == 137 * 60)
}

@Test func onlyTheGAirmetSnapshotForNowIsShown() throws {
    let all = try GAirmet.decode(WeatherFixture.data("gairmets.geojson.gz"))
    let current = all.valid(at: now)
    #expect(current.count == 29)
    #expect(current.allSatisfy { $0.valid == WeatherFixture.date("2026-10-13T00:00:00Z") })
    // Between an issue and its first snapshot time the first snapshot is shown, never an empty map.
    let first = WeatherFixture.date("2026-10-12T21:00:00Z")
    let early = all.valid(at: WeatherFixture.date("2026-10-12T20:50:00Z"))
    #expect(early.count == 31)
    #expect(early.allSatisfy { $0.valid == first })
    #expect(all.valid(at: WeatherFixture.date("2026-10-12T18:00:00Z")).count == 31)
    #expect(all.valid(at: WeatherFixture.date("2026-10-12T17:59:59Z")).isEmpty)
    #expect(all.valid(at: first).count == 31)
    #expect(all.valid(at: WeatherFixture.date("2026-10-13T02:59:59Z")).count == 29)
    #expect(all.valid(at: WeatherFixture.date("2026-10-13T03:00:00Z")).count == 27)
    #expect(all.valid(at: WeatherFixture.date("2026-10-13T11:59:59Z")).count == 32)
    #expect(all.valid(at: WeatherFixture.date("2026-10-13T12:00:00Z")).isEmpty)
}

@Test func aBrokenGAirmetFileIsAnError() {
    #expect(throws: WeatherError.unreadable("gairmets")) { try GAirmet.decode(Data()) }
    #expect(throws: WeatherError.unreadable("gairmets")) { try GAirmet.decode(Data(#"{"features":[]}"#.utf8)) }
    // Freezing level lines are part of every issue, so an empty file is a broken one, never a quiet day.
    #expect(throws: WeatherError.empty(.gairmets)) {
        try GAirmet.decode(Data(#"{"type":"FeatureCollection","features":[]}"#.utf8))
    }
}
