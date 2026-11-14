import FlightCore
import Foundation
import Testing
@testable import Blueside

@Suite @MainActor struct MapPickTests {
    @Test func nearbyListsAirportsNavaidsAndFixesWithinTenMilesClosestFirst() async throws {
        let model = NavModel()
        await model.use(NavFiles.bundledTest).value
        try #require(model.database != nil)
        let pin = Coordinate(latitude: 30.21, longitude: -97.68)
        // EDC and CWK sit just under 13 NM away.
        #expect(model.database!.nearby(pin).map(\.ident) == ["AUS", "TX05", "68TX"])
        let centex = Coordinate(latitude: 30.37855, longitude: -97.52984722)
        #expect(model.database!.nearby(centex).prefix(2).map { "\($0.kind.rawValue) \($0.ident)" } == ["navaid CWK", "airport EDC"])
    }
}
