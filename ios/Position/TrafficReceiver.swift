import FlightCore
import Foundation
import Network
import Observation

/// What one pass over the store hands the main thread.
struct TrafficBatch: Sendable {
    var shown: [TrafficShown]
    var shapes: Data
    var status: ReceiverStatus
    var connected: Bool
    /// The receiving socket is open.
    var listening: Bool
    /// The receiver's own fix, nil once it goes stale.
    var position: Position?
    /// Datagrams heard since launch and the longest wait between two, for UI tests.
    var datagrams = 0
    var longestGap: TimeInterval = 0
}

/// Listens for GDL 90 datagrams on a background queue and passes at most one batch a second to the main thread.
/// With no new data it wakes only when a target goes stale or drops, the receiver goes quiet or a sender goes idle.
final class TrafficListener: @unchecked Sendable {
    /// A sender not heard for this long is let go.
    static let idleAfter: TimeInterval = 60
    /// The longest wait before listening again after a failure; the wait doubles from one second up to this.
    static let longestRetry: TimeInterval = 60

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "blueside.gdl90", qos: .userInitiated)
    private var port: NWEndpoint.Port?
    private var listener: NWListener?
    private var listening = false
    private var failures = 0
    private var retry: DispatchWorkItem?
    private var senders: [NWEndpoint: (connection: NWConnection, heard: Date)] = [:]
    private var store = TrafficStore()
    private var reference: Position?
    private var lastFlush = Date.distantPast
    private var flushPending = false
    private var datagrams = 0
    private var lastDatagram: Date?
    private var longestGap: TimeInterval = 0
    private var wake: DispatchWorkItem?
    private let deliver: @Sendable (TrafficBatch) -> Void

    init(deliver: @escaping @Sendable (TrafficBatch) -> Void) { self.deliver = deliver }

    /// Listens on the port, afresh if it already was, so a socket lost while the app was away is replaced.
    func start(port: UInt16) {
        queue.async { [self] in
            self.port = NWEndpoint.Port(rawValue: port)
            failures = 0
            listen()
        }
    }

    func stop() {
        queue.async { [self] in
            port = nil
            close()
            wake?.cancel()
        }
    }

    /// The position the map uses, for relative altitude and alerts.
    func setReference(_ position: Position?) { queue.async { [self] in reference = position } }

    private func listen() {
        close()
        guard let port else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: port) else { return failed() }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                failures = 0
                report(listening: true)
            case .failed: failed()
            // Waiting for a network; the listener becomes ready on its own when one comes.
            case .waiting: report(listening: false)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.read(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func close() {
        retry?.cancel()
        listener?.cancel()
        listener = nil
        for sender in senders.values { sender.connection.cancel() }
        senders = [:]
        report(listening: false)
    }

    // Port in use, permission refused or a socket taken while the app was away: listen again after a growing wait.
    private func failed() {
        close()
        let item = DispatchWorkItem { [weak self] in self?.listen() }
        retry = item
        queue.asyncAfter(deadline: .now() + min(pow(2, Double(failures)), Self.longestRetry), execute: item)
        failures += 1
    }

    private func report(listening: Bool) {
        guard listening != self.listening else { return }
        self.listening = listening
        flush()
    }

    // Each sender is one UDP "connection"; it reads until the sender's flow ends or goes idle.
    private func read(_ connection: NWConnection) {
        let endpoint = connection.endpoint
        senders[endpoint]?.connection.cancel()
        senders[endpoint] = (connection, Date())
        connection.start(queue: queue)
        @Sendable func next() {
            connection.receiveMessage { [weak self] data, _, _, error in
                if let data { self?.receive(data, from: endpoint) }
                if error == nil { next() } else { self?.drop(connection) }
            }
        }
        next()
    }

    private func drop(_ connection: NWConnection) {
        connection.cancel()
        if senders[connection.endpoint]?.connection === connection { senders[connection.endpoint] = nil }
    }

    private func receive(_ data: Data, from endpoint: NWEndpoint) {
        let now = Date()
        senders[endpoint]?.heard = now
        if let lastDatagram { longestGap = max(longestGap, now.timeIntervalSince(lastDatagram)) }
        (lastDatagram, datagrams) = (now, datagrams + 1)
        store.receive(datagram: data, at: now)
        guard !flushPending else { return }
        flushPending = true
        queue.asyncAfter(deadline: .now() + max(0, 1 - Date().timeIntervalSince(lastFlush))) { [self] in flush() }
    }

    private func flush() {
        flushPending = false
        let now = Date()
        lastFlush = now
        store.prune(now: now)
        for (endpoint, sender) in senders where now.timeIntervalSince(sender.heard) > Self.idleAfter {
            sender.connection.cancel()
            senders[endpoint] = nil
        }
        let shown = store.shown(reference: reference, now: now)
        let fix = store.receiverPosition.flatMap { $0.isStale(at: now) ? nil : $0 }
        deliver(TrafficBatch(shown: shown, shapes: TrafficStore.geoJSON(shown), status: store.status,
                             connected: store.status.isConnected(at: now), listening: listening, position: fix,
                             datagrams: datagrams, longestGap: longestGap))
        wake?.cancel()
        let idle = senders.values.map(\.heard).min()?.addingTimeInterval(Self.idleAfter + NextChange.past)
        guard let next = NextChange.earliest(after: now, [store.nextChange(after: now), fix?.staleAt, idle]) else { return }
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        wake = item
        queue.asyncAfter(deadline: .now() + next.timeIntervalSince(now), execute: item)
    }
}

/// The ADS-B receiver as the app sees it. Each value is set only when it changes, so a view reads only what it shows.
@MainActor @Observable final class TrafficReceiver {
    private(set) var status = ReceiverStatus()
    private(set) var connected = false
    /// False while the socket is not open: before it opens, after a failure, or while waiting for a network.
    private(set) var listening = false
    /// True once any receiver has been heard since launch.
    private(set) var heard = false
    private(set) var position: Position?
    /// "traffic 3 alert 1", for UI tests.
    private(set) var summary = "traffic 0 alert 0"
    /// "datagrams 120 gap 2", for UI tests: a gap near the time away means the app was suspended.
    private(set) var received = "datagrams 0 gap 0"

    @ObservationIgnored let layer = TrafficLayer()
    @ObservationIgnored private var listener: TrafficListener?

    /// Listens for a receiver, afresh if it already was. What was heard is kept.
    func start(port: UInt16 = GDL90.port) {
        if listener == nil {
            listener = TrafficListener { [weak self] batch in
                Task { @MainActor in self?.take(batch) }
            }
        }
        listener?.start(port: port)
    }

    func stop() { listener?.stop() }

    func setReference(_ position: Position?) { listener?.setReference(position) }

    func take(_ batch: TrafficBatch) {
        if status != batch.status { status = batch.status }
        if connected != batch.connected { connected = batch.connected }
        if listening != batch.listening { listening = batch.listening }
        if !heard, batch.status.lastHeartbeat != nil { heard = true }
        if position != batch.position { position = batch.position }
        let text = "traffic \(batch.shown.count) alert \(batch.shown.filter { $0.alert == .alert }.count)"
        if summary != text { summary = text }
        let count = "datagrams \(batch.datagrams) gap \(Int(batch.longestGap.rounded()))"
        if received != count { received = count }
        layer.update(batch.shown, shapes: batch.shapes)
    }
}
