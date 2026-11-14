import FlightCore
import PDFKit
import SwiftUI

/// Core's airport sketch drawn to scale, on chart paper like an FAA diagram.
struct SketchCanvas: View {
    let sketch: AirportSketch

    var body: some View {
        Canvas { context, _ in
            context.fill(Path(CGRect(x: 0, y: 0, width: sketch.width, height: sketch.height)),
                         with: .color(Color(uiColor: .white))) // design-lint: allow, the chart paper
            let ink = Color(uiColor: .darkGray)
            func path(_ points: [[Double]], closed: Bool) -> Path {
                var path = Path()
                path.addLines(points.map { CGPoint(x: $0[0], y: $0[1]) })
                if closed { path.closeSubpath() }
                return path
            }
            for area in sketch.areas {
                context.fill(path(area.outline, closed: true), with: .color(ink.opacity(area.shade)))
            }
            // Taxiways round-ended, so their joins close.
            for line in sketch.under {
                context.stroke(path(line.points, closed: false), with: .color(ink.opacity(line.shade)),
                               style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round))
            }
            for runway in sketch.runways {
                let outline = path(runway.outline, closed: true)
                context.fill(outline, with: .color(ink.opacity(runway.closed ? 0.3 : runway.paved ? 1 : 0.45)))
                context.stroke(outline, with: .color(ink), lineWidth: 1)
            }
            for line in sketch.lines {
                context.stroke(path(line.points, closed: false),
                               with: .color(line.white ? Color(uiColor: .white) : ink.opacity(line.shade)), // design-lint: allow, runway paint
                               style: StrokeStyle(lineWidth: line.width, dash: (line.dash ?? []).map { CGFloat($0) }))
            }
            for label in sketch.labels {
                var c = context
                c.translateBy(x: label.x, y: label.y)
                c.rotate(by: .degrees(label.rotation))
                // Sizes are page units, so the text keeps its scale to the runways.
                let text = Text(label.text).font(.system(size: label.size, weight: label.bold ? .bold : .regular)) // design-lint: allow
                    .foregroundStyle(Color(uiColor: .darkText).opacity(label.shade))
                c.draw(text, at: .zero, anchor: label.leading ? .leading : .center)
            }
        }
        .frame(width: sketch.width, height: sketch.height)
        .environment(\.colorScheme, .light)
    }
}

/// The sketch as a one-page PDF, so it opens, zooms and carries ownship like an FAA chart.
@MainActor enum SketchDocument {
    static func make(_ sketch: AirportSketch) -> PDFDocument? {
        let data = NSMutableData()
        ImageRenderer(content: SketchCanvas(sketch: sketch)).render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data),
                  let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            draw(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
        }
        return PDFDocument(data: data as Data)
    }
}
