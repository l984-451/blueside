import Foundation
import Testing
@testable import FlightCore

private let testDatabase = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ios/MapAssets/nav-test.sqlite").path

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let inputs = FlightPlanInputs(cruiseAltitudeFt: 5500, departure: now + 3600)

private func skyhawk() -> AircraftProfile {
    var p = AircraftTemplates.c172s
    p.tail = "N12345"
    p.emptyWeightLb = 1663
    p.emptyArmIn = 39.3
    p.stations[0].armIn = 37.0
    p.stations[2].armIn = 95
    p.stations[3].armIn = 123
    return p
}

private func navlog(alternate: RouteWaypoint? = nil, aircraft: AircraftProfile? = nil, balance: WeightBalance? = nil,
                    database: NavDatabase? = nil, vertical: FlightPlan.Vertical? = nil) throws -> RoutePages.Navlog {
    let db = try NavDatabase(path: testDatabase)
    let plan = try #require(RoutePages.typed("KAUS CWK KEDC", plan: nil, database: db, now: now).plan)
    var inputs = inputs
    inputs.alternate = alternate
    let page = try #require(RoutePages.planPage(plan, position: nil, now: now, inputs: inputs, trueAirspeedKt: 120,
                                                burnGPH: 9, taxiFuelGal: 1, fuelOnBoardGal: 30, winds: nil, tafs: [],
                                                vertical: vertical))
    return RoutePages.navlog(plan, page: page, position: nil, now: now, aircraft: aircraft, balance: balance,
                             localOffsetSeconds: -5 * 3600, database: database ?? db)
}

@Suite struct NavlogTests {
    @Test func climbAndDescentRowsPrintAndTheNMColumnAddsUp() throws {
        let vertical = FlightPlan.Vertical(climb: .init(rateFPM: 500, tasKt: 80, burnGPH: 10),
                                           descent: .init(rateFPM: 500, tasKt: 110, burnGPH: 6))
        let log = try navlog(vertical: vertical)
        let nm = try #require(RoutePages.logColumns.firstIndex(of: "NM"))
        #expect(log.rows.contains { $0[0].hasPrefix("-TO") })
        let sum = log.rows.compactMap { Double($0[nm]) }.reduce(0, +)
        #expect(abs(sum - (Double(log.totals[nm]) ?? -1)) < 0.2)
    }

    @Test func theLegTableHasTheThirteenColumnsAnEmptyActualColumnAndTotals() throws {
        let log = try navlog()
        #expect(log.columns == RoutePages.logColumns + [RoutePages.actualColumn])
        #expect(log.columns.count == 14 && RoutePages.actualColumn == "Actual")
        #expect(log.rows.map { $0[0] } == ["KAUS", "CWK", "KEDC"])
        #expect(log.rows.allSatisfy { $0.count == 14 && $0[13] == "" })
        #expect(log.totals.count == 14 && log.totals[0] == "Total" && log.totals[13] == "")
        #expect(log.totals[3] == log.rows[1][3].toDouble.map { NavText.fixed($0 + (log.rows[2][3].toDouble ?? 0), 1) })
    }

    @Test func theSummaryNamesTheFlightInLocalTimeAndZ() throws {
        let log = try navlog(aircraft: skyhawk())
        let value = { (title: String) in log.summary.lines.first { $0.title == title }?.value }
        #expect(value("Aircraft") == "N12345 · C172S")
        #expect(value("Route") == "KAUS CWK KEDC")
        #expect(value("Altitude") == "5,500 ft")
        // 1_800_003_600 is 2027-01-15 09:00:00Z, so 0400 at five hours behind.
        #expect(value("ETD") == "0400 local · 0900Z")
        #expect(value("ETE")?.isEmpty == false && value("ETE") != NavText.dashes)
        #expect(value("ETA")?.contains("local") == true && value("ETA")?.hasSuffix("Z") == true)
        #expect(value("Distance")?.hasSuffix("NM") == true)
        #expect(log.fileName.hasPrefix("Navlog KAUS-KEDC ") && log.fileName.hasSuffix(".pdf"))
        // No aircraft, no invented name.
        #expect(try navlog().summary.lines.first { $0.title == "Aircraft" }?.value == NavText.dashes)
    }

    @Test func theFuelBlockAddsUpAndShowsTheAlternate() throws {
        let log = try navlog()
        let gallons = { (title: String) in log.fuel.lines.first { $0.title == title }?.value.flatMap { Double($0.dropLast(4)) } }
        let taxi = try #require(gallons("Taxi")), trip = try #require(gallons("Trip"))
        let reserve = try #require(gallons("Reserve")), total = try #require(gallons("Total"))
        #expect(taxi == 1 && abs(taxi + trip + reserve - total) < 0.11)
        // None picked: a dash, not a made-up zero.
        #expect(log.fuel.lines.first { $0.title == "Alternate" }?.value == NavText.dashes)
        let db = try NavDatabase(path: testDatabase)
        let t82 = try #require(RoutePages.alternate("T82", database: db))
        let with = try navlog(alternate: t82)
        let alt = try #require(with.fuel.lines.first { $0.title == "Alternate" }?.value.flatMap { Double($0.dropLast(4)) })
        let all = ["Taxi", "Trip", "Reserve", "Alternate"].compactMap { t in
            with.fuel.lines.first { $0.title == t }?.value.flatMap { Double($0.dropLast(4)) }
        }
        let sum = try #require(with.fuel.lines.first { $0.title == "Total" }?.value.flatMap { Double($0.dropLast(4)) })
        #expect(alt > 0 && abs(all.reduce(0, +) - sum) < 0.21)
    }

    @Test func weightRowsAppearOnlyWithWeightAndBalance() throws {
        #expect(try navlog(aircraft: skyhawk()).weights == nil)
        let wb = try #require(WeightBalance(profile: skyhawk(), stationWeightsLb: [340, 0, 50, 0], burnedGal: 20))
        let log = try navlog(aircraft: skyhawk(), balance: wb)
        let weights = try #require(log.weights)
        #expect(weights.lines.map(\.title) == ["Payload", "Zero fuel weight", "Takeoff weight", "Landing weight"])
        let lb = { (w: Double) in NavText.grouped(Int(w.rounded())) + " lb" }
        #expect(weights.lines.map(\.value) == ["390 lb", "2,053 lb", lb(wb.takeoff.weightLb), lb(try #require(wb.landing).weightLb)])
        // With no fuel burned, as airborne, the landing weight is unknown.
        let airborne = try #require(WeightBalance(profile: skyhawk(), stationWeightsLb: [340, 0, 50, 0], burnedGal: nil))
        #expect(try navlog(aircraft: skyhawk(), balance: airborne).weights?.lines.last?.value == NavText.dashes)
    }

    @Test func noLoadEnteredPrintsNoWeights() throws {
        let empty = try #require(WeightBalance(profile: skyhawk(), stationWeightsLb: [0, 0, 0, 0], burnedGal: 20))
        #expect(try navlog(aircraft: skyhawk(), balance: empty).weights == nil)
    }

    @Test func aCappedClimbPrintsItsPeak() throws {
        // A slow climb over the short KAUS CWK KEDC route cannot reach 5500 ft.
        let slow = FlightPlan.Vertical(climb: .init(rateFPM: 100, tasKt: 90, burnGPH: 10),
                                       descent: .init(rateFPM: 100, tasKt: 110, burnGPH: 6))
        let log = try navlog(vertical: slow)
        let altitude = try #require(log.summary.lines.first { $0.title == "Altitude" }?.value)
        #expect(altitude != "5,500 ft" && altitude.hasSuffix(" ft"))
    }

    @Test func theFrequencyTableReadsBothEndsFromTheNavDatabase() throws {
        let log = try navlog()
        #expect(log.frequencies.columns == ["", "KAUS", "KEDC"])
        let row = { (title: String) in log.frequencies.rows.first { $0[0] == title } }
        #expect(log.frequencies.rows.map { $0[0] } == ["ATIS/AWOS", "Tower/CTAF", "Clearance", "Ground", "Elevation", "Longest runway"])
        // The primary tower, not the secondary one listed first.
        #expect(row("ATIS/AWOS") == ["ATIS/AWOS", "ATIS 124.4", "AWOS-3 118.825"])
        #expect(row("Tower/CTAF") == ["Tower/CTAF", "Tower 121.0", "Tower 120.3"])
        #expect(row("Clearance") == ["Clearance", "125.5", NavText.dashes])
        #expect(row("Ground") == ["Ground", "121.9", "119.45"])
        #expect(row("Elevation") == ["Elevation", "542 ft", "620 ft"])
        #expect(row("Longest runway") == ["Longest runway", "12,250 ft (18R/36L)", "6,025 ft (13/31)"])
    }

    @Test func withoutADatabaseTheFrequencyCellsAreDashes() throws {
        let plan = try #require(RoutePages.typed("KAUS CWK KEDC", plan: nil, database: NavDatabase(path: testDatabase), now: now).plan)
        let page = try #require(RoutePages.planPage(plan, position: nil, now: now, inputs: inputs, trueAirspeedKt: 120,
                                                    burnGPH: 9, winds: nil, tafs: []))
        let log = RoutePages.navlog(plan, page: page, position: nil, now: now, aircraft: nil, balance: nil,
                                    localOffsetSeconds: nil, database: nil)
        #expect(log.frequencies.rows.allSatisfy { $0[1...].allSatisfy { $0 == NavText.dashes } })
        #expect(log.summary.lines.first { $0.title == "ETD" }?.value == "0900Z")
    }

    @Test func theFiveBlankBoxesAreOutOffOnInAndHobbs() throws {
        #expect(try navlog().boxes == ["Out", "Off", "On", "In", "Hobbs"])
    }
}

private extension String {
    var toDouble: Double? { Double(self) }
}
