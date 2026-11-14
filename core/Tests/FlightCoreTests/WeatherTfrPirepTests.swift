import Foundation
import Testing
@testable import FlightCore

private let now = WeatherFixture.date("2026-10-13T00:35:00Z")

@Test func decodesEveryTfrAreaWithAltitudesAndTheirReference() throws {
    let tfrs = try Tfr.decode(WeatherFixture.data("tfrs.geojson.gz"))
    #expect(tfrs.count == 6)
    #expect(tfrs.map(\.notam) == ["6/9020", "6/8927", "6/8927", "6/8927", "6/8927", "0/0367"])
    let areaA = try #require(tfrs.first { $0.notam == "6/8927" && $0.name == "Area A" })
    #expect(areaA.kind == "VIP" && areaA.rule == "91.141" && areaA.facility == "ZSE")
    #expect(areaA.upper == TfrAltitude(value: 17999, unit: "FT", reference: "MSL"))
    #expect(areaA.upper?.text == "17999 FT MSL" && areaA.lower?.text == "SFC")
    #expect(tfrs[0].upper?.text == "2000 FT AGL")
    guard case .polygon(let ring)? = areaA.shape else {
        Issue.record("a drawn TFR area must be a polygon")
        return
    }
    #expect(ring.count == 73 && ring.first == ring.last)
    #expect(areaA.age(at: now) == 13 * 3600 + 39 * 60 + 3)
}

@Test func altitudeTextKeepsUnitAndReference() {
    #expect(TfrAltitude(value: 180, unit: "FL", reference: "MSL").text == "FL180")
    #expect(TfrAltitude(value: 0, unit: "FT", reference: "MSL").text == "0 FT MSL")
    #expect(TfrAltitude(value: 3000, unit: "FT", reference: "AGL").text == "3000 FT AGL")
}

@Test func aTfrIsUpcomingActiveOrExpiredByItsOwnTimes() throws {
    let tfrs = try Tfr.decode(WeatherFixture.data("tfrs.geojson.gz"))
    let areaA = try #require(tfrs.first { $0.name == "Area A" && $0.notam == "6/8927" })
    #expect(areaA.status(at: now) == .upcoming)
    #expect(areaA.status(at: WeatherFixture.date("2026-10-14T22:30:00Z")) == .active)
    #expect(areaA.status(at: WeatherFixture.date("2026-10-15T02:29:59Z")) == .active)
    #expect(areaA.status(at: WeatherFixture.date("2026-10-15T02:30:00Z")) == .expired)
}

@Test func aTfrWithNoExpiryAndNoDrawnAreaStaysActiveAndListed() throws {
    let tfrs = try Tfr.decode(WeatherFixture.data("tfrs.geojson.gz"))
    let standing = try #require(tfrs.first { $0.notam == "0/0367" })
    #expect(standing.shape == nil && standing.expires == nil && standing.upper == nil)
    #expect(standing.status(at: now) == .active)
    #expect(standing.status(at: WeatherFixture.date("2036-01-01T00:00:00Z")) == .active)
    #expect(standing.status(at: WeatherFixture.date("2019-01-01T00:00:00Z")) == .upcoming)
}

@Test func aNoticeWhoseDetailCouldNotBeReadIsListedAsUnreadable() throws {
    // As the weather job writes it: listed fields only, no shape, no times, no altitudes.
    let unread = #"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":null,"properties":{"notam":"6/1234","kind":"SECURITY","facility":"ZFW","state":"TX","title":"DALLAS, TX","rule":null,"issued":"2026-10-12T10:55:00Z","name":null,"upper_value":null,"upper_unit":null,"upper_ref":null,"lower_value":null,"lower_unit":null,"lower_ref":null,"effective":null,"expires":null,"unreadable":true}}]}"#
    let tfr = try #require(try Tfr.decode(Data(unread.utf8)).first)
    #expect(tfr.unreadable && tfr.shape == nil && tfr.title == "DALLAS, TX")
    #expect(WeatherGeoJSON.tfrsWithoutArea([tfr], now: now) == [tfr])
    #expect(try Tfr.decode(WeatherFixture.data("tfrs.geojson.gz")).allSatisfy { !$0.unreadable })
}

@Test func aTfrFileThatCannotBeReadOrIsEmptyIsAnError() {
    #expect(throws: WeatherError.unreadable("tfrs")) { try Tfr.decode(Data("<html>".utf8)) }
    #expect(throws: WeatherError.empty(.tfrs)) {
        try Tfr.decode(Data(#"{"type":"FeatureCollection","features":[]}"#.utf8))
    }
    // An area in a form that cannot be drawn fails the file; it is never listed as a notice with no area.
    let point = #"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[-100,40]},"properties":{"notam":"6/1","issued":"2026-10-12T10:55:57Z"}}]}"#
    #expect(throws: WeatherError.unreadable("tfrs")) { try Tfr.decode(Data(point.utf8)) }
}

@Test func decodesPilotReportsWithTheirObservationTime() throws {
    let reports = try Pirep.decode(WeatherFixture.data("pireps.json.gz"))
    #expect(reports.count == 122)
    #expect(reports.filter(\.urgent).count == 5)
    #expect(reports.filter { $0.altitudeFtMSL == nil }.count == 9)
    let den = try #require(reports.first { $0.raw.hasPrefix("DEN UA /OV DEN/TM 0024") })
    #expect(den.aircraft == "B38M" && den.turbulence == "NEG" && den.icing == nil && !den.urgent)
    #expect(den.observed == WeatherFixture.date("2026-10-13T00:24:00Z"))
    #expect(den.age(at: now) == 11 * 60)
    #expect(abs(den.coordinate.latitude - 39.8125) < 0.0001)
}

@Test func noPilotReportsIsAnEmptyListAndABrokenFileIsAnError() throws {
    #expect(try Pirep.decode(Data("[]".utf8)).isEmpty)
    #expect(throws: WeatherError.unreadable("pireps")) { try Pirep.decode(Data("oops".utf8)) }
}
