import CSQLite

private enum SQLValue {
    case text(String)
    case real(Double)
    case int(Int64)
}

/// The current row of a running statement.
private struct Row {
    let statement: OpaquePointer

    func text(_ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: bytes)
    }

    /// Nil for NULL and for an empty string, which the FAA files use for "not given".
    func optionalText(_ column: Int32) -> String? {
        let value = text(column)
        return value.isEmpty ? nil : value
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

    /// A blank string in a numeric column is stored as text and would read as 0.
    private func isNumber(_ column: Int32) -> Bool {
        let type = sqlite3_column_type(statement, column)
        return type == SQLITE_INTEGER || type == SQLITE_FLOAT
    }

    func optionalInt(_ column: Int32) -> Int? {
        isNumber(column) ? Int(sqlite3_column_int64(statement, column)) : nil
    }

    /// Nil for NULL and for zero, which both mean "not published" for a length or width.
    func positiveInt(_ column: Int32) -> Int? {
        let value = Int(sqlite3_column_int64(statement, column))
        return value > 0 ? value : nil
    }

    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

    /// Little-endian 16-bit pairs, as the surface table packs them.
    func pairs(_ column: Int32) -> [[Double]] {
        guard let bytes = sqlite3_column_blob(statement, column)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let count = Int(sqlite3_column_bytes(statement, column)) / 4
        func value(_ at: Int) -> Double { Double(Int16(bitPattern: UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8)) }
        return (0..<count).map { [value($0 * 4), value($0 * 4 + 2)] }
    }

    func optionalDouble(_ column: Int32) -> Double? {
        isNumber(column) ? sqlite3_column_double(statement, column) : nil
    }
}

/// Read-only access to one navigation database file.
/// Safe to share across threads: SQLite is built serialized and no statement outlives a call.
public final class NavDatabase: @unchecked Sendable {
    public static let supportedSchemaVersion = 1

    public let metadata: NavMetadata
    private let db: OpaquePointer

    /// Opens the file read-only and refuses it unless its meta table is one this code understands.
    public init(path: String) throws {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle = raw else {
            let message = raw.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(raw)
            throw NavDatabaseError.cannotOpen(message)
        }
        do {
            metadata = try NavDatabase.readMetadata(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        db = handle
    }

    deinit { sqlite3_close(db) }

    private static func readMetadata(_ db: OpaquePointer) throws -> NavMetadata {
        let pairs: [(String, String)]
        do {
            pairs = try query(db, "SELECT key, value FROM meta") { ($0.text(0), $0.text(1)) }
        } catch {
            // SQLite reads the file lazily, so a damaged file fails here. Only "no such table" means no version.
            if sqlite3_errcode(db) == SQLITE_ERROR { throw NavDatabaseError.unsupportedSchema(found: nil) }
            throw NavDatabaseError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        let meta = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        guard meta["schema_version"] == String(supportedSchemaVersion) else {
            throw NavDatabaseError.unsupportedSchema(found: meta["schema_version"])
        }
        // An unfilled index or detail table would return nothing without an error.
        // A blank position is stored as text and would read as 0, 0.
        let counts = try query(db, """
            SELECT (SELECT count(*) FROM airports), (SELECT count(*) FROM airports_rtree),
                   (SELECT count(*) FROM airports_fts_docsize),
                   (SELECT count(*) FROM airports WHERE typeof(lat) <> 'real' OR typeof(lon) <> 'real'),
                   (SELECT count(*) FROM runways), (SELECT count(*) FROM runway_ends),
                   (SELECT count(*) FROM frequencies)
            """) { row in (0..<7).map { row.int(Int32($0)) } }.first ?? []
        guard counts.count == 7, counts[0] > 0, counts[1] == counts[0], counts[2] == counts[0],
              counts[3] == 0 else {
            throw NavDatabaseError.badMetadata(key: "airports")
        }
        for (index, table) in ["runways", "runway_ends", "frequencies"].enumerated() where counts[index + 4] == 0 {
            throw NavDatabaseError.badMetadata(key: table)
        }
        func time(_ key: String) throws -> Date {
            guard let text = meta[key], let date = try? Date(text, strategy: .iso8601) else {
                throw NavDatabaseError.badMetadata(key: key)
            }
            return date
        }
        guard let cycle = meta["cycle"], !cycle.isEmpty else { throw NavDatabaseError.badMetadata(key: "cycle") }
        let effective = try time("effective")
        let expires = try time("expires")
        guard effective < expires else { throw NavDatabaseError.badMetadata(key: "expires") }
        return NavMetadata(schemaVersion: supportedSchemaVersion, cycle: cycle,
                           effective: effective, expires: expires, builtAt: try time("built_at"),
                           suaSnapshot: meta["sua_snapshot"].flatMap { try? Date($0, strategy: .iso8601) })
    }

    private static let airportColumns = """
        a.id, a.ident, a.icao, a.name, a.city, a.state, a.type, a.use, a.lat, a.lon, \
        a.elev, a.magvar, a.tpa, a.twr, a.fuel, a.artcc, a.status
        """

    private static func makeAirport(_ row: Row) -> Airport {
        Airport(id: row.int(0), ident: row.text(1), icao: row.optionalText(2), name: row.text(3),
                city: row.text(4), state: row.text(5), type: row.text(6), use: row.text(7),
                coordinate: Coordinate(latitude: row.double(8), longitude: row.double(9)),
                elevationFt: row.optionalDouble(10), magneticVariation: row.optionalText(11),
                patternAltitude: row.optionalText(12), tower: row.text(13), fuel: row.optionalText(14),
                artcc: row.optionalText(15), status: row.text(16))
    }

    /// The facility whose FAA identifier or ICAO code is exactly this text. No prefix is added or removed.
    /// Includes closed facilities; check isOperational before showing one as usable.
    public func airport(identifier: String) throws -> Airport? {
        let code = identifier.trimmed.uppercased()
        return try rows("""
            SELECT \(Self.airportColumns) FROM airports a
            WHERE a.ident = ?1 OR a.icao = ?1 ORDER BY a.ident = ?1 DESC, a.id LIMIT 1
            """, [.text(code)], Self.makeAirport).first
    }

    /// Exact identifier or ICAO code first, then identifiers starting with the text, then name, city and state.
    /// Includes closed facilities; check isOperational before showing one as usable.
    public func search(_ text: String, limit: Int = 25) throws -> [Airport] {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        var found: [Airport] = []
        var seen = Set<Int64>()
        func add(_ airports: [Airport]) {
            for airport in airports where found.count < limit {
                if seen.insert(airport.id).inserted { found.append(airport) }
            }
        }
        // Identifiers hold only letters and digits, so other text goes straight to the word search.
        if trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) {
            let code = trimmed.uppercased()
            add(try rows("""
                SELECT \(Self.airportColumns) FROM airports a
                WHERE a.ident = ?1 OR a.icao = ?1 ORDER BY a.ident = ?1 DESC, a.id
                """, [.text(code)], Self.makeAirport))
            // Scans every airport, about 1 ms on the national file.
            add(try rows("""
                SELECT \(Self.airportColumns) FROM airports a
                WHERE a.ident LIKE ?1 || '%' OR a.icao LIKE ?1 || '%'
                ORDER BY (a.ident LIKE ?1 || '%') DESC, length(a.ident), a.ident LIMIT ?2
                """, [.text(code), .int(Int64(limit))], Self.makeAirport))
        }
        // Each word becomes a quoted prefix term, so nothing the user types is read as query syntax.
        let words = trimmed.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        if !words.isEmpty, found.count < limit {
            let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
            add(try rows("""
                SELECT \(Self.airportColumns) FROM airports_fts JOIN airports a ON a.id = airports_fts.rowid
                WHERE airports_fts MATCH ?1
                ORDER BY a.use != 'PU', a.type != 'A', airports_fts.rank, a.name LIMIT ?2
                """, [.text(match), .int(Int64(limit))], Self.makeAirport))
        }
        return found
    }

    /// The closest operating facilities, nearest first, with distance and true bearing from the point.
    /// Pass false to include heliports, water landing bases and private fields.
    public func nearest(to point: Coordinate, count: Int, publicAirportsOnly: Bool) throws -> [NearbyAirport] {
        guard count > 0, point.latitude.isFinite, point.longitude.isFinite else { return [] }
        let sql = """
            SELECT \(Self.airportColumns) FROM airports_rtree r JOIN airports a ON a.id = r.id
            WHERE r.max_lat >= ?1 AND r.min_lat <= ?2 AND r.max_lon >= ?3 AND r.min_lon <= ?4
              AND a.status = 'O' AND (?5 = 0 OR (a.type = 'A' AND a.use = 'PU'))
            """
        // Half the box height, in degrees of latitude. One degree is just over 60 NM.
        var half = 0.5
        while true {
            // Sized at the poleward edge, so the box holds every point within half * 60 NM.
            let edge = abs(point.latitude) + half
            let lonHalf = edge >= 89 ? 180 : half / cos(edge * .pi / 180)
            var west = point.longitude - lonHalf
            var east = point.longitude + lonHalf
            // Near longitude 180 the box would wrap, so search every longitude there.
            if west < -180 || east > 180 {
                west = -180
                east = 180
            }
            let found = try rows(sql, [.real(point.latitude - half), .real(point.latitude + half),
                                       .real(west), .real(east), .int(publicAirportsOnly ? 1 : 0)], Self.makeAirport)
                .map { airport in
                    NearbyAirport(airport: airport,
                                  distanceNM: Geo.distanceNM(from: point, to: airport.coordinate),
                                  bearingTrue: Geo.initialBearing(from: point, to: airport.coordinate))
                }
                .sorted { ($0.distanceNM, $0.airport.id) < ($1.distanceNM, $1.airport.id) }
            // A facility in a box corner can be farther than one just outside the box,
            // so accept the list only when its last entry is inside the covered circle.
            let coversTheWorld = half >= 90
            if coversTheWorld || (found.count >= count && found[count - 1].distanceNM <= half * 60) {
                return Array(found.prefix(count))
            }
            half *= 2
        }
    }

    /// Operating facilities of every kind inside a box, for the brief's ground line.
    public func airports(in box: MapStyleSpec.Box) throws -> [Airport] {
        try Self.wrapped(box).flatMap { box in
            try rows("""
                SELECT \(Self.airportColumns) FROM airports_rtree r JOIN airports a ON a.id = r.id
                WHERE r.max_lat >= ?1 AND r.min_lat <= ?2 AND r.max_lon >= ?3 AND r.min_lon <= ?4 AND a.status = 'O'
                """, [.real(box.minLatitude), .real(box.maxLatitude), .real(box.minLongitude), .real(box.maxLongitude)],
                Self.makeAirport)
        }
    }

    /// Obstacles with a known height above sea level inside a box, for the brief's route profile.
    public func obstacles(in box: MapStyleSpec.Box) throws -> [Obstacle] {
        try Self.wrapped(box).flatMap { box in
            try rows("""
                SELECT lat, lon, agl, msl, type FROM obstacles
                WHERE msl IS NOT NULL AND lat BETWEEN ?1 AND ?2 AND lon BETWEEN ?3 AND ?4
                """, [.real(box.minLatitude), .real(box.maxLatitude), .real(box.minLongitude), .real(box.maxLongitude)]) { row in
                Obstacle(coordinate: Coordinate(latitude: row.double(0), longitude: row.double(1)), aglFt: Int(row.int(2)),
                         mslFt: Int(row.int(3)), type: row.optionalText(4))
            }
        }
    }

    /// A box whose longitudes run past 180 degrees, as the one or two boxes it covers within -180 to 180.
    static func wrapped(_ box: MapStyleSpec.Box) -> [MapStyleSpec.Box] {
        func part(_ west: Double, _ east: Double) -> MapStyleSpec.Box {
            .init(minLatitude: box.minLatitude, minLongitude: west, maxLatitude: box.maxLatitude, maxLongitude: east)
        }
        guard box.maxLongitude - box.minLongitude < 360 else { return [part(-180, 180)] }
        let west = RouteMath.normalized(box.minLongitude + 180) - 180
        let east = west + box.maxLongitude - box.minLongitude
        return east > 180 ? [part(west, 180), part(-180, east - 360)] : [part(west, east)]
    }

    /// One airport with its runways (longest first), frequencies and remarks. Nil for an unknown id.
    public func detail(airportID: Int64) throws -> AirportDetail? {
        let id: [SQLValue] = [.int(airportID)]
        guard let airport = try rows("SELECT \(Self.airportColumns) FROM airports a WHERE a.id = ?1",
                                     id, Self.makeAirport).first else { return nil }

        let ends = try rows("""
            SELECT rwy_id, end_id, true_hdg, rh_pattern, lat, lon, elev, displaced_len, vgsi, als, tora, lda
            FROM runway_ends WHERE airport_id = ?1 ORDER BY rwy_id, end_id
            """, id) { row -> (runway: String, end: RunwayEnd) in
            var coordinate: Coordinate?
            if let latitude = row.optionalDouble(4), let longitude = row.optionalDouble(5) {
                coordinate = Coordinate(latitude: latitude, longitude: longitude)
            }
            let pattern = row.text(3)
            let rightTraffic: Bool? = pattern == "Y" ? true : (pattern == "N" ? false : nil)
            let end = RunwayEnd(id: row.text(1), trueHeading: row.optionalInt(2), rightTraffic: rightTraffic,
                                coordinate: coordinate, elevationFt: row.optionalDouble(6),
                                displacedThresholdFt: row.optionalInt(7), vgsi: row.optionalText(8),
                                approachLights: row.optionalText(9), toraFt: row.optionalInt(10),
                                ldaFt: row.optionalInt(11))
            return (runway: row.text(0), end: end)
        }

        let runways = try rows("""
            SELECT rwy_id, length, width, surface, cond, lights
            FROM runways WHERE airport_id = ?1 ORDER BY length DESC, rwy_id
            """, id) { row -> Runway in
            let name = row.text(0)
            return Runway(id: name, lengthFt: row.positiveInt(1), widthFt: row.positiveInt(2),
                          surface: row.optionalText(3), condition: row.optionalText(4),
                          lights: row.optionalText(5),
                          ends: ends.filter { $0.runway == name }.map { $0.end })
        }

        // A kind this code does not know, from a newer build, is shown under "other".
        let order = FrequencyKind.allCases
        func rank(_ frequency: Frequency) -> (Int, String, String) {
            (order.firstIndex(of: frequency.kind) ?? order.count, frequency.use, frequency.frequency)
        }
        let frequencies = try rows("""
            SELECT use, kind, freq, call, sector, remark FROM frequencies WHERE airport_id = ?1
            """, id) { row -> Frequency in
            Frequency(kind: FrequencyKind(rawValue: row.text(1)) ?? .other, use: row.text(0),
                      frequency: row.text(2), callSign: row.optionalText(3),
                      sector: row.optionalText(4), remark: row.optionalText(5))
        }.sorted { rank($0) < rank($1) }

        let remarks = try rows("""
            SELECT tab, ref_col, element, seq, remark FROM remarks
            WHERE airport_id = ?1 ORDER BY tab, ref_col, element, seq
            """, id) { row -> Remark in
            Remark(tab: row.optionalText(0), field: row.optionalText(1), element: row.optionalText(2),
                   seq: row.optionalInt(3), text: row.text(4))
        }

        // A file from before the surface table has none.
        let surface = (try? rows("SELECT kind, name, points FROM surface WHERE airport_id = ?1 ORDER BY rowid", id) {
            row in SurfaceFeature.Kind(rawValue: row.text(0)).map {
                SurfaceFeature(kind: $0, name: row.optionalText(1), points: row.pairs(2))
            }
        })?.compactMap { $0 } ?? []

        return AirportDetail(airport: airport, runways: runways, frequencies: frequencies, remarks: remarks,
                             surface: surface)
    }

    private func rows<T>(_ sql: String, _ values: [SQLValue] = [], _ make: (Row) -> T) throws -> [T] {
        try Self.query(db, sql, values, make)
    }

    private static func query<T>(_ db: OpaquePointer, _ sql: String, _ values: [SQLValue] = [],
                                 _ make: (Row) -> T) throws -> [T] {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let statement = raw else {
            throw NavDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        // Tells SQLite to copy bound text, because the Swift string is gone once the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            }
        }
        var out: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                out.append(make(Row(statement: statement)))
            } else if code == SQLITE_DONE {
                return out
            } else {
                throw NavDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}

extension NavDatabase {
    private static func code(_ text: String) -> String {
        text.trimmed.uppercased()
    }

    /// Every navaid with this identifier, because identifiers repeat across the country.
    /// Includes test signals and stations that are shut down; see isRoutePoint and isShutDown.
    public func navaids(ident: String) throws -> [Navaid] {
        try rows("""
            SELECT id, ident, type, name, city, state, lat, lon, elev, freq, chan, magvar, status
            FROM navaids WHERE ident = ?1 ORDER BY id
            """, [.text(Self.code(ident))]) { row in
            Navaid(id: row.int(0), ident: row.text(1), type: row.text(2), name: row.text(3),
                   city: row.optionalText(4), state: row.optionalText(5),
                   coordinate: Coordinate(latitude: row.double(6), longitude: row.double(7)),
                   elevationFt: row.optionalDouble(8), frequency: row.optionalText(9),
                   channel: row.optionalText(10), magneticVariation: row.optionalText(11),
                   status: row.optionalText(12))
        }
    }

    /// Every fix with this identifier.
    public func fixes(ident: String) throws -> [Fix] {
        try rows("""
            SELECT id, ident, state, lat, lon, use, charts FROM fixes WHERE ident = ?1 ORDER BY id
            """, [.text(Self.code(ident))]) { row in
            Fix(id: row.int(0), ident: row.text(1), state: row.optionalText(2),
                coordinate: Coordinate(latitude: row.double(3), longitude: row.double(4)),
                use: row.optionalText(5), charts: row.optionalText(6))
        }
    }

    /// The airway as runs of placed points. A run ends after a row marked as a gap,
    /// at a row with no position, and where the location changes. Empty for an unknown name.
    public func airway(named name: String) throws -> [AirwayRun] {
        let found = try rows("""
            SELECT location, point, point_type, lat, lon, gap, mea
            FROM airway_points WHERE airway = ?1 ORDER BY location, seq
            """, [.text(Self.code(name))]) { row in
            (location: row.text(0), ident: row.text(1), type: row.optionalText(2),
             latitude: row.optionalDouble(3), longitude: row.optionalDouble(4),
             gap: row.int(5) != 0, mea: row.optionalInt(6))
        }
        var runs: [AirwayRun] = []
        var open: AirwayRun?
        for row in found {
            if let run = open, run.location != row.location {
                runs.append(run)
                open = nil
            }
            guard let latitude = row.latitude, let longitude = row.longitude else {
                if let run = open { runs.append(run) }
                open = nil
                continue
            }
            var run = open ?? AirwayRun(location: row.location, points: [])
            run.points.append(AirwayPoint(ident: row.ident, pointType: row.type,
                                          coordinate: Coordinate(latitude: latitude, longitude: longitude),
                                          meaFt: row.mea))
            if row.gap {
                runs.append(run)
                open = nil
            } else {
                open = run
            }
        }
        if let run = open { runs.append(run) }
        return runs
    }

    /// Airports, navaids and fixes within the radius of a point, closest first. Test signals and fan markers are left out.
    public func waypoints(near point: Coordinate, withinNM radius: Double) throws -> [WaypointMatch] {
        guard radius > 0, point.latitude.isFinite, point.longitude.isFinite else { return [] }
        let half = radius / 60
        let lonHalf = min(half / max(cos((abs(point.latitude) + half) * .pi / 180), 0.01), 180)
        let box: [SQLValue] = [.real(point.latitude - half), .real(point.latitude + half),
                               .real(point.longitude - lonHalf), .real(point.longitude + lonHalf)]
        // ponytail: navaids and fixes have no spatial index, so their tables are scanned; add one if this is slow.
        var found = try rows("""
            SELECT a.ident, a.icao, a.name, a.lat, a.lon, a.elev FROM airports_rtree r JOIN airports a ON a.id = r.id
            WHERE r.max_lat >= ?1 AND r.min_lat <= ?2 AND r.max_lon >= ?3 AND r.min_lon <= ?4
            """, box) { row in
            WaypointMatch(kind: .airport, ident: row.text(0), icao: row.optionalText(1), name: row.text(2),
                          coordinate: Coordinate(latitude: row.double(3), longitude: row.double(4)), elevationFt: row.optionalDouble(5))
        }
        found += try rows("""
            SELECT ident, name, lat, lon FROM navaids WHERE lat BETWEEN ?1 AND ?2 AND lon BETWEEN ?3 AND ?4
              AND type NOT IN ('VOT', 'FAN MARKER')
            """, box) { row in
            WaypointMatch(kind: .navaid, ident: row.text(0), icao: nil, name: row.text(1),
                          coordinate: Coordinate(latitude: row.double(2), longitude: row.double(3)))
        }
        found += try rows("""
            SELECT ident, lat, lon FROM fixes WHERE lat BETWEEN ?1 AND ?2 AND lon BETWEEN ?3 AND ?4
            """, box) { row in
            WaypointMatch(kind: .fix, ident: row.text(0), icao: nil, name: row.text(0),
                          coordinate: Coordinate(latitude: row.double(1), longitude: row.double(2)))
        }
        return found.map { ($0, Geo.distanceNM(from: point, to: $0.coordinate)) }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Airports, navaids and fixes whose identifier starts with the text, exact identifiers first.
    /// Test signals and fan markers are left out. Text with anything but letters and digits finds nothing.
    public func waypointSearch(prefix: String, limit: Int = 25) throws -> [WaypointMatch] {
        let code = Self.code(prefix)
        guard !code.isEmpty, limit > 0, code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return [] }
        let values: [SQLValue] = [.text(code), .int(Int64(limit))]
        // Each query scans its table; the largest holds about 70 thousand rows.
        var found = try rows("""
            SELECT a.ident, a.icao, a.name, a.lat, a.lon, a.elev FROM airports a
            WHERE a.ident LIKE ?1 || '%' OR a.icao LIKE ?1 || '%'
            ORDER BY (a.ident = ?1 OR ifnull(a.icao, '') = ?1) DESC, length(a.ident), a.ident LIMIT ?2
            """, values) { row in
            WaypointMatch(kind: .airport, ident: row.text(0), icao: row.optionalText(1), name: row.text(2),
                          coordinate: Coordinate(latitude: row.double(3), longitude: row.double(4)), elevationFt: row.optionalDouble(5))
        }
        found += try rows("""
            SELECT ident, name, lat, lon FROM navaids
            WHERE ident LIKE ?1 || '%' AND type NOT IN ('VOT', 'FAN MARKER')
            ORDER BY length(ident), ident, id LIMIT ?2
            """, values) { row in
            WaypointMatch(kind: .navaid, ident: row.text(0), icao: nil, name: row.text(1),
                          coordinate: Coordinate(latitude: row.double(2), longitude: row.double(3)))
        }
        found += try rows("""
            SELECT ident, lat, lon FROM fixes WHERE ident LIKE ?1 || '%'
            ORDER BY length(ident), ident, id LIMIT ?2
            """, values) { row in
            WaypointMatch(kind: .fix, ident: row.text(0), icao: nil, name: row.text(0),
                          coordinate: Coordinate(latitude: row.double(1), longitude: row.double(2)))
        }
        let kinds = WaypointKind.allCases
        func key(_ match: WaypointMatch) -> (Int, Int, String, Int) {
            let exact = match.ident == code || match.icao == code
            return (exact ? 0 : 1, match.ident.count, match.ident, kinds.firstIndex(of: match.kind) ?? kinds.count)
        }
        return Array(found.sorted { key($0) < key($1) }.prefix(limit))
    }
}
