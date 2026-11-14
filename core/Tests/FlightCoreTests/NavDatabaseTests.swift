import Foundation
import Testing
@testable import FlightCore

/// One read-only database on the sample rows, shared by the nav tests.
let navFixture = try! NavDatabase(path: makeNavDatabase())

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

private func openError(path: String) -> NavDatabaseError? {
    do {
        _ = try NavDatabase(path: path)
        return nil
    } catch {
        return error as? NavDatabaseError
    }
}

private func openError(after sql: String) throws -> NavDatabaseError? {
    openError(path: try makeNavDatabase(extraSQL: sql))
}

private func idents(_ text: String) throws -> [String] {
    try navFixture.search(text).map(\.ident)
}

@Test func metadataCarriesTheCycleAndItsDates() {
    #expect(navFixture.metadata == NavMetadata(
        schemaVersion: 1, cycle: "2026-10-01",
        effective: date("2026-10-01T09:01:00Z"), expires: date("2026-10-29T09:01:00Z"),
        builtAt: date("2026-10-13T04:00:00Z")))
}

@Test func currencyFollowsTheCycleDates() {
    let meta = navFixture.metadata
    #expect(meta.currency(at: date("2026-10-01T09:00:59Z")) == .notYetEffective)
    #expect(meta.currency(at: date("2026-10-01T09:01:00Z")) == .current)
    #expect(meta.currency(at: date("2026-10-29T09:00:59Z")) == .current)
    #expect(meta.currency(at: date("2026-10-29T09:01:00Z")) == .expired)
}

@Test func missingFileFailsToOpen() {
    guard case .cannotOpen? = openError(path: "/nonexistent/nav.sqlite") else {
        Issue.record("expected cannotOpen")
        return
    }
}

@Test func fileThatIsNotADatabaseFailsToOpen() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("not-a-database-\(UUID().uuidString).sqlite").path
    try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: path))
    #expect(openError(path: path) == .cannotOpen("file is not a database"))

    // The first half of a good file, as an interrupted download leaves it.
    let whole = try Data(contentsOf: URL(fileURLWithPath: makeNavDatabase()))
    let half = FileManager.default.temporaryDirectory
        .appendingPathComponent("half-\(UUID().uuidString).sqlite").path
    try whole.prefix(whole.count / 2).write(to: URL(fileURLWithPath: half))
    guard case .cannotOpen? = openError(path: half) else {
        Issue.record("expected cannotOpen for a truncated file")
        return
    }
}

@Test func fileWithEmptyIndexesFailsToOpen() throws {
    #expect(try openError(after: "DELETE FROM airports_rtree") == .badMetadata(key: "airports"))
    #expect(try openError(after: "DELETE FROM airports_fts_docsize") == .badMetadata(key: "airports"))
    #expect(try openError(after: """
        DELETE FROM airports; DELETE FROM airports_rtree; DELETE FROM airports_fts_docsize
        """) == .badMetadata(key: "airports"))
}

@Test func otherSchemaVersionFailsToOpen() throws {
    #expect(try openError(after: "UPDATE meta SET value = '2' WHERE key = 'schema_version'")
        == .unsupportedSchema(found: "2"))
    #expect(try openError(after: "UPDATE meta SET value = '' WHERE key = 'schema_version'")
        == .unsupportedSchema(found: ""))
}

@Test func missingSchemaVersionFailsToOpen() throws {
    #expect(try openError(after: "DELETE FROM meta WHERE key = 'schema_version'") == .unsupportedSchema(found: nil))
    #expect(try openError(after: "DROP TABLE meta") == .unsupportedSchema(found: nil))
}

@Test func missingOrMalformedCycleDatesFailToOpen() throws {
    #expect(try openError(after: "DELETE FROM meta WHERE key = 'cycle'") == .badMetadata(key: "cycle"))
    #expect(try openError(after: "DELETE FROM meta WHERE key = 'expires'") == .badMetadata(key: "expires"))
    #expect(try openError(after: "UPDATE meta SET value = 'soon' WHERE key = 'effective'") == .badMetadata(key: "effective"))
    #expect(try openError(after: "UPDATE meta SET value = '2026-09-01T09:01:00Z' WHERE key = 'expires'")
        == .badMetadata(key: "expires"))
    #expect(try openError(after: "DELETE FROM meta WHERE key = 'built_at'") == .badMetadata(key: "built_at"))
}

@Test func findsAnAirportByEitherIdentifier() throws {
    #expect(try navFixture.airport(identifier: "AUS")?.icao == "KAUS")
    #expect(try navFixture.airport(identifier: "KAUS")?.ident == "AUS")
    #expect(try navFixture.airport(identifier: " kaus ")?.ident == "AUS")
    #expect(try navFixture.airport(identifier: "PANC")?.ident == "ANC")
    #expect(try navFixture.airport(identifier: "ANC")?.icao == "PANC")
    #expect(try navFixture.airport(identifier: "NOPE") == nil)
}

@Test func neverInventsAnICAOCode() throws {
    let t82 = try #require(try navFixture.airport(identifier: "T82"))
    #expect(t82.icao == nil)
    #expect(try navFixture.airport(identifier: "KT82") == nil)
    #expect(try navFixture.airport(identifier: "KTX05") == nil)
    #expect(try navFixture.airport(identifier: "KANC") == nil)
}

@Test func airportFieldsComeThroughAsPublished() throws {
    let aus = try #require(try navFixture.airport(identifier: "AUS"))
    #expect(aus.name == "AUSTIN-BERGSTROM INTL")
    #expect(aus.city == "AUSTIN")
    #expect(aus.state == "TX")
    #expect(aus.type == "A")
    #expect(aus.use == "PU")
    #expect(abs(aus.coordinate.latitude - 30.19452722) < 1e-9)
    #expect(abs(aus.coordinate.longitude - -97.66987611) < 1e-9)
    #expect(aus.elevationFt == 541.5)
    #expect(aus.magneticVariation == "4E")
    #expect(aus.patternAltitude == nil)
    #expect(aus.tower == "ATCT-TRACON")
    #expect(aus.fuel == "100LL,A")
    #expect(aus.artcc == "ZHU")
    #expect(aus.isOperational)

    let helipad = try #require(try navFixture.airport(identifier: "68TX"))
    #expect(helipad.type == "H")
    #expect(helipad.magneticVariation == nil)
    #expect(helipad.fuel == nil)
}

@Test func searchPutsTheExactIdentifierFirst() throws {
    #expect(try idents("AUS") == ["AUS", "EDC", "TX05", "68TX"])
    #expect(try idents("aus") == ["AUS", "EDC", "TX05", "68TX"])
    #expect(try idents("KAUS") == ["AUS"])
    #expect(try idents("PANC") == ["ANC"])
}

@Test func searchMatchesIdentifierPrefixesBeforeNames() throws {
    #expect(try idents("T8") == ["T82"])
    // The other Texas fields follow, matched through their state.
    let texas = try idents("TX")
    #expect(texas.first == "TX05")
    #expect(Set(texas.dropFirst()) == ["AUS", "EDC", "T82", "TS01", "68TX"])
    #expect(try idents("KE") == ["EDC"])
    #expect(try idents("6") == ["68TX"])
    // Three identifiers start with T; the rest follow through the state TX or the word TED.
    let t = try idents("T")
    #expect(Array(t.prefix(3)) == ["T82", "TS01", "TX05"])
    #expect(Set(t.dropFirst(3)) == ["AUS", "EDC", "68TX", "ANC"])
}

@Test func searchMatchesNameAndCity() throws {
    #expect(try idents("Bergstrom") == ["AUS"])
    #expect(try idents("berg") == ["AUS"])
    #expect(try idents("austin exec") == ["EDC"])
    #expect(try idents("austin-bergstrom") == ["AUS"])
    #expect(try idents("fredericksburg") == ["T82"])
    #expect(try idents("ted stevens") == ["ANC"])
    // Public airports come ahead of the private strip and the heliport.
    let austin = try idents("Austin")
    #expect(Set(austin.prefix(2)) == ["AUS", "EDC"])
    #expect(Array(austin.dropFirst(2)) == ["TX05", "68TX"])
}

@Test func searchAcceptsAStateAfterTheCity() throws {
    let austinTx = try idents("austin tx")
    #expect(Set(austinTx.prefix(2)) == ["AUS", "EDC"])
    #expect(try idents("anchorage ak") == ["ANC"])
}

@Test func searchRanksIdentifierPrefixAheadOfIcaoPrefix() throws {
    let db = try NavDatabase(path: makeNavDatabase(extraSQL: """
        INSERT INTO airports(id, site_no, ident, icao, name, city, state, type, use, lat, lon, twr, status)
        VALUES (99, '99999.', 'PAZ', NULL, 'SAMPLE FIELD', 'SAMPLE', 'WA', 'A', 'PU', 47.5, -122.5, 'NON-ATCT', 'O')
        """))
    #expect(try db.search("PA").map(\.ident) == ["PAZ", "ANC"])
}

@Test func blankNumericCellsReadAsMissing() throws {
    let db = try NavDatabase(path: makeNavDatabase(extraSQL: """
        UPDATE airports SET elev = '' WHERE ident = 'T82';
        UPDATE runway_ends SET true_hdg = '', elev = '', tora = '', lda = '', displaced_len = '', lat = '', lon = ''
          WHERE airport_id = (SELECT id FROM airports WHERE ident = 'T82')
        """))
    let airport = try #require(try db.airport(identifier: "T82"))
    #expect(airport.elevationFt == nil)
    let ends = try #require(try db.detail(airportID: airport.id)).runways.flatMap(\.ends)
    #expect(!ends.isEmpty)
    for end in ends {
        #expect(end.trueHeading == nil)
        #expect(end.elevationFt == nil)
        #expect(end.toraFt == nil)
        #expect(end.ldaFt == nil)
        #expect(end.displacedThresholdFt == nil)
        #expect(end.coordinate == nil)
    }
}

@Test func blankAirportPositionFailsToOpen() throws {
    #expect(try openError(after: "UPDATE airports SET lat = '' WHERE ident = 'T82'") == .badMetadata(key: "airports"))
    #expect(try openError(after: "UPDATE airports SET lon = '' WHERE ident = 'T82'") == .badMetadata(key: "airports"))
}

@Test func fileWithEmptyDetailTablesFailsToOpen() throws {
    #expect(try openError(after: "DELETE FROM runways") == .badMetadata(key: "runways"))
    #expect(try openError(after: "DELETE FROM runway_ends") == .badMetadata(key: "runway_ends"))
    #expect(try openError(after: "DELETE FROM frequencies") == .badMetadata(key: "frequencies"))
}

@Test func searchNeverAddsOrStripsALeadingK() throws {
    #expect(try idents("KT82") == [])
    #expect(try idents("KTX05") == [])
    #expect(try idents("KANC") == [])
}

@Test func searchSurvivesPunctuationAndEmptyInput() throws {
    #expect(try idents("") == [])
    #expect(try idents("   ") == [])
    #expect(try idents("\"*") == [])
    #expect(try idents("%") == [])
    #expect(try idents("_") == [])
    #expect(try idents("O'Hare AND (") == [])
}

@Test func searchHonoursTheLimit() throws {
    #expect(try navFixture.search("austin", limit: 2).count == 2)
    #expect(try navFixture.search("austin", limit: 0) == [])
}

@Test func searchFindsAClosedStripAndMarksIt() throws {
    let closed = try #require(try navFixture.search("TS01").first)
    #expect(closed.ident == "TS01")
    #expect(closed.status == "CI")
    #expect(!closed.isOperational)
    #expect(try idents("landry") == ["TS01"])
}

@Test func surfaceFeaturesReadBackInFeetAndAnOlderFileHasNone() throws {
    // (-300, 2) then (1, -2): little-endian 16-bit pairs. A kind this code does not know is skipped.
    let db = try NavDatabase(path: makeNavDatabase(extraSQL: """
        INSERT INTO surface(airport_id, kind, name, points)
          SELECT id, 'taxiway', 'A', X'D4FE02000100FEFF' FROM airports WHERE ident = 'T82';
        INSERT INTO surface(airport_id, kind, name, points)
          SELECT id, 'gate', NULL, X'00000000' FROM airports WHERE ident = 'T82';
        """))
    let airport = try #require(try db.airport(identifier: "T82"))
    let surface = try #require(try db.detail(airportID: airport.id)).surface
    #expect(surface == [SurfaceFeature(kind: .taxiway, name: "A", points: [[-300, 2], [1, -2]])])
    let old = try NavDatabase(path: makeNavDatabase(extraSQL: "DROP TABLE surface"))
    #expect(try #require(try old.detail(airportID: airport.id)).surface.isEmpty)
}
