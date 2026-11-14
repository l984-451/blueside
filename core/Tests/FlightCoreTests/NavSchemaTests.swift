import CSQLite
import Foundation
import Testing

/// Runs a query that returns one integer. Gives -1 when the query cannot run.
private func scalar(_ path: String, _ sql: String) -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return -1
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
}

@Test func schemaAndSampleRowsLoad() throws {
    let path = try makeNavDatabase()
    #expect(scalar(path, "SELECT count(*) FROM airports") == 7)
    #expect(scalar(path, "SELECT count(*) FROM airports WHERE icao IS NULL") == 4)
    #expect(scalar(path, "SELECT count(*) FROM meta WHERE key = 'schema_version' AND value = '1'") == 1)
    for table in ["runways", "runway_ends", "frequencies", "remarks", "navaids", "fixes", "airway_points"] {
        #expect(scalar(path, "SELECT count(*) FROM \(table)") > 0, "\(table) is empty")
    }
}

@Test func insertingAnAirportFillsBothSearchIndexes() throws {
    let path = try makeNavDatabase()
    #expect(scalar(path, "SELECT count(*) FROM airports_rtree") == 7)
    #expect(scalar(path, "SELECT count(*) FROM airports_rtree WHERE min_lat > 61 AND max_lat < 62") == 1)
    #expect(scalar(path, "SELECT count(*) FROM airports_fts WHERE airports_fts MATCH '\"bergstrom\"*'") == 1)
    #expect(scalar(path, "SELECT count(*) FROM airports_fts WHERE airports_fts MATCH '\"austin\"*'") == 4)
}

@Test func frequencyKindOutsideTheListIsRejected() {
    #expect(throws: FixtureError.self) {
        try makeNavDatabase(extraSQL: "INSERT INTO frequencies(airport_id, use, kind, freq) VALUES (1, 'X', 'twr', '1')")
    }
}

// The Mac's own SQLite has the same version number, so check the build itself.
@Test func testsRunOnTheVendoredSQLite() {
    #expect(String(cString: sqlite3_libversion()) == "3.54.0")
    #expect(String(cString: sqlite3_sourceid()).hasPrefix("2026-10-09 15:46:58 be8d059e"))
    #expect(sqlite3_compileoption_used("ENABLE_FTS5") == 1)
    #expect(sqlite3_compileoption_used("ENABLE_RTREE") == 1)
    #expect(sqlite3_compileoption_used("OMIT_LOAD_EXTENSION") == 1)
}

// The server build runs its own copy of the two SQL files. A copy that is absent is skipped.
@Test func serverCopyOfTheSchemaMatches() throws {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let serverFolder = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("pipeline/tests/fixtures/nav")
    for name in ["nav_schema.sql", "nav_fixture.sql"] {
        let serverCopy = serverFolder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: serverCopy.path) else { continue }
        let ours = try Data(contentsOf: here.appendingPathComponent("Fixtures").appendingPathComponent(name))
        #expect(try Data(contentsOf: serverCopy) == ours, "\(name) differs from the server build's copy")
    }
}
