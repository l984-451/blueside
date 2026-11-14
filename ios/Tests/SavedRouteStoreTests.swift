import FlightCore
import Foundation
import Testing
@testable import Blueside

@MainActor struct SavedRouteStoreTests {
    let file = URL.temporaryDirectory.appendingPathComponent("routes-\(UUID().uuidString).json")
    let plan = RoutePlan(route: Route(waypoints: [
        RouteWaypoint(kind: .airport, ident: "KAUS", name: "AUSTIN", coordinate: Coordinate(latitude: 30.19, longitude: -97.67)),
        RouteWaypoint(kind: .airport, ident: "KDAL", name: "DALLAS LOVE", coordinate: Coordinate(latitude: 32.85, longitude: -96.85)),
    ], navCycle: "c")!)
    let inputs = FlightPlanInputs(cruiseAltitudeFt: 6500, departure: Date())

    @Test func savesToTheFileAndReadsItBack() {
        let store = SavedRouteStore(file: file)
        store.update { $0.saving(plan, inputs: inputs, name: "") }
        store.update { $0.noting(plan, inputs: inputs) }
        let again = SavedRouteStore(file: file)
        #expect(again.routes.saved.map(\.name) == ["KAUS to KDAL"])
        #expect(again.routes.recent.count == 1 && again.problem == nil)
    }

    @Test func anUnreadableFileIsLeftAlone() throws {
        let newer = Data(#"{"format":"blueside-routes","version":9}"#.utf8)
        try newer.write(to: file)
        let store = SavedRouteStore(file: file)
        store.update { $0.saving(plan, inputs: inputs, name: "") }
        #expect(store.problem == RoutePages.savedUnreadable && store.routes.saved.isEmpty)
        #expect(try Data(contentsOf: file) == newer)
    }
}
