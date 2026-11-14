import Foundation
import Testing
@testable import FlightCore

private let t0 = WeatherFixture.checked

private func held(_ sources: [WeatherSource], at time: Date) -> WeatherData {
    var data = WeatherData()
    for source in sources { data.checkedAt[source] = time }
    return data
}

private func pictures(_ times: [Date]) -> [RadarLoopFrame] {
    times.map { RadarLoopFrame(valid: $0, file: URL(fileURLWithPath: "/" + WeatherFixture.framePath($0))) }
}

@Suite struct WeatherInflateTests {
    @Test func inflatesAFileTheServerSends() throws {
        let inflated = try #require(Inflate.gunzip([UInt8](try WeatherFixture.raw("metars.json.gz"))))
        let metars = try Metar.decode(Data(inflated))
        #expect(metars.count == 2547)
        #expect(metars.first?.station == "KTVF")
    }

    @Test func roundTripsThroughTheTestWriter() {
        let text = Data(String(repeating: "weather ", count: 500).utf8)
        #expect(Inflate.gunzip([UInt8](WeatherFixture.gzip(text))) == [UInt8](text))
    }

    @Test func refusesBytesThatAreNotGzipOrAreCutShort() throws {
        #expect(Inflate.gunzip(Array("this is a web page, not a gzip file".utf8)) == nil)
        let whole = try WeatherFixture.raw("tafs.json.gz")
        #expect(Inflate.gunzip([UInt8](whole.prefix(whole.count / 2))) == nil)
        #expect(Inflate.gunzip([]) == nil)
    }

    @Test func sampleIndexDecodesWithTheCore() throws {
        let index = try WeatherIndex.decode(try WeatherFixture.raw("index.json"))
        #expect(index.checkedAt[.metars] == t0)
        #expect(index.frames.count == 1)
    }
}

@Suite struct WeatherDataTests {
    @Test(arguments: [14, 16, 29, 31])
    func labelsFollowEachSourcesLimit(minutes: Int) {
        let data = held([.metars, .sigmets, .gairmets, .cwas, .pireps, .tfrs, .winds], at: t0)
        let now = t0 + Double(minutes) * 60
        let labeled = WeatherOverlay.allCases.filter { ![.radar, .satellite, .lightning].contains($0) && data.staleLabel(for: $0, at: now) != nil }
        switch minutes {
        case 14: #expect(labeled.isEmpty)
        case 16, 29: #expect(labeled == [.stations, .sigmets, .gairmets, .cwas, .pireps])
        default: #expect(labeled == [.stations, .sigmets, .gairmets, .cwas, .tfrs, .pireps])
        }
    }

    @Test func labelIsTheFixedTextWithTheCheckTime() {
        let data = held([.metars, .tfrs], at: t0)
        #expect(data.staleLabel(for: .stations, at: t0 + 16 * 60) == "METARs not updated since 0035Z")
        #expect(data.staleLabel(for: .tfrs, at: t0 + 31 * 60) == "TFRs not updated since 0035Z")
        #expect(data.status(of: .metars, at: t0 + 16 * 60) == .notCurrent(since: t0))
    }

    @Test func halfHourSourceForTheAirportPageUsesTheSameText() {
        let data = held([.tafs], at: t0)
        func label(_ minutes: Double) -> String? {
            let now = t0 + minutes * 60
            return WeatherText.notUpdated("TAF", status: data.status(of: .tafs, at: now),
                                          time: data.time(of: .tafs), now: now)
        }
        #expect(label(29) == nil)
        #expect(label(31) == "TAF not updated since 0035Z")
    }

    @Test func nothingHeldIsUnknownAndSaysSo() {
        let data = WeatherData()
        for overlay in WeatherOverlay.allCases {
            #expect(data.status(of: overlay.source, at: t0) == .unknown)
            #expect(data.staleLabel(for: overlay, at: t0) == "\(overlay.name) not available")
        }
        #expect(data.age(of: .metars, at: t0) == nil)
    }

    @Test func checkTimeAheadOfTheClockIsUnknownNeverCurrent() {
        let data = held([.metars], at: t0 + 600)
        #expect(data.status(of: .metars, at: t0) == .unknown)
        #expect(data.staleLabel(for: .stations, at: t0) == "METARs dated 0045Z, ahead of this device's clock")
    }

    @Test func copyADayOldCarriesTheDayOfTheMonth() {
        let data = held([.metars], at: t0)
        #expect(data.staleLabel(for: .stations, at: t0 + 25 * 3600) == "METARs not updated since 130035Z")
    }

    @Test func copyFourWeeksOldOrMoreCarriesTheFullDate() {
        let data = held([.metars], at: t0)
        let day = 86_400.0
        #expect(data.staleLabel(for: .stations, at: t0 + 27 * day - 60) == "METARs not updated since 130035Z")
        #expect(data.staleLabel(for: .stations, at: t0 + 27 * day) == "METARs not updated since 2026-10-13 0035Z")
        // The same day of the month a month on, 25 minutes later in the day.
        #expect(data.staleLabel(for: .stations, at: t0 + 31 * day + 25 * 60)
            == "METARs not updated since 2026-10-13 0035Z")
    }

    @Test(arguments: ["2027-03-01T00:00:00Z", "2027-03-01T00:34:00Z", "2027-03-01T20:00:00Z"])
    func februaryCopyNeverReadsAsTodayOnTheSameDayOfMarch(now: String) {
        // 2027 has a 28-day February, so the 1st comes round again just over 27 days later.
        let data = held([.metars, .tfrs], at: WeatherFixture.date("2027-02-01T00:35:00Z"))
        let clock = WeatherFixture.date(now)
        #expect(data.staleLabel(for: .stations, at: clock) == "METARs not updated since 2027-02-01 0035Z")
        #expect(data.staleLabel(for: .tfrs, at: clock) == "TFRs not updated since 2027-02-01 0035Z")
    }

    @Test func checkTimeFarAheadOfTheClockCarriesTheFullDateToo() {
        // A phone clock set back: the copy's 1 March must not read as this 1 February.
        let data = held([.metars], at: WeatherFixture.date("2027-03-01T00:10:00Z"))
        #expect(data.staleLabel(for: .stations, at: WeatherFixture.date("2027-02-01T23:50:00Z"))
            == "METARs dated 2027-03-01 0010Z, ahead of this device's clock")
        // Within the allowance two clocks may differ by, it is current.
        #expect(held([.metars], at: t0 + 100).staleLabel(for: .stations, at: t0) == nil)
        #expect(held([.metars], at: t0 + 30 * 60).staleLabel(for: .stations, at: t0)
            == "METARs dated 0105Z, ahead of this device's clock")
    }

    @Test func loopIsJudgedByThePicturesOnDiskNotByOnesTheIndexOnlyNames() throws {
        // The index names a picture ahead of the phone clock that never reached the disk.
        var data = WeatherData()
        data.index = try WeatherIndex.decode(WeatherFixture.index(checked: t0, frames: [t0 - 600, t0 + 600]))
        data.frames = pictures([t0 - 600])
        #expect(data.index?.status(of: .radar, at: t0) == .unknown)
        #expect(data.status(of: .radar, at: t0) == .current)
        #expect(data.staleLabel(for: .radar, at: t0) == nil)
        #expect(data.radarLoop(at: t0).map(\.valid) == [t0 - 600])
        data.index = nil
        #expect(data.radarLoop(at: t0).map(\.valid) == [t0 - 600])
    }

    @Test(arguments: [-30, -3, 0, 10, 19, 21, 90], [nil, -10, 10, 40] as [Int?])
    func radarLoopIsEmptyExactlyWhenRadarCarriesALabel(clock: Int, indexNewest: Int?) throws {
        // Pictures end at t0; the clock and the newest picture the index names move around them.
        var data = WeatherData()
        data.frames = pictures([t0 - 600, t0 - 300, t0])
        if let indexNewest {
            let named = [t0 - 600, t0 - 300, t0, t0 + Double(indexNewest) * 60]
            data.index = try WeatherIndex.decode(WeatherFixture.index(checked: t0, frames: named))
        }
        let now = t0 + Double(clock) * 60
        #expect(data.radarLoop(at: now).isEmpty == (data.staleLabel(for: .radar, at: now) != nil))
    }

    @Test func pictureFarBehindTheNewestOnDiskIsLeftOutOfTheLoop() {
        var data = WeatherData()
        data.frames = pictures([t0 - 80 * 60, t0 - 70 * 60, t0])
        #expect(data.radarLoop(at: t0 + 60).map(\.valid) == [t0 - 70 * 60, t0])
        #expect(data.radarLoop(at: t0 + 21 * 60).isEmpty)
    }

    @Test func ageOfASourceIsMeasuredFromItsCheckTime() {
        #expect(held([.metars], at: t0).age(of: .metars, at: t0 + 90) == 90)
    }

    @Test func textForTimesAndAges() {
        #expect(WeatherText.zulu(t0) == "0035Z")
        #expect(WeatherText.zulu(t0, withDay: true) == "130035Z")
        #expect(WeatherText.dated(t0) == "2026-10-13 0035Z")
        #expect(WeatherText.age(13 * 60) == "13 min")
        #expect(WeatherText.age(65 * 60) == "1 h 05 min")
        #expect(WeatherText.age(-30) == "0 min")
        #expect(WeatherText.radarLegend.contains("no radar coverage"))
    }
}
