import Foundation
import Testing
@testable import FlightCore

// The three sample application data fields printed in GDL 90 ICD 560-1058-00 Rev A, §5.1.4 and §5.2.4.
private let specText = """
2180067441905011a02d3305832db0e70c1a04d832d71cf1d60c38c30d8b5204364cd806157c36c2008b3b1cb079c146
370d30c205920b0ccb5204364cd8130d4cb5c3d79d2180067441905011a02d0118832db0e70c1a04d832d71cf1d60c38
c30d8b5204364cd806157c36c2008b3b1cb079c146370d30c205920b0ccb5204364cd8130d4cb5c3d79d218006744190
5011a02c5547832db0e70c1a04d832d71cf1d60c38c30d8b5204364cd806157c36c2008b3b1cb079c146370d30c20592
0b0ccb5204364cd8130d4cb5c3d79d2180067441905011a02c14d4832db0e70c1a04d832d71cf1d60c38c30d8b520436
4cd806157c36c2008b3b1cb079c146370d30c205920b0ccb5204364cd8130d4cb5c3d79d2180067441905011a02c824f
832db0e70c1a04d832d71cf1d60c38c30d8b5204364cd806157c36c2008b3b1cb079c146370d30c205920b0ccb520436
4cd8130d4cb5c3d79d000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000
"""
private let specRadar1 = """
130000FC000084A570308950111A53120930110A23451B0A0918090A1B0C1D0607061D041B0A0108208000FC000084A3
AE00090A1314150617061D04130A01080112131C0D06270615140B0A01000112131C0D06270615140B0A010000090A13
14150617061D04130A0108148000FC000084A1EC00090A1B0C1D0607061D041B0A010808110A23451B0A091018111A53
120920308930130000FC000084AAB7308950111A53120930110A23451B0A0918090A1B0C1D0607061D041B0A01082080
00FC000084A8F500090A1314150617061D04130A01080112131C0D06270615140B0A01000112131C0D06270615140B0A
010000090A1314150617061D04130A0108148000FC000084A73300090A1B0C1D0607061D041B0A010808110A23451B0A
091018111A53120920308930130000FC000084AFFD308950111A53120930110A23451B0A0918090A1B0C1D0607061D04
1B0A01080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000
"""
private let specRadar2 = """
208000FC000084AE3B00090A1314150617061D04130A01080112131C0D06270615140B0A01000112131C0D0627061514
0B0A010000090A1314150617061D04130A0108148000FC000084AC7900090A1B0C1D0607061D041B0A010808110A2345
1B0A091018111A53120920308930040000FC000004B1BDF0040000FC000004AFFBD0040000FC000004AE39D0040000FC
000004AC77D0040000FC000004AAB5D0040000FC000004A8F3D0040000FC000004A731D0040000FC000004A56FE00400
00FC000004A3ADE0040000FC000004A1EBE0000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000
"""

private func hex(_ text: String) -> [UInt8] {
    let digits = Array(text.filter(\.isHexDigit))
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
}

/// Fields of (value, bit width), most significant bit first, zero-padded to a byte.
private func pack(_ fields: [(Int, Int)]) -> [UInt8] {
    var bits: [Bool] = []
    for (value, width) in fields { bits += (0..<width).map { value >> (width - 1 - $0) & 1 == 1 } }
    while bits.count % 8 != 0 { bits.append(false) }
    return stride(from: 0, to: bits.count, by: 8).map { i in bits[i..<i + 8].reduce(UInt8(0)) { $0 << 1 | ($1 ? 1 : 0) } }
}

/// The ICD's header layout: three flags, 11-bit product, segmentation flag, time option 0, hours, minutes.
private func apduHeader(_ product: Int, hours: Int = 0, minutes: Int = 0) -> [UInt8] {
    pack([(0, 3), (product, 11), (0, 1), (0, 2), (hours, 5), (minutes, 6)])
}

private func iframe(_ data: [UInt8], type: UInt8 = 0) -> [UInt8] {
    [UInt8(data.count >> 1), UInt8(data.count & 1) << 7 | type] + data
}

/// An Uplink Data message: id, 3 bytes of reception time, the 8-byte UAT header, 424 bytes of application data.
private func uplink(_ frames: [UInt8], valid: Bool = true) -> [UInt8] {
    [0x07, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, valid ? 0x23 : 0x03, 0x10] + frames
        + [UInt8](repeating: 0, count: 424 - frames.count)
}

private let alphabet = Array("\u{3}ABCDEFGHIJKLMNOPQRSTUVWXYZ") + ["\u{1A}", "\t", "\u{1E}", "\n", "|"]
    + Array(" !\"#$%&'()*+,-./0123456789:;<=>?")

/// Text records as DLAC: 6-bit characters, a record separator after each, each record padded to a byte.
private func dlac(_ records: [String]) -> [UInt8] {
    var out: [UInt8] = []
    for record in records {
        out += pack((record + "\u{1E}").map { (alphabet.firstIndex(of: $0)!, 6) })
    }
    return out
}

private func textApdu(_ records: [String]) -> [UInt8] {
    iframe(apduHeader(FISB.textProduct, hours: 16, minutes: 25) + dlac(records))
}

// 2026-10-26 09:30Z
private let now = Date(timeIntervalSince1970: 1_793_007_000)
private let here = Coordinate(latitude: 44.9, longitude: -123.0)

@Suite struct FISBUplinkTests {
    @Test func theSpecTextSampleHasFiveTafApdus() throws {
        let message = uplink(hex(specText))
        let decoded = try #require(GDL90.decode(message))
        guard case .uplink(let up) = decoded else { Issue.record("not an uplink"); return }
        #expect(up.apdus.count == 5)
        #expect(up.apdus.allSatisfy { $0.productID == 413 })
        // The header time is unused for text, but the sample gives 16:25.
        #expect(up.apdus[0].stamp == FISB.Stamp(hours: 16, minutes: 25))
        let stations = up.apdus.compactMap { FISB.record(FISB.records($0.payload)[0])?.station }
        #expect(stations == ["KSLE", "KPDX", "KEUG", "KAST", "KHIO"])
        let first = try #require(FISB.record(FISB.records(up.apdus[0].payload)[0]))
        #expect(first.time == "260900Z")
        #expect(first.raw == "TAF AMD KSLE 260900Z 251315 08006KT P6SM FEW060 BKN120 FM0400 VRB03KT P6SM SCT250")
    }

    @Test func anUplinkMarkedInvalidIsNotDecoded() {
        #expect(GDL90.decode(uplink(hex(specText), valid: false)) == .other(0x07))
        #expect(GDL90.decode([0x07, 1, 2, 3]) == .other(0x07))
    }

    @Test func framesAreWalkedUntilALengthOfZero() throws {
        let a = iframe(apduHeader(413) + dlac(["TAF KSLE 260900Z X"]))
        let skipped = iframe([1, 2, 3, 4, 5], type: 0x0F)
        let b = iframe(apduHeader(413) + dlac(["TAF KPDX 260900Z X"]))
        guard case .uplink(let up)? = GDL90.decode(uplink(a + skipped + b)) else { Issue.record("no uplink"); return }
        #expect(up.apdus.count == 2)
        // A frame longer than the data left stops the walk.
        guard case .uplink(let cut)? = GDL90.decode(uplink(a + [0xFF, 0x00, 1, 2])) else { Issue.record("no uplink"); return }
        #expect(cut.apdus.count == 1)
    }

    @Test func nineBitLengthsAreRead() throws {
        // 300 bytes of frame data needs the ninth bit: 300 = 0b1_0010_1100.
        let big = iframe(apduHeader(413) + [UInt8](repeating: 0, count: 296))
        #expect(Array(big.prefix(2)) == [0x96, 0x00])
        guard case .uplink(let up)? = GDL90.decode(uplink(big)) else { Issue.record("no uplink"); return }
        #expect(up.apdus.first?.payload.count == 296)
    }

    @Test func headerTimeOptionsAreRead() {
        func apdu(_ fields: [(Int, Int)]) -> FISB.APDU? { FISB.apdu(ArraySlice(pack([(0, 3), (413, 11), (0, 1)] + fields + [(0xAA, 8)]))) }
        #expect(apdu([(0, 2), (16, 5), (25, 6)])?.stamp == FISB.Stamp(hours: 16, minutes: 25))
        #expect(apdu([(1, 2), (16, 5), (25, 6), (59, 6)])?.stamp == FISB.Stamp(hours: 16, minutes: 25, seconds: 59))
        #expect(apdu([(2, 2), (10, 4), (26, 5), (16, 5), (25, 6)])?.stamp
                == FISB.Stamp(month: 10, day: 26, hours: 16, minutes: 25))
        #expect(apdu([(3, 2), (10, 4), (26, 5), (16, 5), (25, 6), (59, 6)])?.stamp
                == FISB.Stamp(month: 10, day: 26, hours: 16, minutes: 25, seconds: 59))
        // The payload starts after the padded header, whatever its length.
        #expect(apdu([(1, 2), (16, 5), (25, 6), (59, 6)])?.payload.isEmpty == false)
    }

    @Test func aSegmentedApduIsLeftOut() {
        let bytes = pack([(0, 3), (413, 11), (1, 1), (0, 2), (1, 5), (2, 6), (0, 4), (0xAA, 8)])
        #expect(FISB.apdu(ArraySlice(bytes)) == nil)
        #expect(FISB.apdu([0x06, 0x74, 0x41]) == nil)
    }

    @Test func stampsLandOnTheLatestPastTime() {
        // 09:30Z now.
        #expect(FISB.Stamp(hours: 9, minutes: 0).date(near: now) == now.addingTimeInterval(-1800))
        #expect(FISB.Stamp(hours: 16, minutes: 25).date(near: now) == now.addingTimeInterval(-(17 * 3600 + 5 * 60)))
        #expect(FISB.Stamp(hours: 9, minutes: 31).date(near: now) == now.addingTimeInterval(60))
    }
}

@Suite struct FISBTextTests {
    @Test func recordsEndAtTheSeparatorAndRealign() {
        // Lengths chosen so the fill is 0, 2, 4 and 6 bits.
        let records = ["TAF KSLE", "TAF KSLE 1", "TAF KSLE 12", "TAF KSLE 123", "METAR KPDX 260855Z"]
        #expect(FISB.records(dlac(records)) == records)
    }

    @Test func aTabCountsSpacesAndLineFeedsStay() {
        // 'E' is 5: tab, 5 spaces.
        let payload = pack([(20, 6), (28, 6), (5, 6), (1, 6), (30, 6), (2, 6), (29, 6)])
        #expect(FISB.records(payload) == ["T     A\nB"])
    }

    @Test func aRecordIsTypeStationTimeAndText() {
        let metar = FISB.record("METAR KSLE 260855Z 18006KT 10SM CLR 12/08 A3001=")
        #expect(metar == FISB.Record(kind: .metar, station: "KSLE", time: "260855Z",
                                     raw: "METAR KSLE 260855Z 18006KT 10SM CLR 12/08 A3001"))
        #expect(FISB.record("METAR KSLE 260855ZSP 18006KT 10SM")?.raw == "SPECI KSLE 260855Z 18006KT 10SM")
        #expect(FISB.record("METAR KSLE 260855Z SP 18006KT 10SM")?.raw == "SPECI KSLE 260855Z 18006KT 10SM")
        #expect(FISB.record("TAF.AMD KSLE 260900Z 2609/2709 18006KT P6SM")?.raw == "TAF AMD KSLE 260900Z 2609/2709 18006KT P6SM")
        #expect(FISB.record("TAF KSLE 260900ZAM 2609/2709 18006KT P6SM")?.raw == "TAF AMD KSLE 260900Z 2609/2709 18006KT P6SM")
        #expect(FISB.record("TAF KSLE 260900Z NIL=") == nil)
        #expect(FISB.record("TAF KSLE NIL=") == nil)
        #expect(FISB.record("PIREP KSLE 260900Z UA /OV") == nil)
        #expect(FISB.record("METAR KSLE 26085Z 18006KT") == nil)
    }

    @Test func aMetarLineIsRead() throws {
        let raw = "METAR KSLE 260855Z AUTO 18006G15KT 120V220 1 1/2SM -RA BKN008 OVC015CB 12/M08 A3001 RMK AO2 SLP165"
        let m = try #require(Metar.parse(raw, coordinate: here, near: now))
        #expect(m.station == "KSLE")
        #expect(m.observed == now.addingTimeInterval(-35 * 60))
        #expect((m.windDirection, m.windSpeedKt, m.windGustKt, m.windVariable) == (180, 6, 15, false))
        #expect(m.visibilityMiles == 1.5 && !m.visibilityOrMore)
        #expect(m.sky == [SkyLayer(cover: "BKN", baseFtAGL: 800), SkyLayer(cover: "OVC", baseFtAGL: 1500)])
        #expect(m.ceilingFtAGL == 800)
        #expect(m.category == .ifr)
        #expect((m.temperatureC, m.dewpointC) == (12, -8))
        #expect(m.altimeterInHg == 30.01)
        #expect(m.raw == raw)
    }

    @Test func missingPartsStayMissing() throws {
        let m = try #require(Metar.parse("METAR KSLE 260855Z VRB03KT P6SM VV002 M02/ A2992", coordinate: here, near: now))
        #expect((m.windDirection, m.windVariable, m.windSpeedKt) == (nil, true, 3))
        #expect(m.visibilityMiles == 6 && m.visibilityOrMore)
        #expect(m.sky == [SkyLayer(cover: "OVX", baseFtAGL: 200)] && m.ceilingFtAGL == 200 && m.category == .lifr)
        #expect(m.temperatureC == -2 && m.dewpointC == nil)
        let bare = try #require(Metar.parse("METAR KSLE 260855Z RMK AO1", coordinate: here, near: now))
        #expect(bare.category == .unknown && bare.visibilityMiles == nil && bare.windSpeedKt == nil)
        #expect(Metar.parse("METAR KSLE 321255Z 18006KT", coordinate: here, near: now) == nil)
    }

    @Test func aTafLineIsRead() throws {
        let raw = "TAF AMD KSLE 260900Z 2609/2709 18006KT P6SM FEW050 TEMPO 2612/2616 3SM -RA BKN020 FM261800 20010G20KT 5SM BR OVC008 WS020/25040KT BECMG 2620/2622 VRB03KT PROB30 2700/2704 1/2SM FG VV002"
        let taf = try #require(Taf.parse(raw, near: now))
        func at(_ day: Int, _ hour: Int) -> Date {
            Date(timeIntervalSince1970: 1_792_972_800 + Double((day - 26) * 24 + hour) * 3600)
        }
        #expect(taf.station == "KSLE" && taf.issued == now.addingTimeInterval(-1800))
        #expect(taf.validFrom == at(26, 9) && taf.validTo == at(27, 9))
        #expect(taf.groups.map(\.kind) == [.initial, .temporary, .from, .becoming, .probability])
        let initial = taf.groups[0]
        #expect((initial.from, initial.to) == (at(26, 9), at(26, 18)))
        #expect((initial.windDirection, initial.windSpeedKt, initial.visibilityMiles, initial.visibilityOrMore) == (180, 6, 6, true))
        #expect(initial.sky == [SkyLayer(cover: "FEW", baseFtAGL: 5000)])
        #expect(taf.groups[1].weather == "-RA" && (taf.groups[1].from, taf.groups[1].to) == (at(26, 12), at(26, 16)))
        let from = taf.groups[2]
        #expect((from.from, from.to, from.windGustKt, from.weather) == (at(26, 18), at(27, 9), 20, "BR"))
        #expect(from.windShear == WindShear(heightFtAGL: 2000, directionTrue: 250, speedKt: 40))
        let becoming = taf.groups[3]
        #expect((becoming.from, becoming.to, becoming.becomingBy) == (at(26, 20), at(26, 22), at(26, 22)))
        #expect(becoming.windVariable && becoming.windDirection == nil)
        let prob = taf.groups[4]
        #expect(prob.probability == 30 && prob.visibilityMiles == 0.5 && prob.verticalVisibilityFt == 200)
        #expect(prob.category == .lifr)
    }

    @Test func aTafWithABadGroupKeepsNone() throws {
        let taf = try #require(Taf.parse("TAF KSLE 260900Z 2609/2709 18006KT P6SM TEMPO 18006KT", near: now))
        #expect(taf.groups.isEmpty)
        #expect(Taf.parse("TAF KSLE 260900Z", near: now) == nil)
    }

    // Nine characters with a slash in place but only seven digits, as the valid period or after TEMPO.
    @Test func aPeriodShortOfDigitsIsNotRead() throws {
        #expect(Taf.parse("TAF KABC 260900Z 1234/5/67 27010KT P6SM SKC", near: now) == nil)
        let tempo = try #require(Taf.parse("TAF KSLE 260900Z 2609/2709 18006KT P6SM SKC TEMPO 1234/5/67 3SM BR", near: now))
        #expect(tempo.groups.isEmpty)
    }

    // NSW ends the weather of the group before it, as the downloaded TAFs read it.
    @Test func noSignificantWeatherIsReadAsWeather() throws {
        let taf = try #require(Taf.parse("TAF KSLE 260900Z 2609/2709 18006KT 3SM BR SCT010 BECMG 2612/2614 P6SM NSW SKC", near: now))
        #expect(taf.groups.map(\.weather) == [Optional("BR"), Optional("NSW")])
        let after = try #require(taf.conditions(at: taf.validFrom.addingTimeInterval(6 * 3600)))
        #expect(after.prevailing.weather == "NSW")
    }

    @Test func theOlderTafFormsAreRead() throws {
        let taf = try #require(Taf.parse("TAF KSLE 260900Z 261015 08006KT P6SM FEW060 FM1200 VRB03KT P6SM SCT250", near: now))
        #expect(taf.groups.map(\.kind) == [.initial, .from])
        #expect(taf.groups[1].from == taf.validFrom.addingTimeInterval(2 * 3600))
    }

    // The worker's samples are the oracle: what it decoded from the same line.
    @Test func linesReadLikeTheDownloadedReports() throws {
        // The worker leaves a visibility of 0SM empty, and reads only statute-mile TAFs the same way; so do not compare those.
        for metar in try Metar.decode(WeatherFixture.data("metars.json.gz")) where !metar.raw.contains(" 0SM") {
            let parsed = try #require(Metar.parse(metar.raw, coordinate: metar.coordinate, near: metar.observed.addingTimeInterval(600)),
                                      "\(metar.raw)")
            #expect(parsed == metar, "\(metar.raw)")
        }
        for taf in try Taf.decode(WeatherFixture.data("tafs.json.gz")) where !taf.groups.isEmpty && taf.raw.contains("SM") {
            let parsed = try #require(Taf.parse(taf.raw, near: taf.issued.addingTimeInterval(600)), "\(taf.raw)")
            #expect(parsed == taf, "\(taf.raw)")
        }
    }
}

@Suite struct FISBRadarTests {
    private func blocks(_ field: String) -> [RadarBlock] {
        guard case .uplink(let up)? = GDL90.decode(uplink(hex(field))) else { return [] }
        return up.apdus.flatMap { FISB.radarBlocks($0, near: now) }
    }

    @Test func theSpecSampleFirstBlockIsDecodedAsPrinted() throws {
        let first = try #require(blocks(specRadar1).first)
        #expect(first.productID == 63 && first.scale == 0 && !first.southern && first.blockNumber == 0x4A570)
        // 123 12' to 122 24' West, 45 04' to 45 08' North.
        #expect(abs(first.west - -(123 + 12.0 / 60)) < 1e-9 && abs(first.lonSize - 48.0 / 60) < 1e-9)
        #expect(abs(first.north - (45 + 8.0 / 60)) < 1e-9 && abs(first.latSize - 4.0 / 60) < 1e-9)
        #expect(first.bins.count == 128)
        // Row 1 of Table 21: 7 empty bins, 18 of intensity 1, 7 empty. Row 2 starts with 4 empty, then 1 1 1 2 2 2 2 3.
        let row0 = (0..<32).map { first.intensity(row: 0, column: $0) }
        #expect(row0 == [UInt8](repeating: 0, count: 7) + [UInt8](repeating: 1, count: 18) + [UInt8](repeating: 0, count: 7))
        let row1 = (0..<32).map { first.intensity(row: 1, column: $0) }
        #expect(Array(row1[0..<12]) == [0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 2, 3])
        // Row 4 of the table peaks at 7.
        #expect(first.bins.max() == 7 && first.intensity(row: 3, column: 16) == 7)
        #expect(first.time == FISB.Stamp(hours: 0, minutes: 0).date(near: now))
    }

    @Test func theSampleBlocksTileTenRowsOfFive() {
        // 9 run-length APDUs and 10 empty-element ones. The empty ones leave out the block a run-length APDU gives,
        // so together they cover a region 5 blocks (4 degrees) wide with no block twice.
        let all = blocks(specRadar1) + blocks(specRadar2)
        #expect(all.filter { $0.bins.contains { $0 > 0 } }.count == 9)
        #expect(Set(all.map(\.blockNumber)).count == all.count)
        let rows = Dictionary(grouping: all, by: { $0.blockNumber / 450 })
        #expect(rows.count == 10 && rows.values.allSatisfy { $0.count == 5 })
        #expect(rows.values.allSatisfy { $0.map { $0.blockNumber % 450 }.sorted() == Array(($0.map { $0.blockNumber % 450 }.min()!)...($0.map { $0.blockNumber % 450 }.min()! + 4)) })
    }

    @Test func anEmptyElementMarksTheBlockAndItsEasternNeighbours() throws {
        // 0x4B1BD with F0: itself and the four to the east, from the sample.
        let marked = blocks(specRadar2).filter { $0.blockNumber >= 0x4B1BD && $0.blockNumber <= 0x4B1BD + 4 }
        #expect(marked.map(\.blockNumber) == [0x4B1BD, 0x4B1BE, 0x4B1BF, 0x4B1C0, 0x4B1C1])
        #expect(marked.allSatisfy { $0.bins == [UInt8](repeating: 0, count: 128) })
        // 124 to 120 West: five blocks of 48 minutes.
        #expect(abs(marked[0].west - -124.0) < 1e-9 && abs(marked[4].west + marked[4].lonSize - -120.0) < 1e-9)
    }

    @Test func laterBytesOfAnEmptyElementMarkEightMoreBlocksEach() throws {
        // Block 450 (column 0 of row 1). Byte 3: bits for +4..+1 clear, L = 2. Byte 4 marks +5..+12, byte 5 +13..+20.
        let payload = apduHeader(64) + [0x00, 0x01, 0xC2, 0x02, 0b0000_0001, 0b1000_0000]
        let apdu = try #require(FISB.apdu(ArraySlice(payload)))
        let out = FISB.radarBlocks(apdu, near: now)
        #expect(out.map(\.blockNumber) == [450, 455, 470])
        // On the row, a mark past column 449 wraps to column 0 rather than the next row.
        let edge = FISB.APDU(productID: 63, stamp: FISB.Stamp(hours: 9, minutes: 0), payload: [0x00, 0x01, 0xC1, 0xF0])
        #expect(FISB.radarBlocks(edge, near: now).map(\.blockNumber) == [449, 0, 1, 2, 3])
    }

    @Test func southernBlocksAndScalesPlaceBlocksBySpec() throws {
        // Four runs of 32 bins at intensity 0.
        let full = [UInt8](repeating: 31 << 3, count: 4)
        // Block 0 north: the four minutes just above the equator. South: the four just below.
        let run = pack([(0b1000, 4), (0, 20)]) + full
        let north = try #require(FISB.radarBlocks(FISB.APDU(productID: 64, stamp: .init(hours: 9, minutes: 0), payload: run), near: now).first)
        #expect(north.north == 4.0 / 60 && north.west == 0 && north.scale == 0)
        var south = run
        south[0] |= 0x40
        let s = try #require(FISB.radarBlocks(FISB.APDU(productID: 64, stamp: .init(hours: 9, minutes: 0), payload: south), near: now).first)
        #expect(s.southern && s.north == 0)
        // Scale 2 makes the bins 9 times larger on both axes; block 450 * 100 + 300 is column 300 of row 100.
        let wide = pack([(0b1010, 4), (450 * 100 + 300, 20)]) + full
        let w = try #require(FISB.radarBlocks(FISB.APDU(productID: 64, stamp: .init(hours: 9, minutes: 0), payload: wide), near: now).first)
        #expect(w.scale == 2 && abs(w.north - 101 * 4.0 / 60) < 1e-9 && abs(w.west - (300 * 48.0 / 60 - 360)) < 1e-9)
        #expect(abs(w.latSize - 36.0 / 60) < 1e-9 && abs(w.lonSize - 432.0 / 60) < 1e-9)
        // Above 60 degrees blocks are twice as wide, and odd numbers fall to the even one below.
        let polar = pack([(0b1000, 4), (405_001, 20)]) + full
        let p = try #require(FISB.radarBlocks(FISB.APDU(productID: 64, stamp: .init(hours: 9, minutes: 0), payload: polar), near: now).first)
        #expect(p.blockNumber == 405_000 && abs(p.lonSize - 96.0 / 60) < 1e-9)
    }

    @Test func aBlockNumberPastTheLastRingStaysOnTheEarth() throws {
        let full = [UInt8](repeating: 31 << 3, count: 4)
        // Run-length, north then south, block 0xFFFFF.
        for flags in [0b1000, 0b1100] {
            let run = pack([(flags, 4), (0xFFFFF, 20)]) + full
            let b = try #require(FISB.radarBlocks(FISB.APDU(productID: 64, stamp: .init(hours: 9, minutes: 0), payload: run), near: now).first)
            #expect(b.north <= 90 && b.north - b.latSize >= -90)
        }
    }

    @Test func aRunLengthBlockOfTheWrongSizeIsDropped() {
        let short = FISB.APDU(productID: 63, stamp: .init(hours: 9, minutes: 0), payload: [0x84, 0xA5, 0x70, 0x30, 0x89])
        #expect(FISB.radarBlocks(short, near: now).isEmpty)
        let other = FISB.APDU(productID: 413, stamp: .init(hours: 9, minutes: 0), payload: [0x84, 0xA5, 0x70, 31 << 3, 31 << 3, 31 << 3, 31 << 3])
        #expect(FISB.radarBlocks(other, near: now).isEmpty)
    }
}

@Suite struct FISBWeatherTests {
    private static let places: [String: Coordinate] = ["KSLE": here, "KPDX": Coordinate(latitude: 45.6, longitude: -122.6)]

    private func store() -> FISBWeather { FISBWeather(locate: { Self.places[$0] }) }

    private func datagram(_ records: [String]) -> [UInt8] {
        GDL90.frame(uplink(textApdu(records)))
    }

    private func downloaded(_ station: String, observed: Date) -> Metar {
        Metar(station: station, coordinate: here, category: .vfr, ceilingFtAGL: nil, visibilityMiles: 10, visibilityOrMore: true,
              windDirection: nil, windVariable: false, windSpeedKt: nil, windGustKt: nil, temperatureC: nil,
              dewpointC: nil, altimeterInHg: nil, observed: observed, raw: "downloaded")
    }

    @Test func aDatagramFillsMetarsAndTafs() {
        var fisb = store()
        fisb.receive(datagram: datagram(["METAR KSLE 260855Z 18006KT 10SM FEW050 12/08 A3001=", "METAR KXXX 260855Z 18006KT 10SM CLR=",
                               "TAF KPDX 260900Z 2609/2709 18006KT P6SM SKC="]), at: now)
        #expect(fisb.metars.keys.sorted() == ["KSLE"])
        #expect(fisb.metars["KSLE"]?.coordinate == here && fisb.metars["KSLE"]?.altimeterInHg == 30.01)
        #expect(fisb.tafs["KPDX"]?.groups.count == 1)
    }

    @Test func aNewerReportReplacesAndAnOlderOneDoesNot() {
        var fisb = store()
        fisb.receive(datagram: datagram(["METAR KSLE 260855Z 18006KT 10SM CLR="]), at: now)
        fisb.receive(datagram: datagram(["SPECI KSLE 260900Z 18010KT 3SM BKN010="]), at: now)
        #expect(fisb.metars["KSLE"]?.windSpeedKt == 10)
        fisb.receive(datagram: datagram(["METAR KSLE 260855Z 18006KT 10SM CLR="]), at: now)
        #expect(fisb.metars["KSLE"]?.windSpeedKt == 10)
    }

    @Test func reportsFillOrReplaceDownloadedOnesByObservationTime() {
        var fisb = store()
        fisb.receive(datagram: datagram(["METAR KSLE 260855Z 18006KT 10SM CLR=", "METAR KPDX 260855Z 18006KT 10SM CLR="]), at: now)
        var weather = WeatherData()
        weather.metars = [downloaded("KSLE", observed: now.addingTimeInterval(-3600)),
                          downloaded("KPDX", observed: now.addingTimeInterval(-600)), downloaded("KBDN", observed: now)]
        weather.checkedAt[.metars] = now.addingTimeInterval(-3000)
        let merged = fisb.merged(into: weather, at: now)
        // KSLE is older than the uplink and replaced; KPDX was observed after it and stays; KBDN has none.
        #expect(merged.metars.filter { $0.station == "KSLE" }.map(\.raw) == ["METAR KSLE 260855Z 18006KT 10SM CLR"])
        #expect(merged.metars.filter { $0.station == "KPDX" }.map(\.raw) == ["downloaded"])
        #expect(merged.metars.count == 3)
        #expect(merged.checkedAt[.metars] == now)
        // With no download at all the uplink fills the station.
        #expect(fisb.merged(into: WeatherData(), at: now).metars.count == 2)
        #expect(FISBWeather(locate: { _ in nil }).merged(into: weather, at: now) == weather)
    }

    @Test func tafsMergeByIssueTime() throws {
        var fisb = store()
        fisb.receive(datagram: datagram(["TAF KSLE 260900Z 2609/2709 18006KT P6SM SKC="]), at: now)
        let old = try #require(Taf.parse("TAF KSLE 260300Z 2603/2703 18006KT P6SM SKC", near: now))
        var weather = WeatherData()
        weather.tafs = [old]
        #expect(fisb.merged(into: weather, at: now).tafs.map(\.issued) == [now.addingTimeInterval(-1800)])
        let newer = try #require(Taf.parse("TAF KSLE 260930Z 2609/2709 18006KT P6SM SKC", near: now))
        weather.tafs = [newer]
        #expect(fisb.merged(into: weather, at: now).tafs == [newer])
    }

    @Test func reportsExpireByTheDownloadedRules() {
        var fisb = store()
        fisb.receive(datagram: datagram(["METAR KSLE 260855Z 18006KT 10SM CLR=", "TAF KSLE 260900Z 2609/2709 18006KT P6SM SKC="]), at: now)
        let observed = now.addingTimeInterval(-35 * 60)
        #expect(fisb.nextChange(after: now) == observed.addingTimeInterval(WeatherGeoJSON.reportLife + NextChange.past))
        fisb.prune(now: observed.addingTimeInterval(WeatherGeoJSON.reportLife))
        #expect(fisb.metars.count == 1)
        fisb.prune(now: observed.addingTimeInterval(WeatherGeoJSON.reportLife + 1))
        #expect(fisb.metars.isEmpty && fisb.tafs.count == 1)
        fisb.prune(now: Date(timeIntervalSince1970: 1_792_972_800 + 33 * 3600))
        #expect(fisb.tafs.isEmpty)
        // One that is already too old, or from the future, is not kept.
        fisb.receive(datagram: datagram(["METAR KSLE 260455Z 18006KT 10SM CLR=", "METAR KPDX 261355Z 18006KT 10SM CLR="]), at: now)
        #expect(fisb.metars.isEmpty)
    }

    @Test func radarBlocksArriveAndGoStale() {
        var fisb = store()
        let blocks = uplink(iframe(apduHeader(63, hours: 9, minutes: 10) + [0x84, 0xA5, 0x70] + [UInt8](repeating: 31 << 3 | 3, count: 4))
                            + iframe(apduHeader(64, hours: 9, minutes: 10) + [0xA4, 0xA5, 0x70] + [UInt8](repeating: 31 << 3 | 2, count: 4)))
        fisb.receive(datagram: GDL90.frame(blocks), at: now)
        #expect(fisb.radarBlocks(at: now).map(\.scale) == [2, 0])
        // A newer block of the same place replaces it; an older one does not.
        let newer = uplink(iframe(apduHeader(63, hours: 9, minutes: 20) + [0x84, 0xA5, 0x70] + [UInt8](repeating: 31 << 3 | 5, count: 4)))
        fisb.receive(datagram: GDL90.frame(newer), at: now)
        fisb.receive(datagram: GDL90.frame(blocks), at: now)
        #expect(fisb.radarBlocks(at: now).last?.bins.first == 5)
        let current = WeatherSource.radar.currentFor
        #expect(fisb.radarBlocks(at: now.addingTimeInterval(600)).count == 1)
        #expect(fisb.radarBlocks(at: now.addingTimeInterval(current + 700)).isEmpty)
        #expect(fisb.nextChange(after: now) == now.addingTimeInterval(-1200 + current + NextChange.past))
    }

    @Test func theTrafficStoreIgnoresUplinksAndReadsTheSameDatagram() {
        var traffic = TrafficStore()
        let bytes = GDL90.frame(gdl90Heartbeat(gps: true)) + datagram(["METAR KSLE 260855Z 18006KT 10SM CLR="])
        traffic.receive(datagram: bytes, at: now)
        #expect(traffic.status.gpsValid && traffic.targetCount == 0)
        var fisb = store()
        fisb.receive(datagram: bytes, at: now)
        #expect(fisb.metars.count == 1)
    }
}
