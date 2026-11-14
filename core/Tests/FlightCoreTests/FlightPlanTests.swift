import Foundation
import Testing
@testable import FlightCore

private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

/// FBUS31 KWNO 142000, DATA BASED ON 141800Z, VALID 150000Z FOR USE 2000-0300Z, worked by hand from these lines:
///   ABI      1725+19 2126+12 2125+09 2141-05 2145-15 214529 233740 223951
///   ABR 9900 2306+07 2413+06 2421+00 2223-14 2344-22 245739 731045 731352
///   ATL 2805 3405+18 9900+15 9900+08 0410-05 9900-15 011029 331039 230850
/// ABI's position is the spec's example; ABR and ATL positions are placeholders, only decoding is checked.
private let bulletin = #"""
{"version": 1, "forecasts": [{"based": "2026-10-14T18:00:00Z", "valid": "2026-10-15T00:00:00Z",
 "from": "2026-10-14T20:00:00Z", "to": "2026-10-15T03:00:00Z", "stations": [
 {"id": "ABI", "lat": 32.48, "lon": -99.86, "levels": [
  {"ft": 39000, "dir": 220, "kt": 39, "temp": -51}, {"ft": 6000, "dir": 170, "kt": 25, "temp": 19},
  {"ft": 9000, "dir": 210, "kt": 26, "temp": 12}, {"ft": 12000, "dir": 210, "kt": 25, "temp": 9},
  {"ft": 18000, "dir": 210, "kt": 41, "temp": -5}, {"ft": 24000, "dir": 210, "kt": 45, "temp": -15},
  {"ft": 30000, "dir": 210, "kt": 45, "temp": -29}, {"ft": 34000, "dir": 230, "kt": 37, "temp": -40}]},
 {"id": "ABR", "lat": 45, "lon": -98, "levels": [
  {"ft": 3000, "dir": null, "kt": 0, "temp": null}, {"ft": 6000, "dir": 230, "kt": 6, "temp": 7},
  {"ft": 30000, "dir": 240, "kt": 57, "temp": -39}, {"ft": 34000, "dir": 230, "kt": 110, "temp": -45},
  {"ft": 39000, "dir": 230, "kt": 113, "temp": -52}]},
 {"id": "ATL", "lat": 34, "lon": -84, "levels": [
  {"ft": 3000, "dir": 280, "kt": 5, "temp": null}, {"ft": 9000, "dir": null, "kt": 0, "temp": 15},
  {"ft": 39000, "dir": 230, "kt": 8, "temp": -50}]}]}]}
"""#

private func station(_ id: String, _ lat: Double, _ lon: Double, _ levels: [WindsAloft.Level]) -> WindsAloft.Station {
    WindsAloft.Station(id: id, lat: lat, lon: lon, levels: levels)
}

private func level(_ ft: Int, _ dir: Int?, _ kt: Int, _ temp: Int? = nil) -> WindsAloft.Level {
    WindsAloft.Level(ft: ft, dir: dir, kt: kt, temp: temp)
}

private func winds(_ stations: [WindsAloft.Station], from: String = "2026-10-15T00:00:00Z",
                   to: String = "2026-10-15T06:00:00Z") -> WindsAloft {
    WindsAloft(forecasts: [WindsAloft.Forecast(based: at(from), valid: at(from), from: at(from), to: at(to),
                                               stations: stations)])
}

private func airport(_ ident: String, _ lat: Double, _ lon: Double) -> RouteWaypoint {
    RouteWaypoint(kind: .airport, ident: ident, name: ident, coordinate: Coordinate(latitude: lat, longitude: lon))
}

// Positions only feed both this code and the reference calculators, so they need not be surveyed values.
private let kaus = airport("KAUS", 30.1945, -97.6699)
private let kdal = airport("KDAL", 32.8471, -96.8518)

@Suite struct WindsAloftTests {
    @Test func decodesTheWireFormatWithLevelsLowestFirst() throws {
        let w = try WindsAloft.decode(Data(bulletin.utf8))
        let f = try #require(w.forecasts.first)
        #expect(f.from == at("2026-10-14T20:00:00Z") && f.to == at("2026-10-15T03:00:00Z"))
        #expect(f.stations.map(\.id) == ["ABI", "ABR", "ATL"])
        let abi = f.stations[0]
        #expect(abi.levels.map(\.ft) == [6000, 9000, 12000, 18000, 24000, 30000, 34000, 39000])
        #expect(abi.levels[0] == level(6000, 170, 25, 19))
        // 9900 is light and variable; 731045 is 230° at 110 kt, -45 °C.
        #expect(f.stations[1].levels[0] == level(3000, nil, 0))
        #expect(f.stations[1].levels[3] == level(34000, 230, 110, -45))
    }

    @Test func rejectsAnUnknownVersionAndAFileWithNoStations() {
        #expect(throws: WeatherError.unsupportedVersion(2)) { try WindsAloft.decode(Data(#"{"version":2,"forecasts":[]}"#.utf8)) }
        #expect(throws: WeatherError.empty(.winds)) { try WindsAloft.decode(Data(#"{"version":1,"forecasts":[]}"#.utf8)) }
        var data = WeatherData()
        #expect(throws: WeatherError.unsupportedVersion(2)) { try data.take(.winds, json: Data(#"{"version":2}"#.utf8)) }
        #expect(throws: Never.self) { try data.take(.winds, json: Data(bulletin.utf8)) }
        #expect(data.winds?.forecasts.count == 1)
    }

    @Test func threeFiftyAndTenAverageToNorthNotSouth() {
        let w = winds([station("W", 35, -98.2, [level(6000, 350, 20)]), station("E", 35, -97.8, [level(6000, 10, 20)])])
        let s = WindsAloft.sample(w.forecasts[0].stations, at: Coordinate(latitude: 35, longitude: -98),
                                  altitudeFt: 6000)!
        let wind = WindsAloft.wind(u: s.u, v: s.v)
        #expect(abs(remainder(wind.directionTrue, 360)) < 0.01)
        #expect(abs(wind.speedKt - 20 * cos(10 * Double.pi / 180)) < 0.01)
    }

    @Test func altitudeIsLinearBetweenLevelsAndHeldAtTheEnds() throws {
        let s = station("S", 35, -98, [level(3000, 270, 10), level(6000, 270, 30, 10), level(9000, 270, 40, 4)])
        func speed(_ ft: Double) throws -> Double {
            let a = try #require(s.at(altitudeFt: ft))
            return (a.u * a.u + a.v * a.v).squareRoot()
        }
        #expect(abs(try speed(4500) - 20) < 1e-9)
        #expect(abs(try speed(1000) - 10) < 1e-9)
        #expect(abs(try speed(20000) - 40) < 1e-9)
        // 3000 ft carries no temperature, so the lowest level that does is held below it.
        #expect(s.at(altitudeFt: 4500)?.temp == 10)
        #expect(s.at(altitudeFt: 7500)?.temp == 7)
        #expect(s.at(altitudeFt: 12000)?.temp == 4)
    }

    @Test func stationsBeyondReachLeaveTheLegCalm() {
        let far = winds([station("F", 45, -98, [level(6000, 270, 30)])])
        #expect(far.leg(from: kaus.coordinate, to: kdal.coordinate, altitudeFt: 6000, at: at("2026-10-15T01:00:00Z")) == nil)
        // A station near the start only: samples past 300 nm of it count as calm.
        let near = winds([station("N", 30.2, -97.7, [level(6000, 270, 30)])])
        let long = airport("KDEN", 39.86, -104.67)
        let leg = near.leg(from: kaus.coordinate, to: long.coordinate, altitudeFt: 6000, at: at("2026-10-15T01:00:00Z"))
        #expect((leg?.calmSamples ?? 0) > 0)
        #expect((leg?.wind.speedKt ?? 99) < 30)
    }

    @Test func aLegOutsideEveryUseWindowTakesTheNearestForecastAndSaysSo() {
        let w = winds([station("N", 31, -97.3, [level(6000, 180, 20)])])
        let inside = w.leg(from: kaus.coordinate, to: kdal.coordinate, altitudeFt: 6000, at: at("2026-10-15T01:00:00Z"))
        let after = w.leg(from: kaus.coordinate, to: kdal.coordinate, altitudeFt: 6000, at: at("2026-10-15T09:00:00Z"))
        #expect(inside?.inUseWindow == true)
        #expect(after?.inUseWindow == false && after?.wind.speedKt ?? 0 > 19)
    }

    // The window is 00Z to 06Z. Planned at 05Z for 07Z it is still the forecast to use; at 07Z it is stale.
    @Test func aForecastWhoseWindowHasEndedIsNeverUsed() throws {
        let w = winds([station("N", 31, -97.3, [level(6000, 180, 20)])])
        let route = try #require(Route(waypoints: [kaus, kdal], navCycle: "2026-10-01"))
        func make(now: String) -> FlightPlan {
            FlightPlan.make(route: route, inputs: FlightPlanInputs(cruiseAltitudeFt: 6000, departure: at("2026-10-15T07:00:00Z")),
                            trueAirspeedKt: 120, burnGPH: 10, winds: w, tafs: [], now: at(now))
        }
        #expect(make(now: "2026-10-15T05:00:00Z").legWinds[0].note == "Forecast outside use window")
        let stale = make(now: "2026-10-15T07:00:00Z")
        #expect(stale.legWinds[0].note == "No winds aloft: calm assumed" && stale.log.legs[0].windIsAssumedCalm)
        #expect(w.unexpired(at: at("2026-10-15T05:59:59Z")) == w && w.unexpired(at: at("2026-10-15T06:00:00Z")) == nil)
        // The brief draws no barbs or freezing level from it either.
        var weather = WeatherData()
        weather.winds = w
        func profile(now: String) -> BriefProfile {
            let p = make(now: now)
            return FlightBrief.make(route: route, inputs: FlightPlanInputs(cruiseAltitudeFt: 6000, departure: p.departure),
                                    plan: p, aircraft: nil, balance: nil, weather: weather, now: at(now)).graphics.profile
        }
        #expect(!profile(now: "2026-10-15T05:00:00Z").winds.isEmpty)
        #expect(profile(now: "2026-10-15T07:00:00Z").winds.isEmpty)
    }
}

@Suite struct SunTests {
    private func near(_ date: Date?, _ text: String, _ seconds: TimeInterval = 60) -> Bool {
        guard let date else { return false }
        return abs(date.timeIntervalSince(at(text))) <= seconds
    }

    // Sunrise and sunset: NOAA Solar Calculator (gml.noaa.gov/grad/solcalc main.js, calcSunriseSetUTC), run 2026-10-14.
    // Civil twilight: USNO aa.usno.navy.mil/api/rstt/oneday, read 2026-10-14; NOAA's calculator does not show it.
    @Test func austinMatchesNoaaAndUsno() {
        let sun = Sun.times(near: at("2026-10-15T18:00:00Z"), at: kaus.coordinate)
        #expect(near(sun.sunrise, "2026-10-15T12:32:47Z"))
        #expect(near(sun.sunset, "2026-10-15T23:59:32Z"))
        #expect(near(sun.civilDawn, "2026-10-15T12:09:00Z"))
        #expect(near(sun.civilDusk, "2026-10-16T00:24:00Z"))
    }

    @Test func bostonSolsticeMatchesNoaaAndUsno() {
        let sun = Sun.times(near: at("2026-06-21T22:00:00Z"), at: Coordinate(latitude: 42.3656, longitude: -71.0096))
        #expect(near(sun.sunrise, "2026-06-21T09:07:18Z"))
        #expect(near(sun.sunset, "2026-06-22T00:24:31Z"))
        #expect(near(sun.civilDawn, "2026-06-21T08:33:00Z"))
        #expect(near(sun.civilDusk, "2026-06-22T00:59:00Z"))
    }

    @Test func honoluluEquinoxMatchesNoaaAndUsno() {
        let sun = Sun.times(near: at("2026-03-20T20:00:00Z"), at: Coordinate(latitude: 21.3187, longitude: -157.9225))
        #expect(near(sun.sunrise, "2026-03-20T16:35:26Z"))
        #expect(near(sun.sunset, "2026-03-21T04:42:52Z"))
        #expect(near(sun.civilDawn, "2026-03-20T16:13:00Z"))
        #expect(near(sun.civilDusk, "2026-03-21T05:05:00Z"))
    }

    @Test func anchorageWinterSolsticeMatchesNoaa() {
        let sun = Sun.times(near: at("2026-12-21T22:00:00Z"), at: Coordinate(latitude: 61.1743, longitude: -149.9963))
        #expect(near(sun.sunrise, "2026-12-21T19:14:16Z"))
        #expect(near(sun.sunset, "2026-12-22T00:42:16Z"))
    }

    @Test func anEveningTimeBelongsToThatLocalDay() {
        // 22:00 CDT on 15 Oct is 03:00Z on the 16th; the sunset shown is the one just past.
        let sun = Sun.times(near: at("2026-10-16T03:00:00Z"), at: kaus.coordinate)
        #expect(near(sun.sunset, "2026-10-15T23:59:32Z"))
    }
}

@Suite struct FlightPlanTests {
    private func route(_ points: RouteWaypoint...) throws -> Route {
        try #require(Route(waypoints: points, navCycle: "2026-10-01"))
    }

    private func plan(_ route: Route, departure: String, rules: FlightPlanInputs.Rules = .vfr, altitude: Int = 5500,
                      alternate: RouteWaypoint? = nil, winds: WindsAloft? = nil, tafs: [Taf] = [],
                      hasApproach: Bool? = true, onBoard: Double? = nil) -> FlightPlan {
        FlightPlan.make(route: route, inputs: FlightPlanInputs(cruiseAltitudeFt: altitude, departure: at(departure),
                                                               rules: rules, alternate: alternate),
                        trueAirspeedKt: 120, burnGPH: 10, taxiFuelGal: 1.5, fuelOnBoardGal: onBoard, winds: winds,
                        tafs: tafs, destinationHasApproach: hasApproach)
    }

    @Test func departureDefaultsToTheNextQuarterHour() {
        #expect(FlightPlanInputs.defaultDeparture(now: at("2026-10-15T13:07:10Z")) == at("2026-10-15T13:15:00Z"))
        #expect(FlightPlanInputs.defaultDeparture(now: at("2026-10-15T13:15:00Z")) == at("2026-10-15T13:15:00Z"))
    }

    @Test func aHeadwindSlowsTheLogAndRaisesTripFuel() throws {
        let r = try route(kaus, kdal)
        let calm = plan(r, departure: "2026-10-15T01:00:00Z")
        let headwind = winds([station("DAL", 32.85, -96.85, [level(6000, 20, 30)]),
                              station("AUS", 30.19, -97.67, [level(6000, 20, 30)])])
        let windy = plan(r, departure: "2026-10-15T01:00:00Z", winds: headwind)
        #expect(calm.log.legs[0].windIsAssumedCalm && !windy.log.legs[0].windIsAssumedCalm)
        #expect(try #require(windy.log.totalTime) > (try #require(calm.log.totalTime)) * 1.2)
        #expect(try #require(windy.fuel?.trip) > (try #require(calm.fuel?.trip)))
        #expect(windy.legWinds[0].wind?.hasPrefix("020° 30 kt") == true)
        #expect(calm.legWinds[0].note == "No winds aloft: calm assumed")
    }

    // 14 CFR 91.151(a): 30 minutes by day, 45 at night; night per 14 CFR 1.1 from civil twilight.
    // KAUS evening civil twilight ends about 00:24Z on 16 Oct 2026 (USNO).
    @Test func vfrReserveIs30MinutesByDayAnd45AtNightPer91_151() throws {
        let short = try route(kaus, airport("X", 30.1945, -97.48))
        let day = plan(short, departure: "2026-10-16T00:05:00Z")
        let night = plan(short, departure: "2026-10-16T00:30:00Z")
        #expect(!day.night && day.reserveMinutes == 30 && day.fuel?.reserve == 5)
        #expect(night.night && night.reserveMinutes == 45 && night.fuel?.reserve == 7.5)
        #expect(night.reserveRule.contains("91.151(a)(2)"))
        // Departing by day but landing after twilight ends is a night flight.
        let landsAtDusk = plan(short, departure: "2026-10-16T00:21:00Z")
        #expect(landsAtDusk.night)
    }

    // 14 CFR 91.167(a)(3): IFR reserve is 45 minutes, day or night.
    @Test func ifrReserveIs45MinutesPer91_167() throws {
        let p = plan(try route(kaus, kdal), departure: "2026-10-15T18:00:00Z", rules: .ifr)
        #expect(p.reserveMinutes == 45 && p.reserveRule.contains("91.167"))
    }

    @Test func requiredFuelAddsTaxiTripAlternateAndReserve() throws {
        let p = plan(try route(kaus, kdal), departure: "2026-10-15T18:00:00Z", alternate: airport("KACT", 31.61, -97.23),
                     onBoard: 40)
        let fuel = try #require(p.fuel)
        let alt = try #require(fuel.alternate)
        #expect(alt > 0)
        #expect(abs(fuel.required - (1.5 + fuel.trip + alt + 5)) < 1e-9)
        let margin = try #require(p.lines.first { $0.title == "Margin" })
        #expect(margin.tag == nil)
        let short = plan(try route(kaus, kdal), departure: "2026-10-15T18:00:00Z", onBoard: 5)
        #expect(short.lines.first { $0.title == "Margin" }?.tag == "Short")
    }

    private func taf(ceiling: Int, visibility: Double, tempoCeiling: Int? = nil) -> Taf {
        let from = at("2026-10-15T12:00:00Z"), to = at("2026-10-16T12:00:00Z")
        func group(_ kind: TafGroup.Kind, _ ceiling: Int) -> TafGroup {
            TafGroup(kind: kind, from: from, to: to, becomingBy: nil, probability: nil, windDirection: 180,
                     windVariable: false, windSpeedKt: 10, windGustKt: nil, visibilityMiles: visibility,
                     visibilityOrMore: false, weather: nil, sky: [SkyLayer(cover: "OVC", baseFtAGL: ceiling, cloudType: nil)],
                     verticalVisibilityFt: nil, windShear: nil)
        }
        var groups = [group(.initial, ceiling)]
        if let tempoCeiling { groups.append(group(.temporary, tempoCeiling)) }
        return Taf(station: "KDAL", issued: from, validFrom: from, validTo: to, raw: "TAF KDAL", groups: groups)
    }

    // 14 CFR 91.169(b): no alternate with an approach and 2000 ft / 3 SM forecast from 1 h before to 1 h after ETA.
    @Test func alternateAdviceFollows91_169b() throws {
        let r = try route(kaus, kdal)
        let dep = "2026-10-15T18:00:00Z"
        let good = plan(r, departure: dep, rules: .ifr, tafs: [taf(ceiling: 2500, visibility: 6)])
        #expect(good.alternate?.required == false)
        let low = plan(r, departure: dep, rules: .ifr, tafs: [taf(ceiling: 1500, visibility: 6)])
        #expect(low.alternate?.required == true)
        let tempo = plan(r, departure: dep, rules: .ifr, tafs: [taf(ceiling: 2500, visibility: 6, tempoCeiling: 1200)])
        #expect(tempo.alternate?.required == true)
        let none = plan(r, departure: dep, rules: .ifr)
        #expect(none.alternate == FlightPlan.Alternate(required: nil, text: "No TAF: check the alternate rule yourself."))
        let unknownApproach = plan(r, departure: dep, rules: .ifr, tafs: [taf(ceiling: 2500, visibility: 6)], hasApproach: nil)
        #expect(unknownApproach.alternate?.required == nil && unknownApproach.alternate?.text.contains("Could not check") == true)
        let noApproach = plan(r, departure: dep, rules: .ifr, tafs: [taf(ceiling: 2500, visibility: 6)], hasApproach: false)
        #expect(noApproach.alternate?.required == true)
        #expect(plan(r, departure: dep).alternate == nil)
    }

    // An amended TAF wins over the one it replaces, whatever the feed order.
    @Test func alternateAdviceReadsTheNewestTaf() throws {
        var old = taf(ceiling: 4000, visibility: 6)
        old.issued = at("2026-10-15T11:00:00Z")
        let amended = taf(ceiling: 1200, visibility: 6)
        let p = plan(try route(kaus, kdal), departure: "2026-10-15T18:00:00Z", rules: .ifr, tafs: [old, amended])
        #expect(p.alternate?.required == true)
    }

    // 91.167(a)(2): with an alternate required and none picked, no fuel total is shown as enough.
    @Test func ifrFuelIsUnknownWhenARequiredAlternateIsMissing() throws {
        let p = plan(try route(kaus, kdal), departure: "2026-10-15T18:00:00Z", rules: .ifr,
                     tafs: [taf(ceiling: 1200, visibility: 6)])
        #expect(p.alternate?.required == true && p.fuel == nil)
    }

    // 14 CFR 91.159(a) VFR and 91.179(b)(1) IFR cruising altitudes.
    @Test func cruisingAltitudeHintsPer91_159And91_179() {
        #expect(FlightPlan.isLegal(5500, magneticCourse: 90, rules: .vfr) == true)
        #expect(FlightPlan.isLegal(4500, magneticCourse: 90, rules: .vfr) == false)
        #expect(FlightPlan.isLegal(4500, magneticCourse: 270, rules: .vfr) == true)
        #expect(FlightPlan.isLegal(6000, magneticCourse: 270, rules: .vfr) == false)
        #expect(FlightPlan.isLegal(5000, magneticCourse: 179, rules: .ifr) == true)
        #expect(FlightPlan.isLegal(6000, magneticCourse: 180, rules: .ifr) == true)
        #expect(FlightPlan.isLegal(19000, magneticCourse: 90, rules: .ifr) == nil)
    }

    // 91.159(a) applies more than 3000 ft above the surface, which 3000 ft MSL or lower never is.
    @Test func vfrAtOrBelow3000FeetMslHasNoHint() {
        #expect(FlightPlan.isLegal(2500, magneticCourse: 90, rules: .vfr) == nil)
        #expect(FlightPlan.isLegal(3000, magneticCourse: 90, rules: .vfr) == nil)
        #expect(FlightPlan.isLegal(3500, magneticCourse: 90, rules: .vfr) == true)
        #expect(FlightPlan.isLegal(2000, magneticCourse: 90, rules: .ifr) == false)
    }

    // 179.6° prints as 180°M, so it is westbound; 359.6° prints as 360°M, eastbound.
    @Test func theHintJudgesTheCourseAsPrinted() {
        #expect(FlightPlan.isLegal(4500, magneticCourse: 179.6, rules: .vfr) == true)
        #expect(FlightPlan.isLegal(5500, magneticCourse: 179.6, rules: .vfr) == false)
        #expect(FlightPlan.isLegal(5500, magneticCourse: 359.6, rules: .vfr) == true)
        #expect(FlightPlan.tableLevels(magneticCourse: 179.6, rules: .vfr) == [4500, 6500, 8500, 10500])
        #expect(FlightPlan.tableLevels(magneticCourse: 179.4, rules: .vfr) == [3500, 5500, 7500, 9500])
    }

    // A blank burn reaches the core as 0: trip and reserve are unknown, never 0.0 gal.
    @Test func aBurnOfZeroLeavesFuelUnknown() throws {
        let p = FlightPlan.make(route: try route(kaus, kdal), inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: at("2026-10-15T18:00:00Z")),
                                trueAirspeedKt: 120, burnGPH: 0, taxiFuelGal: 1.5, fuelOnBoardGal: 20, winds: nil, tafs: [])
        #expect(p.log.totalTime != nil && p.fuel == nil)
        #expect(p.lines.first { $0.title == "Fuel required" }?.value == NavText.dashes)
        #expect(!p.lines.contains { $0.title == "Margin" })
        // A route too short to cruise flies every leg at the climb or descent burn, so the log has fuel; the plan still has none.
        let vertical = FlightPlan.Vertical(climb: .init(rateFPM: 500, tasKt: 100, burnGPH: 10),
                                           descent: .init(rateFPM: 500, tasKt: 120, burnGPH: 6))
        let short = FlightPlan.make(route: try route(kaus, airport("X", 30.1945, -97.29)),
                                    inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: at("2026-10-15T18:00:00Z")),
                                    trueAirspeedKt: 120, burnGPH: 0, winds: nil, tafs: [], vertical: vertical)
        #expect(short.segments.allSatisfy { $0 != .cruise } && short.log.totalFuel != nil && short.fuel == nil)
    }

    // Direct To KDAL from 60 nm out: parked, the start fuel counts; airborne, it says nothing about the tanks now.
    @Test func airborneTheFuelLoadedBeforeStartIsUnknownAndTheEtaRunsFromNow() throws {
        let now = at("2026-10-15T14:03:10Z"), stored = at("2026-10-15T14:15:00Z")
        func page(knots: Double, onBoard: Double? = 40) throws -> RoutePages.PlanPage {
            let fix = try #require(Position(latitude: 31.85, longitude: -96.85, courseDegrees: 0, speedMetersPerSecond: knots / 1.943844,
                                            altitudeMeters: 1500, timestamp: now))
            return try #require(RoutePages.planPage(.direct(to: kdal, navCycle: "2026-10-01"), position: fix, now: now,
                                                    inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: stored),
                                                    trueAirspeedKt: 120, burnGPH: 10, taxiFuelGal: 1.5, fuelOnBoardGal: onBoard,
                                                    winds: nil, tafs: []))
        }
        let parked = try page(knots: 0)
        #expect(!parked.plan.airborne && parked.plan.departure == stored && parked.plan.fuel?.taxi == 1.5)
        #expect(parked.plan.fuelOnBoard == 40 && parked.plan.lines.contains { $0.title == "Margin" && $0.value != NavText.dashes })
        #expect(parked.start.last != NavText.dashes)

        let flying = try page(knots: 100)
        let p = flying.plan
        let time = try #require(p.log.totalTime)
        #expect(p.airborne && p.departure == now && p.eta == now + time)
        let fuel = try #require(p.fuel)
        #expect(fuel.taxi == 0 && abs(fuel.trip - time / 3600 * 10) < 1e-9 && fuel.reserve == 5)
        #expect(abs(fuel.required - (fuel.trip + 5)) < 1e-9)
        #expect(p.lines.filter { ["On board", "Margin"].contains($0.title) }.map(\.value) == [NavText.dashes, NavText.dashes])
        #expect(flying.start.last == NavText.dashes && flying.legs.values.allSatisfy { $0.cells.last == NavText.dashes })
        // With no fuel on board given there is nothing to show as unknown.
        let unloaded = try page(knots: 100, onBoard: nil)
        #expect(!unloaded.plan.lines.contains { ["On board", "Margin"].contains($0.title) })
    }

    // KAUS to KDAL into a 40 kt headwind: parked, the first leg's Time is the plan's; airborne, it is the live one.
    @Test func theFirstLegKeepsThePlannedTimeUntilAirborne() throws {
        let now = at("2026-10-15T14:03:10Z")
        let headwind = winds([station("ACT", 31.6, -97.2, [level(3000, 15, 40), level(6000, 15, 40), level(9000, 15, 40)])],
                             from: "2026-10-15T12:00:00Z", to: "2026-10-15T18:00:00Z")
        let flight = RoutePlan(route: try route(kaus, kdal))
        func cells(knots: Double) throws -> (page: RoutePages.PlanPage, time: String, live: String?) {
            let fix = try #require(Position(latitude: kaus.coordinate.latitude, longitude: kaus.coordinate.longitude,
                                            courseDegrees: 15, speedMetersPerSecond: knots / 1.943844, altitudeMeters: 165,
                                            timestamp: now))
            let page = try #require(RoutePages.planPage(flight, position: fix, now: now,
                                                        inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: now + 900),
                                                        trueAirspeedKt: 120, burnGPH: 10, winds: headwind, tafs: []))
            let point = try #require(RoutePages.editor(flight, position: fix, now: now, trueAirspeedKt: 120, fuelBurnPerHour: 10)
                .points.first { $0.target == flight.activeLeg })
            return (page, RoutePages.logCells(point, page: page)[RoutePages.logTime], point.leg?.time)
        }
        let parked = try cells(knots: 0)
        let planned = try #require(parked.page.plan.log.legs.first?.time.map(NavText.duration))
        #expect(!parked.page.plan.airborne && planned != parked.live)
        #expect(parked.page.legs[flight.activeLeg]?.time == planned && parked.time == planned)

        let flying = try cells(knots: 100)
        #expect(flying.page.plan.airborne && flying.page.legs[flight.activeLeg]?.time == nil)
        #expect(flying.time == flying.live && flying.live != nil)
    }

    // Northbound VFR: odd thousands plus 500 (14 CFR 91.159(a)), so every listed level is legal.
    @Test func altitudeTableHoldsTheLegalLevelsAndThePick() throws {
        let p = plan(try route(kaus, kdal), departure: "2026-10-15T18:00:00Z", altitude: 8000)
        #expect(p.altitudes.map(\.ft) == [3500, 5500, 7500, 8000, 9500])
        #expect(p.altitudes.filter(\.picked).map(\.ft) == [8000])
        #expect(p.altitudes.filter { $0.legal == false }.map(\.ft) == [8000])
        #expect(p.altitudeLines.count == 5)
    }

    @Test func navLogTakesWindsAndTheDepartureDate() throws {
        let rp = RoutePlan(route: try route(kaus, kdal))
        let now = at("2026-10-15T12:00:00Z")
        let calm = try #require(rp.navLog(position: nil, now: now, trueAirspeedKt: 120, fuelBurnPerHour: 10))
        let windy = try #require(rp.navLog(position: nil, now: now, trueAirspeedKt: 120, fuelBurnPerHour: 10,
                                           winds: [LegWind(directionTrue: 20, speedKt: 30)],
                                           departure: at("2026-10-16T12:00:00Z")))
        #expect(try #require(windy.totalTime) > (try #require(calm.totalTime)))
    }
}
