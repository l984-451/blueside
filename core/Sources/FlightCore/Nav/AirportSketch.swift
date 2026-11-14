/// A drawn airport for fields the FAA publishes no diagram for: runways true north up, to scale, in page units
/// from top left. Both apps draw it as given, in order: areas, under, runways, lines, labels.
public struct AirportSketch: Equatable, Sendable, Codable {
    public struct Runway: Equatable, Sendable, Codable {
        public var id: String
        /// Four corners.
        public var outline: [[Double]]
        public var paved: Bool
        public var closed: Bool
    }

    /// A filled shape under the runways, in ink at this opacity.
    public struct Area: Equatable, Sendable, Codable {
        public var outline: [[Double]]
        public var shade: Double
    }

    /// A stroke through points, butt-ended: runway markings, closed X marks, the north arrow and scale bar.
    public struct Line: Equatable, Sendable, Codable {
        public var points: [[Double]]
        public var width: Double
        /// Paint on a runway, white, instead of ink.
        public var white = false
        /// On and off lengths, nil for solid.
        public var dash: [Double]?
        /// Ink opacity.
        public var shade = 1.0
    }

    public struct Label: Equatable, Sendable, Codable {
        public var text: String
        public var x: Double
        public var y: Double
        public var size: Double
        /// Degrees clockwise from upright.
        public var rotation: Double = 0
        /// Left-aligned at x instead of centered on it.
        public var leading = false
        public var bold = false
        /// Ink opacity.
        public var shade = 1.0
    }

    public static let title = "Airport Sketch"
    public static let pageWidth = 1000.0

    public var width: Double
    public var height: Double
    public var areas: [Area]
    /// Strokes under the runways, round-ended: taxiways, hold lines and building outlines.
    public var under: [Line]
    public var runways: [Runway]
    public var lines: [Line]
    public var labels: [Label]
    /// The drawing's corners on earth, so ownship and the map can use it like a plate.
    public var geo: PlateGeo
}

extension AirportSketch.Label {
    /// The page box the text roughly covers, corners clockwise, for keeping labels apart.
    var box: [[Double]] {
        let w = Double(text.count) * size * 0.6, h = size
        let r = rotation * .pi / 180, (c, s) = (cos(r), sin(r))
        let dx = leading ? w / 2 : 0
        return [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)].map { lx, ly in
            [x + (lx + dx) * c - ly * s, y + (lx + dx) * s + ly * c]
        }
    }
}

extension NavPages {
    /// The sketch of an airport's runways, or nil when none can be placed.
    public static func airportSketch(_ detail: AirportDetail) -> AirportSketch? {
        let variation = magneticVariation(detail.airport.magneticVariation)
        // Water lanes are left out, as on the map.
        let strips = detail.runways.filter { $0.id.contains("/") && !($0.surface ?? "").hasPrefix("WATER") }
        let placed = strips.compactMap { runway in
            runwayEnds(runway, airport: detail.airport, variation: variation, only: strips.count == 1)
                .map { (runway, $0.0, $0.1) }
        }
        guard !placed.isEmpty else { return nil }

        // Feet east and north of the middle of the runways.
        let lats = placed.flatMap { [$0.1.latitude, $0.2.latitude] }
        let lons = placed.flatMap { [$0.1.longitude, $0.2.longitude] }
        let center = Coordinate(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let (kx, ky) = feetPerDegree(center.latitude)
        func local(_ c: Coordinate) -> (Double, Double) {
            ((c.longitude - center.longitude) * kx, (c.latitude - center.latitude) * ky)
        }
        // OpenStreetMap detail moved from the airport's point to the runways' middle, kept when near the runways.
        let (sx, sy) = local(detail.airport.coordinate)
        let reach = (lons.map { abs(($0 - center.longitude) * kx) } + lats.map { abs(($0 - center.latitude) * ky) }).max()!
            + 3000
        let surface = detail.surface.map { f in
            var f = f
            f.points = f.points.map { [$0[0] + sx, $0[1] + sy] }
            return f
        }.filter { $0.points.contains { abs($0[0]) < reach && abs($0[1]) < reach } }
        let spread = surface.flatMap(\.points)
        let east = (lons.map { abs(($0 - center.longitude) * kx) } + spread.map { abs($0[0]) }).max()!
        let north = (lats.map { abs(($0 - center.latitude) * ky) } + spread.map { abs($0[1]) }).max()!
        // A title band on top, then the plan view: margins for the end numbers, the wider span fills the page,
        // and a short field is never cramped.
        let width = AirportSketch.pageWidth, margin = 130.0, top = 80.0
        let scale = (width - 2 * margin) / (2 * max(east, north, 1200))
        let drawn = max(2 * north * scale + 2 * margin, width * 0.6)
        func page(_ x: Double, _ y: Double) -> [Double] { [width / 2 + x * scale, top + drawn / 2 - y * scale] }

        var runways: [AirportSketch.Runway] = [], lines: [AirportSketch.Line] = []
        for (runway, a, b) in placed {
            let (ax, ay) = local(a), (bx, by) = local(b)
            let length = max(((bx - ax) * (bx - ax) + (by - ay) * (by - ay)).squareRoot(), 1)
            let (ux, uy) = ((bx - ax) / length, (by - ay) / length)
            // Never thinner than a few page units, so a narrow strip still shows.
            let w = max(Double(runway.widthFt ?? 60) * scale, 6) / scale / 2
            let (nx, ny) = (-uy * w, ux * w)
            let outline = [page(ax + nx, ay + ny), page(bx + nx, by + ny), page(bx - nx, by - ny), page(ax - nx, ay - ny)]
            let closed = NavText.runwayNote(runway, in: detail.remarks) == "CLOSED"
            let surface = (runway.surface ?? "").split(separator: "-").first.map(String.init) ?? ""
            let paved = ["ASPH", "CONC", "PEM"].contains(surface)
            runways.append(.init(id: runway.id, outline: outline, paved: paved, closed: closed))
            // Feet along the runway from end a and across it from its centerline, to the page.
            func at(_ t: Double, _ s: Double) -> [Double] { page(ax + ux * t + nx / w * s, ay + uy * t + ny / w * s) }
            if closed {
                let side = max(w * 2, 120 / scale)
                for t in [0.15, 0.85] {
                    let m = length * t
                    lines.append(.init(points: [at(m - side / 2, -side / 2), at(m + side / 2, side / 2)], width: 3))
                    lines.append(.init(points: [at(m - side / 2, side / 2), at(m + side / 2, -side / 2)], width: 3))
                }
            } else {
                lines += markings(runway, paved: paved, length: length, halfWidth: w, scale: scale, at: at)
            }
        }

        let drawnSurface = surface.map { f in AirportSketch.Area(outline: f.points.map { page($0[0], $0[1]) }, shade: 0) }
        var areas = [AirportSketch.Area(outline: fieldHull(runways.flatMap(\.outline)
                                                          + drawnSurface.flatMap(\.outline),
                                                          pad: 40), shade: 0.06)]
        var under: [AirportSketch.Line] = []
        // Aprons, then buildings outlined, then taxiways about as wide as built, then hold lines across them.
        for (f, shape) in zip(surface, drawnSurface) {
            switch f.kind {
            case .apron: areas.append(.init(outline: shape.outline, shade: 0.12))
            case .building:
                areas.append(.init(outline: shape.outline, shade: 0.2))
                under.append(.init(points: shape.outline + shape.outline.prefix(1), width: 1, shade: 0.8))
            default: break
            }
        }
        let taxiways = zip(surface, drawnSurface).filter { [.taxiway, .taxilane].contains($0.0.kind) && $0.1.outline.count > 1 }
        for (f, shape) in taxiways {
            under.append(.init(points: shape.outline, width: max((f.kind == .taxiway ? 50 : 30) * scale, 3),
                               shade: f.kind == .taxiway ? 0.35 : 0.25))
        }
        for (f, shape) in zip(surface, drawnSurface) where f.kind == .hold {
            if shape.outline.count > 1 {
                under.append(.init(points: shape.outline, width: 2))
            } else if let bar = holdBar(shape.outline[0], across: taxiways.map(\.1.outline), half: max(40 * scale, 4)) {
                under.append(.init(points: bar, width: 2))
            }
        }
        var obstacles = runways.map(\.outline), labels: [AirportSketch.Label] = []
        let plan = (left: 8.0, top: top + 8, right: width - 8, bottom: top + drawn - 8)
        func fits(_ box: [[Double]]) -> Bool {
            box.allSatisfy { plan.left...plan.right ~= $0[0] && plan.top...plan.bottom ~= $0[1] }
                && !obstacles.contains { overlaps(grown(box, 4), $0) }
        }

        // North arrow and scale bar together, in the first corner clear of the runways.
        let (legend, legendAreas, legendLabels, box) = self.legend(scale: scale)
        let corners = [(width - 24 - box.0, top + drawn - 24 - box.1), (24, top + drawn - 24 - box.1),
                       (width - 24 - box.0, top + 24), (24, top + 24)]
        let corner = corners.first { x, y in
            let shape = [[x, y], [x + box.0, y], [x + box.0, y + box.1], [x, y + box.1]]
            return !runways.contains { overlaps(grown(shape, 12), $0.outline) }
        }
        // With every corner taken, it goes under the plan view at the right.
        let (lx, ly) = corner ?? (width - 24 - box.0, top + drawn + 8)
        func moved(_ p: [Double]) -> [Double] { [p[0] + lx, p[1] + ly] }
        lines += legend.map { .init(points: $0.points.map(moved), width: $0.width) }
        areas += legendAreas.map { .init(outline: $0.outline.map(moved), shade: $0.shade) }
        labels += legendLabels.map { var l = $0; (l.x, l.y) = (l.x + lx, l.y + ly); return l }
        obstacles.append([[lx, ly], [lx + box.0, ly], [lx + box.0, ly + box.1], [lx, ly + box.1]])

        // Each end's number just beyond its threshold, along the runway and never upside down, its magnetic course
        // under it. Crowded, a label moves out and aside, then loses its course, then shrinks.
        for (runway, a, b) in placed {
            let (ax, ay) = local(a), (bx, by) = local(b)
            let (ox, oy) = (page(bx, by)[0] - page(ax, ay)[0], page(bx, by)[1] - page(ax, ay)[1])
            let length = max((ox * ox + oy * oy).squareRoot(), 1e-9)
            let names = runway.id.split(separator: "/").map(String.init)
            for (name, end, sign) in [(names[0], page(ax, ay), -1.0), (names[1], page(bx, by), 1.0)] {
                // Outward along the runway on the page, and across it.
                let (ux, uy) = (sign * ox / length, sign * oy / length)
                let landing = degrees(atan2(-ux, uy))
                let course = variation.flatMap { runwayCourse(name, along: landing, variation: $0) }
                let rotation = upright(landing)
                let r = rotation * .pi / 180
                // Down the text, which is along the runway one way or the other.
                let down = (-sin(r), cos(r)), outward = down.0 * ux + down.1 * uy > 0
                let halfWidth = runways.first { $0.id == runway.id }.map { span($0.outline[0], $0.outline[3]) / 2 } ?? 3
                var done = false
                search: for size in [26.0, 21, 17] {
                    for withCourse in course == nil ? [false] : [true, false] {
                        let small = size * 0.7, gap = 2.0
                        // Distances out from the threshold to each text's middle.
                        let (number, under) = withCourse
                            ? (outward ? (size / 2, size + gap + small / 2) : (small + gap + size / 2, small / 2))
                            : (size / 2, 0)
                        for along in [8.0, 20, 34, 50, 70, 95] {
                            for across in [0.0, 1, -1, 2, -2, 3, -3] {
                                let side = across * (halfWidth + size * 0.6)
                                func spot(_ d: Double) -> (Double, Double) {
                                    (end[0] + ux * (along + d) - uy * side, end[1] + uy * (along + d) + ux * side)
                                }
                                let n = spot(number), c = spot(under)
                                let made = [AirportSketch.Label(text: name, x: n.0, y: n.1, size: size, rotation: rotation,
                                                                bold: true)]
                                    + (withCourse ? [.init(text: course!, x: c.0, y: c.1, size: small, rotation: rotation)] : [])
                                if made.allSatisfy({ fits($0.box) }) {
                                    labels += made
                                    obstacles += made.map(\.box)
                                    done = true
                                    break search
                                }
                            }
                        }
                    }
                }
                if !done {
                    let n = (end[0] + ux * 21, end[1] + uy * 21)
                    let label = AirportSketch.Label(text: name, x: n.0, y: n.1, size: 17, rotation: rotation, bold: true)
                    labels.append(label)
                    obstacles.append(label.box)
                }
            }
        }

        // Length and width beside the runway along it, where it fits; it is in the lines below anyway.
        for (index, runway) in placed.map(\.0).enumerated() {
            let size = [runway.lengthFt, runway.widthFt].compactMap { $0 }.map(NavText.grouped).joined(separator: " × ")
            let o = runways[index].outline
            let (ox, oy) = (o[1][0] - o[0][0], o[1][1] - o[0][1])
            let length = span(o[0], o[1])
            guard !size.isEmpty, length > 160 else { continue }
            let (ux, uy) = (ox / length, oy / length)
            let halfWidth = span(o[0], o[3]) / 2
            let rotation = upright(degrees(atan2(uy, ux)))
            spots: for text in [18.0, 15] {
                for t in [0.5, 0.35, 0.65, 0.2, 0.8] {
                    for side in [1.0, -1] {
                        let d = side * (halfWidth + 6 + text / 2)
                        let mx = o[0][0] + ox * t + (o[3][0] - o[0][0]) / 2, my = o[0][1] + oy * t + (o[3][1] - o[0][1]) / 2
                        let label = AirportSketch.Label(text: size, x: mx - uy * d, y: my + ux * d, size: text, rotation: rotation)
                        if fits(label.box) {
                            labels.append(label)
                            obstacles.append(label.box)
                            break spots
                        }
                    }
                }
            }
        }

        // Taxiway letters on their taxiways, level, at most one per stretch.
        for (f, shape) in taxiways {
            guard let ref = f.name else { continue }
            let points = shape.outline
            let length = zip(points, points.dropFirst()).map { span($0, $1) }.reduce(0, +)
            guard length > 30 else { continue }
            let same = labels.filter { $0.text == ref }
            for t in [0.5, 0.3, 0.7, 0.15, 0.85] {
                let at = pointAlong(points, length * t)
                let label = AirportSketch.Label(text: ref, x: at[0], y: at[1], size: 15, bold: true)
                if !same.contains(where: { span([$0.x, $0.y], at) < 250 }), fits(label.box) {
                    labels.append(label)
                    obstacles.append(label.box)
                    break
                }
            }
        }

        // FBOs as a dot with the name beside it; when any name cannot be placed, all of them go under the drawing.
        var fbos: [(String, [Double])] = []
        for (f, shape) in zip(surface, drawnSurface) where f.kind == .fbo {
            if let name = f.name, !fbos.contains(where: { $0.0 == name }) { fbos.append((name, shape.outline[0])) }
        }
        var named: [AirportSketch.Label] = []
        for (name, at) in fbos {
            let dot = [[at[0] - 5, at[1]], [at[0], at[1] - 5], [at[0] + 5, at[1]], [at[0], at[1] + 5]]
            areas.append(.init(outline: dot, shade: 1))
            obstacles.append(dot)
            let width = Double(name.count) * 15 * 0.6
            let spots = [(at[0] + 9, at[1], true), (at[0] - 9 - width, at[1], true),
                         (at[0], at[1] - 16, false), (at[0], at[1] + 16, false)]
            for (x, y, leading) in spots {
                let label = AirportSketch.Label(text: name, x: x, y: y, size: 15, leading: leading)
                if fits(label.box) {
                    named.append(label)
                    obstacles.append(label.box)
                    break
                }
            }
        }
        let fbosBelow = named.count < fbos.count
        if !fbosBelow { labels += named }

        // The airport's code and name over the drawing.
        labels.append(.init(text: NavText.title(detail.airport) + "  " + NavText.capitalized(detail.airport.name),
                            x: 40, y: top / 2 + 4, size: 30, leading: true, bold: true))
        // Runway lines and field elevation under the drawing.
        var y = max(top + drawn, corner == nil ? ly + box.1 : 0) + 24
        let rows = NavText.runways(detail).filter { r in placed.contains { $0.0.id == r.id } }.map { r in
            [r.id + "  " + NavText.runwayLine(r), runways.first { $0.id == r.id }?.closed == true ? "Closed" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        } + [detail.airport.elevationFt.map { "Field elevation " + NavText.elevation($0) },
             detail.airport.fuel.map { "Fuel " + $0.split(separator: ",").joined(separator: ", ") }].compactMap { $0 }
            + (fbosBelow ? wrapped("FBO " + fbos.map(\.0).joined(separator: ", "), 62) : [])
        var lastRight = 0.0
        for row in rows {
            y += 34
            labels.append(.init(text: row, x: 40, y: y, size: 24, leading: true))
            lastRight = 40 + Double(row.count) * 24 * 0.6
        }
        if !surface.isEmpty {
            y += 30
            let credit = "© OpenStreetMap contributors"
            labels.append(.init(text: credit, x: 40, y: y, size: 16, leading: true))
            lastRight = 40 + Double(credit.count) * 16 * 0.6
        }
        // The Blueside mark and name at the bottom right, on the last row when it clears it.
        let brand = Self.brand(width: width, y: y, after: lastRight)
        y = brand.y
        lines += brand.lines
        areas += brand.areas
        labels.append(brand.label)
        let height = y + 32
        // Earth at the plan view's corners: top left, top right, bottom right, bottom left.
        let earth = [(0.0, 0.0), (width, 0.0), (width, drawn), (0.0, drawn)].map { px, py in
            [center.longitude + (px - width / 2) / scale / kx, center.latitude + (drawn / 2 - py) / scale / ky]
        }
        let geo = PlateGeo(corners: earth, plan: [0, top / height, 1, (top + drawn) / height])
        return AirportSketch(width: width, height: height, areas: areas, under: under, runways: runways, lines: lines,
                             labels: labels, geo: geo)
    }

    // A displaced threshold as a bar across with arrows pointing to it; on a hard surface, threshold bars at each
    // end and a dashed centerline when wide enough to hold one. at(t, s) places feet along from end a and across.
    private static func markings(_ runway: Runway, paved: Bool, length: Double, halfWidth w: Double, scale: Double,
                                 at: (Double, Double) -> [Double]) -> [AirportSketch.Line] {
        var lines: [AirportSketch.Line] = []
        let wide = 2 * w * scale
        // Bars as painted (4 on 60 ft, up to 16), as many as stay over a page unit wide.
        let painted = [(200, 16), (150, 12), (100, 8), (75, 6)].first { (runway.widthFt ?? 60) >= $0.0 }?.1 ?? 4
        let bars = max(2, min(painted, Int((wide / 1.2 - 1) / 2)))
        let stripe = 2 * w / Double(2 * bars + 1), barLength = max(150, 10 / scale)
        let names = runway.id.split(separator: "/").map(String.init)
        var inner: [Double] = []
        for (index, name) in names.enumerated() {
            let displaced = Double(runway.ends.first { $0.id == name }?.displacedThresholdFt ?? 0)
            // Feet from end a, pointing into the runway from this end.
            func t(_ d: Double) -> Double { index == 0 ? d : length - d }
            if displaced > 0, displaced < length / 2 {
                lines.append(.init(points: [at(t(displaced), -w), at(t(displaced), w)], width: 2, white: true))
                let head = w * 0.6
                for f in [0.3, 0.75] {
                    let tip = t(displaced * f + head), tail = t(displaced * f - head * 2)
                    lines.append(.init(points: [at(tail, 0), at(tip, 0)], width: 1, white: true))
                    lines.append(.init(points: [at(t(displaced * f), -head), at(tip, 0), at(t(displaced * f), head)],
                                       width: 1, white: true))
                }
            }
            let start = displaced < length / 2 ? displaced : 0
            for k in 0..<(paved ? bars : 0) {
                let s = -w + stripe * (Double(2 * k) + 1.5)
                lines.append(.init(points: [at(t(start + 20), s), at(t(start + 20 + barLength), s)],
                                   width: stripe * scale, white: true))
            }
            inner.append(start + 20 + barLength + 120)
        }
        if paved, wide >= 8, length - inner[1] > inner[0] {
            lines.append(.init(points: [at(inner[0], 0), at(length - inner[1], 0)], width: 1, white: true, dash: [10, 7]))
        }
        return lines
    }

    // The north arrow beside a scale bar of a round length in feet, in a box from its top left.
    private static func legend(scale: Double) -> ([AirportSketch.Line], [AirportSketch.Area], [AirportSketch.Label],
                                                  (Double, Double)) {
        let feet = [5000.0, 3000, 2000, 1000, 500, 200, 100].first { $0 * scale <= 180 } ?? 100
        let bar = feet * scale, x = 56.0
        let lines: [AirportSketch.Line] = [
            .init(points: [[20, 66], [20, 34]], width: 2),
            .init(points: [[x, 56], [x + bar, 56]], width: 2),
        ] + [0, 0.5, 1].map { f in .init(points: [[x + bar * f, 50], [x + bar * f, 62]], width: 2) }
        let areas = [AirportSketch.Area(outline: [[20, 20], [12, 38], [28, 38]], shade: 1)]
        let labels = [AirportSketch.Label(text: "N", x: 20, y: 8, size: 18, bold: true),
                      .init(text: NavText.grouped(Int(feet)) + " ft", x: x + bar / 2, y: 38, size: 16)]
        return (lines, areas, labels, (x + bar + 8, 72))
    }

    // The Blueside mark, a VOR head with its needle one dot right, and the name in gray, right-aligned at the
    // page's bottom; a row lower when the last row reaches it.
    private static func brand(width: Double, y: Double, after right: Double)
        -> (lines: [AirportSketch.Line], areas: [AirportSketch.Area], label: AirportSketch.Label, y: Double) {
        let name = "Blueside", size = 16.0, mark = 20.0, shade = 0.75
        let left = width - 40 - mark - 6 - Double(name.count) * size * 0.6
        let y = right + 24 > left ? y + 30 : y
        // Mark units are 48 to the side, from its top left.
        let k = mark / 48
        func p(_ x: Double, _ v: Double) -> [Double] { [left + x * k, y - mark / 2 + v * k] }
        func circle(_ cx: Double, _ r: Double, _ n: Int) -> [[Double]] {
            (0..<n).map { i in p(cx + r * cos(Double(i) * 2 * .pi / Double(n)), 24 + r * sin(Double(i) * 2 * .pi / Double(n))) }
        }
        let ring = circle(24, 20, 48)
        let lines = [AirportSketch.Line(points: ring + ring.prefix(2), width: 3.4 * k, shade: shade),
                     .init(points: [p(30, 12), p(30, 36)], width: 3.4 * k, shade: shade)]
        let areas = [21.0, 13.5].map { AirportSketch.Area(outline: circle($0, 2.1, 12), shade: shade) }
        let label = AirportSketch.Label(text: name, x: left + mark + 6, y: y, size: size, leading: true, shade: 0.5)
        return (lines, areas, label, y)
    }

    // The point this far along a line.
    private static func pointAlong(_ points: [[Double]], _ distance: Double) -> [Double] {
        var left = distance
        for (p, q) in zip(points, points.dropFirst()) {
            let d = span(p, q)
            if left <= d, d > 0 { return [p[0] + (q[0] - p[0]) * left / d, p[1] + (q[1] - p[1]) * left / d] }
            left -= d
        }
        return points[points.count - 1]
    }

    // A bar across the nearest taxiway at a hold point, or nil when none passes close.
    private static func holdBar(_ at: [Double], across lines: [[[Double]]], half: Double) -> [[Double]]? {
        var best: (Double, Double, Double)?
        for line in lines {
            for (p, q) in zip(line, line.dropFirst()) {
                let (dx, dy) = (q[0] - p[0], q[1] - p[1]), d2 = dx * dx + dy * dy
                guard d2 > 0 else { continue }
                let t = min(max(((at[0] - p[0]) * dx + (at[1] - p[1]) * dy) / d2, 0), 1)
                let gap = span(at, [p[0] + dx * t, p[1] + dy * t])
                if gap < (best?.0 ?? half * 2) { best = (gap, dx, dy) }
            }
        }
        guard case let (_, dx, dy)? = best else { return nil }
        let r = (dx * dx + dy * dy).squareRoot(), (nx, ny) = (-dy / r * half, dx / r * half)
        return [[at[0] - nx, at[1] - ny], [at[0] + nx, at[1] + ny]]
    }

    // Text split at commas into rows of at most this many characters.
    private static func wrapped(_ text: String, _ limit: Int) -> [String] {
        var rows: [String] = []
        for part in text.split(separator: ",").map({ $0.trimmingPrefix(" ") }) {
            if let last = rows.last, last.count + part.count + 2 <= limit {
                rows[rows.count - 1] = last + ", " + part
            } else {
                rows.append(String(part))
            }
        }
        return rows
    }

    // A rounded convex hull around points, pad out from them.
    private static func fieldHull(_ points: [[Double]], pad: Double) -> [[Double]] {
        let ring = points.flatMap { p in
            (0..<12).map { k in
                let a = Double(k) * .pi / 6
                return [p[0] + pad * cos(a), p[1] + pad * sin(a)]
            }
        }.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
        func cross(_ o: [Double], _ a: [Double], _ b: [Double]) -> Double {
            (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
        }
        var hull: [[Double]] = []
        for pass in [ring, ring.reversed()] {
            let start = hull.count
            for p in pass {
                while hull.count >= start + 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
                hull.append(p)
            }
            hull.removeLast()
        }
        return hull
    }

    private static func span(_ p: [Double], _ q: [Double]) -> Double {
        ((p[0] - q[0]) * (p[0] - q[0]) + (p[1] - q[1]) * (p[1] - q[1])).squareRoot()
    }

    // Whether two convex shapes overlap, by separating axes.
    static func overlaps(_ a: [[Double]], _ b: [[Double]]) -> Bool {
        for shape in [a, b] {
            for i in shape.indices {
                let p = shape[i], q = shape[(i + 1) % shape.count]
                let axis = (q[1] - p[1], p[0] - q[0])
                let pa = a.map { $0[0] * axis.0 + $0[1] * axis.1 }, pb = b.map { $0[0] * axis.0 + $0[1] * axis.1 }
                if pa.max()! <= pb.min()! || pb.max()! <= pa.min()! { return false }
            }
        }
        return true
    }

    // A convex shape with each corner pushed d out along both its edges, for a clearance test.
    private static func grown(_ shape: [[Double]], _ d: Double) -> [[Double]] {
        shape.indices.map { i in
            let p = shape[i]
            return [shape[(i + 1) % shape.count], shape[(i + shape.count - 1) % shape.count]].reduce(p) { out, q in
                let (dx, dy) = (p[0] - q[0], p[1] - q[1]), r = max((dx * dx + dy * dy).squareRoot(), 1e-9)
                return [out[0] + dx / r * d, out[1] + dy / r * d]
            }
        }
    }

    // Text rotation kept within 90° of level, so it never reads upside down.
    private static func upright(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        if d > 90 { d -= 180 } else if d <= -90 { d += 180 }
        return d
    }

    /// Degrees east as positive, from text like 3W or 4E.
    static func magneticVariation(_ text: String?) -> Double? {
        guard let text, let hemisphere = text.last, "EW".contains(hemisphere), let value = Double(text.dropLast()) else {
            return nil
        }
        return hemisphere == "W" ? -value : value
    }

    // The runway's two ends: both surveyed, else one surveyed end and its heading, else (the field's only runway)
    // centered on the airport's point along its heading.
    static func runwayEnds(_ runway: Runway, airport: Airport, variation: Double?, only: Bool) -> (Coordinate, Coordinate)? {
        let names = runway.id.split(separator: "/").map(String.init)
        guard names.count == 2 else { return nil }
        let ends = names.map { name in runway.ends.first { $0.id == name } }
        if let a = ends[0]?.coordinate, let b = ends[1]?.coordinate, a != b { return (a, b) }
        guard let length = runway.lengthFt, length > 0 else { return nil }
        let located = ends.enumerated().filter { $0.element?.coordinate != nil }
        let base = located.first?.offset ?? 0
        let numbered = Double(names[base].prefix(2)).map { $0 * 10 + (variation ?? .nan) }
        guard let heading = ends[base]?.trueHeading.map(Double.init) ?? numbered, heading.isFinite else { return nil }
        let miles = Double(length) / 6076.12
        if let start = ends[base]?.coordinate {
            guard let far = Geo.destination(from: start, bearingTrue: heading, distanceNM: miles) else { return nil }
            return base == 0 ? (start, far) : (far, start)
        }
        guard only, let start = Geo.destination(from: airport.coordinate, bearingTrue: heading + 180, distanceNM: miles / 2),
              let far = Geo.destination(from: start, bearingTrue: heading, distanceNM: miles) else { return nil }
        return (start, far)
    }

    // Magnetic course of the end a label faces, such as 160°. along is the true direction of landing on it.
    private static func runwayCourse(_ name: String, along: Double, variation: Double) -> String? {
        guard name.prefix(2).allSatisfy(\.isNumber) else { return nil }
        let course = Int(((along - variation).truncatingRemainder(dividingBy: 360) + 360).rounded()) % 360
        return String(format3(course == 0 ? 360 : course)) + "°"
    }

    private static func format3(_ value: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, 3 - text.count)) + text
    }

    private static func degrees(_ radians: Double) -> Double {
        let d = radians * 180 / .pi
        return d < 0 ? d + 360 : d
    }

    // Feet per degree of longitude and latitude on the WGS84 ellipsoid.
    private static func feetPerDegree(_ latitude: Double) -> (Double, Double) {
        let r = latitude * .pi / 180
        return ((111412.84 * cos(r) - 93.5 * cos(3 * r) + 0.118 * cos(5 * r)) / 0.3048,
                (111132.92 - 559.82 * cos(2 * r) + 1.175 * cos(4 * r)) / 0.3048)
    }
}
