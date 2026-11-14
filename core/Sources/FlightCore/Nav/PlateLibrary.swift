import CSQLite

/// One chart in a plates pack's index.
public struct Plate: Codable, Hashable, Identifiable, Sendable {
    public var airport: String
    public var icao: String
    public var name: String
    public var code: String
    public var file: String
    public var pages: Int
    /// Where the plan view sits on the earth, for approach plates the FAA publishes as GeoPDFs.
    public var geo: PlateGeo?
    /// The pack holding the PDF. Not in the index.
    public var pack: URL?

    public var id: String { file + name }

    public init(airport: String, icao: String, name: String, code: String, file: String, pages: Int,
                geo: PlateGeo? = nil, pack: URL? = nil) {
        (self.airport, self.icao, self.name, self.code) = (airport, icao, name, code)
        (self.file, self.pages, self.geo, self.pack) = (file, pages, geo, pack)
    }

    private enum CodingKeys: String, CodingKey { case airport, icao, name, code, file, pages, geo }

    public enum Group: String, CaseIterable, Sendable {
        case approaches = "Approaches", departures = "Departures", arrivals = "Arrivals", other = "Other"
    }

    public var isDiagram: Bool { code == "APD" }

    public var placed: MapMemory.PlacedPlate { .init(airport: airport, file: file) }

    public var group: Group {
        switch code {
        case "IAP": .approaches
        case "DP", "ODP": .departures
        case "STR": .arrivals
        default: .other
        }
    }
}

/// A plate's plan view placed on the earth.
public struct PlateGeo: Codable, Hashable, Sendable {
    /// The plan view's corners as [longitude, latitude]: top left, top right, bottom right, bottom left.
    public var corners: [[Double]]
    /// The plan view, the airport sketch drawn inside it at its own scale, and boxed insets drawn at no
    /// scale (an alternate missed approach fix, say), as [left, top, right, bottom] fractions of the page from its top left.
    public var plan: [Double]
    public var sketch: [Double]?
    public var insets: [[Double]]?

    public init(corners: [[Double]], plan: [Double], sketch: [Double]? = nil, insets: [[Double]]? = nil) {
        (self.corners, self.plan, self.sketch, self.insets) = (corners, plan, sketch, insets)
    }

    /// The boxes not to scale, sketch and insets, as page fractions.
    public var masks: [[Double]] {
        ([sketch].compactMap { $0 } + (insets ?? [])).filter { $0.count == 4 }
    }

    /// The masks as [left, top, right, bottom] fractions of the plan view, for masking a cropped image.
    public var masksInPlan: [[Double]] {
        guard plan.count == 4 else { return [] }
        let (w, h) = (plan[2] - plan[0], plan[3] - plan[1])
        return masks.map { [($0[0] - plan[0]) / w, ($0[1] - plan[1]) / h, ($0[2] - plan[0]) / w, ($0[3] - plan[1]) / h] }
    }

    /// Where a page point, as fractions from top left, sits on earth: bilinear across the plan view's corners.
    public func coordinate(pageX x: Double, pageY y: Double) -> Coordinate? {
        guard let (u, v) = planFraction(x, y) else { return nil }
        let (lon, lat) = lonLat(u, v)
        return Coordinate(latitude: lat, longitude: lon)
    }

    /// The page point, as [x, y] fractions from top left, under a coordinate.
    /// Nil outside the plan view or inside the airport sketch or an inset, which are not to scale.
    public func pagePoint(_ at: Coordinate) -> [Double]? {
        guard corners.count == 4, corners.allSatisfy({ $0.count == 2 }), plan.count == 4 else { return nil }
        // Newton on the bilinear map; it is affine for FAA plates, so this settles in one or two steps.
        var (u, v) = (0.5, 0.5)
        for _ in 0..<8 {
            let (lon, lat) = lonLat(u, v)
            let (dx, dy) = (lon - at.longitude, lat - at.latitude)
            let c = corners
            let du = ((1 - v) * (c[1][0] - c[0][0]) + v * (c[2][0] - c[3][0]), (1 - v) * (c[1][1] - c[0][1]) + v * (c[2][1] - c[3][1]))
            let dv = ((1 - u) * (c[3][0] - c[0][0]) + u * (c[2][0] - c[1][0]), (1 - u) * (c[3][1] - c[0][1]) + u * (c[2][1] - c[1][1]))
            let det = du.0 * dv.1 - dv.0 * du.1
            guard det != 0 else { return nil }
            u -= (dx * dv.1 - dv.0 * dy) / det
            v -= (du.0 * dy - dx * du.1) / det
        }
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        let point = [plan[0] + u * (plan[2] - plan[0]), plan[1] + v * (plan[3] - plan[1])]
        if masks.contains(where: { ($0[0]...$0[2]).contains(point[0]) && ($0[1]...$0[3]).contains(point[1]) }) { return nil }
        return point
    }

    // Plan view fractions (u right, v down) for a page point, nil outside the plan view.
    private func planFraction(_ x: Double, _ y: Double) -> (Double, Double)? {
        guard plan.count == 4, corners.count == 4, plan[2] > plan[0], plan[3] > plan[1] else { return nil }
        let (u, v) = ((x - plan[0]) / (plan[2] - plan[0]), (y - plan[1]) / (plan[3] - plan[1]))
        return (0...1).contains(u) && (0...1).contains(v) ? (u, v) : nil
    }

    private func lonLat(_ u: Double, _ v: Double) -> (Double, Double) {
        let c = corners
        let top = (c[0][0] + u * (c[1][0] - c[0][0]), c[0][1] + u * (c[1][1] - c[0][1]))
        let bottom = (c[3][0] + u * (c[2][0] - c[3][0]), c[3][1] + u * (c[2][1] - c[3][1]))
        return (top.0 + v * (bottom.0 - top.0), top.1 + v * (bottom.1 - top.1))
    }
}

/// Airport diagrams and procedures read from plates packs: an index of charts and a PDF per chart.
public enum PlateLibrary {
    public static let layer = "plates"
    /// The first word of the plates warning, in the map banner's form.
    public static let subject = "Plates"

    /// The pack in force for each region on disk.
    public static func packs(installed: [PackFile], now: Date) -> [URL] {
        let packs = installed.map(\.pack)
        return Set(packs.map(\.id.region)).sorted().compactMap { region in
            let shown = ChartLibrary.packToShow(layer: layer, region: region, installed: packs, now: now)
            return installed.first { $0.pack == shown }?.url
        }
    }

    /// Every chart in the packs by airport identifier, each airport's in the FAA's order.
    public static func byAirport(_ packs: [URL]) -> [String: [Plate]] {
        var byAirport: [String: [Plate]] = [:]
        for pack in packs {
            for plate in index(pack) { byAirport[plate.airport, default: []].append(plate) }
        }
        return byAirport
    }

    /// The charts one pack holds. Empty when the file or its index cannot be read.
    public static func index(_ pack: URL) -> [Plate] {
        guard let data = blob(pack, "SELECT value FROM meta WHERE name = 'index'", nil),
              let plates = try? JSONDecoder().decode([Plate].self, from: data) else { return [] }
        return plates.map { var plate = $0; plate.pack = pack; return plate }
    }

    /// The chart's PDF bytes.
    public static func pdf(_ plate: Plate) -> Data? {
        plate.pack.flatMap { blob($0, "SELECT data FROM pdfs WHERE file = ?", plate.file) }
    }

    /// Writes the chart's PDF to a file, for a viewer that opens paths. False when there is none.
    public static func extract(_ plate: Plate, to file: URL) -> Bool {
        (try? pdf(plate)?.write(to: file)) != nil
    }

    // One column of one row as bytes, with an optional text argument.
    private static func blob(_ file: URL, _ query: String, _ argument: String?) -> Data? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        if let argument {
            sqlite3_bind_text(statement, 1, argument, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}
