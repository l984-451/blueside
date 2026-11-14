public enum WeatherSource: String, CaseIterable, Sendable {
    case metars, tafs, sigmets, gairmets, cwas, pireps, tfrs, radar, winds, satellite, lightning

    /// Object name under the weather prefix. Radar and satellite pictures are listed in the index instead.
    public var fileName: String? {
        switch self {
        case .metars: "metars.json.gz"
        case .tafs: "tafs.json.gz"
        case .sigmets: "sigmets.geojson.gz"
        case .gairmets: "gairmets.geojson.gz"
        case .cwas: "cwas.geojson.gz"
        case .pireps: "pireps.json.gz"
        case .tfrs: "tfrs.geojson.gz"
        case .winds: "winds.json.gz"
        case .lightning: "lightning.json.gz"
        case .radar, .satellite: nil
        }
    }

    /// How long a source counts as current: from its last good check, or for radar from its newest frame.
    public var currentFor: TimeInterval {
        switch self {
        case .metars, .sigmets, .gairmets, .cwas, .pireps, .lightning: 15 * 60
        case .radar, .satellite: 20 * 60
        // FB is issued four times a day.
        case .winds: 6 * 60 * 60
        default: 30 * 60
        }
    }
}

public enum WeatherError: Error, Equatable {
    case unreadable(String)
    case empty(WeatherSource)
    case unsupportedVersion(Int)
}

public enum SourceStatus: Equatable, Sendable {
    case current
    case notCurrent(since: Date)
    case unknown
}

public protocol WeatherTimed {
    /// Observation or issue time.
    var time: Date { get }
}

extension WeatherTimed {
    public func age(at now: Date) -> TimeInterval { now.timeIntervalSince(time) }
}

/// A radar or satellite picture the index names.
public struct RadarFrame: Equatable, Sendable, Decodable, WeatherTimed {
    public var valid: Date
    public var path: String
    public var time: Date { valid }

    public init(valid: Date, path: String) {
        self.valid = valid
        self.path = path
    }

    public var source: WeatherSource { path.hasPrefix("wx/satellite/") ? .satellite : .radar }
}

enum WeatherJSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw WeatherError.unreadable(what)
        }
    }
}

public struct WeatherIndex: Equatable, Sendable {
    public static let supportedVersion = 1
    /// A time this far ahead of the phone clock still counts; clocks differ by a few seconds.
    public static let clockAllowance: TimeInterval = 120
    /// A frame this far behind the newest one is left out of the loop.
    public static let loopSpan: TimeInterval = 70 * 60

    public var checkedAt: [WeatherSource: Date]
    /// Oldest first.
    public var frames: [RadarFrame]
    /// The newest infrared satellite picture.
    public var satellite: RadarFrame?

    public static func decode(_ data: Data) throws -> WeatherIndex {
        struct VersionOnly: Decodable { var version: Int }
        struct Wire: Decodable {
            var checked_at: [String: Date?]
            var frames: [RadarFrame]
            var satellite: RadarFrame?
        }
        let version = try WeatherJSON.decode(VersionOnly.self, from: data, what: "index").version
        guard version == supportedVersion else { throw WeatherError.unsupportedVersion(version) }
        let wire = try WeatherJSON.decode(Wire.self, from: data, what: "index")
        for (frame, folder) in wire.frames.map({ ($0, "wx/radar/") }) + [wire.satellite].compactMap({ $0.map { ($0, "wx/satellite/") } }) {
            guard frame.path.hasPrefix(folder), frame.path.hasSuffix(".pmtiles"), !frame.path.contains("..") else {
                throw WeatherError.unreadable("index")
            }
        }
        var checked: [WeatherSource: Date] = [:]
        for (name, time) in wire.checked_at {
            if let source = WeatherSource(rawValue: name), let time { checked[source] = time }
        }
        return WeatherIndex(checkedAt: checked, frames: wire.frames.sorted { $0.valid < $1.valid }, satellite: wire.satellite)
    }

    public func status(of source: WeatherSource, at now: Date) -> SourceStatus {
        // Pictures are judged by their newest one, every other source by the worker's last good check.
        source.status(checkedAt: source == .radar ? frames.last?.valid : source == .satellite ? satellite?.valid : checkedAt[source], at: now)
    }

    /// Frames to animate, oldest first. Empty unless radar is current; frames far behind the newest are left out.
    public func radarLoop(at now: Date) -> [RadarFrame] {
        guard status(of: .radar, at: now) == .current, let newest = frames.last?.valid else { return [] }
        return frames.filter { newest.timeIntervalSince($0.valid) <= Self.loopSpan }
    }
}

extension WeatherSource {
    /// Status of data held on the phone, from the check time it was downloaded under, or for radar a frame's valid time.
    public func status(checkedAt time: Date?, at now: Date) -> SourceStatus {
        guard let time, time <= now.addingTimeInterval(WeatherIndex.clockAllowance) else { return .unknown }
        return now.timeIntervalSince(time) <= currentFor ? .current : .notCurrent(since: time)
    }
}
