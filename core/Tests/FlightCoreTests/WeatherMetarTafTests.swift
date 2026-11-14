import Foundation
import Testing
@testable import FlightCore

private let now = WeatherFixture.date("2026-10-13T00:35:00Z")

@Test func decodesEveryMetarTheWorkerWrote() throws {
    let metars = try Metar.decode(WeatherFixture.data("metars.json.gz"))
    #expect(metars.count == 2547)
    let ktvf = try #require(metars.first { $0.station == "KTVF" })
    #expect(ktvf.category == .mvfr)
    #expect(ktvf.ceilingFtAGL == 1400)
    #expect(ktvf.sky == [SkyLayer(cover: "SCT", baseFtAGL: 700), SkyLayer(cover: "OVC", baseFtAGL: 1400)])
    #expect(ktvf.visibilityMiles == 10 && ktvf.visibilityOrMore)
    #expect(ktvf.windDirection == 40 && ktvf.windSpeedKt == 11 && ktvf.windGustKt == nil && !ktvf.windVariable)
    #expect(ktvf.temperatureC == 7 && ktvf.dewpointC == 6)
    #expect(abs((ktvf.altimeterInHg ?? 0) - 29.8) < 0.001)
    #expect(abs(ktvf.coordinate.latitude - 48.0597) < 0.0001 && abs(ktvf.coordinate.longitude + 96.1787) < 0.0001)
    #expect(ktvf.observed == WeatherFixture.date("2026-10-13T00:23:00Z"))
    #expect(ktvf.raw.hasPrefix("SPECI KTVF 130023Z"))
    #expect(ktvf.age(at: now) == 12 * 60)
}

@Test func aMissingFlightCategoryIsUnknownNeverVFR() throws {
    let metars = try Metar.decode(WeatherFixture.data("metars.json.gz"))
    #expect(metars.filter { $0.category == .unknown }.count == 72)
    #expect(metars.first { $0.station == "K40B" }?.category == .unknown)
    let odd = try Metar.decode(Data(#"[{"id":"KXXX","lat":1,"lon":2,"cat":"SVFR","t":"2026-10-13T00:23:00Z","raw":"x"}]"#.utf8))
    #expect(odd[0].category == .unknown)
    #expect(odd[0].visibilityMiles == nil && !odd[0].visibilityOrMore && odd[0].ceilingFtAGL == nil)
}

@Test func variableWindHasNoDirection() throws {
    let metars = try Metar.decode(WeatherFixture.data("metars.json.gz"))
    let kgwb = try #require(metars.first { $0.station == "KGWB" })
    #expect(kgwb.windVariable && kgwb.windDirection == nil && kgwb.windSpeedKt == 1)
}

@Test func aMetarFileThatCannotBeReadIsAnErrorAndNeverAnEmptyMap() throws {
    #expect(throws: WeatherError.unreadable("metars")) { try Metar.decode(Data("Service Unavailable".utf8)) }
    #expect(throws: WeatherError.empty(.metars)) { try Metar.decode(Data("[]".utf8)) }
    // Still compressed: the caller has to inflate a .gz file first.
    let packed = try Data(contentsOf: WeatherFixture.folder.appendingPathComponent("metars.json.gz"))
    #expect(throws: WeatherError.unreadable("metars")) { try Metar.decode(packed) }
    let tafs = try WeatherFixture.data("tafs.json.gz")
    #expect(throws: WeatherError.unreadable("metars")) { try Metar.decode(tafs) }
}

@Test func decodesTafsWithIssueTimeAndPeriod() throws {
    let tafs = try Taf.decode(WeatherFixture.data("tafs.json.gz"))
    #expect(tafs.count == 768)
    let kaus = try #require(tafs.first { $0.station == "KAUS" })
    #expect(kaus.issued == WeatherFixture.date("2026-10-12T23:38:00Z"))
    #expect(kaus.raw.hasPrefix("TAF KAUS 122338Z"))
    #expect(kaus.age(at: now) == 57 * 60)
    #expect(kaus.isValid(at: now))
    #expect(!kaus.isValid(at: WeatherFixture.date("2026-10-12T23:59:59Z")))
    #expect(!kaus.isValid(at: WeatherFixture.date("2026-10-14T06:00:00Z")))
}

@Test func aTafFileThatCannotBeReadIsAnError() {
    #expect(throws: WeatherError.unreadable("tafs")) { try Taf.decode(Data("{}".utf8)) }
    #expect(throws: WeatherError.empty(.tafs)) { try Taf.decode(Data("[]".utf8)) }
}
