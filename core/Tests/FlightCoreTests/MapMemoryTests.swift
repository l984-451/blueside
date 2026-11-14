import Foundation
import Testing
@testable import FlightCore

private let testDatabase = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ios/MapAssets/nav-test.sqlite").path

@Suite struct MapMemoryTests {
    @Test func roundTripsAndFallsBackFieldByField() {
        let kept = MapMemory(base: .ifrLow, night: true, orientation: .trackUp, following: false,
                             camera: .init(latitude: 30.2, longitude: -97.7, zoom: 9.5), route: "KAUS CWK",
                             plates: [.init(airport: "BHM", file: "00050IL6.PDF")])
        #expect(MapMemory(text: kept.text) == kept)
        #expect(!MapMemory().text.contains("plates"))
        #expect(MapMemory(text: nil) == MapMemory())
        #expect(MapMemory(text: "not json") == MapMemory())
        #expect(MapMemory(text: #"{"version": 2, "night": true}"#) == MapMemory())
        // A base no longer offered and a bad camera fall back; the rest stays.
        let old = MapMemory(text: #"{"version":1,"base":"sectional-gone","night":true,"camera":{"latitude":95,"longitude":0,"zoom":5},"route":"  "}"#)
        #expect(old == MapMemory(night: true))
    }

    @Test func launchOptionsWinAndFollowingComesBackOnlyIfItWasOn() {
        let left = MapMemory(base: .ifrHigh, night: true, following: false, camera: .init(latitude: 30, longitude: -97, zoom: 9))
        #expect(left.launched(base: nil, night: nil, orientation: nil, center: nil, zoom: nil, follow: false) == left)
        let forced = left.launched(base: .vfr, night: false, orientation: .trackUp,
                                   center: Coordinate(latitude: 32.9, longitude: -97.04), zoom: nil, follow: false)
        #expect(forced.base == .vfr && !forced.night && forced.orientation == .trackUp)
        #expect(forced.camera == .init(latitude: 32.9, longitude: -97.04, zoom: MapMemory.home.zoom) && !forced.following)
        #expect(left.launched(base: nil, night: nil, orientation: nil, center: nil, zoom: 11, follow: false).camera.zoom == 11)
        #expect(left.launched(base: nil, night: nil, orientation: nil, center: nil, zoom: nil, follow: true).following)
        // A first launch follows, as before, unless a fixed center says otherwise.
        #expect(MapMemory().launched(base: nil, night: nil, orientation: nil, center: nil, zoom: nil, follow: false).following)
        #expect(!MapMemory().launched(base: nil, night: nil, orientation: nil, center: Coordinate(latitude: 30, longitude: -97),
                                      zoom: 10, follow: false).following)
    }

    @Test func savedRouteParsesAgainOrIsDropped() throws {
        let db = try NavDatabase(path: testDatabase)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RoutePages.restored("KAUS CWK", database: db, now: now)?.route.waypoints.map(\.ident) == ["KAUS", "CWK"])
        #expect(RoutePages.restored("CWK", database: db, now: now)?.isDirect == true)
        #expect(RoutePages.restored("KAUS QQQQQ", database: db, now: now) == nil)
        #expect(RoutePages.restored(nil, database: db, now: now) == nil)
    }
}
