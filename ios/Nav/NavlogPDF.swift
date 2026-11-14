import CoreTransferable
import FlightCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the nav log is built from. The core builds the page and the PDF is drawn, both off the main thread.
struct NavlogPDF: Transferable, Sendable {
    let route: RoutePlan
    let page: RoutePages.PlanPage
    var position: Position?
    var approximate = false
    let now: Date
    var aircraft: AircraftProfile?
    var balance: WeightBalance?
    var localOffset: Int?
    var database: NavDatabase?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { SentTransferredFile(try $0.write()) }
    }

    func write() throws -> URL {
        let log = RoutePages.navlog(route, page: page, position: position, approximate: approximate, now: now,
                                    aircraft: aircraft, balance: balance, localOffsetSeconds: localOffset, database: database)
        let url = URL.temporaryDirectory.appending(path: log.fileName)
        try NavlogSheet(log).data().write(to: url)
        return url
    }
}

/// The core's nav log drawn on US Letter pages turned wide, the mark in each footer.
struct NavlogSheet {
    let log: RoutePages.Navlog
    private let size = CGSize(width: 792, height: 612)
    private let margin: CGFloat = 32, footer: CGFloat = 20

    init(_ log: RoutePages.Navlog) { self.log = log }

    func data() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            var y = margin
            var open = false
            // A new page when the block does not fit, with the mark and name in its footer.
            func room(_ height: CGFloat) {
                guard !open || y + height > size.height - margin - footer else { return }
                context.beginPage()
                open = true
                y = margin
                let note = NSAttributedString(string: "Blueside", attributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.gray])
                let width = note.size().width
                note.draw(at: CGPoint(x: size.width - margin - width, y: size.height - margin))
                UIImage(named: "Mark")?.withTintColor(.gray).draw(in: CGRect(x: size.width - margin - width - 12, y: size.height - margin, width: 9, height: 9))
            }
            func text(_ string: String, _ rect: CGRect, font: UIFont, align: NSTextAlignment = .left) {
                let style = NSMutableParagraphStyle()
                style.alignment = align
                style.lineBreakMode = .byTruncatingTail
                NSAttributedString(string: string, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: UIColor.black]) // design-lint: allow ink on paper
                    .draw(in: rect)
            }
            func line(from a: CGPoint, to b: CGPoint, width: CGFloat = 0.5) {
                let path = UIBezierPath()
                path.move(to: a)
                path.addLine(to: b)
                path.lineWidth = width
                UIColor.black.setStroke() // design-lint: allow ink on paper
                path.stroke()
            }
            let body = UIFont.systemFont(ofSize: 9), bold = UIFont.boldSystemFont(ofSize: 9)
            let mono = UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            let heading = UIFont.boldSystemFont(ofSize: 11)
            let width = size.width - 2 * margin

            // A grid: the first column is wider, the last may be left empty to write in.
            func table(_ title: String, _ columns: [String], _ rows: [[String]], totals: [String]? = nil, weights: [CGFloat], rowHeight: CGFloat = 18) {
                let total = weights.reduce(0, +)
                let xs = weights.reduce(into: [CGFloat(0)]) { $0.append($0.last! + width * $1 / total) }
                func draw(_ cells: [String], font: UIFont, numbers: Bool) {
                    for (i, cell) in cells.enumerated() {
                        let rect = CGRect(x: margin + xs[i] + 3, y: y + 4, width: xs[i + 1] - xs[i] - 6, height: rowHeight - 4)
                        text(cell, rect, font: i == 0 || !numbers ? font : (font == bold ? bold : mono), align: i == 0 || !numbers ? .left : .right)
                    }
                    for x in xs { line(from: CGPoint(x: margin + x, y: y), to: CGPoint(x: margin + x, y: y + rowHeight)) }
                    line(from: CGPoint(x: margin, y: y + rowHeight), to: CGPoint(x: margin + width, y: y + rowHeight))
                }
                func header() {
                    line(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + width, y: y))
                    draw(columns, font: bold, numbers: false)
                    y += rowHeight
                }
                room(rowHeight * 3 + 20)
                text(title, CGRect(x: margin, y: y, width: width, height: 14), font: heading)
                y += 16
                header()
                for row in rows + (totals.map { [$0] } ?? []) {
                    if y + rowHeight > size.height - margin - footer { room(.infinity); header() }
                    draw(row, font: row == totals ? bold : body, numbers: true)
                    y += rowHeight
                }
                y += 10
            }

            room(0)
            text(log.title, CGRect(x: margin, y: y, width: width, height: 22), font: .boldSystemFont(ofSize: 16))
            y += 26
            table("", log.columns, log.rows, totals: log.totals, weights: [2.4] + Array(repeating: 1, count: log.columns.count - 2) + [1.8])

            // Summary, fuel and weights side by side as name and value lines.
            let blocks = [log.summary, log.fuel] + (log.weights.map { [$0] } ?? [])
            let gap: CGFloat = 20, column = (width - gap * CGFloat(blocks.count - 1)) / CGFloat(blocks.count)
            let tallest = blocks.map { $0.lines.count }.max() ?? 0
            room(CGFloat(tallest) * 14 + 30)
            for (b, block) in blocks.enumerated() {
                let x = margin + CGFloat(b) * (column + gap)
                text(block.title, CGRect(x: x, y: y, width: column, height: 14), font: heading)
                for (i, item) in block.lines.enumerated() {
                    let top = y + 16 + CGFloat(i) * 14
                    text(item.title, CGRect(x: x, y: top, width: column / 2.5, height: 12), font: body)
                    text(item.value ?? "", CGRect(x: x + column / 2.5, y: top, width: column * 0.6, height: 12), font: bold, align: .right)
                }
            }
            y += CGFloat(tallest) * 14 + 26

            table(log.frequencies.title, log.frequencies.columns, log.frequencies.rows, weights: [1.4, 2, 2])

            room(70)
            text(log.boxesTitle, CGRect(x: margin, y: y, width: width, height: 14), font: heading)
            y += 18
            let box = width / CGFloat(log.boxes.count)
            for (i, label) in log.boxes.enumerated() {
                let rect = CGRect(x: margin + CGFloat(i) * box, y: y, width: box - 10, height: 40)
                UIColor.black.setStroke() // design-lint: allow ink on paper
                UIBezierPath(rect: rect).stroke()
                text(label, CGRect(x: rect.minX + 4, y: rect.minY + 3, width: rect.width - 8, height: 12), font: body)
            }
        }
    }
}
