import Foundation
import Testing
@testable import FlightCore

private func at(_ text: String) -> Date { WeatherFixture.date(text) }

private func taf(_ station: String) throws -> Taf {
    let tafs = try Taf.decode(WeatherFixture.data("tafs.json.gz"))
    return try #require(tafs.first { $0.station == station })
}

/// One TAF valid all of 13 October, holding the given groups as JSON. Nil gives the shape without groups.
private func oneTaf(_ groups: String?) throws -> Taf {
    let head = #"{"id":"KXXX","issued":"2026-10-13T00:00:00Z","from":"2026-10-13T00:00:00Z","to":"2026-10-14T00:00:00Z","raw":"TAF KXXX""#
    let json = "[" + head + (groups.map { #","groups":["# + $0 + "]" } ?? "") + "}]"
    return try Taf.decode(Data(json.utf8))[0]
}

private let allDay = #""from":"2026-10-13T00:00:00Z","to":"2026-10-14T00:00:00Z""#
private let noon = WeatherFixture.date("2026-10-13T12:00:00Z")

@Test func groupsDecodeInTimeOrderFromTheWorkersFile() throws {
    let tafs = try Taf.decode(WeatherFixture.data("tafs.json.gz"))
    #expect(tafs.count == 768)
    #expect(tafs.allSatisfy { !$0.groups.isEmpty })
    #expect(tafs.map(\.groups.count).reduce(0, +) == 2894)
    #expect(tafs.allSatisfy { taf in zip(taf.groups, taf.groups.dropFirst()).allSatisfy { $0.from <= $1.from } })
    let kaus = try #require(tafs.first { $0.station == "KAUS" })
    #expect(kaus.groups.map(\.kind) == [.initial, .from, .from, .from, .from, .from])
    #expect(kaus.groups[0].sky == [SkyLayer(cover: "SCT", baseFtAGL: 4500), SkyLayer(cover: "SCT", baseFtAGL: 10000),
                                   SkyLayer(cover: "BKN", baseFtAGL: 20000)])
    #expect(kaus.raw.hasPrefix("TAF KAUS 122338Z"))
}

@Test func prevailingConditionsFollowTheFromGroups() throws {
    let kaus = try taf("KAUS")
    let first = try #require(kaus.conditions(at: at("2026-10-13T00:35:00Z")))
    #expect(first.prevailing.windDirection == 140 && first.prevailing.windSpeedKt == 12)
    #expect(first.prevailing.windGustKt == nil && !first.prevailing.windVariable)
    #expect(first.prevailing.visibilityMiles == 6 && first.prevailing.visibilityOrMore)
    #expect(first.prevailing.ceilingFtAGL == 20000 && first.category == .vfr)
    #expect(first.overlays.isEmpty)
    let night = try #require(kaus.conditions(at: at("2026-10-13T08:00:00Z")))
    #expect(night.prevailing.ceilingFtAGL == 1500 && night.category == .mvfr)
    // A group starts on its first second, and the one before it ends there.
    #expect(kaus.conditions(at: at("2026-10-13T06:59:59Z"))?.category == .vfr)
    #expect(kaus.conditions(at: at("2026-10-13T07:00:00Z"))?.category == .mvfr)
    let afternoon = try #require(kaus.conditions(at: at("2026-10-13T19:00:00Z")))
    #expect(afternoon.prevailing.windGustKt == 21 && afternoon.prevailing.ceilingFtAGL == 4000)
    #expect(afternoon.category == .vfr)
    // Outside the forecast period there are no conditions.
    #expect(kaus.conditions(at: at("2026-10-12T23:59:59Z")) == nil)
    #expect(kaus.conditions(at: at("2026-10-14T06:00:00Z")) == nil)
}

@Test func aTempoGroupIsAnOverlayAndNeverChangesThePrevailingConditions() throws {
    // FM130700 00000KT 5SM BR FEW250 TEMPO 1310/1313 2SM BR
    let kabe = try taf("KABE")
    let found = try #require(kabe.conditions(at: at("2026-10-13T11:00:00Z")))
    #expect(found.prevailing.visibilityMiles == 5)
    #expect(found.prevailing.windSpeedKt == 0 && found.prevailing.windDirection == 0)
    #expect(found.prevailing.sky == [SkyLayer(cover: "FEW", baseFtAGL: 25000)])
    #expect(found.category == .mvfr)
    try #require(found.overlays.count == 1)
    let tempo = found.overlays[0]
    #expect(tempo.group.kind == .temporary && tempo.group.visibilityMiles == 2 && tempo.group.weather == "BR")
    // The overlay holds only what the group states. Its category takes the sky from the prevailing conditions.
    #expect(tempo.group.sky == nil && tempo.group.windSpeedKt == nil && tempo.group.category == .unknown)
    #expect(tempo.category == .ifr)
    #expect(kabe.conditions(at: at("2026-10-13T09:59:59Z"))?.overlays.isEmpty == true)
    #expect(kabe.conditions(at: at("2026-10-13T13:00:00Z"))?.overlays.isEmpty == true)
    #expect(kabe.conditions(at: at("2026-10-13T13:00:00Z"))?.category == .mvfr)
}

@Test func aProbGroupIsAnOverlayWithItsProbability() throws {
    // FM130600 06012G18KT 6SM BR VCSH OVC008 PROB30 1308/1311 4SM -SHRA BR OVC006
    let kbos = try taf("KBOS")
    let found = try #require(kbos.conditions(at: at("2026-10-13T09:00:00Z")))
    #expect(found.prevailing.windDirection == 60 && found.prevailing.windGustKt == 18)
    #expect(found.prevailing.visibilityMiles == 6 && !found.prevailing.visibilityOrMore)
    #expect(found.prevailing.ceilingFtAGL == 800 && found.category == .ifr)
    try #require(found.overlays.count == 1)
    #expect(found.overlays[0].group.kind == .probability && found.overlays[0].group.probability == 30)
    #expect(found.overlays[0].group.ceilingFtAGL == 600 && found.overlays[0].category == .ifr)
    #expect(kbos.conditions(at: at("2026-10-13T11:00:00Z"))?.overlays.isEmpty == true)
}

@Test func aBecomingGroupIsAnOverlayUntilItsChangeIsComplete() throws {
    // 27006KT 9999 FEW100 ... BECMG 1310/1312 24006KT 4800 BR FEW015 ... BECMG 1313/1315 24006KT 9999 NSW SKC
    let kdov = try taf("KDOV")
    let during = try #require(kdov.conditions(at: at("2026-10-13T11:00:00Z")))
    #expect(during.prevailing.windDirection == 270 && during.prevailing.visibilityOrMore)
    #expect(during.prevailing.category == .vfr)
    #expect(during.overlays.map(\.group.kind) == [.becoming])
    #expect(during.overlays.first?.category == .ifr)
    // The change may come at any moment from its start, so the worse of the two is the category.
    #expect(during.category == .ifr)
    let after = try #require(kdov.conditions(at: at("2026-10-13T12:00:00Z")))
    #expect(after.prevailing.windDirection == 240 && after.prevailing.visibilityMiles == 2.98)
    #expect(after.prevailing.weather == "BR" && after.category == .ifr && after.overlays.isEmpty)
    // A change for the better counts only once it is complete.
    let second = try #require(kdov.conditions(at: at("2026-10-13T14:00:00Z")))
    #expect(second.category == .ifr && second.overlays.first?.category == .vfr)
    let clear = try #require(kdov.conditions(at: at("2026-10-13T15:00:00Z")))
    #expect(clear.prevailing.sky == [SkyLayer(cover: "SKC", baseFtAGL: nil)] && clear.prevailing.weather == "NSW")
    #expect(clear.category == .vfr && clear.overlays.isEmpty)
}

@Test func windShearStaysWithThePeriodThatStatesIt() throws {
    // FM130300 33003KT P6SM BKN090 WS019/25025KT FM130600 VRB03KT P6SM BKN045 WS020/26025KT FM130800 28004KT ...
    let kgrb = try taf("KGRB")
    #expect(kgrb.conditions(at: at("2026-10-13T01:00:00Z"))?.prevailing.windShear == nil)
    let light = try #require(kgrb.conditions(at: at("2026-10-13T04:00:00Z")))
    #expect(light.prevailing.windSpeedKt == 3 && light.category == .vfr)
    #expect(light.prevailing.windShear == WindShear(heightFtAGL: 1900, directionTrue: 250, speedKt: 25))
    #expect(kgrb.conditions(at: at("2026-10-13T07:00:00Z"))?.prevailing.windShear
            == WindShear(heightFtAGL: 2000, directionTrue: 260, speedKt: 25))
    // An FM group replaces everything before it, wind shear included.
    #expect(kgrb.conditions(at: at("2026-10-13T09:00:00Z"))?.prevailing.windShear == nil)

    // 19010G15KT 9999 FEW150 BECMG 1302/1303 21006KT 9999 FEW150 WS020/24035KT
    let kblv = try taf("KBLV")
    let shear = WindShear(heightFtAGL: 2000, directionTrue: 240, speedKt: 35)
    let during = try #require(kblv.conditions(at: at("2026-10-13T02:30:00Z")))
    #expect(during.prevailing.windShear == nil && during.overlays.map(\.group.windShear) == [shear])
    #expect(kblv.conditions(at: at("2026-10-13T03:00:00Z"))?.prevailing.windShear == shear)

    // A file with no wind shear for a period leaves it nil. One that cannot be read drops the TAF's groups.
    let plain = "{" + allDay + #","vis":6,"sky":[{"cover":"SKC"}]"#
    #expect(try oneTaf(plain + "}").groups.map(\.windShear) == [nil])
    #expect(try oneTaf(plain + #","ws":{"hgt":2000,"dir":240,"spd":35}}"#).groups.map(\.windShear) == [shear])
    #expect(try oneTaf(plain + #","ws":{"hgt":2000}}"#).groups.isEmpty)
    // A completed BECMG change that states none leaves the wind shear before it standing.
    let first = "{" + allDay + #","vis":6,"sky":[{"cover":"SKC"}],"ws":{"hgt":2000,"dir":240,"spd":35}}"#
    let change = #"{"from":"2026-10-13T06:00:00Z","to":"2026-10-14T00:00:00Z","kind":"BECMG","#
        + #""becoming":"2026-10-13T08:00:00Z","wdir":180,"wspd":10}"#
    #expect(try oneTaf(first + "," + change).conditions(at: noon)?.prevailing.windShear == shear)
}

@Test func aCumulonimbusLayerKeepsItsMark() throws {
    // TEMPO 1302/1305 6SM -TSRA SCT040 BKN060CB OVC090
    let kfnt = try taf("KFNT")
    let found = try #require(kfnt.conditions(at: at("2026-10-13T03:00:00Z")))
    #expect(found.overlays.map(\.group.kind) == [.temporary])
    #expect(found.overlays.first?.group.sky == [SkyLayer(cover: "SCT", baseFtAGL: 4000),
                                                SkyLayer(cover: "BKN", baseFtAGL: 6000, cloudType: "CB"),
                                                SkyLayer(cover: "OVC", baseFtAGL: 9000)])
    #expect(found.prevailing.sky?.allSatisfy { $0.cloudType == nil } == true)
    let tafs = try Taf.decode(WeatherFixture.data("tafs.json.gz"))
    let marked = tafs.flatMap(\.groups).flatMap { $0.sky ?? [] }.compactMap(\.cloudType)
    #expect(marked.count == 59 && Set(marked) == ["CB"])
    #expect(tafs.flatMap(\.groups).compactMap(\.windShear).count == 59)
}

@Test func verticalVisibilityIsACeiling() throws {
    // FM130500 00000KT 1/4SM FG VV001
    let kcrw = try taf("KCRW")
    let fog = try #require(kcrw.conditions(at: at("2026-10-13T06:00:00Z")))
    #expect(fog.prevailing.verticalVisibilityFt == 100 && fog.prevailing.ceilingFtAGL == 100)
    #expect(fog.prevailing.visibilityMiles == 0.25 && fog.category == .lifr)
    // FM130300 00000KT 4SM BR SCT002: a scattered layer is no ceiling, however low.
    let mist = try #require(kcrw.conditions(at: at("2026-10-13T04:00:00Z")))
    #expect(mist.prevailing.ceilingFtAGL == nil && mist.category == .mvfr)
    #expect(kcrw.conditions(at: at("2026-10-13T13:30:00Z"))?.category == .ifr)
}

@Test func aGroupWithoutUsableCeilingAndVisibilityIsUnknownNeverVFR() throws {
    let cases: [(String, FlightCategory)] = [
        (#""wdir":180,"wspd":5"#, .unknown),
        (#""vis":6,"visp":true"#, .unknown),
        (#""sky":[{"cover":"SKC"}]"#, .unknown),
        (#""vis":6,"sky":[{"cover":"OVX"}]"#, .unknown),
        (#""vis":6,"sky":[{"cover":"BKN"}]"#, .unknown),
        // A broken layer with no height could lie below the overcast that has one.
        (#""vis":6,"sky":[{"cover":"BKN"},{"cover":"OVC","base":5000}]"#, .unknown),
        (#""vis":6,"sky":[{"cover":"XYZ","base":9000}]"#, .unknown),
        (#""vis":6,"sky":[]"#, .unknown),
        (#""vis":6,"visp":true,"sky":[{"cover":"SKC"}]"#, .vfr),
        (#""vis":6,"sky":[{"cover":"FEW","base":300},{"cover":"SCT","base":800}]"#, .vfr),
        (#""vis":6,"vv":200"#, .lifr),
        (#""vis":0.5,"sky":[{"cover":"SKC"}]"#, .lifr),
        (#""vis":10,"sky":[{"cover":"OVC","base":3000}]"#, .mvfr),
    ]
    for (values, expected) in cases {
        let taf = try oneTaf("{" + allDay + "," + values + "}")
        #expect(taf.conditions(at: noon)?.category == expected, "\(values)")
    }
}

@Test func aFileWithoutGroupsStillDecodes() throws {
    let old = try oneTaf(nil)
    #expect(old.groups.isEmpty && old.raw == "TAF KXXX")
    #expect(old.isValid(at: noon) && old.conditions(at: noon) == nil)
}

@Test func groupsThisCodeCannotReadAreDroppedWhole() throws {
    let good = "{" + allDay + #","vis":6,"sky":[{"cover":"SKC"}]}"#
    #expect(try oneTaf(good).groups.count == 1)
    let bad = [
        #"{"from":"2026-10-13T02:00:00Z","to":"2026-10-13T04:00:00Z","kind":"RAPID"}"#,
        #"{"from":"2026-10-13T02:00:00Z","to":"2026-10-13T04:00:00Z","kind":"BECMG","vis":1}"#,
        #"{"from":"2026-10-13T02:00:00Z","to":"2026-10-13T04:00:00Z","kind":"BECMG","becoming":"2026-10-13T20:00:00Z","vis":1}"#,
        #"{"from":"2026-10-13T04:00:00Z","to":"2026-10-13T02:00:00Z","kind":"TEMPO","vis":1}"#,
        #"{"from":"2026-10-13T02:00:00Z","to":"2026-10-13T04:00:00Z","kind":"TEMPO","vis":"far"}"#,
        #"{"to":"2026-10-13T04:00:00Z","kind":"TEMPO"}"#,
    ]
    for group in bad {
        let taf = try oneTaf(good + "," + group)
        #expect(taf.groups.isEmpty, "\(group)")
        #expect(taf.raw == "TAF KXXX" && taf.conditions(at: noon) == nil, "\(group)")
    }
    // Groups out of order in the file are put in order.
    let late = #"{"from":"2026-10-13T06:00:00Z","to":"2026-10-14T00:00:00Z","kind":"FM","vis":2,"sky":[{"cover":"SKC"}]}"#
    let sorted = try oneTaf(late + "," + good)
    #expect(sorted.groups.map(\.kind) == [.initial, .from])
    #expect(sorted.conditions(at: noon)?.category == .ifr)
    // A change that starts with the opening group is read after it, wherever the file lists it.
    let change = "{" + allDay + #","kind":"BECMG","becoming":"2026-10-13T02:00:00Z","vis":2}"#
    let tied = try oneTaf(change + "," + good)
    #expect(tied.groups.map(\.kind) == [.initial, .becoming])
    #expect(tied.conditions(at: noon)?.category == .ifr)
    // A change that starts with an FM group changes that group, wherever the file lists it.
    let sixOn = #""from":"2026-10-13T06:00:00Z","to":"2026-10-14T00:00:00Z""#
    let fog = "{" + sixOn + #","kind":"BECMG","becoming":"2026-10-13T08:00:00Z","vis":0.5}"#
    let wind = "{" + sixOn + #","kind":"FM","wdir":180,"wspd":10,"vis":6,"sky":[{"cover":"SKC"}]}"#
    for groups in [[good, fog, wind], [good, wind, fog], [fog, wind, good]] {
        let both = try oneTaf(groups.joined(separator: ","))
        #expect(both.groups.map(\.kind) == [.initial, .from, .becoming])
        let after = try #require(both.conditions(at: noon))
        #expect(after.prevailing.visibilityMiles == 0.5 && after.prevailing.windSpeedKt == 10)
        #expect(after.category == .lifr && after.overlays.isEmpty)
        // Until the change is complete the FM group stands and the change is shown beside it.
        let during = try #require(both.conditions(at: at("2026-10-13T07:00:00Z")))
        #expect(during.prevailing.visibilityMiles == 6 && during.prevailing.category == .vfr)
        #expect(during.overlays.map(\.group.kind) == [.becoming] && during.overlays.first?.category == .lifr)
        #expect(during.category == .lifr)
    }
}

@Test func aChangeUnderWayToASkyThatCannotBeReadMakesTheCategoryUnknown() throws {
    let good = "{" + allDay + #","vis":6,"sky":[{"cover":"SKC"}]}"#
    let sixOn = #""from":"2026-10-13T06:00:00Z","to":"2026-10-14T00:00:00Z""#
    let change = "{" + sixOn + #","kind":"BECMG","becoming":"2026-10-13T08:00:00Z","sky":[{"cover":"BKN"}]}"#
    let during = try #require(try oneTaf(good + "," + change).conditions(at: at("2026-10-13T07:00:00Z")))
    #expect(during.prevailing.category == .vfr && during.overlays.first?.category == .unknown)
    #expect(during.category == .unknown)
    // A TEMPO or PROB group to the same sky is beside the prevailing conditions and does not count.
    for kind in [#""kind":"TEMPO""#, #""kind":"PROB","prob":30"#] {
        let beside = "{" + sixOn + "," + kind + #","vis":0.5,"sky":[{"cover":"BKN"}]}"#
        let found = try #require(try oneTaf(good + "," + beside).conditions(at: noon))
        #expect(found.overlays.count == 1 && found.category == .vfr, "\(kind)")
    }
}

@Test func categoryLimitsGiveTheSourcesOwnCategoryForEveryMetar() throws {
    let metars = try Metar.decode(WeatherFixture.data("metars.json.gz"))
    var compared = 0
    for metar in metars where metar.category != .unknown {
        guard let visibility = metar.visibilityMiles else { continue }
        compared += 1
        #expect(FlightCategory.from(visibilityMiles: visibility, ceilingFtAGL: metar.ceilingFtAGL) == metar.category,
                "\(metar.station)")
    }
    #expect(compared == 2474)
    let limits: [(Double, Int?, FlightCategory)] = [
        (5.01, nil, .vfr), (5, nil, .mvfr), (3, nil, .mvfr), (2.99, nil, .ifr), (1, nil, .ifr), (0.99, nil, .lifr),
        (10, 3001, .vfr), (10, 3000, .mvfr), (10, 1000, .mvfr), (10, 999, .ifr), (10, 500, .ifr), (10, 499, .lifr),
        (0.5, 5000, .lifr), (10, 0, .lifr), (-1, nil, .unknown), (10, -100, .unknown), (.nan, nil, .unknown),
    ]
    for (visibility, ceiling, expected) in limits {
        #expect(FlightCategory.from(visibilityMiles: visibility, ceilingFtAGL: ceiling) == expected,
                "\(visibility) \(String(describing: ceiling))")
    }
}
