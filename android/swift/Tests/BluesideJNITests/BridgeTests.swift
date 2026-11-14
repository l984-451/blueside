import Foundation
import Testing
@testable import BluesideJNI
import FlightCore

private let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let repo = here.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// Writes the golden JSON the Kotlin tests decode. Sorted keys keep the files stable.
private func golden(_ name: String, args: Data? = nil, result: Data) throws {
    let folder = here.appendingPathComponent("Fixtures")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let args { try args.write(to: folder.appendingPathComponent("\(name).args.json")) }
    try result.write(to: folder.appendingPathComponent("\(name).result.json"))
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func distanceAustinToDallas() throws {
    let args = try Bridge.encoder.encode(Bridge.Distance(
        from: Coordinate(latitude: 30.1945, longitude: -97.6699),
        to: Coordinate(latitude: 32.8968, longitude: -97.0380)))
    let result = Bridge.call("distanceNM", args)
    let nm = try #require(try object(result)["nm"] as? Double)
    #expect(abs(nm - 165.436) < 0.01)
    try golden("distanceNM", args: args, result: result)
}

@Test func countsCyclesInThePipelineFixture() throws {
    let manifest = try Data(contentsOf: repo.appendingPathComponent("pipeline/tests/fixtures/manifest.json"))
    let result = Bridge.call("manifestCheck", manifest)
    #expect(try object(result)["cycles"] as? Int == 2)
    try golden("manifestCheck", result: result)
}

@Test func errorsComeBackAsJSON() throws {
    let result = Bridge.call("manifestCheck", Data(#"{"version": 2, "cycles": []}"#.utf8))
    #expect(try object(result)["error"] as? String == "unsupportedVersion(2)")
    try golden("error", result: result)
    #expect(try object(Bridge.call("manifestCheck", Data("not json".utf8)))["error"] != nil)
    #expect(try object(Bridge.call("manifestCheck", Data()))["error"] != nil)
    #expect(try object(Bridge.call("noSuchOp", Data()))["error"] as? String == "unknownOp(\"noSuchOp\")")
}

private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

private func tempStore() throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private let assets = repo.appendingPathComponent("ios/MapAssets").path
// 2026-10-14T12:00:00Z
private let now = 1_791_979_200_000

@Test func emptyMapSaysWhatIsMissing() throws {
    let fields: (String) throws -> Data = { templates in
        try json(["base": "vfr", "night": false, "now": now, "stores": [] as [String], "templates": templates, "assets": "asset:/"])
    }
    let result = Bridge.call("mapStyle", try fields(assets))
    let shown = try object(result)
    #expect(shown["notice"] as? String == "No VFR chart downloaded")
    #expect((shown["style"] as? String)?.contains("#7f7f7f") == true)
    // The golden copy names the folder relative to the repo, so it holds no machine path.
    try golden("mapStyle", args: try fields("ios/MapAssets"), result: result)
}

@Test func terrainDrawsDimmedAtNightWithItsCredit() throws {
    let store = try tempStore()
    let session = try Bridge.open("packs", store)
    _ = Bridge.callHandle(session, "seed", try json([
        "name": "current", "now": now, "files": [["layer": "terrain", "path": assets + "/test-vfr.pmtiles"]]]))
    let fields = try object(Bridge.call("mapStyle", try json([
        "base": "terrain", "night": true, "now": now, "stores": [store], "templates": assets, "assets": "asset:/"])))
    #expect(fields["notice"] == nil)
    #expect(fields["credit"] as? String == MapStyleSpec.terrainCredit + " · © OpenStreetMap")
    // No chart coverage hints for terrain.
    #expect((fields["rasters"] as? [Any])?.isEmpty == true)
    let style = try #require(fields["style"] as? String)
    #expect(style.contains("pmtiles://file://" + store))
    #expect(style.contains("\"raster-brightness-max\":0.4") && style.contains("\"raster-hue-rotate\":0"))
}

@Test func seededChartsDrawWithNightPaintAndTheNavOverlay() throws {
    let store = try tempStore()
    let nav = try tempStore()
    let session = try Bridge.open("packs", store)
    _ = Bridge.callHandle(session, "seed", try json([
        "name": "current", "now": now,
        "files": [["layer": "vfr", "path": assets + "/test-vfr.pmtiles"]]]))
    // A nav store with a database and tiles of one cycle.
    let navSession = try Bridge.open("packs", nav)
    _ = Bridge.callHandle(navSession, "configure", try json(["nav": true]))
    _ = Bridge.callHandle(navSession, "seed", try json([
        "name": "current", "now": now,
        "files": [["layer": "nav-db", "path": assets + "/nav-test.sqlite"],
                  ["layer": "nav-tiles", "path": assets + "/nav-tiles.pmtiles"]]]))
    let fields = try object(Bridge.call("mapStyle", try json([
        "base": "vfr", "night": true, "now": now, "stores": [store], "navStore": nav,
        "templates": assets, "assets": "asset:/"])))
    #expect(fields["notice"] == nil)
    #expect(fields["overlay"] as? Bool == true)
    #expect((fields["navDatabase"] as? String)?.hasSuffix("nav-db/US.pmtiles") == true)
    let style = try #require(fields["style"] as? String)
    #expect(style.contains("pmtiles://file://" + store))
    #expect(style.contains("raster-hue-rotate"))
    #expect(style.contains("asset://fonts"))
    // Night inks replace the day ones.
    #expect(!style.contains("#1557b0") && style.contains("#7fb0f2"))
    let rasters = try #require(fields["rasters"] as? [[String: Any]])
    #expect(rasters.map { $0["identifier"] as? String } == ["vfr:TX"])

    let coverage = try Bridge.open("coverage", "")
    let gap = try object(Bridge.callHandle(coverage, "gap", try json([
        "rasters": rasters, "latitude": 0.0, "longitude": 0.0, "zoom": 8.0])))
    #expect(gap["text"] as? String == "No chart coverage here")

    let notices = try object(Bridge.call("notices", try json([
        "base": "vfr", "stores": [store], "now": now, "overlayWanted": true,
        "nav": ["unreadable": false, "hasTiles": true, "cycle": "2026-10-01",
                "effective": 1_790_845_260_000, "expires": 1_790_845_260_000 + 56 * 86_400_000]])))
    #expect(notices["banner"] == nil && notices["nav"] == nil)
}

@Test func expiredSeedShowsTheBanner() throws {
    let store = try tempStore()
    let session = try Bridge.open("packs", store)
    _ = Bridge.callHandle(session, "seed", try json([
        "name": "expired", "now": now, "files": [["layer": "vfr", "path": assets + "/test-vfr.pmtiles"]]]))
    let args = try json(["base": "vfr", "stores": [store], "now": now, "overlayWanted": true])
    let result = Bridge.call("notices", args)
    #expect(try object(result)["banner"] as? String == "Charts expired 13 Oct 2026 UTC")
    #expect(try object(result)["nav"] as? String == "Navigation data not downloaded")
    try golden("notices", result: result)
}

@Test func theStreetKeyChangesOnlyWithThePacksInView() throws {
    let store = try tempStore()
    _ = Bridge.callHandle(try Bridge.open("packs", store), "seed", try json([
        "name": "current", "now": now, "files": [["layer": "street", "path": assets + "/test-vfr.pmtiles"]]]))
    func key(_ store: String, latitude: Double) throws -> String? {
        try object(Bridge.call("streetKey", try json(["stores": [store], "now": now, "view": [
            "minLatitude": latitude, "minLongitude": -98.0, "maxLatitude": latitude + 1, "maxLongitude": -97.0]])))["key"] as? String
    }
    // One pack covers every view, near it or not, so moving the map keeps the key.
    let key30 = try key(store, latitude: 30)
    #expect(key30?.hasSuffix(".pmtiles") == true)
    #expect(try key(store, latitude: 45) == key30)
    #expect(try key(try tempStore(), latitude: 30) == "")
}

@Test func aFixDrivesTheStripSymbolAndCamera() throws {
    let args = try json(["fix": ["latitude": 30.2, "longitude": -97.7, "course": 90.0, "speed": 51.4, "altitude": 1000.0,
                                 "time": now],
                         "now": now, "following": true, "orientation": "trackUp", "heading": 0.0, "zoom": 4.0,
                         "zoomedToFirstFix": false])
    let result = Bridge.call("position", args)
    let fields = try object(result)
    let strip = try #require(fields["strip"] as? [String: Any])
    #expect(strip["groundspeed"] as? String == "100 kt")
    #expect(strip["altitude"] as? String == "3281 ft")
    let camera = try #require(fields["camera"] as? [String: Any])
    #expect(camera["zoom"] as? Double == 10 && camera["heading"] as? Double == 90)
    #expect((fields["ownship"] as? [String: Any])?["image"] as? String == "ownship-live")
    try golden("position", args: args, result: result)

    // A height above the ellipsoid in place of MSL goes through the geoid.
    let ellipsoid = try object(Bridge.call("position", try json([
        "fix": ["latitude": 30.2, "longitude": -97.7, "course": 90.0, "speed": 51.4, "ellipsoidAltitude": 1000.0, "time": now],
        "now": now, "following": false, "orientation": "northUp", "heading": 0.0, "zoom": 10.0, "zoomedToFirstFix": true])))
    let geoid = try #require(Geoid.height(latitude: 30.2, longitude: -97.7))
    #expect((ellipsoid["strip"] as? [String: Any])?["altitude"] as? String == "\(Int(((1000 - geoid) * 3.28084).rounded())) ft")

    // A fix wider than 500 m reads as approximate; one at 500 m does not.
    func image(_ accuracy: Double) throws -> String? {
        let fields = try object(Bridge.call("position", try json([
            "fix": ["latitude": 30.2, "longitude": -97.7, "course": 90.0, "speed": 51.4, "time": now, "accuracy": accuracy],
            "now": now, "following": false, "orientation": "northUp", "heading": 0.0, "zoom": 10.0, "zoomedToFirstFix": true])))
        return (fields["ownship"] as? [String: Any])?["image"] as? String
    }
    #expect(try image(500.1) == "ownship-live-ring" && image(500) == "ownship-live")

    let none = try object(Bridge.call("position", try json(["now": now, "following": true, "orientation": "northUp",
                                                            "heading": 0.0, "zoom": 4.0, "zoomedToFirstFix": false,
                                                            "accessOff": true])))
    #expect((none["strip"] as? [String: Any])?["track"] as? String == "---")
    #expect((none["strip"] as? [String: Any])?["message"] as? String == "Location access is off")
}

@Test func datesGoOutAsWholeMilliseconds() throws {
    // Kotlin reads dates as Long, so a fraction would drop the whole reply.
    let time = 1_763_049_601_120
    let result = Bridge.call("position", try json([
        "fix": ["latitude": 30.2, "longitude": -97.7, "course": 90.0, "speed": 51.4, "time": time],
        "now": time, "following": false, "orientation": "northUp", "heading": 0.0, "zoom": 10.0, "zoomedToFirstFix": true]))
    #expect(String(decoding: result, as: UTF8.self).contains("\"staleAt\":\(time + 5_001),"))
}

@Test func revealMovesOnlyAPlaceUnderThePanel() throws {
    func args(_ x: Double) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["place": ["latitude": 30.2, "longitude": -97.7], "x": x, "y": 400,
            "open": ["x": 400, "y": 0, "width": 600, "height": 800], "width": 1000, "height": 800,
            "zoom": 10, "bearing": 0] as [String: Any])
    }
    #expect(try object(Bridge.call("reveal", try args(700))).isEmpty)
    let moved = try #require(try object(Bridge.call("reveal", try args(100)))["camera"] as? [String: Any])
    #expect(moved["zoom"] as? Double == 10 && (moved["center"] as? [String: Double])?["longitude"] ?? 0 < -97.7)
}

@Test func trackingLaunchAndCatalog() throws {
    let next = try object(Bridge.call("tracking", try json(["following": true, "orientation": "northUp"])))
    #expect(next["orientation"] as? String == "trackUp" && next["label"] as? String == "Following, track up")
    let launch = try object(Bridge.call("launch", try json(["base": "ifr-low", "center": ["latitude": 30.0, "longitude": -97.0],
                                                            "follow": false])))
    #expect(launch["base"] as? String == "ifr-low" && launch["following"] as? Bool == false)
    // The setup saved as the map stood comes back at launch, under any launch option.
    let memoryArgs = try JSONSerialization.data(withJSONObject: ["base": "ifr-high", "night": true, "orientation": "trackUp", "following": false,
                               "camera": ["latitude": 30.2, "longitude": -97.7, "zoom": 9.0], "route": "KAUS CWK"] as [String: Any], options: .sortedKeys)
    let memory = Bridge.call("mapMemory", memoryArgs)
    let saved = try #require(try object(memory)["text"] as? String)
    try golden("mapMemory", args: memoryArgs, result: memory)
    let launchArgs = try JSONSerialization.data(withJSONObject: ["saved": saved, "night": false, "follow": false] as [String: Any],
                                                options: .sortedKeys)
    let back = Bridge.call("launch", launchArgs)
    let restored = try object(back)
    #expect(restored["base"] as? String == "ifr-high" && restored["night"] as? Bool == false)
    #expect(restored["orientation"] as? String == "trackUp" && restored["following"] as? Bool == false)
    #expect((restored["camera"] as? [String: Any])?["zoom"] as? Double == 9 && restored["route"] as? String == "KAUS CWK")
    try golden("launch", args: launchArgs, result: back)
    let catalog = Bridge.call("layerCatalog", Data())
    #expect((try object(catalog)["bases"] as? [Any])?.count == 7)
    try golden("layerCatalog", result: catalog)
}

@Test func sessionFetchesRetriesOnceAndInstalls() throws {
    let store = try tempStore()
    let session = try Bridge.open("packs", store)
    _ = Bridge.callHandle(session, "configure", try json(["skipLayers": ["street"]]))
    let body = try String(contentsOf: repo.appendingPathComponent("pipeline/tests/fixtures/manifest.json"), encoding: .utf8)
    _ = Bridge.callHandle(session, "listFetched", try json(["status": 200, "body": body]))
    _ = Bridge.callHandle(session, "choose", try json(["region": "TX"]))
    // 2026-10-01: the first cycle is current and the second is next.
    let day = 1_790_845_260_000
    let pass = Bridge.callHandle(session, "pass", try json(["active": [] as [Any], "freeBytes": 10_000_000_000, "now": day]))
    let starts = try #require(try object(pass)["start"] as? [[String: Any]])
    // Only the current cycle starts; the next one waits for it.
    #expect(starts.count == 3)
    #expect(starts.allSatisfy { ($0["id"] as? [String: Any])?["cycle"] as? String == "2026-09-03" })
    try golden("pass", result: pass)

    let pending = starts[0]
    let file = store + "/incoming.part"
    try Data("pack".utf8).write(to: URL(fileURLWithPath: file))
    let bad = try object(Bridge.callHandle(session, "event", try json([
        "kind": "downloaded", "pending": pending, "file": file, "sha256": "00", "now": day])))
    #expect((bad["retry"] as? [String: Any])?["attempt"] as? Int == 2)
    try Data("pack".utf8).write(to: URL(fileURLWithPath: file))
    _ = Bridge.callHandle(session, "event", try json([
        "kind": "downloaded", "pending": pending, "file": file, "sha256": pending["sha256"]!, "now": day]))
    // With TX vfr in place, the next cycle's TX vfr may start beside the running current packs.
    let next = try #require(try object(Bridge.callHandle(session, "pass", try json([
        "active": Array(starts.dropFirst()), "freeBytes": 10_000_000_000, "now": day])))["start"] as? [[String: Any]])
    #expect(next.compactMap { ($0["id"] as? [String: Any]).map { "\($0["cycle"]!) \($0["layer"]!) \($0["region"]!)" } }
            == ["2026-10-29 vfr TX"])
    let rows = Bridge.callHandle(session, "rows", try json(["now": day]))
    let row = try #require((try object(rows)["rows"] as? [[String: Any]])?.first)
    #expect(row["region"] as? String == "TX" && row["state"] as? String == "downloading")
    #expect(row["text"] as? String == "Downloading 59%")
    try golden("rows", result: rows)

    let removed = try object(Bridge.callHandle(session, "remove", try json(["region": "TX"])))
    #expect(removed["cancel"] as? [String] == ["TX"])
    #expect(PackSession.installedFiles(root: store).isEmpty)
}

@Test func navMetadataThroughAHandle() throws {
    let nav = try Bridge.open("nav", repo.appendingPathComponent("ios/MapAssets/nav-test.sqlite").path)
    let result = Bridge.callHandle(nav, "metadata", Data())
    let fields = try object(result)
    #expect(fields["cycle"] as? String == "2026-10-01")
    // 2026-10-01T09:01:00Z
    #expect(fields["effective"] as? Int == 1_790_845_260_000)
    try golden("metadata", result: result)
    #expect(throws: (any Error).self) { try Bridge.open("nav", "/nonexistent.sqlite") }
    #expect(throws: (any Error).self) { try Bridge.open("chart", "/tmp") }
}

private let navTest = repo.appendingPathComponent("ios/MapAssets/nav-test.sqlite").path
// 2027-01-15T08:00:00Z. The searches run a second later, so the fix is live.
private let fixAt = 1_800_000_000_000

@Test func searchFavoritesNearestAndPages() throws {
    let nav = try Bridge.open("nav", navTest)
    let fix: [String: Any] = ["latitude": 30.20, "longitude": -97.66, "course": -1.0, "speed": -1.0, "time": fixAt]
    let empty = try json(["text": " ", "favorites": ["T82"], "fix": fix, "now": fixAt + 1000])
    let page = Bridge.callHandle(nav, "search", empty)
    let sections = try #require(try object(page)["sections"] as? [[String: Any]])
    #expect(sections.map { $0["title"] as? String } == ["Favorites", "Nearest airports from 30°12.00′N 097°39.60′W at 08:00:00Z"])
    let nearest = try #require(sections[1]["items"] as? [[String: Any]])
    #expect(nearest.compactMap { ($0["row"] as? [String: Any])?["ident"] as? String } == ["AUS", "EDC", "T82", "ANC"])
    try golden("search", args: empty, result: page)

    let typed = try object(Bridge.callHandle(nav, "search", try json(["text": "KAUS", "favorites": [] as [String], "now": fixAt])))
    let found = try #require((typed["sections"] as? [[String: Any]])?.first?["items"] as? [[String: Any]])
    #expect((found.first?["row"] as? [String: Any])?["title"] as? String == "KAUS")

    let pageArgs = try json(["ident": "AUS", "fix": fix, "now": fixAt + 1000])
    let airport = Bridge.callHandle(nav, "airportPage", pageArgs)
    let fields = try object(airport)
    let shown = try #require(fields["page"] as? [String: Any])
    #expect(shown["title"] as? String == "KAUS")
    #expect((shown["runways"] as? [String: Any])?["title"] as? String == "Runways")
    #expect((fields["header"] as? [String: Any])?["addTitle"] as? String == "Add to Route")
    try golden("airportPage", args: pageArgs, result: airport)
    #expect(try object(Bridge.callHandle(nav, "airportPage", try json(["ident": "NOPE", "now": fixAt])))["error"] != nil)

    let pinArgs = try json(["pin": ["latitude": 30.21, "longitude": -97.68]])
    let pin = try #require(try object(Bridge.callHandle(nav, "pick", pinArgs))["place"] as? [String: Any])
    #expect(pin["kind"] as? String == "user")
    let cardArgs = try json(["place": pin, "now": fixAt])
    let card = Bridge.callHandle(nav, "placeCard", cardArgs)
    let cardFields = try object(card)
    #expect((cardFields["card"] as? [String: Any])?["subtitle"] as? String == "Dropped Pin")
    #expect((cardFields["nearby"] as? [[String: Any]])?.count == 3)
    try golden("placeCard", args: cardArgs, result: card)

    let near = Bridge.callHandle(nav, "waypointsNear", try json(["latitude": 30.21, "longitude": -97.68]))
    let places = try #require(try JSONSerialization.jsonObject(with: near) as? [[String: Any]])
    let hits = places.enumerated().map { ["place": $1, "distance": Double($0) * 10] }
    let pickArgs = try json(["hits": hits])
    let pick = Bridge.callHandle(nav, "pick", pickArgs)
    #expect(try object(pick)["open"] as? String == "here")
    try golden("pick", args: pickArgs, result: pick)
    let one = try object(Bridge.callHandle(nav, "pick", try json(["hits": [hits[0]]])))
    #expect(one["open"] as? String == "airport" && one["ident"] as? String == "AUS")
    try golden("labels", result: Bridge.call("navLabels", Data()))
    let prefix = try JSONSerialization.jsonObject(with: Bridge.callHandle(nav, "waypointSearch", try json(["prefix": "AU"])))
    #expect((prefix as? [Any])?.isEmpty == false)
}

@Test func directToTypedRouteBendAndRuler() throws {
    let nav = try Bridge.open("nav", navTest)
    let fix: [String: Any] = ["latitude": 30.40, "longitude": -97.75, "course": 90.0, "speed": 50.0, "time": fixAt]
    let aus: [String: Any] = ["kind": "airport", "ident": "AUS", "icao": "KAUS", "name": "AUSTIN-BERGSTROM INTL",
                              "latitude": 30.19452722, "longitude": -97.66987611]
    let directArgs = try json(["edit": ["op": "direct", "place": aus], "fix": fix, "now": fixAt + 1000,
                               "speed": 120.0, "burn": 9.0])
    let direct = Bridge.callHandle(nav, "route", directArgs)
    let shown = try object(direct)
    #expect(shown["title"] as? String == "Direct To")
    let line = try #require(shown["line"] as? [String: Any])
    #expect(line["firstDot"] as? Int == 1 && (line["points"] as? [Any])?.count == 2)
    #expect(((shown["rows"] as? [[String: Any]])?.first?["row"] as? [String: Any])?["isActive"] as? Bool == true)
    try golden("routeDirect", args: directArgs, result: direct)

    // The plan key goes back with the next fix: a few meters keep the start, a kilometer moves it.
    let key = try #require(shown["planKey"] as? NSDictionary)
    // Every field of the core's key crosses but its route, which is the plan beside it, so one added later reaches Android too.
    let fields = Mirror(reflecting: RoutePages.planKey(nil, position: nil, now: Date())).children.compactMap(\.label)
    #expect(Set(key.allKeys.compactMap { $0 as? String }) == Set(fields).subtracting(["route"]))
    func keyAt(_ latitude: Double) throws -> NSDictionary? {
        let moved = fix.merging(["latitude": latitude, "time": fixAt + 2000] as [String: Any]) { $1 }
        return try object(Bridge.callHandle(nav, "route", try json(["plan": try #require(shown["plan"]), "fix": moved,
                                                                   "now": fixAt + 3000, "planKey": key])))["planKey"] as? NSDictionary
    }
    #expect(try keyAt(30.40002) == key)
    #expect(try #require(try keyAt(30.41)) != key)

    // Closing on the first waypoint of a route from the aircraft sequences no leg, so the route is not flown yet.
    let cwk: [String: Any] = ["kind": "navaid", "ident": "CWK", "name": "CENTEX", "latitude": 30.37855, "longitude": -97.52984722]
    let added = try object(Bridge.callHandle(nav, "route", try json([
        "plan": try #require(shown["plan"]), "edit": ["op": "add", "place": cwk], "fix": fix, "now": fixAt + 1000])))
    #expect((added["plan"] as? [String: Any])?["closing"] as? Bool == true)
    #expect(added["flown"] as? Bool == false)

    // Typing over a Direct To makes the typed route, with the nav log totals.
    let plan = try #require(shown["plan"])
    let typedArgs = try json(["plan": plan, "edit": ["op": "typed", "text": "KAUS CWK"], "fix": fix, "now": fixAt + 1000,
                              "speed": 120.0, "burn": 9.0])
    let typed = Bridge.callHandle(nav, "route", typedArgs)
    let typedFields = try object(typed)
    #expect(typedFields["title"] as? String == "Route" && typedFields["text"] as? String == "KAUS CWK")
    let editor = try #require(typedFields["editor"] as? [String: Any])
    #expect((editor["points"] as? [[String: Any]])?.map { $0["title"] as? String } == ["KAUS", "CWK"])
    #expect((editor["totals"] as? [[String: Any]])?.map { $0["title"] as? String } == ["Distance", "Time", "Fuel"])
    try golden("routeTyped", args: typedArgs, result: typed)

    // A problem keeps the route and says why.
    let bad = try object(Bridge.callHandle(nav, "route", try json([
        "plan": try #require(typedFields["plan"]), "edit": ["op": "typed", "text": "KAUS QQQQQ"], "now": fixAt])))
    #expect(bad["text"] as? String == "KAUS CWK")
    #expect(((bad["typed"] as? [String: Any])?["problems"] as? [String])?.count == 1)

    // A band let go on open map adds a point and offers places near it.
    let bend = try object(Bridge.callHandle(nav, "route", try json([
        "plan": try #require(typedFields["plan"]),
        "edit": ["op": "bend", "grab": ["kind": "leg", "index": 0], "drawnCount": 2, "hits": [] as [Any],
                 "at": ["latitude": 30.21, "longitude": -97.68], "metersPerPoint": 100.0] as [String: Any],
        "now": fixAt])))
    #expect((bend["editor"] as? [String: Any]).flatMap { ($0["points"] as? [Any])?.count } == 3)
    #expect((bend["offer"] as? [String: Any])?["target"] as? Int == 0)

    let grabArgs = try json(["points": [["x": 0.0, "y": 0.0], ["x": 100.0, "y": 0.0]], "firstDot": 1,
                             "finger": ["x": 50.0, "y": 10.0]])
    let grab = Bridge.call("grab", grabArgs)
    #expect(try object(grab)["anchors"] as? [Int] == [0, 1])
    try golden("grab", args: grabArgs, result: grab)

    let rulerArgs = try json(["from": ["latitude": 30.19, "longitude": -97.67], "to": ["latitude": 32.9, "longitude": -97.04],
                              "now": fixAt])
    let ruler = Bridge.call("ruler", rulerArgs)
    #expect((try object(ruler)["text"] as? String)?.hasPrefix("165") == true)
    try golden("ruler", args: rulerArgs, result: ruler)
    try golden("routeLabels", result: Bridge.call("routeLabels", Data()))
    let take = try object(Bridge.call("routeTake", try json(["text": "KAUS CW", "place": ["kind": "navaid", "ident": "CWK",
        "name": "CENTEX", "latitude": 30.38, "longitude": -97.53]])))
    #expect(take["text"] as? String == "KAUS CWK ")

    // The plan for the typed route, calm with no winds file.
    let planArgs = try json(["plan": try #require(typedFields["plan"]), "now": fixAt, "speed": 120.0, "burn": 9.0,
                             "taxi": 1.0, "onBoard": 40.0,
                             "inputs": ["cruiseAltitudeFt": 5500, "departure": 1_792_195_200_000.0, "rules": "vfr"]])
    let view = try #require(Bridge.planView(try Bridge.decoder.decode(Bridge.FlightPlanArgs.self, from: planArgs),
                                            winds: nil, tafs: []))
    #expect(view.legs.first?.note == "No winds aloft: calm assumed")
    #expect(view.altitudes.count == 4 && view.sun.count == 2)
    // With no speed every altitude line would be dashes, so none is sent.
    var slow = try object(planArgs)
    slow["speed"] = nil
    #expect(try #require(Bridge.planView(try Bridge.decoder.decode(Bridge.FlightPlanArgs.self,
                                                                   from: JSONSerialization.data(withJSONObject: slow)),
                                         winds: nil, tafs: [])).altitudes.isEmpty)
    #expect(!view.log.isEmpty && view.log.allSatisfy { $0.count == RoutePages.logColumns.count })
    // The log leaves out columns with no value in any row, then fits what is left to the room across.
    #expect(view.logShown.first == 0 && view.logShown.count < RoutePages.logColumns.count)
    func fitted(_ room: Double) throws -> [Int]? {
        let widths = RoutePages.logColumns.map { _ in 50.0 }
        return try object(Bridge.call("logFitted", try json(["shown": view.logShown, "widths": widths, "room": room])))["columns"] as? [Int]
    }
    #expect(try fitted(Double(view.logShown.count) * 50) == view.logShown)
    let fewer = try #require(try fitted(Double(view.logShown.count - 1) * 50))
    #expect(fewer.count == view.logShown.count - 1 && fewer.contains(RoutePages.logTime))
    // No room for the waypoint, its distance and its time: no table.
    #expect(try fitted(100) == nil)
    #expect(view.logTotals.first == "Total")
    // Without climb and descent numbers the page says why; with them it carries top of climb and descent rows.
    #expect(view.notes == [FlightPlan.verticalMissingNote] && view.logBefore.count == view.log.count && view.logBefore.allSatisfy(\.isEmpty))
    // The page wakes as the kept departure two hours on rolls past.
    var later = try object(planArgs)
    later["stored"] = String(decoding: RoutePages.storing(FlightPlanInputs(cruiseAltitudeFt: 5500,
        departure: Date(timeIntervalSince1970: 1_800_007_200))), as: UTF8.self)
    let waking = try #require(Bridge.planView(try Bridge.decoder.decode(Bridge.FlightPlanArgs.self,
                                                                        from: JSONSerialization.data(withJSONObject: later)),
                                              winds: nil, tafs: []))
    #expect(abs(waking.next.timeIntervalSince1970 - 1_800_007_200) < 1)
    var climbing = AircraftTemplates.pa28181
    (climbing.climbRateFPM, climbing.climbTASKt, climbing.climbBurnGPH) = (700, 90, 12)
    (climbing.descentRateFPM, climbing.descentTASKt, climbing.descentBurnGPH) = (500, 110, 6)
    var climbArgs = try object(planArgs)
    climbArgs["aircraft"] = try JSONSerialization.jsonObject(with: Bridge.encoder.encode(climbing))
    let climbView = try #require(Bridge.planView(try Bridge.decoder.decode(Bridge.FlightPlanArgs.self,
                                                                          from: JSONSerialization.data(withJSONObject: climbArgs)),
                                                 winds: nil, tafs: []))
    let inserted = climbView.logBefore.joined().map { $0[0] }
    #expect(!inserted.isEmpty && inserted.allSatisfy { $0.hasPrefix("-TO") } && !climbView.notes.contains(FlightPlan.verticalMissingNote))
    #expect(climbView.logBefore.joined().allSatisfy { $0.count == RoutePages.logColumns.count })

    // The panel's inputs: an alternate typed by ident, the rest defaults.
    let inputArgs = try json(["now": fixAt, "altitude": 6500, "alternate": "kaus"])
    let inputs = Bridge.callHandle(nav, "planInputs", inputArgs)
    let inputFields = try object(inputs)
    #expect(inputFields["alternate"] as? String == "KAUS")
    #expect((inputFields["inputs"] as? [String: Any])?["cruiseAltitudeFt"] as? Int == 6500)
    try golden("planInputs", args: inputArgs, result: inputs)

    // The flight's aircraft by id; text that is no id leaves it.
    let craftID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    let withCraft = try object(Bridge.callHandle(nav, "planInputs", try json(["now": fixAt, "aircraft": craftID])))
    #expect((withCraft["inputs"] as? [String: Any])?["aircraftID"] as? String == craftID)
    let kept = try object(Bridge.callHandle(nav, "planInputs",
                                            try json(["now": fixAt, "aircraft": "x", "stored": withCraft["stored"] as Any])))
    #expect((kept["inputs"] as? [String: Any])?["aircraftID"] as? String == craftID)

    // Save the typed route, then load it back; a fixed id keeps the golden files put.
    let typedPlan = try #require(typedFields["plan"])
    let stored = try #require(inputFields["stored"] as? String)
    let first = try object(Bridge.call("savedRoutes", try json(["plan": typedPlan, "stored": stored, "now": fixAt,
                                                                  "save": " "])))
    let made = try #require((first["saved"] as? [[String: Any]])?.first)
    #expect(made["name"] as? String == "KAUS to CWK" && (made["detail"] as? String)?.hasSuffix("local · 6,500 ft · VFR · Alternate KAUS") == true)
    let id = "00000000-0000-0000-0000-000000000001"
    let file = try #require(first["file"] as? String).replacingOccurrences(of: try #require(made["id"] as? String), with: id)
    // Central time in January, with the change to daylight time on 14 Mar 2027.
    let savedArgs = try json(["file": file, "plan": typedPlan, "stored": stored, "now": fixAt, "rename": id,
                              "name": "Hill Country",
                              "localOffset": ["seconds": -21_600, "nextChange": 1_805_011_200_000, "secondsAfter": -18_000]])
    let saved = Bridge.call("savedRoutes", savedArgs)
    let savedFields = try object(saved)
    #expect((savedFields["saved"] as? [[String: Any]])?.first?["name"] as? String == "Hill Country")
    #expect(((savedFields["saved"] as? [[String: Any]])?.first?["detail"] as? String)?.hasPrefix("15 Jan 0200 local") == true)
    #expect(savedFields["defaultName"] as? String == "KAUS to CWK" && savedFields["file"] is String)
    try golden("savedRoutes", args: savedArgs, result: saved)
    let unreadable = try object(Bridge.call("savedRoutes", try json(["file": "{}", "now": fixAt, "remove": id])))
    #expect(unreadable["problem"] as? String == RoutePages.savedUnreadable && unreadable["file"] == nil)

    let loadArgs = try json(["file": file, "id": id, "now": fixAt])
    let loaded = Bridge.callHandle(nav, "loadRoute", loadArgs)
    let loadedFields = try object(loaded)
    #expect(loadedFields["text"] as? String == "KAUS CWK" && loadedFields["plan"] != nil)
    #expect((loadedFields["inputs"] as? [String: Any])?["alternate"] as? String == "KAUS")
    #expect((loadedFields["file"] as? String)?.contains("\"recent\":[{") == true)
    try golden("loadRoute", args: loadArgs, result: loaded)

    // A flight saved with its aircraft and load gives both back while that aircraft is still here.
    let craft = AircraftProfile(tail: "N2")
    let craftFile = String(decoding: try AircraftProfile.encodeList([craft]), as: UTF8.self)
    let flying = try object(Bridge.callHandle(nav, "planInputs", try json(["now": fixAt, "aircraft": craft.id.uuidString])))
    let flight = try object(Bridge.call("savedRoutes", try json([
        "plan": typedPlan, "stored": try #require(flying["stored"] as? String), "now": fixAt, "save": "Trip",
        "load": ["weights": [170, NSNull()], "startFuel": 40]])))
    let flightID = try #require((flight["saved"] as? [[String: Any]])?.first?["id"] as? String)
    let back = try object(Bridge.callHandle(nav, "loadRoute", try json([
        "file": try #require(flight["file"] as? String), "id": flightID, "now": fixAt, "aircraft": craftFile])))
    #expect((back["load"] as? [String: Any])?["startFuel"] as? Double == 40)
    #expect(((back["inputs"] as? [String: Any])?["inputs"] as? [String: Any])?["aircraftID"] as? String == craft.id.uuidString)

    // Flown on the fallback aircraft (none picked): the save names the aircraft so its load comes back.
    let fallback = try object(Bridge.call("savedRoutes", try json([
        "plan": typedPlan, "stored": stored, "now": fixAt, "save": "Fallback", "aircraft": craft.id.uuidString,
        "load": ["weights": [], "startFuel": 30]])))
    let fallbackID = try #require((fallback["saved"] as? [[String: Any]])?.first { $0["name"] as? String == "Fallback" }?["id"] as? String)
    let fallbackBack = try object(Bridge.callHandle(nav, "loadRoute", try json([
        "file": try #require(fallback["file"] as? String), "id": fallbackID, "now": fixAt, "aircraft": craftFile])))
    #expect((fallbackBack["load"] as? [String: Any])?["startFuel"] as? Double == 30)
}

@Test func platesGroupAndExtract() throws {
    let store = try tempStore()
    let session = try Bridge.open("packs", store)
    _ = Bridge.callHandle(session, "seed", try json([
        "name": "current", "now": now, "files": [["layer": "plates", "path": assets + "/plates-test.sqlite"]]]))
    let shown = try object(Bridge.call("plates", try json(["store": store, "ident": "AUS", "now": now])))
    let diagram = try #require(shown["diagram"] as? [String: Any])
    #expect(diagram["file"] as? String == "00556AD.PDF")
    let groups = try #require(shown["groups"] as? [[String: Any]])
    #expect(groups.map { $0["title"] as? String } == ["Approaches", "Departures", "Arrivals", "Other"])
    #expect(shown["count"] as? Int == 6)
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("plate-\(UUID().uuidString).pdf")
    #expect(try object(Bridge.call("plateExtract", try json(["plate": diagram, "out": out.path])))["ok"] as? Bool == true)
    #expect(try Data(contentsOf: out).prefix(4) == Data("%PDF".utf8))
    let none = try object(Bridge.call("plates", try json(["store": store, "ident": "NOPE", "now": now])))
    #expect(none["diagram"] == nil && (none["groups"] as? [Any])?.isEmpty == true)

    // Plates out of date get the chart banner under their own name; current ones wake when the pack expires.
    let old = try tempStore()
    _ = Bridge.callHandle(try Bridge.open("packs", old), "seed", try json([
        "name": "expired", "now": now, "files": [["layer": "plates", "path": assets + "/plates-test.sqlite"]]]))
    func notices(_ plates: String) throws -> [String: Any] {
        try object(Bridge.call("notices", try json(["base": "vfr", "stores": [] as [String], "now": now,
                                                    "overlayWanted": false, "plates": plates])))
    }
    #expect(try notices(old)["plates"] as? String == "Plates expired 13 Oct 2026 UTC")
    let current = try notices(store)
    #expect(current["plates"] == nil && current["next"] as? Int == now + 55 * 86_400_000)
}

@Test func ifrAlternateAdviceReadsThePlatesOnTheDevice() throws {
    // The seeded pack stands in for Texas, where it has approaches for AUS and none for EDC.
    let store = try tempStore()
    _ = Bridge.callHandle(try Bridge.open("packs", store), "seed", try json([
        "name": "current", "now": fixAt, "files": [["layer": "plates", "path": assets + "/plates-test.sqlite"]]]))
    let aus = RouteWaypoint(kind: .airport, ident: "KAUS", name: "AUSTIN-BERGSTROM INTL",
                            coordinate: Coordinate(latitude: 30.1945, longitude: -97.6699))
    let edc = RouteWaypoint(kind: .airport, ident: "KEDC", name: "AUSTIN EXECUTIVE",
                            coordinate: Coordinate(latitude: 30.3978, longitude: -97.5664))
    func advice(_ from: RouteWaypoint, _ to: RouteWaypoint, rules: String = "ifr", plates: String? = store,
                nav: String = navTest) throws -> String? {
        var args: [String: Any] = ["plan": try JSONSerialization.jsonObject(with: Bridge.encoder.encode(
                                       RoutePlan(route: try #require(Route(waypoints: [from, to], navCycle: "2027-01-01"))))),
                                   "now": fixAt, "speed": 120.0, "burn": 9.0, "navDatabase": nav,
                                   "inputs": ["cruiseAltitudeFt": 5000, "departure": Double(fixAt), "rules": rules]]
        args["plates"] = plates
        let a = try Bridge.decoder.decode(Bridge.FlightPlanArgs.self, from: JSONSerialization.data(withJSONObject: args))
        return Bridge.planView(a, winds: nil, tafs: [])?.alternate?.text
    }
    let required = "Alternate required: no instrument approach at KEDC (14 CFR 91.169(b))."
    let unknown = "No TAF: check the alternate rule yourself."
    #expect(try advice(aus, edc) == required)
    #expect(try advice(edc, aus) == unknown)
    #expect(try advice(aus, edc, plates: nil) == unknown)
    #expect(try advice(aus, edc, plates: try tempStore()) == unknown)
    #expect(try advice(aus, edc, rules: "vfr") == nil)
    // Asked again with nothing changed, the answer is kept: the nav database is not opened again.
    let nav = try tempStore() + "/nav.sqlite"
    try FileManager.default.copyItem(atPath: navTest, toPath: nav)
    #expect(try advice(aus, edc, nav: nav) == required)
    try FileManager.default.removeItem(atPath: nav)
    #expect(try advice(aus, edc, nav: nav) == required)
}

@Test func ownshipFindsItsSpotOnAGeoreferencedPlate() throws {
    let geo: [String: Any] = ["corners": [[-87.227021, 33.810793], [-86.560188, 33.811087], [-86.559867, 33.30017], [-87.2267, 33.299876]],
                              "plan": [0.047, 0.1808, 0.953, 0.7212], "sketch": [0.6631, 0.6039, 0.953, 0.7212],
                              "insets": [[0.7134, 0.1808, 0.953, 0.3038]]]
    let args = try json(["geo": geo, "latitude": 33.6, "longitude": -86.9])
    let result = Bridge.call("platePoint", args)
    let point = try #require(try object(result)["point"] as? [Double])
    #expect(point.count == 2 && (0.047...0.953).contains(point[0]) && (0.1808...0.7212).contains(point[1]))
    try golden("platePoint", args: args, result: result)
    #expect(try object(Bridge.call("platePoint", try json(["geo": geo, "latitude": 35.0, "longitude": -86.9])))["point"] == nil)
    // Inside the alternate missed approach inset.
    #expect(try object(Bridge.call("platePoint", try json(["geo": geo, "latitude": 33.77, "longitude": -86.6])))["point"] == nil)
}

@Test func aircraftExportImportAndWeightBalance() throws {
    var p = AircraftTemplates.pa28181
    p.id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    p.tail = "N181PA"
    p.emptyWeightLb = 1600
    p.emptyArmIn = 86.0
    let exported = try object(Bridge.call("aircraftExport", Bridge.encoder.encode(p)))
    #expect(exported["name"] as? String == "N181PA.json")
    let text = try #require(exported["text"] as? String)
    let list = try object(Bridge.call("aircraftImport", try json(["text": text])))
    #expect((list["aircraft"] as? [Any])?.count == 1)
    let file = try #require(list["file"] as? String)
    #expect(try object(Bridge.call("aircraftImport", try json(["text": text, "file": file])))["conflict"] as? Bool == true)

    let args = try JSONSerialization.data(withJSONObject: [
        "profile": try JSONSerialization.jsonObject(with: Bridge.encoder.encode(p)),
        "weights": [340, 0, 20], "burned": 10,
    ] as [String: Any], options: .sortedKeys)
    let result = Bridge.call("weightBalance", args)
    let balance = try #require(try object(result)["balance"] as? [String: Any])
    #expect(balance["status"] as? String == "Within limits")
    #expect((balance["takeoff"] as? [String: Any])?["cgIn"] is Double)
    try golden("weightBalance", args: args, result: result)
    // With no fuel burned given and no trip known, the burn runs to all the fuel at start, else the usable fuel.
    func burned(_ fields: [String: Any]) throws -> Double? {
        var sent = fields
        sent["profile"] = try JSONSerialization.jsonObject(with: Bridge.encoder.encode(p))
        return try object(Bridge.call("weightBalance", try json(sent)))["burned"] as? Double
    }
    #expect(try burned(["weights": [340, 0, 20], "startFuel": 30]) == 30)
    #expect(try burned(["weights": [340, 0, 20]]) == p.usableFuelGal)
    // Airborne with none typed there is no burn, so no landing point, no verdict and no note under the field.
    let flying = try object(Bridge.call("weightBalance", try json([
        "profile": try JSONSerialization.jsonObject(with: Bridge.encoder.encode(p)), "weights": [340, 0, 20],
        "startFuel": 30, "airborne": true])))
    let flown = try #require(flying["balance"] as? [String: Any])
    #expect(flying["burned"] == nil && flying["burnedNote"] == nil && flown["landing"] == nil && flown["status"] == nil)
    #expect(try object(result)["burnedNote"] as? String == AircraftPages.burnedNote)
    let labels = Bridge.call("aircraftLabels", Data())
    #expect((try object(labels)["sections"] as? [Any])?.count == AircraftPages.sections.count)
    try golden("aircraftLabels", result: labels)

    var blank = p
    blank.emptyArmIn = nil
    blank.fuelArmIn = nil
    let missing = try object(Bridge.call("weightBalance", try json(["profile": try JSONSerialization.jsonObject(
        with: Bridge.encoder.encode(blank)), "weights": [Double](), "burned": 0])))
    #expect(missing["missingNote"] as? String == "Fill in the empty arm and fuel arm to work out weight and balance.")
}

// 2026-10-13T00:40:00Z, five minutes after the weather fixture's checks.
private let wxNow = 1_791_852_000_000

/// A reply as Kotlin hands it: the body copied to a file the session reads and deletes.
private func reply(_ name: String, status: Int = 200) throws -> [String: Any] {
    let file = try tempStore() + "/body"
    try FileManager.default.copyItem(atPath: repo.appendingPathComponent("pipeline/tests/fixtures/wx/out/" + name).path, toPath: file)
    return ["status": status, "file": file]
}

@Test func weatherPassFetchesDecodesAndDraws() throws {
    let folder = try tempStore()
    let session = try Bridge.open("weather", folder)
    let plan = try object(Bridge.callHandle(session, "index", try json(["reply": try reply("index.json"), "now": wxNow])))
    let jobs = try #require(plan["jobs"] as? [[String: Any]])
    #expect(jobs.compactMap { $0["path"] as? String }.contains("wx/metars.json.gz"))
    // The fixture's only radar picture is 13 min old, so it is fetched.
    #expect((plan["frames"] as? [[String: Any]])?.first?["path"] as? String == "wx/radar/20261013-002636.pmtiles")
    for name in ["metars.json.gz", "tafs.json.gz", "tfrs.geojson.gz"] {
        let source = String(name.prefix { $0 != "." })
        _ = Bridge.callHandle(session, "source", try json(["source": source, "reply": try reply(name)]))
    }
    // A picture that is not a pack is refused.
    let kept = try object(Bridge.callHandle(session, "frame", try json(["path": "wx/radar/x.pmtiles", "reply": try reply("index.json")])))
    #expect(kept["kept"] as? Bool == false)

    let on = ["weather-stations", "weather-radar", "weather-tfrs"]
    let notices = try object(Bridge.callHandle(session, "notices", try json(["now": wxNow, "on": on])))
    let labels = try #require(notices["labels"] as? [[String: Any]])
    #expect(labels.map { $0["id"] as? String } == ["radar"])
    #expect(notices["clock"] == nil)
    try golden("weatherNotices", result: Bridge.callHandle(session, "notices", try json(["now": wxNow, "on": on])))

    let layers = try object(Bridge.callHandle(session, "layers", try json(["now": wxNow, "on": on, "show": "wind"])))
    let sources = try #require(layers["sources"] as? [String: String])
    #expect(Set(sources.keys) == ["wx-stations", "wx-tfrs"])
    #expect(sources["wx-stations"]?.contains("\"station\":\"KTVF\"") == true)
    #expect((layers["visible"] as? [String: Bool])?["wx-stations-wind"] == true)
    #expect(layers["radar"] == nil)

    let station = try object(Bridge.callHandle(session, "station", try json(["ident": "TVF", "icao": "KTVF"])))
    let metarJSON = try #require(station["metar"] as? [String: Any])
    #expect((metarJSON["raw"] as? String)?.contains("KTVF 130023Z") == true)
    #expect((station["lines"] as? [String])?.first?.hasPrefix("TAF") == true)
    // The METAR goes back in as the nav airportPage op's argument, with its date and fields unchanged.
    let weather = try #require(session as? WeatherSession)
    let held = try #require(weather.data.metars.filter { $0.station == "KTVF" }.max { $0.observed < $1.observed })
    #expect(try Bridge.decoder.decode(Metar.self, from: JSONSerialization.data(withJSONObject: metarJSON)) == held)

    // The brief from the held weather, KTVF to KGFK.
    let tvfToGfk = Route(waypoints: [
        RouteWaypoint(kind: .airport, ident: "KTVF", name: "THIEF RIVER FALLS", coordinate: Coordinate(latitude: 48.0656, longitude: -96.185)),
        RouteWaypoint(kind: .airport, ident: "KGFK", name: "GRAND FORKS INTL", coordinate: Coordinate(latitude: 47.9493, longitude: -97.1761)),
    ], navCycle: "2026-10-01")!
    let briefArgs = try json(["plan": try JSONSerialization.jsonObject(with: Bridge.encoder.encode(RoutePlan(route: tvfToGfk))),
                              "now": wxNow, "speed": 120.0, "burn": 9.0, "localOffset": -18000,
                              "inputs": ["cruiseAltitudeFt": 4500, "departure": wxNow, "rules": "vfr"]])
    let brief = Bridge.callHandle(session, "flightBrief", briefArgs)
    let briefFields = try object(brief)
    let sections = try #require(briefFields["sections"] as? [[String: Any]])
    #expect(sections.map { $0["title"] as? String }.first == "Flight" && sections.count == 9)
    let current = try #require(sections.first { $0["title"] as? String == "Current conditions" }?["lines"] as? [[String: Any]])
    #expect((current.first?["detail"] as? String)?.contains("KTVF 130023Z") == true)
    #expect((briefFields["notice"] as? String)?.hasPrefix("Not an official briefing") == true)
    let graphics = try #require(briefFields["graphics"] as? [String: Any])
    let pictures = try #require((graphics["map"] as? [String: Any])?["pictures"] as? [[String: Any]])
    #expect(pictures.first?["id"] as? String == "route" && (pictures.first?["style"] as? String)?.contains("brief-route") == true)
    #expect((graphics["airports"] as? [[String: Any]])?.map { $0["title"] as? String } == ["Departure KTVF", "Destination KGFK"])
    #expect((graphics["profile"] as? [String: Any])?["cruiseFt"] as? Int == 4500)
    try golden("flightBrief", args: briefArgs, result: brief)

    // The nav log from the same plan: 13 columns and Actual, then the blocks; weights only with an aircraft and its loading.
    let navlog = try object(Bridge.callHandle(session, "navlog", briefArgs))
    #expect((navlog["columns"] as? [String])?.count == 14 && (navlog["columns"] as? [String])?.last == "Actual")
    #expect((navlog["rows"] as? [[String]])?.map { $0[0] } == ["KTVF", "KGFK"])
    #expect(navlog["weights"] == nil && (navlog["boxes"] as? [String]) == ["Out", "Off", "On", "In", "Hobbs"])
    #expect((navlog["fileName"] as? String)?.hasPrefix("Navlog KTVF-KGFK ") == true)
    try golden("navlog", args: briefArgs, result: Bridge.callHandle(session, "navlog", briefArgs))
    var loaded = try object(briefArgs)
    var filled = AircraftTemplates.c172s
    (filled.tail, filled.emptyWeightLb, filled.emptyArmIn) = ("N12345", 1663, 39.3)
    (filled.stations[0].armIn, filled.stations[2].armIn, filled.stations[3].armIn) = (37, 95, 123)
    loaded["aircraft"] = try JSONSerialization.jsonObject(with: Bridge.encoder.encode(filled))
    loaded["weights"] = [340.0, 0, 50, 0]
    let weighed = try object(Bridge.callHandle(session, "navlog", try JSONSerialization.data(withJSONObject: loaded)))
    #expect((weighed["weights"] as? [String: Any])?["title"] as? String == "Weights")

    // The panel's plan takes speed, burn, taxi and full usable fuel from the aircraft.
    var craft = AircraftTemplates.pa28181
    craft.cruiseTASKt = 120
    craft.burnGPH = 9
    var planOnly = try object(briefArgs)
    planOnly["speed"] = nil
    planOnly["burn"] = nil
    planOnly["aircraft"] = try JSONSerialization.jsonObject(with: Bridge.encoder.encode(craft))
    let planView = try object(Bridge.callHandle(session, "planView", try JSONSerialization.data(withJSONObject: planOnly)))
    func titles(_ key: String) -> [String] { (planView[key] as? [[String: Any]])?.compactMap { $0["title"] as? String } ?? [] }
    #expect(titles("summary") == ["Distance", "Departure", "Time en route", "ETA", "Fuel required", "Margin"])
    #expect(titles("fuelLines") == ["Taxi", "Trip", "Reserve", "On board"])
    #expect((planView["legs"] as? [[String: Any]])?.count == 1)
    #expect(planView["burned"] as? Double != nil)
    try golden("planView", result: Bridge.callHandle(session, "planView", briefArgs))

    // A second session reads the same folder back, so a restart shows the last copy.
    let again = try Bridge.open("weather", folder)
    let reread = try object(Bridge.callHandle(again, "notices", try json(["now": wxNow + 31 * 60_000, "on": ["weather-stations"]])))
    #expect((reread["labels"] as? [[String: Any]])?.first?["text"] as? String == "METARs not updated since 0035Z")
    #expect(reread["clock"] as? String == "Weather 0035Z")
}

@Test func unreachedServerKeepsWordsForEverySource() throws {
    let session = try Bridge.open("weather", try tempStore())
    _ = Bridge.callHandle(session, "index", try json(["reply": ["failed": "offline"], "now": wxNow]))
    let notices = try object(Bridge.callHandle(session, "notices", try json(["now": wxNow, "on": ["weather-pireps"]])))
    #expect((notices["labels"] as? [[String: Any]])?.first?["text"] as? String == "PIREPs not available")
}

@Test func satelliteIsPlannedAndLightningDrawsWithItsLegend() throws {
    let session = try Bridge.open("weather", try tempStore())
    let plan = try object(Bridge.callHandle(session, "index", try json(["reply": try reply("index.json"), "now": wxNow])))
    let frames = try #require(plan["frames"] as? [[String: Any]])
    #expect(frames.map { $0["source"] as? String } == ["radar", "satellite"])
    _ = Bridge.callHandle(session, "source", try json(["source": "lightning", "reply": try reply("lightning.json.gz")]))
    let on = ["weather-satellite", "weather-lightning"]
    let layers = try object(Bridge.callHandle(session, "layers", try json(["now": wxNow, "on": on])))
    #expect((layers["sources"] as? [String: String])?["wx-lightning"]?.contains("\"age_min\"") == true)
    #expect(layers["satellite"] == nil)
    let notices = try object(Bridge.callHandle(session, "notices", try json(["now": wxNow, "on": on])))
    #expect((notices["labels"] as? [[String: Any]])?.map { $0["id"] as? String } == ["satellite"])
    #expect(notices["legend"] as? String == SatelliteStyle.legend + "\n" + LightningStyle.legend)
    #expect(notices["radar"] as? Bool == false)
}

@Test func unreadableTfrIsListedWithItsNoteAndNoLevels() throws {
    let session = try Bridge.open("weather", try tempStore())
    _ = Bridge.callHandle(session, "index", try json(["reply": try reply("index.json"), "now": wxNow]))
    let plain = try tempStore() + "/tfrs.json"
    let body = #"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":null,"properties":{"notam":"6/1234","title":"DALLAS, TX","issued":"2026-10-12T10:55:00Z","unreadable":true}}]}"#
    try Data(body.utf8).write(to: URL(fileURLWithPath: plain))
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    zip.arguments = ["-k", plain]
    try zip.run()
    zip.waitUntilExit()
    _ = Bridge.callHandle(session, "source", try json(["source": "tfrs", "reply": ["status": 200, "file": plain + ".gz"]]))
    let layers = try object(Bridge.callHandle(session, "layers", try json(["now": wxNow, "on": ["weather-tfrs"]])))
    let listed = try #require((layers["tfrsWithoutArea"] as? [[String: Any]])?.first)
    #expect(listed["levels"] == nil && listed["note"] as? String == FlightCore.Tfr.unreadableNote)
}

@Test func weatherCatalogAndStyle() throws {
    let result = Bridge.call("weatherCatalog", Data())
    let catalog = try object(result)
    let toggles = try #require(catalog["toggles"] as? [[String: Any]])
    #expect(toggles.map { $0["title"] as? String } == ["Radar", "Satellite", "Stations", "AIR/SIGMET/CWA", "PIREPs", "Lightning", "Winds Aloft"])
    #expect((catalog["barbs"] as? [[String: Any]])?.count == WindBarb.buckets.count)
    #expect((toggles.first?["layers"] as? [String])?.contains("wx-radar-frame") == true)
    #expect((catalog["saved"] as? [String])?.contains("nav-obstacles") == true)
    try golden("weatherCatalog", result: result)

    for night in [false, true] {
        let fields = try object(Bridge.call("mapStyle", try json([
            "base": "vfr", "night": night, "now": now, "stores": [] as [String], "templates": assets, "assets": "asset:/"])))
        let style = try #require(fields["style"] as? String)
        #expect(style.contains("\"wx-stations-dot\"") && style.contains("\"wx-radar-outside\""))
        #expect(style.contains("asset://fonts"))
        // Night swaps white halos for the map ground, as iOS paints them.
        #expect(style.contains("#1e1d1b") == night)
    }
}

@Test func trafficSessionTakesDatagramsAndBatches() throws {
    let session = try Bridge.open("traffic", "")
    // A heartbeat with GPS and the spec's example traffic report, framed as a receiver sends them.
    let heartbeat = GDL90.frame([0x00, 0x81, 0x01, 0, 0, 0, 0])
    let traffic = GDL90.frame([0x14, 0x00, 0xAB, 0x45, 0x49, 0x1F, 0xEF, 0x15, 0xA8, 0x89, 0x78, 0x0F, 0x09, 0xA9,
                               0x07, 0xB0, 0x01, 0x20, 0x01, 0x4E, 0x38, 0x32, 0x35, 0x56, 0x20, 0x20, 0x20, 0x00])
    #expect(try object(Bridge.callHandle(session, "receive", Data(heartbeat + traffic))).isEmpty)
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let batch = try object(Bridge.callHandle(session, "batch", try json(["now": now])))
    #expect(batch["count"] as? Int == 1)
    #expect((batch["shapes"] as? String)?.contains("N825V") == true)
    let status = try #require(batch["status"] as? [String: Any])
    #expect(status["connected"] as? Bool == true && status["gpsValid"] as? Bool == true)
    #expect(abs(try #require(status["lastMessageAt"] as? Int) - now) < 60_000)
    #expect(batch["next"] as? Double != nil)
}

@Test func theAppKeepsRunningAfterFlyingOrWhileAReceiverTalks() throws {
    let now = 1_800_000_000_000
    func rule(_ args: [String: Any]) throws -> [String: Any] { try object(Bridge.call("background", try json(args))) }
    let fast: [String: Any] = ["latitude": 33.5, "longitude": -86.8, "course": 90.0, "speed": 51.4, "time": now]
    let flying = try rule(["fix": fast, "now": now + 1000])
    #expect(flying["until"] as? Int == now + 300_000 && flying["lastFast"] as? Int == now)
    // On the ground it runs on from the last fix at flying speed, which the caller sends back; without one it sleeps.
    let slow = fast.merging(["speed": 2.0, "time": now + 60_000]) { $1 }
    #expect(try rule(["fix": slow, "lastFast": now, "now": now + 61_000])["until"] as? Int == now + 300_000)
    #expect(try rule(["fix": slow, "now": now + 61_000])["until"] == nil)
    #expect(try rule(["heard": now, "now": now + 1000])["until"] as? Int == now + 60_000)
    // In flight by the core's rule: fast, live and exact.
    func airborne(_ args: [String: Any]) throws -> Bool? { try object(Bridge.call("airborne", try json(args)))["airborne"] as? Bool }
    #expect(try airborne(["fix": fast, "now": now + 1000]) == true)
    #expect(try airborne(["fix": slow, "now": now + 61_000]) == false)
    #expect(try airborne(["fix": fast, "now": now + 60_000]) == false)
    #expect(try airborne(["now": now]) == false)
}

@Test func trafficCatalogAndFixChoice() throws {
    let catalog = Bridge.call("trafficCatalog", Data())
    #expect((try object(catalog)["sources"] as? [Any])?.count == 3)
    try golden("trafficCatalog", result: catalog)
    // The device fix carries a height above the ellipsoid, as Android does with no MSL height; the receiver's is MSL.
    let fix: [String: Any] = ["latitude": 33.5, "longitude": -86.8, "course": 90.5, "speed": 50.5, "time": now]
    let args = try json(["source": "auto", "device": fix.merging(["ellipsoidAltitude": 1000.5]) { $1 },
                         "receiver": fix.merging(["latitude": 33.6, "altitude": 1000.5]) { $1 }, "now": now + 1000])
    let result = Bridge.call("chooseFix", args)
    #expect(try object(result)["use"] as? String == "receiver")
    try golden("chooseFix", args: args, result: result)
    #expect(try object(Bridge.call("chooseFix", try json(["source": "device", "now": now])))["use"] as? String == "none")
}
