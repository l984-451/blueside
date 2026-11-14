import CSQLite
import Foundation

struct FixtureError: Error {
    var message: String
}

private let fixtureFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures")

/// Builds a database file from the schema and the sample rows, then runs any extra SQL.
func makeNavDatabase(extraSQL: String = "") throws -> String {
    let schema = try String(contentsOf: fixtureFolder.appendingPathComponent("nav_schema.sql"), encoding: .utf8)
    let sample = try String(contentsOf: fixtureFolder.appendingPathComponent("nav_fixture.sql"), encoding: .utf8)
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("nav-\(UUID().uuidString).sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else {
        sqlite3_close(db)
        throw FixtureError(message: "cannot create \(path)")
    }
    defer { sqlite3_close(db) }
    for sql in [schema, sample, extraSQL] {
        var message: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &message) != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw FixtureError(message: text)
        }
    }
    return path
}
