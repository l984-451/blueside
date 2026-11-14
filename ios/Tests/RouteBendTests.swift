import FlightCore
import Foundation
import Testing
@testable import Blueside

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let austin = RouteWaypoint(kind: .airport, ident: "KAUS", name: "AUSTIN-BERGSTROM INTL",
                                   coordinate: Coordinate(latitude: 30.1945, longitude: -97.6699))
private let waco = RouteWaypoint(kind: .navaid, ident: "ACT", name: "WACO",
                                 coordinate: Coordinate(latitude: 31.6624, longitude: -97.2690))
private let dallas = RouteWaypoint(kind: .airport, ident: "KDFW", name: "DALLAS-FORT WORTH INTL",
                                   coordinate: Coordinate(latitude: 32.8968, longitude: -97.0380))

private func planned() throws -> RoutePlan {
    RoutePlan(route: try #require(Route(waypoints: [austin, waco, dallas], navCycle: "c")))
}

private func place(_ kind: WaypointKind, _ ident: String) -> WaypointMatch {
    WaypointMatch(kind: kind, ident: ident, name: ident, coordinate: Coordinate(latitude: 30, longitude: -97))
}

@Suite @MainActor struct RouteBendTests {
    @Test func theBandSnapsToTheNearestPlaceAndAsksWhenPlacesTie() {
        #expect(MapPick.snap([]) == .open)
        #expect(MapPick.snap([(place(.fix, "BITER"), 18), (place(.navaid, "CWK"), 5)]) == .one(place(.navaid, "CWK")))
        // A navaid on an airport sits within 4 points of it, so both are offered.
        #expect(MapPick.snap([(place(.airport, "CWK"), 6), (place(.navaid, "CWK"), 3), (place(.fix, "X"), 20)])
                == .choose([place(.navaid, "CWK"), place(.airport, "CWK")]))
    }

    @Test func addInsertsBesideALegAndAppendsPastTheEnd() throws {
        let model = NavModel()
        #expect(model.addSpot(waco.coordinate, position: nil, now: now).title == "Add to Route")
        model.route = try planned()
        let besideFirst = Coordinate(latitude: 30.9, longitude: -97.3)
        #expect(model.addSpot(besideFirst, position: nil, now: now) == (0, "Insert after KAUS"))
        let besideLast = Coordinate(latitude: 32.3, longitude: -97.3)
        #expect(model.addSpot(besideLast, position: nil, now: now) == (1, "Insert after ACT"))
        let pastEnd = Coordinate(latitude: 33.5, longitude: -96.9)
        #expect(model.addSpot(pastEnd, position: nil, now: now) == (nil, "Add to Route"))
        let moc = RouteWaypoint(kind: .fix, ident: "MID", name: "MID", coordinate: besideFirst)
        model.addToRoute(moc, at: 0)
        #expect(model.route?.route.waypoints.map(\.ident) == ["KAUS", "MID", "ACT", "KDFW"])
    }
}
