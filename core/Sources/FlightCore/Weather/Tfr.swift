public struct TfrAltitude: Equatable, Sendable {
    public var value: Int
    /// FT or FL.
    public var unit: String
    /// MSL or AGL.
    public var reference: String

    public var text: String {
        if value == 0 && reference == "AGL" { return "SFC" }
        return unit == "FL" ? "FL\(value)" : "\(value) \(unit) \(reference)"
    }
}

public enum TfrStatus: Equatable, Sendable {
    case upcoming, active, expired
}

public struct Tfr: Equatable, Sendable, WeatherTimed {
    public var notam: String
    public var kind: String?
    public var facility: String?
    public var state: String?
    public var title: String?
    public var rule: String?
    public var name: String?
    public var issued: Date
    public var effective: Date?
    public var expires: Date?
    public var upper: TfrAltitude?
    public var lower: TfrAltitude?
    /// Nil for a notice with no drawn area, such as a nationwide one. It still has to be listed.
    public var shape: WeatherShape?
    /// The notice's detail could not be read, so it has no shape and is listed with `unreadableNote`.
    public var unreadable = false

    public var time: Date { issued }

    /// The title of the list of notices with no shape on the map.
    public static let listTitle = "TFRs Not on the Map"
    public static let unreadableNote = "Shape could not be read. Check the FAA notice."

    public func status(at now: Date) -> TfrStatus {
        if let expires, now >= expires { return .expired }
        if let effective, now < effective { return .upcoming }
        // No start means already in force, and no end means it has not ended.
        return .active
    }

    public static func decode(_ data: Data) throws -> [Tfr] {
        struct Wire: Decodable {
            var notam: String, kind: String?, facility: String?, state: String?, title: String?
            var rule: String?, name: String?, issued: Date, effective: Date?, expires: Date?
            var upper_value: Int?, upper_unit: String?, upper_ref: String?
            var lower_value: Int?, lower_unit: String?, lower_ref: String?
            var unreadable: Bool?
        }
        func altitude(_ value: Int?, _ unit: String?, _ reference: String?) -> TfrAltitude? {
            guard let value, let unit, let reference else { return nil }
            return TfrAltitude(value: value, unit: unit, reference: reference)
        }
        let features = try WeatherJSON.features(Wire.self, from: data, what: "tfrs")
        // The list always holds standing notices, so an empty file means a broken one.
        guard !features.isEmpty else { throw WeatherError.empty(.tfrs) }
        return features.map { feature in
            let wire = feature.properties
            return Tfr(notam: wire.notam, kind: wire.kind, facility: wire.facility, state: wire.state,
                       title: wire.title, rule: wire.rule, name: wire.name, issued: wire.issued,
                       effective: wire.effective, expires: wire.expires,
                       upper: altitude(wire.upper_value, wire.upper_unit, wire.upper_ref),
                       lower: altitude(wire.lower_value, wire.lower_unit, wire.lower_ref),
                       shape: feature.geometry?.shape, unreadable: wire.unreadable ?? false)
        }
    }
}
