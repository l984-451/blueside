import Foundation
import Testing
@testable import FlightCore

private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private func airport(_ ident: String, _ lat: Double, _ lon: Double) -> RouteWaypoint {
    RouteWaypoint(kind: .airport, ident: ident, name: ident, coordinate: Coordinate(latitude: lat, longitude: lon))
}

/// KAUS to KDAL, about 165 nm on a course of about 014°; its middle sits near 31.52 N 97.26 W.
private let route = Route(waypoints: [airport("KAUS", 30.1945, -97.6699), airport("KDAL", 32.8471, -96.8518)],
                          navCycle: "2026-10-01")!
private let mid = (lat: 31.52, lon: -97.26)
private let departure = at("2026-10-15T14:00:00Z")
private let inputs = FlightPlanInputs(cruiseAltitudeFt: 5500, departure: departure)

/// A square around a point east of the route's middle; 1° of longitude is about 49 nm across the route there.
private func box(east: Double, half: Double) -> WeatherShape {
    let (la, lo) = (mid.lat, mid.lon + east)
    return .polygon([(la - half, lo - half), (la - half, lo + half), (la + half, lo + half), (la + half, lo - half),
                     (la - half, lo - half)].map { Coordinate(latitude: $0.0, longitude: $0.1) })
}

private func sigmet(_ hazard: String, _ shape: WeatherShape) -> Sigmet {
    Sigmet(hazard: hazard, severity: nil, kind: "SIGMET", validFrom: departure - 3600, validTo: departure + 7200,
           baseFtMSL: 0, topFtMSL: 12000, raw: hazard, shape: shape)
}

private func tfr(_ notam: String, effective: Date?, shape: WeatherShape?) -> Tfr {
    Tfr(notam: notam, kind: nil, facility: nil, state: nil, title: notam, rule: nil, name: nil, issued: departure - 86400,
        effective: effective, expires: nil, upper: TfrAltitude(value: 180, unit: "FL", reference: "MSL"),
        lower: TfrAltitude(value: 0, unit: "FT", reference: "AGL"), shape: shape)
}

private func pirep(east: Double, urgent: Bool) -> Pirep {
    Pirep(observed: departure - 600, coordinate: Coordinate(latitude: mid.lat, longitude: mid.lon + east),
          altitudeFtMSL: 6000, urgent: urgent, aircraft: "C172", turbulence: nil, icing: nil, raw: "PIREP \(east)")
}

private func brief(_ weather: WeatherData) -> FlightBrief {
    let plan = FlightPlan.make(route: route, inputs: inputs, trueAirspeedKt: 120, burnGPH: 9, winds: nil, tafs: [])
    return FlightBrief.make(route: route, inputs: inputs, plan: plan, aircraft: nil, balance: nil, weather: weather,
                            now: departure - 1800, localOffsetSeconds: -5 * 3600)
}

private func titles(_ b: FlightBrief, _ section: String) -> [String] {
    b.sections.first { $0.title == section }?.lines.map(\.title) ?? []
}

@Suite struct FlightBriefTests {
    // With no landing point, the Plan section names no verdict for weight and balance.
    @Test func weightAndBalanceWithNoLandingGivesNoVerdict() throws {
        var p = AircraftTemplates.named("Beechcraft A36 Bonanza")
        (p.tail, p.emptyWeightLb, p.emptyArmIn) = ("N36", 2500, 83.0)
        let plan = FlightPlan.make(route: route, inputs: inputs, trueAirspeedKt: 120, burnGPH: 9, winds: nil, tafs: [])
        func line(burned: Double?) throws -> NavPages.Line? {
            let wb = try #require(WeightBalance(profile: p, stationWeightsLb: [200, 170, 100, 0, 70], startFuelGal: 74, burnedGal: burned))
            return FlightBrief.make(route: route, inputs: inputs, plan: plan, aircraft: p, balance: wb, weather: WeatherData(),
                                    now: departure - 1800).sections.flatMap(\.lines).first { $0.title == "Weight and balance" }
        }
        #expect(try line(burned: nil)?.value == NavText.dashes)
        #expect(try line(burned: 30)?.value == WeightBalance.withinLimits)
    }

    @Test func sectionsComeInBriefingOrderUnderTheNotice() {
        let b = brief(WeatherData())
        #expect(b.notice.hasPrefix("Not an official briefing"))
        #expect(b.sections.map(\.title) == ["Flight", "Adverse conditions", Tfr.listTitle, "Current conditions",
                                            "Destination forecast", "Winds aloft", "NOTAMs", "PIREPs", "Plan"])
        #expect(titles(b, "NOTAMs") == [FlightBrief.notamsBlocked])
        #expect(b.fileName == "Brief KAUS-KDAL 2026-10-15 1400Z.pdf")
        #expect(b.sections[0].lines.first { $0.title == "Departure" }?.value == "2026-10-15 1400Z (0900 local)")
        // Nothing held reads as not available, never as all clear.
        #expect(b.sections[1].warning?.contains("SIGMETs not available") == true)
        #expect(titles(b, "Current conditions") == ["Departure KAUS", "Destination KDAL"])
    }

    @Test func sigmetCrossingOrBesideTheRouteCountsAndOneFarOffDoesNot() {
        var w = WeatherData()
        w.sigmets = [sigmet("CROSSING", box(east: 0, half: 0.3)), sigmet("BESIDE", box(east: 0.55, half: 0.1)),
                     sigmet("FAR", box(east: 1.5, half: 0.3))]
        let b = brief(w)
        #expect(titles(b, "Adverse conditions") == ["CROSSING SIGMET", "BESIDE SIGMET"])
        // Surface to 12000 ft holds the 5500 ft cruise.
        #expect(b.sections[1].lines[0].tag == FlightBrief.atAltitude)
    }

    @Test func cwaMeetingTheRouteCountsAndOneFarOffDoesNot() {
        var w = WeatherData()
        func cwa(_ series: String, _ shape: WeatherShape) -> Cwa {
            Cwa(center: "ZFW", series: series, hazard: "TS", qualifier: "", validFrom: departure - 600, validTo: departure + 6600,
                baseFtMSL: nil, topFtMSL: 40000, raw: series, shape: shape)
        }
        w.cwas = [cwa("101", box(east: 0, half: 0.3)), cwa("102", box(east: 1.5, half: 0.3))]
        let b = brief(w)
        #expect(titles(b, "Adverse conditions") == ["TS CWA ZFW 101"])
        #expect(b.sections[1].lines[0].tag == FlightBrief.atAltitude)
        #expect(b.sections[1].warning?.contains("CWAs not available") == true)
    }

    @Test func gairmetSnapshotsOfOneTagMakeOneRow() {
        var w = WeatherData()
        let g = GAirmet(product: "SIERRA", tag: "1S", hazard: "IFR", severity: nil, issued: departure, valid: departure,
                        expires: departure + 21600, dueTo: "CIG BLW 010", base: nil, top: nil, level: nil,
                        freezingBase: nil, freezingTop: nil, shape: box(east: 0, half: 0.3))
        var later = g
        later.valid = departure + GAirmet.snapshotSpacing
        w.gairmets = [g, later]
        #expect(titles(brief(w), "Adverse conditions") == ["G-AIRMET IFR"])
    }

    @Test func tfrStartingInsideTheWindowCountsAndOneAfterDoesNot() {
        var w = WeatherData()
        // ETA is about 1523Z, so the window runs to about 1623Z.
        w.tfrs = [tfr("SOON", effective: departure + 1800, shape: box(east: 0, half: 0.1)),
                  tfr("LATER", effective: departure + 4 * 3600, shape: box(east: 0, half: 0.1)),
                  tfr("NATIONWIDE", effective: nil, shape: nil)]
        let b = brief(w)
        #expect(titles(b, "Adverse conditions") == ["TFR SOON"])
        #expect(b.sections[1].lines[0].tag == FlightBrief.atAltitude)
        #expect(titles(b, Tfr.listTitle) == ["TFR NATIONWIDE"])
    }

    @Test func anUnreadableTfrSaysSoAndInventsNoTimesOrLevels() throws {
        // The pipeline's shape for a notice whose detail could not be read.
        let unread = #"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":null,"properties":{"notam":"6/1234","kind":"SECURITY","facility":"ZFW","state":"TX","title":"DALLAS, TX","rule":null,"issued":"2026-10-12T10:55:00Z","name":null,"upper_value":null,"upper_unit":null,"upper_ref":null,"lower_value":null,"lower_unit":null,"lower_ref":null,"effective":null,"expires":null,"unreadable":true}}]}"#
        var w = WeatherData()
        w.tfrs = try Tfr.decode(Data(unread.utf8))
        let line = try #require(brief(w).sections.first { $0.title == Tfr.listTitle }?.lines.first)
        #expect(line.title == "TFR 6/1234" && line.value == nil && line.detail == "DALLAS, TX\n" + Tfr.unreadableNote)
    }

    @Test func pirepOutsideTheCorridorIsDropped() {
        var w = WeatherData()
        w.pireps = [pirep(east: 0.3, urgent: true), pirep(east: 1.0, urgent: false)]
        let b = brief(w)
        #expect(b.sections.first { $0.title == "PIREPs" }?.lines.map(\.detail) == ["PIREP 0.3"])
        // Urgent and within 2000 ft of cruise: listed as adverse at your altitude.
        let adverse = b.sections[1].lines
        #expect(adverse.map(\.title) == ["Urgent PIREP 6000 ft"] && adverse[0].tag == FlightBrief.atAltitude)
    }
}
