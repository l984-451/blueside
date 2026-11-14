import Foundation
import Testing
@testable import FlightCore

private let now = WeatherFixture.now

private func features(_ data: Data) throws -> [[String: Any]] {
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["type"] as? String == "FeatureCollection")
    return try #require(object["features"] as? [[String: Any]])
}

private func properties(_ feature: [String: Any]) -> [String: Any] {
    feature["properties"] as? [String: Any] ?? [:]
}

private func text(_ feature: [String: Any], _ key: String) -> String? {
    properties(feature)[key] as? String
}

private func metars(_ rows: String) throws -> [Metar] { try Metar.decode(Data("[\(rows)]".utf8)) }

private func tfrs(_ features: String) throws -> [Tfr] {
    try Tfr.decode(Data(#"{"type":"FeatureCollection","features":[\#(features)]}"#.utf8))
}

private let square = #"{"type":"Polygon","coordinates":[[[-97,30],[-96,30],[-96,31],[-97,30]]]}"#

@Suite struct WeatherStationOverlayTests {
    @Test func aStationCarriesCategoryCueCeilingVisibilityWindAndAge() throws {
        let all = try Metar.decode(try WeatherFixture.data("metars.json.gz"))
        let drawn = try features(WeatherGeoJSON.stations(all, now: now))
        #expect(drawn.count == 2547)
        let first = try #require(drawn.first)
        #expect(text(first, "station") == "KTVF")
        #expect(text(first, "cat") == "MVFR" && text(first, "cue") == "M")
        #expect(text(first, "ceiling") == "CIG 1400")
        #expect(text(first, "visibility") == "VIS 10+SM")
        #expect(text(first, "wind") == "04011KT")
        #expect(text(first, "obs") == "130023Z")
        #expect(text(first, "age") == "13 min")
        #expect(properties(first)["age_min"] as? Int == 13)
        #expect(text(first, "temp") == "7/6°C" && text(first, "spread") == "spread 1°")
        #expect(text(first, "label") == "KTVF 13 min\nCIG 1400 VIS 10+SM\n04011KT 7/6°C spread 1°")
        let geometry = try #require(first["geometry"] as? [String: Any])
        #expect(geometry["type"] as? String == "Point")
        #expect(geometry["coordinates"] as? [Double] == [-96.1787, 48.0597])
    }

    @Test func everyStationCarriesItsObservationTimeAndAge() throws {
        let all = try Metar.decode(try WeatherFixture.data("metars.json.gz"))
        for feature in try features(WeatherGeoJSON.stations(all, now: now)) {
            #expect(text(feature, "obs")?.count == 7)
            #expect(text(feature, "age")?.hasSuffix("min") == true)
            #expect(text(feature, "cue")?.count == 1)
        }
    }

    @Test func aMissingOrOddCategoryIsUnknownNeverVFR() throws {
        let rows = try metars(#"""
        {"id":"KNONE","lat":30,"lon":-97,"t":"2026-10-13T00:20:00Z","raw":"KNONE"},
        {"id":"KODD","lat":31,"lon":-97,"cat":"CLEAR","t":"2026-10-13T00:20:00Z","raw":"KODD"}
        """#)
        let drawn = try features(WeatherGeoJSON.stations(rows, now: now))
        #expect(drawn.map { text($0, "cat") } == ["UNKNOWN", "UNKNOWN"])
        #expect(drawn.map { text($0, "cue") } == ["?", "?"])
        #expect(text(drawn[0], "ceiling") == "CIG --" && text(drawn[0], "visibility") == "VIS --")
        #expect(text(drawn[0], "wind") == "WIND --")
        // The sample file has 72 such stations, and none of them may come out green.
        let all = try Metar.decode(try WeatherFixture.data("metars.json.gz"))
        let unknown = try features(WeatherGeoJSON.stations(all, now: now)).filter { text($0, "cat") == "UNKNOWN" }
        #expect(unknown.count == 72)
    }

    @Test func everyCategoryHasItsOwnLetter() {
        #expect(Set(FlightCategory.allCases.map(WeatherGeoJSON.cue)).count == FlightCategory.allCases.count)
        #expect(WeatherGeoJSON.cue(.unknown) == "?")
    }

    @Test func anOldReportLosesItsCategoryButKeepsItsAge() throws {
        let rows = try metars(#"""
        {"id":"KOLD","lat":30,"lon":-97,"cat":"VFR","ceil":null,"vis":10,"t":"2026-10-12T21:36:00Z","raw":"KOLD"},
        {"id":"KNEW","lat":31,"lon":-97,"cat":"VFR","vis":10,"t":"2026-10-12T22:37:00Z","raw":"KNEW"},
        {"id":"KAHEAD","lat":32,"lon":-97,"cat":"IFR","vis":2,"t":"2026-10-13T00:46:00Z","raw":"KAHEAD"}
        """#)
        let drawn = try features(WeatherGeoJSON.stations(rows, now: now))
        #expect(drawn.map { text($0, "cat") } == ["UNKNOWN", "VFR", "UNKNOWN"])
        #expect(text(drawn[0], "age") == "3 h 00 min")
        #expect(text(drawn[0], "label") == "KOLD 3 h 00 min old")
        #expect(text(drawn[1], "age") == "1 h 59 min")
        // Ten minutes ahead of the clock: never read as a fresh report.
        #expect(text(drawn[2], "label") == "KAHEAD dated ahead of clock")
        #expect(properties(drawn[2])["age_min"] as? Int == -10)
    }

    @Test func temperatureAndDewpointSpreadAreShownAndNeverTrap() throws {
        let rows = try metars(#"""
        {"id":"KA","lat":30,"lon":-97,"temp":-0.4,"dewp":-3.6,"vis":1e30,"t":"2026-10-13T00:20:00Z","raw":"KA"},
        {"id":"KB","lat":30,"lon":-97,"temp":1e30,"dewp":0,"t":"2026-10-13T00:20:00Z","raw":"KB"},
        {"id":"KC","lat":30,"lon":-97,"temp":5,"t":"2026-10-13T00:20:00Z","raw":"KC"}
        """#)
        let drawn = try features(WeatherGeoJSON.stations(rows, now: now))
        #expect(text(drawn[0], "temp") == "0/-4°C" && text(drawn[0], "spread") == "spread 3°")
        #expect(text(drawn[0], "visibility") == "VIS 1e+30SM")
        #expect(text(drawn[1], "temp") == "--/0°C" && text(drawn[1], "spread") == "spread --°")
        #expect(text(drawn[2], "temp") == "--/--°C")
    }

    @Test func windAndVisibilityTextCoversTheOddCases() throws {
        let rows = try metars(#"""
        {"id":"KA","lat":30,"lon":-97,"wspd":0,"wdir":0,"vis":0.25,"t":"2026-10-13T00:20:00Z","raw":"KA"},
        {"id":"KB","lat":30,"lon":-97,"wspd":5,"vrb":true,"vis":3,"t":"2026-10-13T00:20:00Z","raw":"KB"},
        {"id":"KC","lat":30,"lon":-97,"wspd":14,"wdir":300,"gust":22,"t":"2026-10-13T00:20:00Z","raw":"KC"}
        """#)
        let drawn = try features(WeatherGeoJSON.stations(rows, now: now))
        #expect(drawn.map { text($0, "wind") } == ["CALM", "VRB05KT", "30014G22KT"])
        #expect(drawn.map { text($0, "visibility") } == ["VIS 0.25SM", "VIS 3SM", "VIS --"])
    }
}

@Suite struct WeatherAdvisoryOverlayTests {
    @Test func sigmetsAreDrawnOnlyInsideTheirValidTime() throws {
        let all = try Sigmet.decode(try WeatherFixture.data("sigmets.geojson.gz"))
        // The six samples run from 23:55Z to 01:55Z.
        #expect(try features(WeatherGeoJSON.sigmets(all, now: now)).count == 6)
        #expect(try features(WeatherGeoJSON.sigmets(all, now: WeatherFixture.date("2026-10-12T23:54:59Z"))).isEmpty)
        #expect(try features(WeatherGeoJSON.sigmets(all, now: WeatherFixture.date("2026-10-13T01:54:59Z"))).count == 6)
        #expect(try features(WeatherGeoJSON.sigmets(all, now: WeatherFixture.date("2026-10-13T01:55:00Z"))).isEmpty)
    }

    @Test func aSigmetCarriesWhatATapShows() throws {
        let all = try Sigmet.decode(try WeatherFixture.data("sigmets.geojson.gz"))
        let first = try #require(try features(WeatherGeoJSON.sigmets(all, now: now)).first)
        #expect(text(first, "title") == "CONVECTIVE SIGMET")
        #expect(text(first, "label") == "CONVECTIVE SIGMET\nto 0155Z")
        #expect(text(first, "from") == "122355Z" && text(first, "to") == "130155Z")
        #expect(text(first, "top") == "28000 ft MSL" && text(first, "base") == "")
        #expect(text(first, "raw")?.contains("CONVECTIVE SIGMET 54W") == true)
        #expect((first["geometry"] as? [String: Any])?["type"] as? String == "Polygon")
    }

    @Test func aGairmetShownBeforeItsTimeSaysWhenItStarts() throws {
        let all = try GAirmet.decode(try WeatherFixture.data("gairmets.geojson.gz"))
        let first = try #require(all.map(\.valid).min())
        let early = try features(WeatherGeoJSON.gairmets(all, now: first - 3600))
        #expect(!early.isEmpty)
        #expect(early.allSatisfy { text($0, "label")?.hasSuffix("from \(WeatherText.zulu(first))") == true })
        #expect(try features(WeatherGeoJSON.gairmets(all, now: first)).allSatisfy {
            text($0, "label")?.contains("from") == false
        })
    }

    @Test func gairmetsShowOnlyTheSnapshotCoveringNow() throws {
        let all = try GAirmet.decode(try WeatherFixture.data("gairmets.geojson.gz"))
        let drawn = try features(WeatherGeoJSON.gairmets(all, now: now))
        #expect(drawn.count == 29)
        #expect(Set(drawn.compactMap { text($0, "valid") }) == ["130000Z"])
        #expect(drawn.allSatisfy { text($0, "title")?.hasPrefix("G-AIRMET ") == true })
        let kinds = Set(drawn.compactMap { ($0["geometry"] as? [String: Any])?["type"] as? String })
        #expect(kinds.isSubset(of: ["Polygon", "LineString"]))
        // Two days on, every snapshot is over.
        #expect(try features(WeatherGeoJSON.gairmets(all, now: now + 2 * 86_400)).isEmpty)
    }

    @Test func aTfrWithNoExpiryIsInEffectUntilCanceled() throws {
        let list = try tfrs(#"""
        {"type":"Feature","geometry":\#(square),"properties":{"notam":"0/0001","issued":"2020-01-15T00:01:00Z",
         "effective":"2020-01-15T00:01:00Z","expires":null,"upper_value":3000,"upper_unit":"FT","upper_ref":"MSL",
         "lower_value":0,"lower_unit":"FT","lower_ref":"AGL"}}
        """#)
        let drawn = try features(WeatherGeoJSON.tfrs(list, now: now))
        #expect(drawn.count == 1)
        #expect(text(drawn[0], "status") == "active")
        #expect(text(drawn[0], "until") == "until canceled")
        #expect(text(drawn[0], "levels") == "SFC to 3000 FT MSL")
        #expect(text(drawn[0], "label") == "TFR 0/0001\nSFC to 3000 FT MSL\nuntil canceled")
        // Years later it is still there.
        #expect(try features(WeatherGeoJSON.tfrs(list, now: now + 3 * 365 * 86_400)).count == 1)
    }

    @Test func expiredTfrsAreLeftOutAndUpcomingOnesAreMarked() throws {
        let list = try tfrs(#"""
        {"type":"Feature","geometry":\#(square),"properties":{"notam":"6/0001","issued":"2026-10-10T00:00:00Z",
         "effective":"2026-10-12T00:00:00Z","expires":"2026-10-13T00:36:00Z"}},
        {"type":"Feature","geometry":\#(square),"properties":{"notam":"6/0002","issued":"2026-10-10T00:00:00Z",
         "effective":"2026-10-15T00:55:00Z","expires":"2026-10-15T03:05:00Z"}},
        {"type":"Feature","geometry":\#(square),"properties":{"notam":"6/0003","issued":"2026-10-10T00:00:00Z",
         "effective":"2026-10-12T00:00:00Z","expires":"2026-10-13T00:37:00Z"}}
        """#)
        let drawn = try features(WeatherGeoJSON.tfrs(list, now: now))
        #expect(drawn.map { text($0, "notam") } == ["6/0002", "6/0003"])
        #expect(text(drawn[0], "status") == "upcoming")
        #expect(text(drawn[0], "label") == "TFR 6/0002\n? to ?\nfrom 2026-10-15 0055Z")
        #expect(text(drawn[1], "status") == "active")
        #expect(text(drawn[1], "until") == "until 2026-10-13 0037Z")
    }

    @Test func aTfrWithNoDrawnAreaIsKeptForTheList() throws {
        let all = try Tfr.decode(try WeatherFixture.data("tfrs.geojson.gz"))
        // The sample holds five areas not yet in effect and one standing notice with no area.
        let drawn = try features(WeatherGeoJSON.tfrs(all, now: now))
        #expect(drawn.count == 5)
        #expect(drawn.allSatisfy { text($0, "status") == "upcoming" })
        let listed = WeatherGeoJSON.tfrsWithoutArea(all, now: now)
        #expect(listed.map(\.notam) == ["0/0367"])
        #expect(listed.first?.expires == nil && listed.first?.status(at: now) == .active)
    }

    @Test func pirepsAreDrawnForTwoHoursAndUrgentOnesSaySo() throws {
        let list = try Pirep.decode(Data(#"""
        [{"t":"2026-10-13T00:06:00Z","lat":39.8,"lon":-104.6,"alt":null,"urgent":true,"acft":"B38M","turb":"SEV","ice":null,"raw":"DEN UUA"},
         {"t":"2026-10-12T22:37:00Z","lat":34.5,"lon":-117.6,"alt":10000,"urgent":false,"acft":"C208","turb":null,"ice":"LGT","raw":"PMD UA"},
         {"t":"2026-10-12T22:35:00Z","lat":41.9,"lon":-73.9,"alt":11000,"urgent":false,"acft":null,"turb":null,"ice":null,"raw":"OLD UA"}]
        """#.utf8))
        let drawn = try features(WeatherGeoJSON.pireps(list, now: now))
        #expect(drawn.map { text($0, "raw") } == ["DEN UUA", "PMD UA"])
        #expect(text(drawn[0], "type") == "UUA" && text(drawn[0], "label") == "UUA 30 min")
        #expect(text(drawn[0], "altitude") == "altitude not given" && text(drawn[0], "turbulence") == "SEV")
        #expect(text(drawn[1], "type") == "UA" && text(drawn[1], "altitude") == "10000 ft")
        #expect(text(drawn[1], "age") == "1 h 59 min" && text(drawn[1], "obs") == "122237Z")
        let all = try Pirep.decode(try WeatherFixture.data("pireps.json.gz"))
        #expect(try features(WeatherGeoJSON.pireps(all, now: now)).count == 122)
        #expect(try features(WeatherGeoJSON.pireps(all, now: now + 4 * 3600)).isEmpty)
    }
}
