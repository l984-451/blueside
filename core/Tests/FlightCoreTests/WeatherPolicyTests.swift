import Foundation
import Testing
@testable import FlightCore

private let t0 = WeatherFixture.checked

@Suite struct WeatherStationValueTests {
    private func metar() throws -> Metar {
        var metar = try #require(try Metar.decode(try WeatherFixture.data("metars.json.gz")).first)
        metar.windDirection = 270
        metar.windVariable = false
        metar.windSpeedKt = 12
        metar.windGustKt = 20
        metar.temperatureC = 15.4
        metar.dewpointC = 12.6
        metar.visibilityMiles = 0.75
        metar.visibilityOrMore = false
        metar.ceilingFtAGL = 2500
        return metar
    }

    @Test func stationValueTextForEachChoice() throws {
        var m = try metar()
        let text = { (show: StationShow) in WeatherGeoJSON.stationValue(m, show: show) }
        #expect(text(.category) == "")
        #expect(text(.wind) == "12G20")
        #expect(text(.temperature) == "15°")
        #expect(text(.spread) == "3°")
        #expect(text(.visibility) == "0.75 SM")
        #expect(text(.ceiling) == "2500 ft")
        m.sky = [SkyLayer(cover: "FEW", baseFtAGL: 800), SkyLayer(cover: "BKN", baseFtAGL: 3500),
                 SkyLayer(cover: "OVC", baseFtAGL: 9000)]
        #expect(text(.sky) == "BKN 035")
        m.sky = [SkyLayer(cover: "FEW", baseFtAGL: 800), SkyLayer(cover: "SCT", baseFtAGL: 25000)]
        #expect(text(.sky) == "SCT 250")
        m.sky = [SkyLayer(cover: "OVX", baseFtAGL: 100)]
        #expect(text(.sky) == "VV 001")
        m.sky = [SkyLayer(cover: "CLR", baseFtAGL: nil)]
        #expect(text(.sky) == "CLR")
        m.sky = []
        #expect(text(.sky) == "")
        m.windSpeedKt = 0
        #expect(text(.wind) == "CALM")
        m.windSpeedKt = 4; m.windGustKt = nil; m.windVariable = true
        #expect(text(.wind) == "VRB 4")
        m.visibilityMiles = 10; m.visibilityOrMore = true; m.ceilingFtAGL = nil; m.dewpointC = nil
        #expect(text(.visibility) == "10+ SM")
        #expect(text(.ceiling) == "")
        #expect(text(.spread) == "")
    }

    @Test func generalMatchesPrintf() {
        for value in [0.0, 0.125, 0.25, 0.5, 0.75, 1, 1.5, 2.5, 3, 10, 15, 99.95, 123_456, -0.75, 0.0001] {
            #expect(WeatherText.general(value) == String(format: "%g", value))
        }
    }

    @Test func clockIsTheRadarPictureOrTheNewestCheck() {
        var data = WeatherData()
        data.checkedAt = [.metars: t0 - 60, .sigmets: t0]
        #expect(data.clock([.stations], at: t0) == t0 - 60)
        #expect(data.clock([.stations, .sigmets], at: t0) == t0)
        #expect(data.clock([.radar, .sigmets], at: t0) == nil)
        data.frames = [RadarLoopFrame(valid: t0 - 300, file: URL(fileURLWithPath: "/f.pmtiles"))]
        #expect(data.clock([.radar, .sigmets], at: t0) == t0 - 300)
    }

    @Test func switchesShowTheirOverlays() {
        var list = OverlayList(groups: [WeatherSwitches.withTfrs(AeronauticalLayers.layerGroup),
                                        WeatherSwitches.layerGroup])
        #expect(WeatherSwitches.shown(list).isEmpty)
        list.setOverlay("weather-airsigmet", on: true)
        list.setOverlay(WeatherSwitches.tfrsID, on: true)
        #expect(WeatherSwitches.shown(list) == [.gairmets, .sigmets, .cwas, .tfrs])
        #expect(WeatherSwitches.saved.isSuperset(of: AeronauticalLayers.groups.map(\.id) + [WeatherSwitches.tfrsID]))
    }
}

@Suite struct WeatherPolicyTests {
    @Test func fetchesOnlySourcesWhoseCheckTimeMovedOn() throws {
        let index = try WeatherIndex.decode(WeatherFixture.index(checked: t0))
        let all = WeatherPolicy.jobs(index: index, held: [:])
        #expect(all.map(\.source) == [.metars, .tafs, .sigmets, .gairmets, .pireps, .tfrs])
        #expect(all.first?.path == "wx/metars.json.gz" && all.first?.etag == nil)
        let held = ["metars": WeatherPolicy.Held(checkedAt: t0, etag: "a"),
                    "tafs": WeatherPolicy.Held(checkedAt: t0 - 60, etag: "b")]
        let some = WeatherPolicy.jobs(index: index, held: held)
        #expect(!some.contains { $0.source == .metars })
        #expect(some.first { $0.source == .tafs }?.etag == "b")
    }

    private func reason(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return WeatherPolicy.reason(error) }
    }

    @Test func repliesAreReadOrRefusedWithTheirWords() throws {
        let text = Data("[]".utf8)
        #expect(try WeatherPolicy.source(status: 304, body: Data(), isHeld: true) == .unchanged)
        #expect(try WeatherPolicy.source(status: 200, body: WeatherFixture.gzip(text), isHeld: false) == .file(text))
        #expect(reason { _ = try WeatherPolicy.source(status: 304, body: Data(), isHeld: false) } == "Server answered 304")
        #expect(reason { _ = try WeatherPolicy.source(status: 200, body: text, isHeld: false) } == "Not a gzip file")
        #expect(reason { _ = try WeatherPolicy.index(status: 500, body: Data()) } == "Server answered 500")
        #expect(reason { _ = try WeatherPolicy.index(status: 200, body: WeatherFixture.index(checked: t0, version: 2)) }
            == "Needs a newer app")
        #expect(reason { _ = try WeatherPolicy.index(status: 200, body: text) } == "File could not be read")
        #expect(reason { try WeatherPolicy.frame(status: 200, body: Data("PMTiles".utf8)) } == "Not a whole radar picture")
        #expect(WeatherPolicy.reason(CancellationError()) == "Timed out")
        #expect(WeatherPolicy.reason(URLError(.notConnectedToInternet)) == nil)
    }

    @Test func framePlanDropsStalePicturesAndFetchesOnlyTheNewest() throws {
        let times = [t0 - 600, t0 - 300, t0]
        let index = try WeatherIndex.decode(WeatherFixture.index(checked: t0, frames: times))
        let first = "f\(Int(times[0].timeIntervalSince1970)).pmtiles"
        let plan = WeatherPolicy.framePlan(index: index, now: t0 + 60, onDisk: [first, "old.pmtiles"])
        #expect(plan.delete == ["old.pmtiles"])
        #expect(plan.fetch.map(\.valid) == [t0])
        let newest = "f\(Int(t0.timeIntervalSince1970)).pmtiles"
        #expect(WeatherPolicy.framePlan(index: index, now: t0 + 60, onDisk: [newest]).fetch.isEmpty)
        #expect(WeatherPolicy.framePlan(index: index, now: t0 + 21 * 60, onDisk: []).fetch.isEmpty)
    }

    @Test func radarLoopFetchesTheLastHourAndCleansUpWhatItFetched() throws {
        let times = [t0 - 65 * 60, t0 - 50 * 60, t0 - 20 * 60, t0]
        let index = try WeatherIndex.decode(WeatherFixture.index(checked: t0, frames: times))
        let name = { (t: Date) in "f\(Int(t.timeIntervalSince1970)).pmtiles" }
        var loop = try #require(RadarLoop(index: index, now: t0 + 60))
        #expect(loop.frames.map(\.valid) == Array(times.dropFirst()))
        let fetch = loop.toFetch(onDisk: [name(t0)])
        #expect(fetch.map(\.valid) == [t0 - 50 * 60, t0 - 20 * 60])
        fetch.forEach { loop.kept($0) }
        #expect(loop.playable(onDisk: [name(t0), name(t0 - 20 * 60)]).map(\.valid) == [t0 - 20 * 60, t0])
        #expect(loop.cleanup(index: index) == [name(t0 - 50 * 60), name(t0 - 20 * 60)].sorted())
        // A pass during the loop keeps its pictures even once the index drops them.
        let later = try WeatherIndex.decode(WeatherFixture.index(checked: t0, frames: [t0]))
        #expect(WeatherPolicy.framePlan(index: later, now: t0, onDisk: [name(t0 - 50 * 60)], keeping: loop.names).delete.isEmpty)
        #expect(RadarLoop.hold(0, of: 3) == 0.5 && RadarLoop.hold(2, of: 3) == 1.5)
        #expect(!loop.isExpired(at: t0 + 29 * 60) && loop.isExpired(at: t0 + 31 * 60))
        #expect(RadarLoop.loading(2, of: 8) == "Loading 3 of 8")
        #expect(RadarLoop(index: index, now: t0 + 21 * 60) == nil)
    }

    @Test func radarBandsUseThePipelineFloors() {
        // pipeline/wxpipe/radar.py cuts bands at 5, 10 ... 70 dBZ.
        #expect(RadarStyle.bands.map(\.dbz) == Array(stride(from: 5.0, through: 70, by: 5)))
    }
}
