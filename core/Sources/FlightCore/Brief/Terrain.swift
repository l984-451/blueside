/// One Terrarium elevation tile: z/x/y in the usual web map scheme.
public struct TerrainTile: Hashable, Sendable {
    public var z: Int
    public var x: Int
    public var y: Int

    public init(z: Int, x: Int, y: Int) { (self.z, self.x, self.y) = (z, x, y) }
}

/// Tile PNG bytes for a tile, or nil when the app does not have it. The core does no networking; the app fills this.
public typealias TerrainTiles = (TerrainTile) -> [UInt8]?

/// A Terrarium PNG: 8-bit RGB or RGBA, not interlaced. Elevation in meters is R * 256 + G + B / 256 - 32768.
struct TerrariumImage {
    let size: Int
    private let pixels: [UInt8]
    private let stride: Int

    init?(png bytes: [UInt8]) {
        guard bytes.count > 33, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return nil }
        func int(_ at: Int) -> Int { bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) } }
        var at = 8, header: (w: Int, h: Int, channels: Int)?
        var data: [UInt8] = []
        while at + 12 <= bytes.count {
            let length = int(at), kind = String(decoding: bytes[(at + 4)..<(at + 8)], as: UTF8.self)
            guard length >= 0, at + 12 + length <= bytes.count else { return nil }
            let body = bytes[(at + 8)..<(at + 8 + length)]
            if kind == "IHDR" {
                guard length == 13, body[body.startIndex + 8] == 8, body[body.startIndex + 12] == 0 else { return nil }
                let color = body[body.startIndex + 9]
                guard color == 2 || color == 6 else { return nil }
                header = (int(at + 8), int(at + 12), color == 2 ? 3 : 4)
            } else if kind == "IDAT" {
                data += body
            } else if kind == "IEND" {
                break
            }
            at += 12 + length
        }
        // A zlib wrapper is two header bytes and a checksum around the deflate stream.
        guard let header, header.w == header.h, header.w > 0, header.w <= 1024, data.count > 6,
              let inflated = Inflate.raw(Array(data[2...])) else { return nil }
        let row = header.w * header.channels
        guard inflated.count >= (row + 1) * header.h else { return nil }
        var out = [UInt8](repeating: 0, count: row * header.h)
        let bpp = header.channels
        for y in 0..<header.h {
            let filter = inflated[y * (row + 1)], line = y * (row + 1) + 1
            for i in 0..<row {
                let raw = Int(inflated[line + i])
                let left = i >= bpp ? Int(out[y * row + i - bpp]) : 0
                let up = y > 0 ? Int(out[(y - 1) * row + i]) : 0
                let corner = i >= bpp && y > 0 ? Int(out[(y - 1) * row + i - bpp]) : 0
                let predicted: Int
                switch filter {
                case 0: predicted = 0
                case 1: predicted = left
                case 2: predicted = up
                case 3: predicted = (left + up) / 2
                case 4:
                    let p = left + up - corner
                    let a = abs(p - left), b = abs(p - up), c = abs(p - corner)
                    predicted = a <= b && a <= c ? left : b <= c ? up : corner
                default: return nil
                }
                out[y * row + i] = UInt8(truncatingIfNeeded: raw + predicted)
            }
        }
        (size, pixels, stride) = (header.w, out, bpp)
    }

    /// Meters at a pixel, clamped to the image.
    func meters(x: Int, y: Int) -> Double {
        let at = (min(max(y, 0), size - 1) * size + min(max(x, 0), size - 1)) * stride
        return Double(pixels[at]) * 256 + Double(pixels[at + 1]) + Double(pixels[at + 2]) / 256 - 32768
    }
}

/// Ground height from Terrarium tiles, one decoded tile at a time.
final class TerrainSampler {
    static let feetPerMeter = 3.28084
    private static let equatorMetersPerPixelZ0 = 156_543.03
    private let tiles: TerrainTiles
    let zoom: Int
    private var held: [TerrainTile: TerrariumImage?] = [:]

    /// The zoom for 150 to 300 m cells at a latitude.
    static func zoom(atLatitude lat: Double) -> Int {
        let metersAtZ0 = equatorMetersPerPixelZ0 * max(cos(lat * .pi / 180), 0.05)
        return min(14, max(0, Int(log2(metersAtZ0 / 300).rounded(.up))))
    }

    /// Cell size in nautical miles.
    static func cellNM(zoom: Int, latitude lat: Double) -> Double {
        equatorMetersPerPixelZ0 * cos(lat * .pi / 180) / Double(1 << zoom) / 1852
    }

    init(zoom: Int, tiles: @escaping TerrainTiles) { (self.zoom, self.tiles) = (zoom, tiles) }

    /// The tile and pixel under a point. A longitude counted past 180 degrees is wrapped back onto the map.
    static func locate(_ c: Coordinate, zoom: Int) -> (tile: TerrainTile, px: Int, py: Int) {
        let n = Double(1 << zoom)
        let lat = max(-85.0511, min(85.0511, c.latitude))
        let fx = RouteMath.normalized(c.longitude + 180) / 360 * n
        let fy = (1 - log(tan(lat * .pi / 180) + 1 / cos(lat * .pi / 180)) / .pi) / 2 * n
        let tx = min(max(Int(fx.rounded(.down)), 0), Int(n) - 1), ty = min(max(Int(fy.rounded(.down)), 0), Int(n) - 1)
        return (TerrainTile(z: zoom, x: tx, y: ty), Int((fx - Double(tx)) * 256), Int((fy - Double(ty)) * 256))
    }

    /// Feet MSL under a point; nil when its tile is missing or unreadable.
    func feet(at c: Coordinate) -> Double? {
        let spot = Self.locate(c, zoom: zoom)
        if held[spot.tile] == nil { held[spot.tile] = .some(tiles(spot.tile).flatMap { TerrariumImage(png: $0) }) }
        guard let image = held[spot.tile] ?? nil else { return nil }
        return image.meters(x: spot.px, y: spot.py) * Self.feetPerMeter
    }
}

extension Corridor {
    /// Points across the band to `reachNM` either side of the route, every `step` nm along and across, with their
    /// distance from departure.
    func band(reachNM: Double, step: Double) -> [(alongNM: Double, coordinate: Coordinate)] {
        let length = lengthNM
        guard path.count > 1, length > 0 else { return [] }
        var out: [(Double, Coordinate)] = []
        let across = Int((reachNM / step).rounded(.up))
        var k = 0
        var s = 0.0
        while s <= length {
            while k + 2 < path.count, along[k + 1] <= s { k += 1 }
            let a = path[k], b = path[k + 1]
            let dx = b.x - a.x, dy = b.y - a.y, d = (dx * dx + dy * dy).squareRoot()
            if d > 0 {
                let t = max(0, min(1, (s - along[k]) / (along[k + 1] - along[k])))
                let (px, py) = (a.x + t * dx, a.y + t * dy), (nx, ny) = (-dy / d, dx / d)
                for j in -across...across {
                    let off = max(-reachNM, min(reachNM, Double(j) * step))
                    out.append((s, unproject((px + nx * off, py + ny * off))))
                }
            }
            s += step
        }
        return out
    }

    /// The inverse of `project` near the route.
    func unproject(_ p: Point) -> Coordinate {
        let lat = origin.latitude + p.y / 60
        return Coordinate(latitude: lat, longitude: origin.longitude + p.x / (60 * max(cos(lat * .pi / 180), 0.01)))
    }
}

extension FlightBrief {
    /// The tiles the route profile reads, so the app can fetch them before it makes the brief.
    public static func terrainTiles(route: Route) -> [TerrainTile] {
        let c = Corridor(route)
        let zoom = TerrainSampler.zoom(atLatitude: c.origin.latitude)
        var seen: Set<TerrainTile> = []
        for p in c.band(reachNM: BriefProfile.groundReachNM, step: 1) { seen.insert(TerrainSampler.locate(p.coordinate, zoom: zoom).tile) }
        return seen.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    }
}
