public enum WeatherShape: Equatable, Sendable {
    /// The outer ring, with the first point repeated at the end.
    case polygon([Coordinate])
    case line([Coordinate])
}

struct GeoGeometry: Decodable {
    var shape: WeatherShape

    enum Keys: String, CodingKey { case type, coordinates }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Keys.self)
        func points(_ pairs: [[Double]], atLeast count: Int) throws -> [Coordinate] {
            guard pairs.count >= count else {
                throw DecodingError.dataCorruptedError(forKey: .coordinates, in: box, debugDescription: "too few points")
            }
            return try pairs.map { pair in
                guard pair.count >= 2, (-180...180).contains(pair[0]), (-90...90).contains(pair[1]) else {
                    throw DecodingError.dataCorruptedError(forKey: .coordinates, in: box, debugDescription: "bad position")
                }
                return Coordinate(latitude: pair[1], longitude: pair[0])
            }
        }
        switch try box.decode(String.self, forKey: .type) {
        case "Polygon":
            let rings = try box.decode([[[Double]]].self, forKey: .coordinates)
            shape = .polygon(try points(rings.first ?? [], atLeast: 4))
        case "LineString":
            shape = .line(try points(try box.decode([[Double]].self, forKey: .coordinates), atLeast: 2))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: box, debugDescription: "unsupported geometry")
        }
    }
}

struct GeoFeature<Properties: Decodable>: Decodable {
    var properties: Properties
    var geometry: GeoGeometry?
}

struct GeoCollection<Properties: Decodable>: Decodable {
    var type: String
    var features: [GeoFeature<Properties>]
}

extension WeatherJSON {
    static func features<P: Decodable>(_ type: P.Type, from data: Data, what: String) throws -> [GeoFeature<P>] {
        let all = try decode(GeoCollection<P>.self, from: data, what: what)
        guard all.type == "FeatureCollection" else { throw WeatherError.unreadable(what) }
        return all.features
    }
}

public struct Sigmet: Equatable, Sendable, WeatherTimed {
    public var hazard: String
    public var severity: String?
    public var kind: String?
    public var validFrom: Date
    public var validTo: Date
    public var baseFtMSL: Int?
    public var topFtMSL: Int?
    public var raw: String
    public var shape: WeatherShape

    /// A SIGMET carries no separate issue time; its period start stands in for it.
    public var time: Date { validFrom }

    public func isValid(at now: Date) -> Bool { validFrom <= now && now < validTo }

    public static func decode(_ data: Data) throws -> [Sigmet] {
        struct Wire: Decodable {
            var hazard: String, severity: String?, kind: String?
            var from: Date, to: Date, base_ft: Int?, top_ft: Int?, raw: String
        }
        return try WeatherJSON.features(Wire.self, from: data, what: "sigmets").map { feature in
            // A SIGMET that cannot be drawn fails the file, so it is never dropped quietly.
            guard let shape = feature.geometry?.shape else { throw WeatherError.unreadable("sigmets") }
            let wire = feature.properties
            return Sigmet(hazard: wire.hazard, severity: wire.severity, kind: wire.kind,
                          validFrom: wire.from, validTo: wire.to, baseFtMSL: wire.base_ft, topFtMSL: wire.top_ft,
                          raw: wire.raw, shape: shape)
        }
    }
}

public struct GAirmet: Equatable, Sendable, WeatherTimed {
    /// Snapshots are three hours apart; each one stands until the next.
    public static let snapshotSpacing: TimeInterval = 3 * 3600

    public var product: String?
    public var tag: String?
    public var hazard: String
    public var severity: String?
    public var issued: Date
    public var valid: Date
    public var expires: Date
    public var dueTo: String?
    public var base: String?
    public var top: String?
    public var level: String?
    public var freezingBase: String?
    public var freezingTop: String?
    public var shape: WeatherShape

    public var time: Date { issued }

    public func isValid(at now: Date) -> Bool {
        valid <= now && now < valid.addingTimeInterval(Self.snapshotSpacing)
    }

    public static func decode(_ data: Data) throws -> [GAirmet] {
        struct Wire: Decodable {
            var product: String?, tag: String?, hazard: String, severity: String?
            var issued: Date, valid: Date, expires: Date, due_to: String?
            var base: String?, top: String?, level: String?, fzl_base: String?, fzl_top: String?
        }
        let features = try WeatherJSON.features(Wire.self, from: data, what: "gairmets")
        // Every issue carries freezing level lines, so an empty file means a broken one.
        guard !features.isEmpty else { throw WeatherError.empty(.gairmets) }
        return try features.map { feature in
            guard let shape = feature.geometry?.shape else { throw WeatherError.unreadable("gairmets") }
            let wire = feature.properties
            return GAirmet(product: wire.product, tag: wire.tag, hazard: wire.hazard, severity: wire.severity,
                           issued: wire.issued, valid: wire.valid, expires: wire.expires, dueTo: wire.due_to,
                           base: wire.base, top: wire.top, level: wire.level,
                           freezingBase: wire.fzl_base, freezingTop: wire.fzl_top, shape: shape)
        }
    }
}

/// A Center Weather Advisory: a short-fused warning from one ARTCC's weather unit.
public struct Cwa: Equatable, Sendable, WeatherTimed {
    public var center: String
    public var series: String
    public var hazard: String
    public var qualifier: String
    public var validFrom: Date
    public var validTo: Date
    public var baseFtMSL: Int?
    public var topFtMSL: Int?
    public var raw: String
    public var shape: WeatherShape

    public var time: Date { validFrom }

    public func isValid(at now: Date) -> Bool { validFrom <= now && now < validTo }

    public static func decode(_ data: Data) throws -> [Cwa] {
        struct Wire: Decodable {
            var cwsu: String, series: String, hazard: String, qualifier: String
            var from: Date, to: Date, base_ft: Int?, top_ft: Int?, raw: String
        }
        return try WeatherJSON.features(Wire.self, from: data, what: "cwas").map { feature in
            guard let shape = feature.geometry?.shape else { throw WeatherError.unreadable("cwas") }
            let wire = feature.properties
            return Cwa(center: wire.cwsu, series: wire.series, hazard: wire.hazard, qualifier: wire.qualifier,
                       validFrom: wire.from, validTo: wire.to, baseFtMSL: wire.base_ft, topFtMSL: wire.top_ft,
                       raw: wire.raw, shape: shape)
        }
    }
}

extension Array where Element == Cwa {
    public func valid(at now: Date) -> [Cwa] { filter { $0.isValid(at: now) } }
}

extension Array where Element == Sigmet {
    public func valid(at now: Date) -> [Sigmet] { filter { $0.isValid(at: now) } }
}

extension Array where Element == GAirmet {
    /// The snapshot covering now. Just before the first snapshot time that first
    /// snapshot is returned, so a fresh issue never reads as an empty map.
    public func valid(at now: Date) -> [GAirmet] {
        let shown = filter { $0.isValid(at: now) }
        guard shown.isEmpty, let first = map(\.valid).min(), now < first,
              first.timeIntervalSince(now) <= GAirmet.snapshotSpacing else { return shown }
        return filter { $0.valid == first }
    }
}
