import CoreGraphics
import CoreLocation
import FlightCore
import MapLibre
import Testing
import UIKit
@testable import Blueside

/// When a new fix redraws the aircraft symbol, and so the whole map.
struct OwnshipRedrawTests {
    private let symbol = OwnshipLayer.Symbol(coordinate: Coordinate(latitude: 30.2, longitude: -97.7), track: 90,
                                             isStale: false, imageName: "ownship-live")
    private let screen = CGRect(x: 0, y: 0, width: 800, height: 1000)

    private func moved(_ change: (inout OwnshipLayer.Symbol) -> Void) -> OwnshipLayer.Symbol {
        var next = symbol
        next.coordinate = Coordinate(latitude: 30.2001, longitude: -97.7)
        change(&next)
        return next
    }

    @Test func aMoveUnderHalfAPointDrawsNothingAndOneOfHalfAPointDraws() {
        let at = CGPoint(x: 400, y: 500)
        #expect(!OwnshipLayer.redraws(symbol, at: at, moved { _ in }, at: CGPoint(x: 400.3, y: 500.3), visible: screen))
        #expect(OwnshipLayer.redraws(symbol, at: at, moved { _ in }, at: CGPoint(x: 400.5, y: 500), visible: screen))
        // Measured from what was drawn, two small steps in one direction add up to a drawn move.
        #expect(OwnshipLayer.redraws(symbol, at: at, moved { _ in }, at: CGPoint(x: 400.6, y: 500), visible: screen))
    }

    @Test func aNewHeadingStalenessOrLookDrawsEvenInPlace() {
        let at = CGPoint(x: 400, y: 500)
        #expect(OwnshipLayer.redraws(symbol, at: at, moved { $0.track = 91 }, at: at, visible: screen))
        #expect(OwnshipLayer.redraws(symbol, at: at, moved { $0.isStale = true; $0.imageName = "ownship-stale" }, at: at,
                                     visible: screen))
        #expect(OwnshipLayer.redraws(symbol, at: at, moved { $0.imageName = "ownship-live-ring" }, at: at, visible: screen))
    }

    @Test func aSymbolThatStaysOffScreenDrawsNothingAndOneComingOnDraws() {
        let off = CGPoint(x: -500, y: 500)
        #expect(!OwnshipLayer.redraws(symbol, at: off, moved { _ in }, at: CGPoint(x: -450, y: 500), visible: screen))
        #expect(OwnshipLayer.redraws(symbol, at: off, moved { _ in }, at: CGPoint(x: 10, y: 500), visible: screen))
        #expect(OwnshipLayer.redraws(symbol, at: off, moved { $0.track = 180 }, at: CGPoint(x: -450, y: 500), visible: screen))
    }

    /// On a real map at zoom 9: a move of a third of a point leaves the drawn symbol where it was, small steps that add
    /// up are drawn, a turn in place redraws it, and a move of a kilometer redraws it at the new place.
    @Test @MainActor func theMapHoldsTheLastDrawnSymbol() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let empty = try #require(Bundle.main.url(forResource: "empty", withExtension: "json", subdirectory: "MapAssets"))
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), styleURL: empty)
        map.setCenter(CLLocationCoordinate2D(latitude: 30.2, longitude: -97.7), zoomLevel: 9, animated: false)
        let host = UIViewController()
        host.view.addSubview(map)
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<100 where map.style == nil { try await Task.sleep(for: .milliseconds(100)) }
        let ownship = OwnshipLayer()
        ownship.install(on: try #require(map.style), map: map, night: false)
        let time = Date()
        func fix(_ latitude: Double, track: Double) -> Position? {
            Position(latitude: latitude, longitude: -97.7, courseDegrees: track, speedMetersPerSecond: 0, altitudeMeters: nil,
                     timestamp: time)
        }
        // What the map holds, once it settles: the latitude and track drawn.
        func held() async throws -> (Double, Double)? {
            try await Task.sleep(for: .milliseconds(600))
            let source = map.style?.source(withIdentifier: "ownship") as? MLNShapeSource
            guard let point = source?.features(matching: nil).first as? MLNPointFeature else { return nil }
            return (point.coordinate.latitude, (point.attributes["track"] as? NSNumber)?.doubleValue ?? -1)
        }
        // The map answers from its tiles, good to about 4 m. At zoom 9 here a point is about 0.0012° of latitude.
        func at(_ latitude: Double, _ drawn: (Double, Double)?) -> Bool { abs((drawn?.0 ?? 0) - latitude) < 0.0001 }
        ownship.update(fix(30.2, track: 90), now: time)
        let first = try await held()
        #expect(at(30.2, first), "\(String(describing: first))")
        ownship.update(fix(30.2004, track: 90), now: time)
        let jittered = try await held()
        #expect(at(30.2, jittered), "a third of a point was drawn: \(String(describing: jittered))")
        // Two thirds of a point from what was drawn, a third from the last fix: drawn.
        ownship.update(fix(30.2008, track: 90), now: time)
        let drifted = try await held()
        #expect(at(30.2008, drifted), "drift added up unseen: \(String(describing: drifted))")
        ownship.update(fix(30.2008, track: 120), now: time)
        let turned = try await held()
        #expect(turned?.1 == 120 && at(30.2008, turned), "a turn in place was not drawn: \(String(describing: turned))")
        ownship.update(fix(30.21, track: 120), now: time)
        let far = try await held()
        #expect(at(30.21, far), "a kilometer's move was not drawn: \(String(describing: far))")
        // Following: a fix a third of a point from the center leaves the camera, and a far one recenters it.
        map.setCenter(CLLocationCoordinate2D(latitude: 30.2, longitude: -97.7), zoomLevel: 9, animated: false)
        ownship.follow(map, position: try #require(fix(30.2004, track: 90)), orientation: .northUp)
        #expect(abs(map.centerCoordinate.latitude - 30.2) < 0.00001, "the camera moved for a third of a point")
        ownship.follow(map, position: try #require(fix(30.21, track: 90)), orientation: .northUp)
        #expect(abs(map.centerCoordinate.latitude - 30.21) < 0.0001, "the camera did not follow a kilometer's move")
    }

    @Test func theFirstFixAndALostFixAlwaysDraw() {
        #expect(OwnshipLayer.redraws(nil, at: nil, symbol, at: CGPoint(x: 400, y: 500), visible: screen))
        #expect(OwnshipLayer.redraws(symbol, at: CGPoint(x: 400, y: 500), nil, at: nil, visible: screen))
        #expect(!OwnshipLayer.redraws(nil, at: nil, nil, at: nil, visible: screen))
        // Without a map to place them, any change draws.
        #expect(OwnshipLayer.redraws(symbol, at: nil, moved { _ in }, at: nil, visible: .null))
    }
}
