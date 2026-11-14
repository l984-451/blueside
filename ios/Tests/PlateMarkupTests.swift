import FlightCore
import Foundation
import PDFKit
import PencilKit
import Testing
import UIKit
@testable import Blueside

private let pack = Bundle.main.resourceURL!.appendingPathComponent("MapAssets/plates-test.sqlite")

private func line(to end: CGPoint) -> PKDrawing {
    let points = [CGPoint.zero, end].enumerated().map { i, at in
        PKStrokePoint(location: at, timeOffset: Double(i) / 10, size: CGSize(width: 3, height: 3),
                      opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))])
}

@Test func aChartKeepsItsMarksFileWhenANewCycleReplacesIt() {
    let now = Plate(airport: "AUS", icao: "KAUS", name: "ILS OR LOC RWY 18R", code: "IAP", file: "00556IL18R.PDF", pages: 1,
                    pack: URL(filePath: "/c1/plates-TX.sqlite"))
    var next = now
    (next.file, next.pack) = ("00556IL18R_A.PDF", URL(filePath: "/c2/plates-TX.sqlite"))
    #expect(PlateMarkup.fileName(next) == PlateMarkup.fileName(now))
    var other = now
    other.name = "ILS OR LOC/DME RWY 18R"
    #expect(PlateMarkup.fileName(other) != PlateMarkup.fileName(now))
    #expect(!PlateMarkup.fileName(other).contains("/"))
}

@Test func marksRoundTripAndAChartWithNoneKeepsNoFile() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("AUS-AUSTIN.drawing")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(await PlateMarkup.read(file).isEmpty)
    let pages = [0: line(to: CGPoint(x: 50, y: 80)), 2: line(to: CGPoint(x: 10, y: 300))]
    await PlateMarkup.write(pages.merging([1: PKDrawing()]) { a, _ in a }, to: file)
    #expect(await PlateMarkup.read(file) == pages)
    await PlateMarkup.write([0: PKDrawing()], to: file)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

/// Putting the app away writes a new mark at once, without waiting out the pause after drawing.
@MainActor @Test func aMarkIsSavedWhenTheAppIsPutAway() async throws {
    let plate = try #require(PlateLibrary.index(pack).first { $0.file != "00556IL18R.PDF" })
    let file = PlateMarkup.root.appendingPathComponent(PlateMarkup.fileName(plate))
    defer { try? FileManager.default.removeItem(at: file) }
    let markup = await PlateMarkup.open(plate)
    let pdf = PDFView()
    pdf.document = await Plates.document(plate)
    let page = try #require(pdf.document?.page(at: 0))
    let canvas = try #require(markup.pdfView(pdf, overlayViewFor: page) as? PKCanvasView)
    canvas.drawing = line(to: CGPoint(x: 40, y: 60))
    markup.canvasViewDrawingDidChange(canvas)
    let start = ContinuousClock.now
    NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: nil)
    // Opening the chart waits for its newest save.
    _ = await PlateMarkup.open(plate)
    #expect(ContinuousClock.now - start < .milliseconds(800), "the mark waited for the pause")
    #expect(await PlateMarkup.read(file)[0]?.strokes.count == 1)
}

/// While the picker shows, the page's foot scrolls clear of what it covers; hidden, or with Markup off, it leaves no room.
/// Taking the room away leaves the page and ownship where they are.
@MainActor @Test func markingMakesRoomForTheToolPickerAndTakingItAwayKeepsThePage() async throws {
    let plate = try #require(PlateLibrary.index(pack).first { $0.file == "00556IL18R.PDF" })
    // A window in the app's scene, so the system shows the picker.
    let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    let view = PlateView()
    view.frame = window.bounds
    window.rootViewController?.view.addSubview(view)
    // The document before the window, as the reader does, so the first layout fits the page.
    view.markup = await PlateMarkup.open(plate)
    view.pdf.document = await Plates.document(plate)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    view.layoutIfNeeded()
    let geo = PlateGeo(corners: [[-97.9, 30.5], [-97.4, 30.5], [-97.4, 30.0], [-97.9, 30.0]], plan: [0.1, 0.3, 0.9, 0.7])
    let fix = Fix(position: Position(latitude: 30.4, longitude: -97.8, courseDegrees: 175, speedMetersPerSecond: 50,
                                     altitudeMeters: 600, timestamp: .now),
                  approximate: false, accessOff: false, now: .now)
    view.ownship = OwnshipMark(geo, fix)
    let marker = try #require(view.subviews.first { $0.accessibilityIdentifier == "plate-ownship" })
    let scroll = try #require(view.pdf.subviews.lazy.compactMap { $0 as? UIScrollView }.first)
    let picker = try #require(view.markup?.picker)
    let page = try #require(view.pdf.document?.page(at: 0))
    func toFoot() {
        scroll.contentOffset.y = max(-scroll.adjustedContentInset.top,
                                     scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
    }
    func room() -> CGFloat { scroll.contentInset.bottom }
    func foot() -> CGFloat { view.pdf.convert(CGPoint(x: 0, y: page.bounds(for: .mediaBox).minY), from: page).y }
    // What the picker covers, or the docked iPad palette, which reports nothing.
    func pickerTop() -> CGFloat {
        let covered = picker.frameObscured(in: view.pdf)
        return covered.isEmpty ? view.pdf.bounds.maxY - PlateView.dockedPicker - view.safeAreaInsets.bottom : covered.minY
    }
    func waitFor(visible: Bool) async throws {
        for _ in 0..<20 where picker.isVisible != visible { try await Task.sleep(for: .milliseconds(50)) }
    }

    // Nothing shows until Markup is on.
    try await Task.sleep(for: .milliseconds(200))
    #expect(!picker.isVisible && room() == 0)
    view.marking = true
    try await waitFor(visible: true)
    #expect(picker.isVisible && room() > 0)
    #expect(scroll.verticalScrollIndicatorInsets.bottom == room())
    // Zoomed in and at the whole page, the foot scrolls above the picker; a double tap still zooms in and back out.
    view.pdf.doubleTapped(UITapGestureRecognizer())
    #expect(view.pdf.scaleFactor > view.pdf.minScaleFactor * 2)
    toFoot()
    #expect(foot() <= pickerTop() + 0.5, "zoomed in, the foot cannot scroll above the picker")
    view.pdf.doubleTapped(UITapGestureRecognizer())
    #expect(view.pdf.scaleFactor == view.pdf.minScaleFactor)
    toFoot()
    #expect(foot() <= pickerTop() + 0.5, "at the whole page, the foot cannot scroll above the picker")

    view.pencilKitResponderState.toolPickerVisibility = .hidden
    try await waitFor(visible: false)
    #expect(!picker.isVisible && room() == 0)
    view.pencilKitResponderState.toolPickerVisibility = .visible
    try await waitFor(visible: true)
    #expect(room() > 0)

    // Zoomed in, turning Markup off at the foot leaves the page where it is. A whole page shorter than the view goes back to the middle.
    view.pdf.doubleTapped(UITapGestureRecognizer())
    toFoot()
    let (offset, at) = (scroll.contentOffset, marker.center)
    view.marking = false
    #expect(room() == 0 && scroll.verticalScrollIndicatorInsets.bottom == 0)
    #expect(scroll.contentOffset == offset)
    #expect(marker.center == at)
}

/// With Markup off the page takes every touch, so a Pencil cannot draw by accident.
@MainActor @Test func marksTakeTouchesOnlyWhileMarkupIsOn() async throws {
    let plate = try #require(PlateLibrary.index(pack).first { $0.file == "00556IL18R.PDF" })
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    let view = PlateView()
    view.frame = window.bounds
    window.addSubview(view)
    window.isHidden = false
    view.markup = await PlateMarkup.open(plate)
    view.pdf.document = await Plates.document(plate)
    func canvases(_ in: UIView) -> [PKCanvasView] { (`in` as? PKCanvasView).map { [$0] } ?? `in`.subviews.flatMap(canvases) }
    func onCanvas() -> Bool {
        sequence(first: window.hitTest(CGPoint(x: 200, y: 300), with: nil), next: { $0?.superview }).contains { $0 is PKCanvasView }
    }
    for _ in 0..<20 where canvases(view).isEmpty {
        view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(canvases(view).count == 1)
    #expect(!onCanvas())
    view.marking = true
    #expect(onCanvas())
    view.marking = false
    #expect(!onCanvas())
}
