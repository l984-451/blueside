import CoreGraphics
import FlightCore
import Foundation
import Testing
import UIKit
@testable import Blueside

@Suite struct BriefPDFTests {
    @MainActor @Test func theBriefWritesAPDFUnderTheCoreFileNameWithItsGraphics() async throws {
        func airport(_ ident: String, _ lat: Double, _ lon: Double) -> RouteWaypoint {
            RouteWaypoint(kind: .airport, ident: ident, name: ident, coordinate: Coordinate(latitude: lat, longitude: lon))
        }
        let aus = airport("KAUS", 30.1945, -97.6699), dal = airport("KDAL", 32.8471, -96.8518)
        let route = try #require(Route(waypoints: [aus, dal], navCycle: "2026-10-01"))
        let departure = Date(timeIntervalSince1970: 1_800_000_000)
        let inputs = FlightPlanInputs(cruiseAltitudeFt: 5500, departure: departure)
        let plan = FlightPlan.make(route: route, inputs: inputs, trueAirspeedKt: 120, burnGPH: 9, winds: nil, tafs: [])
        let assets = try #require(Bundle.main.resourceURL?.appending(path: "MapAssets"))
        let database = try NavDatabase(path: assets.appending(path: "nav-test.sqlite").path)
        let job = BriefJob(route: route, inputs: inputs, plan: plan, aircraft: nil, balance: nil, weather: WeatherData(),
                           now: departure - 1800, localOffset: nil, database: database, packs: AppModel.bundledPacks(named: "test"))
        let brief = job.make(assets: assets)
        let picture = try #require(brief.graphics.map.pictures.first)
        let map = try #require(await BriefSnapshot.take(picture, bounds: brief.graphics.map.bounds, scale: 2))

        let url = try BriefPDF(brief: brief, images: ["route": map]).write()
        #expect(url.lastPathComponent == brief.fileName)
        let pages = try #require(CGPDFDocument(url as CFURL)).numberOfPages
        #expect(pages >= 2)
        if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            let copy = URL(fileURLWithPath: folder).appending(path: "brief.pdf")
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: url, to: copy)
        }
    }
}
