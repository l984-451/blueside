import Foundation
import Testing
@testable import FlightCore

@Suite struct SatelliteLightningTests {
    let t0 = WeatherFixture.checked

    private func index(satellite: Date, path: String? = nil) throws -> WeatherIndex {
        var object = try JSONSerialization.jsonObject(with: WeatherFixture.index(checked: t0, frames: [t0])) as! [String: Any]
        object["satellite"] = ["valid": ISO8601DateFormatter().string(from: satellite),
                               "path": path ?? "wx/satellite/s\(Int(satellite.timeIntervalSince1970)).pmtiles"]
        return try WeatherIndex.decode(JSONSerialization.data(withJSONObject: object))
    }

    @Test func theSampleIndexNamesASatellitePicture() throws {
        let index = try WeatherIndex.decode(try WeatherFixture.raw("index.json"))
        #expect(index.satellite?.path == "wx/satellite/20261013-003117.pmtiles")
        #expect(index.satellite?.source == .satellite)
    }

    @Test func aSatellitePathOutsideItsFolderIsRefused() {
        #expect(throws: WeatherError.self) { try index(satellite: t0, path: "wx/radar/x.pmtiles") }
        #expect(throws: WeatherError.self) { try index(satellite: t0, path: "wx/satellite/../x.pmtiles") }
    }

    @Test func theNewestSatellitePictureIsFetchedBesideRadarWhileCurrent() throws {
        let i = try index(satellite: t0 - 300)
        let sat = WeatherPolicy.frameName(try #require(i.satellite))
        #expect(sat.hasPrefix("satellite-"))
        let plan = WeatherPolicy.framePlan(index: i, now: t0 + 60, onDisk: ["satellite-old.pmtiles"])
        #expect(plan.delete == ["satellite-old.pmtiles"])
        #expect(plan.fetch.map(\.source) == [.radar, .satellite])
        #expect(WeatherPolicy.framePlan(index: i, now: t0 + 60, onDisk: [sat]).fetch.map(\.source) == [.radar])
        // Over 20 minutes old, neither is fetched.
        #expect(WeatherPolicy.framePlan(index: i, now: t0 + 21 * 60, onDisk: []).fetch.isEmpty)
    }

    @Test func satelliteIsDrawnOnlyWhileCurrentAndLabeledAfter() throws {
        var data = WeatherData()
        data.index = try index(satellite: t0)
        #expect(data.staleLabel(for: .satellite, at: t0 + 60) == "Satellite not updated since 0035Z")
        data.satellite = RadarLoopFrame(valid: t0, file: URL(fileURLWithPath: "/s.pmtiles"))
        #expect(data.staleLabel(for: .satellite, at: t0 + 60) == nil)
        #expect(data.satelliteShown(at: t0 + 60) != nil && data.clock([.satellite], at: t0 + 60) == t0)
        #expect(data.satelliteShown(at: t0 + 21 * 60) == nil)
        #expect(data.staleLabel(for: .satellite, at: t0 + 21 * 60) == "Satellite not updated since 0035Z")
    }

    @Test func lightningKeepsTheLastHalfHourWithItsAge() throws {
        let json = Data(#"[{"t":"2026-10-13T00:00:00Z","p":[[30,-90]]},{"t":"2026-10-13T00:30:00Z","p":[[35.12,-97.46],[36,-98]]}]"#.utf8)
        var data = WeatherData()
        try data.take(.lightning, json: json)
        #expect(data.lightning.map(\.flashes.count) == [1, 2])
        let geo = String(decoding: WeatherGeoJSON.overlay(.lightning, data, show: .category, now: t0), as: UTF8.self)
        // 35 minutes old is gone; 5 minutes old stays with its age.
        #expect(!geo.contains("-90"))
        #expect(geo.components(separatedBy: #""age_min":5"#).count == 3)
        #expect(throws: WeatherError.self) { try data.take(.lightning, json: Data("{}".utf8)) }
    }

    @Test func menuPutsSatelliteAfterRadarAndLightningAfterPireps() {
        let rows = LayerMenu.overlays.flatMap(\.rows)
        let at = { (id: String) in rows.firstIndex(of: .overlay(id))! }
        #expect(at("weather-satellite") == at("weather-radar") + 1)
        #expect(at("weather-lightning") == at("weather-pireps") + 1)
        #expect(WeatherSwitches.saved.isSuperset(of: ["weather-satellite", "weather-lightning"]))
    }
}
