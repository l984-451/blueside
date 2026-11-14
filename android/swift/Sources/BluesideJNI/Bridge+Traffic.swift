import FlightCore

/// One receiver's GDL 90 state. Kotlin hands it raw datagrams and asks for a batch at most once a second.
final class TrafficSession {
    var store = TrafficStore()
}

extension Bridge {
    struct TrafficCatalog: Encodable {
        struct Source: Encodable { var id: String; var title: String }
        var sources = OwnshipSource.allCases.map { Source(id: $0.rawValue, title: $0.title) }
        var sourceKey = OwnshipSource.key
        var port = Int(GDL90.port)
        var notListening = ReceiverStatus.notListening
    }

    struct ChooseArgs: Decodable { var source: String; var device: Fix?; var receiver: Fix?; var now: Date }

    struct BatchArgs: Decodable { var reference: Fix?; var now: Date }

    struct Batch: Encodable {
        struct Status: Encodable {
            var name: String?
            var connected: Bool
            var heard: Bool
            var gpsValid: Bool
            var lastMessage: String
            var lastMessageNext: Date?
            /// When the receiver last sent anything.
            var lastMessageAt: Date?
        }
        var shapes: String
        var count: Int
        var alerts: Int
        var status: Status
        /// The receiver's live fix, in the shape Kotlin sends fixes in.
        var receiver: FixOut?
        /// When to ask again with no new datagram.
        var next: Date?
    }

    struct FixOut: Encodable { var latitude: Double; var longitude: Double; var course: Double; var speed: Double; var altitude: Double?; var time: Int64 }

    static func fixOut(_ p: Position?) -> FixOut? {
        p.map { FixOut(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, course: $0.trackTrue ?? -1,
                       speed: $0.groundspeedKt.map { $0 / 1.943844 } ?? -1, altitude: $0.altitudeFtMSL.map { $0 / 3.28084 },
                       time: Int64(($0.timestamp.timeIntervalSince1970 * 1000).rounded())) }
    }

    /// Which fix the map uses: "receiver", "device" or "none".
    static func chooseFix(_ a: ChooseArgs) -> [String: String] {
        let (device, receiver) = (position(a.device), position(a.receiver))
        let chosen = (OwnshipSource(rawValue: a.source) ?? .auto).choose(device: device, receiver: receiver, now: a.now)
        return ["use": chosen == nil ? "none" : chosen == receiver ? "receiver" : "device"]
    }

    struct BackgroundArgs: Decodable { var fix: Fix?; var lastFast: Date?; var heard: Date?; var now: Date }
    struct BackgroundResult: Encodable { var until: Date?; var lastFast: Date? }

    /// Until when the app keeps running out of the front, by `BackgroundPolicy`. lastFast goes back with the next call.
    static func background(_ a: BackgroundArgs) -> BackgroundResult {
        let rule = BackgroundPolicy.runsUntil(position: position(a.fix), lastFast: a.lastFast, receiverHeard: a.heard, now: a.now)
        return BackgroundResult(until: rule.until, lastFast: rule.lastFast)
    }

    static func trafficCall(_ s: TrafficSession, _ op: String, _ args: Data) throws -> any Encodable {
        switch op {
        // The args are the datagram itself, not JSON.
        case "receive":
            s.store.receive(datagram: args, at: Date())
            return Empty()
        case "batch":
            let a = try decoder.decode(BatchArgs.self, from: args)
            s.store.prune(now: a.now)
            let shown = s.store.shown(reference: position(a.reference), now: a.now)
            let fix = s.store.receiverPosition.flatMap { $0.isStale(at: a.now) ? nil : $0 }
            let status = s.store.status
            return Batch(shapes: String(decoding: TrafficStore.geoJSON(shown), as: UTF8.self), count: shown.count,
                         alerts: shown.filter { $0.alert == .alert }.count,
                         status: .init(name: status.name, connected: status.isConnected(at: a.now), heard: status.lastHeartbeat != nil,
                                       gpsValid: status.gpsValid, lastMessage: status.lastMessageText(at: a.now),
                                       lastMessageNext: status.lastMessageChange(after: a.now),
                                       lastMessageAt: status.lastMessage),
                         receiver: fixOut(fix),
                         next: NextChange.earliest(after: a.now, [s.store.nextChange(after: a.now), fix?.staleAt]))
        default:
            throw Failure.unknownOp(op)
        }
    }
}
