import FlightCore
import PDFKit
import PencilKit
import UIKit

/// A chart's marks: a PencilKit canvas over each page, the system tool picker, and one file per chart.
@MainActor final class PlateMarkup: NSObject {
    let picker = PKToolPicker()
    /// Off, the canvases take no touches, so nothing is drawn by accident; the marks still show.
    var marking = false {
        didSet { for canvas in canvases.values { canvas.isUserInteractionEnabled = marking } }
    }
    private let file: URL
    private var pages: [Int: PKDrawing]
    // Kept for the reader's life, so a page scrolled back into view keeps its canvas and gestures.
    private var canvases: [Int: PKCanvasView] = [:]
    private var saving: Task<Void, Never>?
    // Only a chart drawn on is written, so reading one never rewrites or drops its file.
    private var edited = false
    // The newest save of any chart, so a chart opened again reads what its last reader wrote.
    private static var lastSave: Task<Void, Never>?

    private init(file: URL, pages: [Int: PKDrawing]) {
        (self.file, self.pages) = (file, pages)
        super.init()
        // Saves at once when the app is put away, so a mark made just before it is killed is kept.
        NotificationCenter.default.addObserver(self, selector: #selector(leaving), name: UIScene.willDeactivateNotification, object: nil)
    }

    @objc private func leaving() { save() }

    /// The folder holding every chart's marks.
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("Markup", isDirectory: true) }

    /// The chart's marks, read off the main thread.
    static func open(_ plate: Plate) async -> PlateMarkup {
        let file = root.appendingPathComponent(fileName(plate))
        await lastSave?.value
        return PlateMarkup(file: file, pages: await read(file))
    }

    /// Airport and chart name, which the next cycle's chart keeps; the PDF's name can change.
    nonisolated static func fileName(_ plate: Plate) -> String {
        [plate.airport, plate.name].map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 }
            .joined(separator: "-") + ".drawing"
    }

    @concurrent nonisolated static func read(_ file: URL) async -> [Int: PKDrawing] {
        (try? Data(contentsOf: file)).flatMap { try? PropertyListDecoder().decode([Int: PKDrawing].self, from: $0) } ?? [:]
    }

    /// Writes through a temp file and rename. A chart with no marks keeps no file.
    @concurrent nonisolated static func write(_ pages: [Int: PKDrawing], to file: URL) async {
        let marked = pages.filter { !$0.value.strokes.isEmpty }
        guard !marked.isEmpty else { try? FileManager.default.removeItem(at: file); return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PropertyListEncoder().encode(marked).write(to: file, options: .atomic)
    }

    /// Saves after the pause, one write at a time, so an older drawing never lands last.
    func save(after pause: Duration = .zero) {
        guard edited else { return }
        let previous = saving
        previous?.cancel()
        saving = Task {
            try? await Task.sleep(for: pause)
            await previous?.value
            guard !Task.isCancelled else { return }
            for (index, canvas) in canvases { pages[index] = canvas.drawing }
            await Self.write(pages, to: file)
        }
        Self.lastSave = saving
    }
}

extension PlateMarkup: @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let index = view.document?.index(for: page) else { return nil }
        if let canvas = canvases[index] { return canvas }
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        // The reader inverts page and marks together at night, so the canvas must not adapt ink for dark itself.
        canvas.overrideUserInterfaceStyle = .light
        // The page's own scroll view pans and zooms.
        canvas.isScrollEnabled = false
        canvas.drawing = pages[index] ?? PKDrawing()
        canvas.isUserInteractionEnabled = marking
        canvas.delegate = self
        picker.addObserver(canvas)
        canvases[index] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        // A stroke never also pans, zooms or taps the page; a finger that does not draw still does.
        let scroll = pdfView.subviews.lazy.compactMap { $0 as? UIScrollView }.first
        for gesture in [scroll?.panGestureRecognizer, scroll?.pinchGestureRecognizer].compactMap({ $0 }) + (pdfView.gestureRecognizers ?? []) {
            gesture.require(toFail: canvas.drawingGestureRecognizer)
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        edited = true
        save(after: .seconds(1))
    }
}
