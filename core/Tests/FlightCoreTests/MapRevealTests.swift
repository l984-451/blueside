import Foundation
import Testing
@testable import FlightCore

// A coordinate's place in the 512-per-tile world at a zoom.
private func world(_ c: Coordinate, _ zoom: Double) -> (x: Double, y: Double) {
    let size = 512 * pow(2, zoom), sine = sin(c.latitude * .pi / 180)
    return ((c.longitude + 180) / 360 * size, (0.5 - log((1 + sine) / (1 - sine)) / (4 * .pi)) * size)
}

@Suite struct MapRevealTests {
    let place = Coordinate(latitude: 30.2, longitude: -97.7)
    let size = ScreenPoint(x: 1000, y: 800)
    // Right of a 400-wide card and below an 100-tall strip.
    let open = ScreenRect(x: 400, y: 100, width: 600, height: 700)

    @Test func aPlaceInTheMiddleOfTheOpenPartLeavesTheMapAlone() {
        #expect(MapReveal.camera(place: place, at: ScreenPoint(x: 700, y: 450), open: open, size: size, zoom: 10, bearing: 0) == nil)
        #expect(MapReveal.camera(place: place, at: ScreenPoint(x: 530, y: 650), open: open, size: size, zoom: 10, bearing: 0) == nil)
    }

    @Test func aPlaceUnderTheCardMovesToTheOpenPartsCenterAtTheSameZoom() throws {
        let camera = try #require(MapReveal.camera(place: place, at: ScreenPoint(x: 100, y: 400), open: open, size: size,
                                                   zoom: 10, bearing: 0))
        #expect(camera.zoom == 10)
        // The place ends up 200 right of and 50 below the screen center: the open part's center.
        let (p, c) = (world(place, 10), world(camera.center, 10))
        #expect(abs(p.x - c.x - 200) < 1e-6 && abs(p.y - c.y - 50) < 1e-6)
    }

    @Test func aTurnedMapShiftsAlongItsBearing() throws {
        // East up: screen left is north and screen up is east, so the center goes north and a little east.
        let camera = try #require(MapReveal.camera(place: place, at: ScreenPoint(x: 100, y: 400), open: open, size: size,
                                                   zoom: 10, bearing: 90))
        let (p, c) = (world(place, 10), world(camera.center, 10))
        #expect(abs(c.x - p.x - 50) < 1e-6 && abs(c.y - p.y + 200) < 1e-6)
    }

    @Test func offScreenAtACountryZoomZoomsIn() throws {
        let far = ScreenPoint(x: -400, y: 300)
        #expect(try #require(MapReveal.camera(place: place, at: far, open: open, size: size, zoom: 5, bearing: 0)).zoom
            == NavPages.showOnMapZoom)
        #expect(try #require(MapReveal.camera(place: place, at: far, open: open, size: size, zoom: 9, bearing: 0)).zoom == 9)
    }

    @Test func showOnMapAlwaysMovesAndASlimOpenPartNeverDoes() throws {
        let shown = try #require(MapReveal.camera(place: place, at: ScreenPoint(x: 700, y: 450), open: open, size: size,
                                                  zoom: 13, bearing: 0, force: true))
        #expect(shown.zoom == NavPages.showOnMapZoom)
        // A sheet pulled up to the top leaves a strip too thin to aim for.
        let slim = ScreenRect(x: 0, y: 0, width: 1000, height: 120)
        #expect(MapReveal.camera(place: place, at: ScreenPoint(x: 500, y: 700), open: slim, size: size, zoom: 10, bearing: 0,
                                 force: true) == nil)
    }
}
