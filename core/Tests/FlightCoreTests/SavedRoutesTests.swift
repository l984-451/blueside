import Foundation
import Testing
@testable import FlightCore

private let testDatabase = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ios/MapAssets/nav-test.sqlite").path

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let inputs = FlightPlanInputs(cruiseAltitudeFt: 6500, departure: now, rules: .ifr)

private func plan(_ text: String, _ db: NavDatabase) throws -> RoutePlan {
    try #require(RoutePages.typed(text, plan: nil, database: db, now: now).plan)
}

@Suite struct SavedRoutesTests {
    @Test func savesNamesRenamesRemovesAndRoundTrips() throws {
        let db = try NavDatabase(path: testDatabase)
        let route = try plan("KAUS CWK KEDC", db)
        #expect(SavedRoutes.defaultName(route) == "KAUS to KEDC")
        #expect(SavedRoutes.defaultName(.direct(to: route.route.waypoints[2], navCycle: "c")) == "KEDC")

        var store = SavedRoutes().saving(route, inputs: inputs, name: "  ")
        #expect(store.saved.map(\.name) == ["KAUS to KEDC"])
        // The same name again replaces it, whatever its case.
        store = store.saving(route, inputs: inputs, name: "kaus to kedc")
        #expect(store.saved.count == 1)
        let id = store.saved[0].id
        #expect(store.renaming(id, to: " ").saved[0].name == "kaus to kedc")
        store = store.renaming(id, to: "Home run ")
        #expect(SavedRoutes.row(store.saved[0], localOffset: LocalOffset(seconds: -6 * 3600))
                 == .init(id: id, name: "Home run", text: "KAUS CWK KEDC", detail: "15 Jan 0200 local · 6,500 ft · IFR"))

        let read = try SavedRoutes.decode(store.encoded())
        #expect(read == store)
        #expect(String(decoding: try store.encoded(), as: UTF8.self).contains(#""version":1"#))
        #expect(store.removing(id).saved.isEmpty)
    }

    @Test func anUnreadableFileThrowsSoItIsNotWrittenOver() throws {
        #expect(try SavedRoutes.decode(nil) == SavedRoutes())
        #expect(throws: SavedRoutes.Unreadable.newerVersion(2)) {
            try SavedRoutes.decode(Data(#"{"format":"blueside-routes","version":2}"#.utf8))
        }
        #expect(throws: SavedRoutes.Unreadable.notRoutes) { try SavedRoutes.decode(Data(#"{"format":"x"}"#.utf8)) }
        #expect(throws: (any Error).self) { try SavedRoutes.decode(Data("nope".utf8)) }
    }

    @Test func recentKeepsTheLastTenOncePerRoute() throws {
        let db = try NavDatabase(path: testDatabase)
        var store = SavedRoutes()
        let texts = ["KAUS CWK", "KAUS SAT", "KAUS KEDC", "KAUS T82", "KEDC CWK", "KEDC SAT", "KEDC T82", "SAT CWK",
                     "SAT T82", "CWK T82", "T82 KAUS"]
        for text in texts { store = store.noting(try plan(text, db), inputs: inputs) }
        #expect(store.recent.count == 10)
        #expect(store.recent[0].text == "T82 KAUS" && !store.recent.contains { $0.text == "KAUS CWK" })
        store = store.noting(try plan("KEDC SAT", db), inputs: inputs)
        #expect(store.recent.count == 10 && store.recent[0].text == "KEDC SAT")
        #expect(store.recent.filter { $0.text == "KEDC SAT" }.count == 1)
    }

    @Test func loadingParsesAgainAndSaysWhatChanged() throws {
        let db = try NavDatabase(path: testDatabase)
        let route = try plan("KAUS CWK KEDC", db)
        var saved = SavedRoute(name: "Trip", plan: route, inputs: FlightPlanInputs(cruiseAltitudeFt: 4500, departure: now,
                                                                                  rules: .ifr, alternate: route.route.waypoints[1]))
        let current = FlightPlanInputs(cruiseAltitudeFt: 9500, departure: now + 3600)

        let loaded = SavedRoutes.load(saved, inputs: current, database: db, now: now)
        #expect(loaded.problems.isEmpty && loaded.notes.isEmpty)
        #expect(loaded.plan?.text == "KAUS CWK KEDC")
        #expect(loaded.inputs.cruiseAltitudeFt == 4500 && loaded.inputs.rules == .ifr && loaded.inputs.departure == now + 3600)
        #expect(loaded.inputs.alternate?.ident == "CWK")

        // A point saved where it no longer is, under an older cycle.
        var points = route.route.waypoints
        points[1].coordinate.latitude += 0.5
        saved.route = Route(waypoints: points, navCycle: "old")
        saved.alternate = "QQQQ"
        let moved = SavedRoutes.load(saved, inputs: current, database: db, now: now)
        #expect(moved.plan != nil)
        #expect(moved.notes.contains { $0.hasPrefix("CWK moved") })
        #expect(moved.notes.contains("Alternate QQQQ is not in this nav cycle") && moved.inputs.alternate == nil)

        // A name the cycle no longer has is the parser's problem, and the route is not replaced.
        saved.text = "KAUS QQQQQ KEDC"
        let bad = SavedRoutes.load(saved, inputs: current, database: db, now: now)
        #expect(bad.plan == nil && bad.problems.count == 1 && bad.text == "KAUS QQQQQ KEDC")
    }

    @Test func aFlightKeepsDepartureAircraftAndLoad() throws {
        let db = try NavDatabase(path: testDatabase)
        let route = try plan("KAUS CWK KEDC", db)
        let craft = AircraftProfile(tail: "N2")
        var flight = inputs
        flight.departure = now + 86400
        flight.aircraftID = craft.id
        let load = FlightLoad(weights: [170, nil], startFuel: 40)
        let store = try SavedRoutes.decode(SavedRoutes().saving(route, inputs: flight, name: "", load: load).encoded())
        let current = FlightPlanInputs(cruiseAltitudeFt: 9500, departure: now + 3600)
        let loaded = SavedRoutes.load(store.saved[0], inputs: current, database: db, now: now, aircraft: [craft])
        #expect(loaded.inputs.departure == now + 86400 && loaded.inputs.aircraftID == craft.id)
        #expect(loaded.load == load)
    }

    @Test func anOlderFileLoadsAndKeepsTheCurrentFlight() throws {
        let db = try NavDatabase(path: testDatabase)
        let old = #"{"format":"blueside-routes","version":1,"recent":[],"saved":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","#
            + #""name":"Old","text":"KAUS CWK KEDC","cruiseAltitudeFt":4500,"rules":"vfr"}]}"#
        let store = try SavedRoutes.decode(Data(old.utf8))
        let craft = AircraftProfile(tail: "N2")
        let current = FlightPlanInputs(aircraftID: craft.id, cruiseAltitudeFt: 9500, departure: now + 3600)
        let loaded = SavedRoutes.load(store.saved[0], inputs: current, database: db, now: now, aircraft: [craft])
        #expect(loaded.inputs.departure == now + 3600 && loaded.inputs.aircraftID == craft.id && loaded.load == nil)
    }

    @Test func aPastDepartureAndADeletedAircraftAreNotRestored() throws {
        let db = try NavDatabase(path: testDatabase)
        let route = try plan("KAUS CWK KEDC", db)
        var flight = inputs
        flight.departure = now - 3600
        flight.aircraftID = UUID()
        let store = SavedRoutes().saving(route, inputs: flight, name: "", load: FlightLoad(startFuel: 40))
        let mine = AircraftProfile(tail: "N1")
        let current = FlightPlanInputs(aircraftID: mine.id, cruiseAltitudeFt: 9500, departure: now + 3600)
        let loaded = SavedRoutes.load(store.saved[0], inputs: current, database: db, now: now, aircraft: [mine])
        #expect(loaded.inputs.departure == now + 3600 && loaded.inputs.aircraftID == mine.id && loaded.load == nil)
    }

    // Saved on 30 Oct in CDT for 2 Nov at 0800 CST (1400Z); CDT ends at 0700Z on 1 Nov.
    @Test func aDepartureAfterTheClockChangeReadsInTheOffsetThen() throws {
        let iso = ISO8601DateFormatter()
        let points = [RouteWaypoint.user(at: Coordinate(latitude: 30, longitude: -97)),
                      RouteWaypoint.user(at: Coordinate(latitude: 31, longitude: -97))]
        let plan = RoutePlan(route: try #require(Route(waypoints: points, navCycle: "c")))
        let departure = try #require(iso.date(from: "2026-11-02T14:00:00Z"))
        let flight = FlightPlanInputs(cruiseAltitudeFt: 6500, departure: departure, rules: .ifr)
        let offset = LocalOffset(seconds: -5 * 3600, nextChange: iso.date(from: "2026-11-01T07:00:00Z"), secondsAfter: -6 * 3600)
        let store = SavedRoutes().saving(plan, inputs: flight, name: "Trip").noting(plan, inputs: flight)
        let now = try #require(iso.date(from: "2026-10-30T15:00:00Z"))
        #expect(store.savedRows(now: now, localOffset: offset).first?.detail.hasPrefix("02 Nov 0800 local") == true)
        #expect(store.recentRows(localOffset: offset).first?.detail.hasPrefix("02 Nov 0800 local") == true)
        // The offset now alone reads an hour late.
        #expect(store.savedRows(now: now, localOffset: LocalOffset(seconds: -5 * 3600)).first?.detail.hasPrefix("02 Nov 0900 local") == true)
        #expect(offset.seconds(at: now) == -5 * 3600 && LocalOffset(seconds: 3600).seconds(at: departure) == 3600)
    }

    @Test func upcomingFlightsComeFirstSoonestFirst() throws {
        let db = try NavDatabase(path: testDatabase)
        let route = try plan("KAUS CWK KEDC", db)
        func at(_ d: Date) -> FlightPlanInputs { var f = inputs; f.departure = d; return f }
        let store = SavedRoutes()
            .saving(route, inputs: at(now - 60), name: "Gone")
            .saving(route, inputs: at(now + 2 * 86400), name: "Later")
            .saving(route, inputs: at(now + 86400), name: "Soon")
        #expect(store.savedRows(now: now, localOffset: LocalOffset(seconds: 0)).map(\.name) == ["Soon", "Later", "Gone"])
    }
}
