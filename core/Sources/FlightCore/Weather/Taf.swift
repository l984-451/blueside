public struct SkyLayer: Equatable, Sendable, Codable {
    /// The forecast's own word, such as FEW, SCT, BKN, OVC, OVX or SKC.
    public var cover: String
    public var baseFtAGL: Int?
    /// CB for cumulonimbus or TCU for towering cumulus, when the forecast marks the layer.
    public var cloudType: String? = nil
}

/// Low-level wind shear not caused by storms: the top of the shear layer and the wind above it.
public struct WindShear: Equatable, Sendable {
    public var heightFtAGL: Int
    public var directionTrue: Int
    public var speedKt: Int
}

extension FlightCategory {
    /// The standard limits; the worse of ceiling and visibility decides. No ceiling puts no limit on the sky.
    public static func from(visibilityMiles: Double, ceilingFtAGL: Int?) -> FlightCategory {
        guard visibilityMiles.isFinite, visibilityMiles >= 0, (ceilingFtAGL ?? 0) >= 0 else { return .unknown }
        let ceiling = ceilingFtAGL ?? Int.max
        if visibilityMiles < 1 || ceiling < 500 { return .lifr }
        if visibilityMiles < 3 || ceiling < 1000 { return .ifr }
        if visibilityMiles <= 5 || ceiling <= 3000 { return .mvfr }
        return .vfr
    }
}

/// One forecast period of a TAF. A value the forecast does not state is nil, never zero.
public struct TafGroup: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case initial = "", from = "FM", becoming = "BECMG", temporary = "TEMPO", probability = "PROB"
    }

    public var kind: Kind
    public var from: Date
    public var to: Date
    /// BECMG only: when the change is complete.
    public var becomingBy: Date?
    /// Percent, when the forecast gives one.
    public var probability: Int?
    /// Degrees true, as in a METAR.
    public var windDirection: Int?
    public var windVariable: Bool
    public var windSpeedKt: Int?
    public var windGustKt: Int?
    public var visibilityMiles: Double?
    /// True when the forecast says "this far or more", such as P6SM.
    public var visibilityOrMore: Bool
    public var weather: String?
    /// Nil when the group says nothing about the sky.
    public var sky: [SkyLayer]?
    public var verticalVisibilityFt: Int?
    public var windShear: WindShear?

    private static let ceilingCovers: Set<String> = ["BKN", "OVC", "OVX"]
    private static let openCovers: Set<String> = ["SKC", "CLR", "NSC", "NCD", "CAVOK", "FEW", "SCT"]

    /// The lowest broken or overcast base, or the vertical visibility.
    public var ceilingFtAGL: Int? {
        let bases = (sky ?? []).filter { Self.ceilingCovers.contains($0.cover) }.compactMap(\.baseFtAGL)
        return (bases + [verticalVisibilityFt].compactMap { $0 }).min()
    }

    /// Unknown unless the group states a visibility and a sky this code can read. Never VFR for want of a value.
    public var category: FlightCategory {
        guard let visibility = visibilityMiles, sky != nil || verticalVisibilityFt != nil else { return .unknown }
        for layer in sky ?? [] where !Self.openCovers.contains(layer.cover) {
            // A cover word this code does not know, or a ceiling layer with no height, could be any ceiling.
            let obscured = layer.cover == "OVX" && verticalVisibilityFt != nil
            guard Self.ceilingCovers.contains(layer.cover), layer.baseFtAGL != nil || obscured else { return .unknown }
        }
        return FlightCategory.from(visibilityMiles: visibility, ceilingFtAGL: ceilingFtAGL)
    }

    /// This group with each element the other one states put in its place.
    func overlaid(by other: TafGroup) -> TafGroup {
        var out = self
        if other.windSpeedKt != nil || other.windDirection != nil || other.windVariable {
            out.windDirection = other.windDirection
            out.windVariable = other.windVariable
            out.windSpeedKt = other.windSpeedKt
            out.windGustKt = other.windGustKt
        }
        if let visibility = other.visibilityMiles {
            out.visibilityMiles = visibility
            out.visibilityOrMore = other.visibilityOrMore
        }
        if let weather = other.weather { out.weather = weather }
        if other.sky != nil || other.verticalVisibilityFt != nil {
            out.sky = other.sky
            out.verticalVisibilityFt = other.verticalVisibilityFt
        }
        if let shear = other.windShear { out.windShear = shear }
        return out
    }
}

public struct TafOverlay: Equatable, Sendable {
    /// A TEMPO or PROB group, or a BECMG group whose change is still under way. Holds only what the group states.
    public var group: TafGroup
    /// From the group's values, with anything it leaves out taken from the prevailing conditions.
    public var category: FlightCategory
}

public struct TafConditions: Equatable, Sendable {
    /// From the opening group, FM groups and completed BECMG changes. Its times are those of the group that began it.
    public var prevailing: TafGroup
    /// Shown beside the prevailing conditions, never merged into them.
    public var overlays: [TafOverlay]

    /// The prevailing category, or a worse one from a BECMG change under way. TEMPO and PROB groups are not counted.
    public var category: FlightCategory {
        // The cases run from VFR to LIFR and then unknown, so the later of two is the worse.
        let order = FlightCategory.allCases
        let found = [prevailing.category] + overlays.filter { $0.group.kind == .becoming }.map(\.category)
        return found.max { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) } ?? .unknown
    }
}

public struct Taf: Equatable, Sendable, WeatherTimed {
    public var station: String
    public var issued: Date
    public var validFrom: Date
    public var validTo: Date
    public var raw: String
    /// Forecast periods by start time. Empty when the file has none or they could not all be read.
    public var groups: [TafGroup] = []

    public var time: Date { issued }

    /// False before the forecast period starts and from the moment it ends.
    public func isValid(at now: Date) -> Bool { validFrom <= now && now < validTo }

    /// Prevailing conditions and the overlays in force at a time. Nil outside the forecast or with no groups.
    public func conditions(at time: Date) -> TafConditions? {
        guard isValid(at: time) else { return nil }
        var prevailing: TafGroup?
        var overlays: [TafGroup] = []
        for group in groups where group.from <= time {
            switch group.kind {
            case .initial, .from:
                prevailing = group
            case .becoming:
                // Until the change is complete the old conditions stand and the new ones are shown beside them.
                if let done = group.becomingBy, done <= time {
                    prevailing = prevailing?.overlaid(by: group)
                } else if time < group.to {
                    overlays.append(group)
                }
            case .temporary, .probability:
                if time < group.to { overlays.append(group) }
            }
        }
        guard let prevailing else { return nil }
        return TafConditions(prevailing: prevailing, overlays: overlays.map {
            TafOverlay(group: $0, category: prevailing.overlaid(by: $0).category)
        })
    }

    public static func decode(_ data: Data) throws -> [Taf] {
        struct WireLayer: Decodable {
            var cover: String, base: Int?, type: String?
        }
        struct WireShear: Decodable {
            var hgt: Int, dir: Int, spd: Int
        }
        struct WireGroup: Decodable {
            var from: Date, to: Date, kind: String?, prob: Int?, becoming: Date?
            var wdir: Int?, vrb: Bool?, wspd: Int?, gust: Int?
            var vis: Double?, visp: Bool?, wx: String?, sky: [WireLayer]?, vv: Int?, ws: WireShear?
        }
        struct Wire: Decodable {
            var id: String, issued: Date, from: Date, to: Date, raw: String
            var groups: [WireGroup]

            enum Keys: String, CodingKey {
                case id, issued, from, to, raw, groups
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: Keys.self)
                id = try values.decode(String.self, forKey: .id)
                issued = try values.decode(Date.self, forKey: .issued)
                from = try values.decode(Date.self, forKey: .from)
                to = try values.decode(Date.self, forKey: .to)
                raw = try values.decode(String.self, forKey: .raw)
                // A file from before groups were published has none. Groups that cannot be read are dropped whole.
                groups = (try? values.decode([WireGroup].self, forKey: .groups)) ?? []
            }
        }
        func group(_ wire: WireGroup) -> TafGroup? {
            // A BECMG change is complete at a time inside its own period.
            guard let kind = TafGroup.Kind(rawValue: wire.kind ?? ""), wire.from < wire.to,
                  kind != .becoming || wire.becoming.map({ wire.from <= $0 && $0 <= wire.to }) == true
            else { return nil }
            let layers = (wire.sky ?? []).map { SkyLayer(cover: $0.cover, baseFtAGL: $0.base, cloudType: $0.type) }
            let shear = wire.ws.map { WindShear(heightFtAGL: $0.hgt, directionTrue: $0.dir, speedKt: $0.spd) }
            return TafGroup(kind: kind, from: wire.from, to: wire.to, becomingBy: wire.becoming,
                            probability: wire.prob, windDirection: wire.wdir, windVariable: wire.vrb ?? false,
                            windSpeedKt: wire.wspd, windGustKt: wire.gust,
                            visibilityMiles: wire.vis, visibilityOrMore: wire.visp ?? false, weather: wire.wx,
                            sky: layers.isEmpty ? nil : layers, verticalVisibilityFt: wire.vv, windShear: shear)
        }
        // Of groups that start together the opening or FM one is read first, then a BECMG change to it,
        // then what lies over it.
        func rank(_ kind: TafGroup.Kind) -> Int {
            switch kind {
            case .initial: 0
            case .from: 1
            case .becoming: 2
            case .temporary, .probability: 3
            }
        }
        let rows = try WeatherJSON.decode([Wire].self, from: data, what: "tafs")
        guard !rows.isEmpty else { throw WeatherError.empty(.tafs) }
        return rows.map { row in
            let groups = row.groups.compactMap(group)
            // One group left out could hide a change, so a TAF keeps all of its groups or none.
            let kept = groups.count == row.groups.count
                ? groups.sorted { ($0.from, rank($0.kind)) < ($1.from, rank($1.kind)) } : []
            return Taf(station: row.id, issued: row.issued, validFrom: row.from, validTo: row.to, raw: row.raw,
                       groups: kept)
        }
    }
}
