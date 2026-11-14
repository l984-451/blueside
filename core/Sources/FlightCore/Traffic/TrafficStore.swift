/// Where the aircraft symbol takes its position from.
public enum OwnshipSource: String, CaseIterable, Sendable {
    case auto, device, receiver

    public static let key = "ownship-source"

    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .device: "This Device"
        case .receiver: "ADS-B Receiver"
        }
    }

    /// Automatic takes the receiver while its fix is live, else the device.
    public func choose(device: Position?, receiver: Position?, now: Date) -> Position? {
        switch self {
        case .device: device
        case .receiver: receiver
        case .auto: receiver.flatMap { $0.isStale(at: now) ? nil : $0 } ?? device
        }
    }
}

/// How urgent a target is, after TCAS: other, proximate (6 nm, 1,200 ft), alert (close now or soon).
public enum TrafficAlert: String, Sendable, Comparable {
    case other, proximate, alert

    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
    private var order: Int { self == .other ? 0 : self == .proximate ? 1 : 2 }
}

/// One target as the map shows it.
public struct TrafficShown: Equatable, Sendable {
    public var address: UInt32
    public var coordinate: Coordinate
    /// Degrees true; nil when the receiver gives no true track.
    public var track: Double?
    public var callsign: String
    /// Target minus ownship, in feet. Nil when either altitude is unknown.
    public var relativeFt: Int?
    public var verticalFpm: Int?
    public var alert: TrafficAlert
    public var isStale: Bool

    /// "+05↑", "-12↓", "00": hundreds of feet with a climb or descent arrow past 500 fpm.
    public var label: String {
        guard let relativeFt else { return "" }
        let hundreds = Int((Double(relativeFt) / 100).rounded())
        let digits = NavText.pad(abs(hundreds), 2)
        let sign = hundreds > 0 ? "+" : hundreds < 0 ? "-" : ""
        let arrow = (verticalFpm ?? 0) >= 500 ? "↑" : (verticalFpm ?? 0) <= -500 ? "↓" : ""
        return sign + digits + arrow
    }
}

/// The receiver as Settings describes it.
public struct ReceiverStatus: Equatable, Sendable {
    /// No heartbeat for this long and the receiver counts as gone.
    public static let lostAfter: TimeInterval = 5
    /// The Status row while the receiving socket is not open.
    public static let notListening = "Not listening"
    /// The Devices page footer on iOS, where a refused Local Network permission is the usual cause.
    public static let listenFailureNote = "Blueside can't listen for a receiver. Check that Local Network is on for Blueside in Settings, Privacy & Security."

    public var name: String?
    public var lastHeartbeat: Date?
    public var lastMessage: Date?
    public var gpsValid = false

    public init() {}

    public func isConnected(at now: Date) -> Bool {
        lastHeartbeat.map { abs(now.timeIntervalSince($0)) <= Self.lostAfter } ?? false
    }

    /// When `isConnected` turns false with no new heartbeat.
    public func nextChange(after now: Date) -> Date? {
        NextChange.earliest(after: now, [lastHeartbeat?.addingTimeInterval(Self.lostAfter + NextChange.past)])
    }

    /// "Now" while messages flow, then whole minutes since the last one.
    public func lastMessageText(at now: Date) -> String {
        guard let lastMessage else { return "Never" }
        let age = now.timeIntervalSince(lastMessage)
        if age < 60 { return age <= Self.lostAfter ? "Now" : "Under a minute ago" }
        return "\(Int(age / 60)) min ago"
    }

    /// When `lastMessageText` reads differently.
    public func lastMessageChange(after now: Date) -> Date? {
        guard let lastMessage else { return nil }
        return NextChange.earliest(after: now, [lastMessage.addingTimeInterval(Self.lostAfter + NextChange.past),
                                                NextChange.minute(since: lastMessage, after: now)])
    }
}

/// What a GDL 90 receiver has said: targets merged by address, ownship and the receiver's state.
public struct TrafficStore: Sendable {
    /// The layer picker's switch, on from the start; it draws only while a receiver sends targets.
    public static let switchID = "traffic"
    /// The map layers the switch shows and hides.
    public static let layers = ["traffic", "traffic-label", "traffic-callsign"]
    public static var layerGroup: LayerGroup {
        LayerGroup(id: switchID, title: "Traffic", overlays: [OverlayLayer(id: switchID, title: "Traffic", isImage: false, isOn: true)])
    }

    /// A target not heard for this long is drawn dim, then dropped.
    public static let staleAfter: TimeInterval = 10
    public static let dropAfter: TimeInterval = 60
    /// Alert inside this range and height, or when the closest approach within `alertLook` comes this close.
    public static let alertNM = 2.0, alertFt = 600, closeNM = 0.5, alertLook: TimeInterval = 60
    public static let proximateNM = 6.0, proximateFt = 1200
    /// Addresses past this many are ignored until older ones drop, so a flood cannot swamp the map.
    static let targetLimit = 2000

    struct Heard: Sendable { var report: GDL90.Report; var at: Date }

    private(set) var targets: [UInt32: Heard] = [:]
    public private(set) var status = ReceiverStatus()
    private var ownship: Heard?
    private var ownshipGeometricFt: Int?
    /// The device's ID message says its geometric altitude is MSL rather than above the WGS-84 ellipsoid.
    private var geometricIsMSL = false

    public init() {}

    public var targetCount: Int { targets.count }

    /// Takes every message in one datagram.
    public mutating func receive(datagram: some Sequence<UInt8>, at now: Date) {
        for message in GDL90.messages(in: datagram) {
            if let decoded = GDL90.decode(message) { receive(decoded, at: now) }
        }
    }

    public mutating func receive(_ message: GDL90.Message, at now: Date) {
        status.lastMessage = now
        switch message {
        case .heartbeat(let beat):
            status.lastHeartbeat = now
            status.gpsValid = beat.gpsValid
        case .ownship(let report): ownship = Heard(report: report, at: now)
        case .ownshipAltitude(let feet): ownshipGeometricFt = feet
        case .traffic(let report):
            guard report.coordinate != nil, targets[report.address] != nil || targets.count < Self.targetLimit else { return }
            targets[report.address] = Heard(report: report, at: now)
        case .device(let device):
            status.name = device.longName.isEmpty ? device.name : device.longName
            geometricIsMSL = device.altitudeMSL
        case .uplink, .other: break
        }
    }

    /// Drops targets not heard for `dropAfter`. The caller runs it before each `shown`, not per message.
    public mutating func prune(now: Date) {
        targets = targets.filter { now.timeIntervalSince($0.value.at) <= Self.dropAfter }
    }

    /// The receiver's own fix, while its GPS says it is valid. Its geometric altitude goes through the geoid
    /// unless the device says it is already MSL.
    public var receiverPosition: Position? {
        guard status.gpsValid, let ownship, let at = ownship.report.coordinate else { return nil }
        let r = ownship.report
        let meters = ownshipGeometricFt.map { Double($0) / 3.28084 }
        return Position(latitude: at.latitude, longitude: at.longitude, courseDegrees: r.track ?? -1,
                        speedMetersPerSecond: r.groundspeedKt.map { Double($0) / 1.943844 } ?? -1,
                        altitudeMeters: geometricIsMSL ? meters : nil,
                        ellipsoidAltitudeMeters: geometricIsMSL ? nil : meters, timestamp: ownship.at)
    }

    /// Every target heard in the last minute, with the receiver's own aircraft left out, most urgent last.
    /// `reference` is the ownship position the map uses, for range and closure. Relative altitude is pressure
    /// altitude on both sides, so it is unknown when the receiver sends none for ownship.
    public func shown(reference: Position?, now: Date) -> [TrafficShown] {
        let own = ownship?.report
        let ownFt = own?.altitudeFt
        return targets.values.compactMap { heard -> TrafficShown? in
            let r = heard.report
            guard r.address != own?.address || r.addressType != own?.addressType, let at = r.coordinate,
                  now.timeIntervalSince(heard.at) <= Self.dropAfter else { return nil }
            let relative = r.altitudeFt.flatMap { feet in ownFt.map { feet - $0 } }
            return TrafficShown(address: r.address, coordinate: at, track: r.track, callsign: r.callsign,
                                relativeFt: relative, verticalFpm: r.verticalFpm,
                                alert: Self.alert(r, relativeFt: relative, ownship: reference,
                                                  ownVerticalFpm: own?.verticalFpm),
                                isStale: now.timeIntervalSince(heard.at) > Self.staleAfter)
        }
        .sorted { ($0.alert, $0.address) < ($1.alert, $1.address) }
    }

    /// The next time `shown` or the receiver's state changes with no new message.
    public func nextChange(after now: Date) -> Date? {
        NextChange.earliest(after: now, targets.values.flatMap {
            [$0.at.addingTimeInterval(Self.staleAfter + NextChange.past), $0.at.addingTimeInterval(Self.dropAfter + NextChange.past)]
        } + [status.nextChange(after: now)])
    }

    /// TCAS-like: close now, or a closest approach in the next minute inside half a mile, else proximate or other.
    /// An unknown altitude counts as co-altitude, as TCAS treats a target that reports none.
    static func alert(_ r: GDL90.Report, relativeFt: Int?, ownship: Position?, ownVerticalFpm: Int?) -> TrafficAlert {
        guard let own = ownship, let at = r.coordinate else { return .other }
        let dz = Double(relativeFt ?? 0)
        let range = Geo.distanceNM(from: own.coordinate, to: at)
        if range <= alertNM, abs(dz) <= Double(alertFt) { return .alert }
        // Flat frame around ownship, nm and nm per second.
        let bearing = Geo.initialBearing(from: own.coordinate, to: at) * .pi / 180
        let (px, py) = (range * sin(bearing), range * cos(bearing))
        func velocity(_ track: Double?, _ kt: Double?) -> (Double, Double) {
            guard let track, let kt else { return (0, 0) }
            return (kt / 3600 * sin(track * .pi / 180), kt / 3600 * cos(track * .pi / 180))
        }
        let target = velocity(r.track, r.groundspeedKt.map(Double.init))
        let mine = velocity(own.trackTrue, own.groundspeedKt)
        let (vx, vy) = (target.0 - mine.0, target.1 - mine.1)
        let speed2 = vx * vx + vy * vy
        if speed2 > 0 {
            let t = -(px * vx + py * vy) / speed2
            if t > 0, t <= alertLook {
                let (cx, cy) = (px + vx * t, py + vy * t)
                let climb = Double((r.verticalFpm ?? 0) - (ownVerticalFpm ?? 0)) / 60
                if (cx * cx + cy * cy).squareRoot() <= closeNM, abs(dz + climb * t) <= Double(alertFt) { return .alert }
            }
        }
        return range <= proximateNM && abs(dz) <= Double(proximateFt) ? .proximate : .other
    }

    /// Points with the symbol's track (0 for a circle, which never turns), alert level, stale flag, data block
    /// and callsign, and the names of the images each platform draws for them (the map fonts have no arrows).
    public static func geoJSON(_ shown: [TrafficShown]) -> Data {
        WeatherGeoJSON.collection(shown.map {
            WeatherGeoJSON.point($0.coordinate, [
                "track": .double($0.track ?? 0), "alert": .string($0.alert.rawValue), "stale": .int($0.isStale ? 1 : 0),
                "label": .string($0.label), "callsign": .string($0.callsign), "icon": .string(icon($0)),
                "labelIcon": .string(labelIcon($0)), "callsignIcon": .string(callsignIcon($0)),
            ])
        })
    }

    /// A chevron along the track, or a circle for a target that reports none.
    public static func icon(_ t: TrafficShown) -> String { icon(t.alert, directed: t.track != nil) }
    public static func icon(_ alert: TrafficAlert, directed: Bool) -> String { "traffic-" + alert.rawValue + (directed ? "" : "-circle") }
    public static func labelIcon(_ t: TrafficShown) -> String { t.label.isEmpty ? "" : "traffic-label-\(t.alert.rawValue)-\(t.label)" }
    public static func callsignIcon(_ t: TrafficShown) -> String { t.callsign.isEmpty ? "" : "traffic-callsign-" + t.callsign }
}
