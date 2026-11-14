import Foundation
import Testing
@testable import FlightCore

/// A Terrarium PNG written with stored deflate blocks. `filter` is applied to every row.
private func png(size: Int = 256, channels: Int = 3, filter: UInt8 = 0, meters: (Int, Int) -> Double) -> [UInt8] {
    func be(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: n >> (8 * (3 - $0))) } }
    func chunk(_ kind: String, _ body: [UInt8]) -> [UInt8] { be(body.count) + Array(kind.utf8) + body + [0, 0, 0, 0] }
    var pixels = [[UInt8]](repeating: [], count: size)
    for y in 0..<size {
        for x in 0..<size {
            let v = meters(x, y) + 32768
            let r = Int(v / 256), g = Int(v) % 256, b = Int((v - v.rounded(.down)) * 256)
            pixels[y] += [UInt8(r), UInt8(g), UInt8(b)] + (channels == 4 ? [255] : [])
        }
    }
    var raw: [UInt8] = []
    for y in 0..<size {
        raw.append(filter)
        for i in 0..<pixels[y].count {
            // Sub subtracts the left pixel, up subtracts the pixel above.
            let left = i >= channels ? Int(pixels[y][i - channels]) : 0, up = y > 0 ? Int(pixels[y - 1][i]) : 0
            raw.append(UInt8(truncatingIfNeeded: Int(pixels[y][i]) - (filter == 1 ? left : filter == 2 ? up : 0)))
        }
    }
    var deflate: [UInt8] = [0x78, 0x01]
    var at = 0
    repeat {
        let n = min(65535, raw.count - at), final: UInt8 = at + n == raw.count ? 1 : 0
        deflate += [final, UInt8(n & 255), UInt8(n >> 8), UInt8(~n & 255), UInt8((~n >> 8) & 255)] + raw[at..<(at + n)]
        at += n
    } while at < raw.count
    deflate += [0, 0, 0, 0]
    let header = be(size) + be(size) + [8, channels == 4 ? 6 : 2, 0, 0, 0]
    return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", header) + chunk("IDAT", deflate) + chunk("IEND", [])
}

private let kaus = RouteWaypoint(kind: .airport, ident: "KAUS", name: "KAUS",
                                 coordinate: Coordinate(latitude: 30.1945, longitude: -97.6699))
private let kdal = RouteWaypoint(kind: .airport, ident: "KDAL", name: "KDAL",
                                 coordinate: Coordinate(latitude: 32.8471, longitude: -96.8518))
private let route = Route(waypoints: [kaus, kdal], navCycle: "2026-10-01")!
private let departure = ISO8601DateFormatter().date(from: "2026-10-15T14:00:00Z")!

private func profile(_ flown: Route = route, terrain: TerrainTiles?, extraSQL: String = "") throws -> BriefProfile {
    let db = try NavDatabase(path: try makeNavDatabase(extraSQL: extraSQL))
    let inputs = FlightPlanInputs(cruiseAltitudeFt: 5500, departure: departure)
    let plan = FlightPlan.make(route: flown, inputs: inputs, trueAirspeedKt: 120, burnGPH: 9, winds: nil, tafs: [])
    return FlightBrief.make(route: flown, inputs: inputs, plan: plan, aircraft: nil, balance: nil, weather: WeatherData(),
                            now: departure - 1800, database: db, terrain: terrain).graphics.profile
}

@Suite struct TerrainTests {
    @Test func decodesElevationFromEveryFilterAndFormat() throws {
        let shape = { (x: Int, y: Int) -> Double in Double(x * 10 + y) - 300.25 }
        for (filter, channels) in [(UInt8(0), 3), (1, 3), (2, 3), (0, 4)] {
            let image = try #require(TerrariumImage(png: png(channels: channels, filter: filter, meters: shape)))
            #expect(image.size == 256)
            #expect(abs(image.meters(x: 17, y: 5) - shape(17, 5)) < 0.01)
            #expect(abs(image.meters(x: 255, y: 255) - shape(255, 255)) < 0.01)
        }
        #expect(TerrariumImage(png: [1, 2, 3]) == nil)
        #expect(TerrariumImage(png: Array(png { _, _ in 0 }.dropLast(40))) == nil)
    }

    @Test func zoomGivesCellsOf150To300MetersAndTilesLandWhereTheMathSaysTheyDo() {
        for lat in [0.0, 25, 30, 45, 60, 70] {
            let z = TerrainSampler.zoom(atLatitude: lat)
            let meters = TerrainSampler.cellNM(zoom: z, latitude: lat) * 1852
            #expect(meters > 150 && meters <= 300, "\(lat) \(meters)")
        }
        // Austin at zoom 9 is column 117, row 210 of the usual scheme.
        #expect(TerrainSampler.locate(kaus.coordinate, zoom: 9).tile == TerrainTile(z: 9, x: 117, y: 210))
    }

    @Test func theGroundLineTakesTheHighestTerrainInTheBandAndIgnoresWhatIsOutsideIt() throws {
        let c = Corridor(route)
        let ridge = c.coordinate(at: 82)
        let far = c.unproject((c.project(ridge).x + 15, c.project(ridge).y))
        let zoom = TerrainSampler.zoom(atLatitude: c.origin.latitude)
        let high = TerrainSampler.locate(ridge, zoom: zoom), outside = TerrainSampler.locate(far, zoom: zoom)
        func tile(_ id: TerrainTile) -> [UInt8] {
            png { x, y in
                func near(_ s: (tile: TerrainTile, px: Int, py: Int)) -> Bool {
                    s.tile == id && abs(x - s.px) <= 4 && abs(y - s.py) <= 4
                }
                return near(high) ? 1000 : near(outside) ? 3000 : 100
            }
        }
        let p = try profile(terrain: { tile($0) })
        let k = Int(82 / 5)
        #expect(p.ground.count == 33)
        #expect(p.ground[k].ft == Int((1000 * 3.28084).rounded()))
        #expect(p.ground.allSatisfy { $0.ft <= 3281 })
        // 100 m everywhere else, though the Austin airports stand higher than that.
        #expect(p.ground[20].ft == 328)
        #expect(p.topFt >= 6000)
    }

    @Test func aMissingTileFallsBackToAirportsAndNoProviderIsTheOldBehavior() throws {
        let without = try profile(terrain: nil)
        let nothing = try profile(terrain: { _ in nil })
        let garbage = try profile(terrain: { _ in [1, 2, 3] })
        #expect(nothing == without && garbage == without)
        #expect(without.ground.contains { $0.ft == 620 })
    }

    @Test func tilesNeededForARouteAreFewAndAtOneZoom() {
        let tiles = FlightBrief.terrainTiles(route: route)
        #expect(tiles.count >= 3 && tiles.count <= 12)
        #expect(Set(tiles.map(\.z)).count == 1)
        #expect(Set(tiles).count == tiles.count)
    }

    // Shemya to Adak crosses 180°: the Adak half reads its own tiles and towers, not the 180° meridian's.
    @Test func aRouteAcrossTheDateLineReadsTheGroundOnBothSides() throws {
        let shemya = RouteWaypoint(kind: .airport, ident: "PASY", name: "PASY", coordinate: Coordinate(latitude: 52.7183, longitude: 174.1136))
        let adak = RouteWaypoint(kind: .airport, ident: "PADK", name: "PADK", coordinate: Coordinate(latitude: 51.878, longitude: -176.646))
        let aleutians = try #require(Route(waypoints: [shemya, adak], navCycle: "2026-10-01"))
        let c = Corridor(aleutians)
        let zoom = TerrainSampler.zoom(atLatitude: c.origin.latitude)
        #expect(TerrainSampler.locate(Coordinate(latitude: 51.9, longitude: 183.3), zoom: zoom)
                == TerrainSampler.locate(Coordinate(latitude: 51.9, longitude: -176.7), zoom: zoom))
        let half = 1 << (zoom - 1)
        let tiles = FlightBrief.terrainTiles(route: aleutians)
        #expect(tiles.contains { $0.x < half } && tiles.contains { $0.x >= half })
        // A tower 15 nm short of Adak, kept at the longitude the database stores.
        var tower = c.coordinate(at: c.lengthNM - 15)
        #expect(tower.longitude > 180)
        tower.longitude -= 360
        let sql = "INSERT INTO obstacles(oas, type, lat, lon, agl, msl) VALUES ('02-1', 'TOWER', \(tower.latitude), \(tower.longitude), 300, 1200);"
        // 1000 m west of 180° (Adak's side), sea level east of it.
        let p = try profile(aleutians, terrain: { tile in png { _, _ in tile.x < half ? 1000 : 0 } }, extraSQL: sql)
        #expect(p.obstacles.map(\.ft) == [1200])
        #expect(p.ground.first?.ft == 0 && p.ground.last?.ft == Int((1000 * 3.28084).rounded()))
        // With no tiles the ground comes from airports, and Adak's is found east of 180°.
        let field = """
            INSERT INTO airports(id, site_no, ident, icao, name, city, state, type, use, lat, lon, elev, twr, status)
            VALUES (90001, '50001.', 'ADK', 'PADK', 'ADAK', 'ADAK ISLAND', 'AK', 'A', 'PU', 51.878, -176.646, 18, 'NON-ATCT', 'O');
            """
        let bare = try profile(aleutians, terrain: nil, extraSQL: field)
        #expect(bare.ground.map(\.ft) == [18])
    }

    @Test func obstaclesKeepTheTallestPerStretchWithinReach() throws {
        let c = Corridor(route)
        let on = c.coordinate(at: 82)
        let off = c.unproject((c.project(on).x + 15, c.project(on).y))
        let later = c.coordinate(at: 120)
        func row(_ n: Int, _ at: Coordinate, _ agl: Int, _ msl: String) -> String {
            "INSERT INTO obstacles(oas, type, lat, lon, agl, msl) VALUES ('48-\(n)', 'TOWER', \(at.latitude), \(at.longitude), \(agl), \(msl));"
        }
        let sql = [row(1, on, 300, "1500"), row(2, on, 450, "1800"), row(3, off, 900, "3500"), row(4, later, 250, "NULL"),
                   row(5, later, 250, "1300")].joined(separator: "\n")
        let p = try profile(terrain: nil, extraSQL: sql)
        #expect(p.obstacles.map(\.ft) == [1800, 1300])
        #expect(abs(p.obstacles[0].nm - 82) < 1 && abs(p.obstacles[1].nm - 120) < 1)
    }
}
