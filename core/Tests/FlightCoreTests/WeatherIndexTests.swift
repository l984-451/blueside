import Foundation
import Testing
@testable import FlightCore

private let wrote = WeatherFixture.date("2026-10-13T00:35:00Z")

private func index(_ checked: String, frames: String = "[]", version: Int = 1) throws -> WeatherIndex {
    try WeatherIndex.decode(Data(#"{"version":\#(version),"checked_at":\#(checked),"frames":\#(frames)}"#.utf8))
}

@Test func sourcesTheWorkerJustCheckedAreCurrent() throws {
    let index = try WeatherIndex.decode(WeatherFixture.data("index.json"))
    #expect(index.status(of: .metars, at: wrote) == .current)
    #expect(index.status(of: .tafs, at: wrote) == .current)
}

@Test func metarsStopBeingCurrentAfterFifteenMinutesAndTafsAfterThirty() throws {
    let index = try WeatherIndex.decode(WeatherFixture.data("index.json"))
    #expect(index.status(of: .metars, at: wrote.addingTimeInterval(15 * 60)) == .current)
    #expect(index.status(of: .metars, at: wrote.addingTimeInterval(15 * 60 + 1)) == .notCurrent(since: wrote))
    #expect(index.status(of: .tafs, at: wrote.addingTimeInterval(30 * 60)) == .current)
    #expect(index.status(of: .tafs, at: wrote.addingTimeInterval(30 * 60 + 1)) == .notCurrent(since: wrote))
}

@Test func onlyTafsAndTfrsAllowThirtyMinutes() throws {
    for source in [WeatherSource.metars, .sigmets, .gairmets, .pireps] {
        #expect(source.currentFor == 15 * 60)
    }
    #expect(WeatherSource.tafs.currentFor == 30 * 60)
    #expect(WeatherSource.tfrs.currentFor == 30 * 60)
    #expect(WeatherSource.radar.currentFor == 20 * 60)
    let sigmets = try index(#"{"sigmets":"2026-10-13T00:35:00Z"}"#)
    #expect(sigmets.status(of: .sigmets, at: wrote.addingTimeInterval(15 * 60)) == .current)
    #expect(sigmets.status(of: .sigmets, at: wrote.addingTimeInterval(15 * 60 + 1)) == .notCurrent(since: wrote))
}

@Test func aSourceThatNeverSucceededIsUnknown() throws {
    #expect(try index(#"{"metars":null}"#).status(of: .metars, at: wrote) == .unknown)
    #expect(try index("{}").status(of: .tfrs, at: wrote) == .unknown)
}

@Test func aCheckDatedAheadOfTheClockIsUnknown() throws {
    #expect(try index(#"{"metars":"2026-10-13T00:38:00Z"}"#).status(of: .metars, at: wrote) == .unknown)
    // Two minutes are allowed for a phone clock that runs a little behind the server.
    #expect(try index(#"{"metars":"2026-10-13T00:36:00Z"}"#).status(of: .metars, at: wrote) == .current)
}

@Test func radarGoesByItsNewestFrameAndHidesAfterTwentyMinutes() throws {
    let frames = #"[{"valid":"2026-10-13T00:26:36Z","path":"wx/radar/20261013-002636.pmtiles"},{"valid":"2026-10-13T00:21:40Z","path":"wx/radar/20261013-002140.pmtiles"}]"#
    let radar = try index(#"{"radar":"2026-10-13T00:35:00Z"}"#, frames: frames)
    let newest = WeatherFixture.date("2026-10-13T00:26:36Z")
    #expect(radar.frames.map(\.valid).last == newest)
    #expect(radar.frames[0].age(at: newest) == 296)
    #expect(radar.status(of: .radar, at: newest.addingTimeInterval(20 * 60)) == .current)
    #expect(radar.radarLoop(at: newest.addingTimeInterval(20 * 60)).count == 2)
    #expect(radar.status(of: .radar, at: newest.addingTimeInterval(20 * 60 + 1)) == .notCurrent(since: newest))
    #expect(radar.radarLoop(at: newest.addingTimeInterval(20 * 60 + 1)).isEmpty)
    #expect(try index(#"{"radar":"2026-10-13T00:35:00Z"}"#).status(of: .radar, at: wrote) == .unknown)
}

@Test func aFrameHoursBehindTheNewestIsLeftOutOfTheLoop() throws {
    let frames = #"[{"valid":"2026-10-12T21:26:36Z","path":"wx/radar/20261012-212636.pmtiles"},{"valid":"2026-10-13T00:26:36Z","path":"wx/radar/20261013-002636.pmtiles"}]"#
    let loop = try index("{}", frames: frames).radarLoop(at: wrote)
    #expect(loop.map(\.path) == ["wx/radar/20261013-002636.pmtiles"])
}

@Test func aCachedFileIsJudgedByTheCheckItWasFetchedUnder() throws {
    // The newest index says 00:35, but the file on the phone came down under the 00:00 check.
    let newest = try index(#"{"tfrs":"2026-10-13T00:35:00Z"}"#)
    let held = WeatherFixture.date("2026-10-13T00:00:00Z")
    let now = WeatherFixture.date("2026-10-13T00:36:00Z")
    #expect(newest.status(of: .tfrs, at: now) == .current)
    #expect(WeatherSource.tfrs.status(checkedAt: held, at: now) == .notCurrent(since: held))
    #expect(WeatherSource.tfrs.status(checkedAt: nil, at: now) == .unknown)
}

@Test func theSampleIndexCarriesOneRadarFrame() throws {
    let index = try WeatherIndex.decode(WeatherFixture.data("index.json"))
    #expect(index.frames.map(\.path) == ["wx/radar/20261013-002636.pmtiles"])
    #expect(index.status(of: .radar, at: wrote) == .current)
    #expect(index.radarLoop(at: wrote).count == 1)
    #expect(index.radarLoop(at: WeatherFixture.date("2026-10-13T00:46:37Z")).isEmpty)
    // The sample index predates winds; drop the filter once wxpipe's fixture carries them.
    for source in WeatherSource.allCases where source != .winds {
        #expect(index.status(of: source, at: wrote) == .current)
    }
}

@Test func anIndexThatCannotBeReadIsATypedError() {
    #expect(throws: WeatherError.unreadable("index")) { try WeatherIndex.decode(Data("<html>".utf8)) }
    #expect(throws: WeatherError.unreadable("index")) { try WeatherIndex.decode(Data()) }
    #expect(throws: WeatherError.unsupportedVersion(2)) { try index("{}", version: 2) }
    #expect(throws: WeatherError.unreadable("index")) {
        try index("{}", frames: #"[{"valid":"2026-10-13T00:26:36Z","path":"../manifest.json"}]"#)
    }
}
