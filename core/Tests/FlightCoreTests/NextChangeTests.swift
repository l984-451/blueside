import Foundation
import Testing
@testable import FlightCore

private let t0 = Date(timeIntervalSince1970: 1_790_812_800) // 01 Oct 2026 00:00Z

/// Walks time in steps: the words never change before the deadline, and they have changed once it is reached.
private func wakesOnTime<T: Equatable>(from start: Date, hours: Double, step: TimeInterval = 7,
                                       _ output: (Date) -> T, _ next: (Date) -> Date?) {
    let end = start.addingTimeInterval(hours * 3600)
    var now = start
    var woke = 0
    while now < end {
        let shown = output(now)
        guard let deadline = next(now) else {
            var t = now
            while t < end { #expect(output(t) == shown, "\(t)"); t += step }
            return
        }
        #expect(deadline > now)
        var t = now
        while t < deadline, t < end { #expect(output(t) == shown, "changed at \(t) before \(deadline)"); t += step }
        now = deadline
        woke += 1
    }
    #expect(woke > 0)
}

private func metar(observed: Date) -> Metar {
    Metar(station: "KAUS", coordinate: Coordinate(latitude: 30.19, longitude: -97.67), category: .vfr,
          ceilingFtAGL: nil, visibilityMiles: 10, visibilityOrMore: true,
          windDirection: 180, windVariable: false, windSpeedKt: 8, windGustKt: nil,
          temperatureC: 20, dewpointC: 10, altimeterInHg: 30.01, observed: observed, raw: "KAUS 010000Z")
}

@Suite struct NextChangeTests {
    @Test func navDataWarningWakesAtTheCycleEdges() {
        let metadata = NavMetadata(schemaVersion: 1, cycle: "2026-10-01", effective: t0,
                                   expires: t0.addingTimeInterval(28 * 86_400), builtAt: t0)
        #expect(metadata.nextChange(after: t0.addingTimeInterval(-1)) == t0)
        #expect(metadata.nextChange(after: t0) == metadata.expires)
        #expect(metadata.nextChange(after: metadata.expires) == nil)
        #expect(NavText.dataDates(metadata, now: metadata.expires).warning != nil)
        wakesOnTime(from: t0.addingTimeInterval(-3600), hours: 30 * 24, step: 600,
                    { NavText.dataDates(metadata, now: $0).warning }, metadata.nextChange)
    }

    @Test func ageLineWakesEachMinuteAndThePageWhenTheReportGoesStale() {
        let report = metar(observed: t0.addingTimeInterval(12.4))
        wakesOnTime(from: t0, hours: 3, { NavPages.observed(report, at: $0) }) {
            NextChange.minute(since: report.observed, after: $0)
        }
        let detail = AirportDetail(airport: Airport(id: 1, ident: "AUS", icao: "KAUS", name: "Austin", city: "Austin",
                                                    state: "TX", type: "A", use: "PU",
                                                    coordinate: Coordinate(latitude: 30.19, longitude: -97.67),
                                                    tower: "ATCT", status: "O"),
                                   runways: [], frequencies: [], remarks: [])
        // The page without its age line changes only when the report turns fresh or stale.
        wakesOnTime(from: t0.addingTimeInterval(-3600), hours: 4, { now -> NavPages.AirportWeather in
            var weather = NavPages.airportWeather(detail, metar: report, now: now).0
            weather.note = weather.category == nil ? weather.note : ""
            return weather
        }) { NavPages.airportWeatherChange(metar: report, after: $0) }
    }

    @Test func weatherNoticesWakeWhenASourceAgesOrAWindsWindowTurns() {
        var data = WeatherData()
        data.checkedAt[.metars] = t0
        data.checkedAt[.sigmets] = t0.addingTimeInterval(400)
        let on: [WeatherOverlay] = [.stations, .sigmets]
        wakesOnTime(from: t0.addingTimeInterval(-600), hours: 30 * 24, step: 31, { now in
            on.map { data.staleLabel(for: $0, at: now) } + [data.clock(on, at: now).map { WeatherText.zulu($0) }]
        }) { data.nextChange(on, after: $0) }
    }

    @Test func chartBannerWakesAtEachPackEdge() throws {
        let pack = { (cycle: String, start: Double) in
            InstalledPack(id: PackID(cycle: cycle, layer: "vfr", region: "dallas"),
                          effective: t0.addingTimeInterval(start * 86_400),
                          expires: t0.addingTimeInterval((start + 56) * 86_400))
        }
        let installed = [pack("a", 0), pack("b", 56)]
        wakesOnTime(from: t0.addingTimeInterval(-86_400), hours: 120 * 24, step: 3600, {
            MapPlan.currency(layers: ["vfr"], installed: installed, now: $0)
        }) { MapPlan.nextChange(layers: ["vfr"], installed: installed, after: $0) }
    }

    @Test func departureRollsJustAfterItPasses() {
        wakesOnTime(from: t0.addingTimeInterval(-61), hours: 2, step: 13, {
            RoutePages.planInputs(stored: nil, now: $0).departure
        }) { RoutePages.planInputsChange(stored: nil, after: $0) }
    }

    // A use window ending at 0307Z, between two quarter hours: the plan drops the forecast then, not at 0315Z.
    @Test func thePlanWakesWhenAWindsWindowEnds() throws {
        let a = RouteWaypoint(kind: .airport, ident: "KAUS", name: "KAUS", coordinate: Coordinate(latitude: 30.19, longitude: -97.67))
        let b = RouteWaypoint(kind: .airport, ident: "KDAL", name: "KDAL", coordinate: Coordinate(latitude: 32.85, longitude: -96.85))
        let route = try #require(Route(waypoints: [a, b], navCycle: "2026-10-01"))
        let station = WindsAloft.Station(id: "N", lat: 31, lon: -97.3, levels: [WindsAloft.Level(ft: 6000, dir: 180, kt: 20, temp: nil)])
        let winds = WindsAloft(forecasts: [WindsAloft.Forecast(based: t0, valid: t0, from: t0, to: t0 + 3 * 3600 + 420,
                                                               stations: [station])])
        wakesOnTime(from: t0 + 2.5 * 3600, hours: 1.5, step: 30, { now in
            FlightPlan.make(route: route, inputs: RoutePages.planInputs(stored: nil, now: now), trueAirspeedKt: 120, burnGPH: 10,
                            winds: winds, tafs: [], now: now).legWinds[0].note
        }) { RoutePages.planChange(stored: nil, winds: winds, after: $0) }
    }

    @Test func aFixGoesStaleAtItsDeadline() throws {
        let fix = try #require(Position(latitude: 30, longitude: -97, courseDegrees: 0, speedMetersPerSecond: 0,
                                        altitudeMeters: nil, timestamp: t0))
        #expect(!fix.isStale(at: fix.staleAt.addingTimeInterval(-0.01)))
        #expect(fix.isStale(at: fix.staleAt))
    }
}
