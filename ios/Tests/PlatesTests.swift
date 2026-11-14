import FlightCore
import Foundation
import Testing
import UIKit
@testable import Blueside

private let pack = Bundle.main.resourceURL!.appendingPathComponent("MapAssets/plates-test.sqlite")

@Test func theTestPackIndexesAustinsChartsAndOpensEachPDF() async throws {
    let plates = PlateLibrary.index(pack)
    #expect(plates.count == 7)
    #expect(plates.allSatisfy { $0.airport == "AUS" && $0.icao == "KAUS" && $0.pack == pack })
    let diagram = try #require(plates.first { $0.isDiagram })
    #expect(diagram.name == "AIRPORT DIAGRAM")
    #expect(await Plates.document(diagram)?.pageCount == diagram.pages)
    #expect(Set(plates.filter { !$0.isDiagram }.map(\.group)) == [.approaches, .departures, .arrivals, .other])
}

@Test func platesOutOfTheirCycleSaySoAndOtherLayersDoNot() throws {
    let utc = TimeZone(identifier: "UTC")!
    func day(_ d: Int, _ m: Int) -> Date { DateComponents(calendar: .current, timeZone: utc, year: 2026, month: m, day: d).date! }
    let plates = InstalledPack(id: PackID(cycle: "c1", layer: PlateLibrary.layer, region: "TX"),
                               effective: day(29, 10), expires: day(26, 11))
    let charts = InstalledPack(id: PackID(cycle: "c0", layer: "vfr", region: "TX"), effective: day(1, 9), expires: day(29, 10))
    #expect(Plates.warning(installed: [plates, charts], now: day(13, 11)) == nil)
    #expect(Plates.warning(installed: [plates, charts], now: day(10, 12)) == "Plates expired 26 Nov 2026 UTC")
    #expect(Plates.warning(installed: [plates], now: day(1, 10)) == "Plates not yet in effect until 29 Oct 2026 UTC")
    #expect(Plates.warning(installed: [charts], now: day(10, 12)) == nil)
}

@Test func aPlacedPlateIsDrawnAtMost2048PixelsIn8BitColor() throws {
    var plate = try #require(PlateLibrary.index(pack).first { $0.file == "00556IL18R.PDF" })
    plate.geo = PlateGeo(corners: [[-97.9, 30.5], [-97.4, 30.5], [-97.4, 30.0], [-97.9, 30.0]], plan: [0, 0, 1, 1])
    let image = try #require(Plates.planImage(plate)?.cgImage)
    #expect(max(image.width, image.height) <= 2048 && max(image.width, image.height) > 2000)
    #expect(image.bitsPerComponent == 8)
}

/// The ownship mark follows the page as it scrolls and zooms, with nothing running between moves.
@MainActor @Test func theOwnshipMarkMovesWithThePage() async throws {
    let plate = try #require(PlateLibrary.index(pack).first { $0.file == "00556IL18R.PDF" })
    let geo = PlateGeo(corners: [[-97.9, 30.5], [-97.4, 30.5], [-97.4, 30.0], [-97.9, 30.0]], plan: [0.1, 0.3, 0.9, 0.7])
    // Off the middle of the page, so a zoom moves it.
    let fix = Fix(position: Position(latitude: 30.4, longitude: -97.8, courseDegrees: 175, speedMetersPerSecond: 50,
                                     altitudeMeters: 600, timestamp: .now),
                  approximate: false, accessOff: false, now: .now)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    let view = PlateView()
    view.frame = window.bounds
    window.addSubview(view)
    window.isHidden = false
    view.pdf.document = await Plates.document(plate)
    view.layoutIfNeeded()
    let mark = try #require(OwnshipMark(geo, fix))
    view.ownship = mark
    let marker = try #require(view.subviews.first { $0.accessibilityIdentifier == "plate-ownship" })
    let page = try #require(view.pdf.document?.page(at: 0))
    func onPage() -> CGPoint {
        let box = page.bounds(for: .mediaBox)
        let point = CGPoint(x: box.minX + mark.x * box.width, y: box.maxY - mark.y * box.height)
        return view.pdf.convert(view.pdf.convert(point, from: page), to: view)
    }
    func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 }
    #expect(!marker.isHidden && near(marker.center, onPage()))
    let before = marker.center
    let scroll = try #require(view.pdf.subviews.lazy.compactMap { $0 as? UIScrollView }.first)
    scroll.contentOffset.y += 40
    #expect(near(marker.center, CGPoint(x: before.x, y: before.y - 40)))
    view.pdf.scaleFactor *= 2
    #expect(!near(marker.center, CGPoint(x: before.x, y: before.y - 40)))
    #expect(near(marker.center, onPage()))
}
