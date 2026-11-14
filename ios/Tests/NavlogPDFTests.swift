import CoreGraphics
import FlightCore
import Foundation
import Testing
@testable import Blueside

@Suite struct NavlogPDFTests {
    @Test func theNavlogWritesAWidePDFUnderTheCoreFileName() throws {
        func airport(_ ident: String, _ lat: Double, _ lon: Double) -> RouteWaypoint {
            RouteWaypoint(kind: .airport, ident: ident, name: ident, coordinate: Coordinate(latitude: lat, longitude: lon))
        }
        let route = try #require(Route(waypoints: [airport("KAUS", 30.1945, -97.6699), airport("KDAL", 32.8471, -96.8518)],
                                       navCycle: "2026-10-01"))
        let departure = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = RoutePlan(route: route)
        let page = try #require(RoutePages.planPage(plan, position: nil, now: departure - 1800,
                                                    inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: departure),
                                                    trueAirspeedKt: 120, burnGPH: 9, winds: nil, tafs: []))
        let url = try NavlogPDF(route: plan, page: page, now: departure - 1800, localOffset: -18000).write()
        #expect(url.lastPathComponent.hasPrefix("Navlog KAUS-KDAL "))
        let document = try #require(CGPDFDocument(url as CFURL))
        #expect(document.numberOfPages >= 1)
        let box = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        #expect(box.width > box.height)
    }
}
