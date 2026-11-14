import CoreLocation
import FlightCore
import Observation

/// Turns system location fixes into the core's Position and keeps a stale flag current.
/// An ADS-B receiver's fix stands in for the device's as the pilot's source setting says.
@MainActor @Observable final class LocationProvider {
    /// The device's own fix.
    private(set) var device: Position?
    /// The receiver's live fix, nil once it goes stale.
    var receiver: Position?
    var source = OwnshipSource.auto
    /// The fix the map, strip and route use.
    var position: Position? { source.choose(device: device, receiver: receiver, now: Date()) }
    var usesReceiver: Bool { receiver != nil && position == receiver }
    /// True with no fix, or when the last fix is older than the core allows. Rechecked when it can change.
    var isStale: Bool { usesReceiver ? false : deviceStale }
    private var deviceStale = true
    /// True when location permission is denied or restricted, or location services are off.
    private(set) var accessOff = false
    /// True while the system says the device is not moving. The last fix is then kept live.
    private(set) var isStationary = false
    /// True when the fix cannot place the aircraft on a chart: a wide error, or reduced accuracy permission.
    var isApproximate: Bool { usesReceiver ? false : deviceApproximate }
    private var deviceApproximate = false

    /// Seconds without a fix before the system is asked again. Each ask that brings no fix doubles it, up to `longestQuiet`.
    static let quietLimit: TimeInterval = 2
    static let longestQuiet: TimeInterval = 30
    /// A stationary report keeps the last fix live only when that fix was slower than this.
    static let heldSpeedLimitKt: Double = 5

    // The receiver's time of the newest fix. A held fix is given later times, so the order is kept here.
    @ObservationIgnored private var fixTime: Date?
    @ObservationIgnored private var heard: Date?
    @ObservationIgnored private var wideError = false
    @ObservationIgnored private var reduced = false
    @ObservationIgnored private var asks = 0
    @ObservationIgnored private var session: CLServiceSession?
    @ObservationIgnored private var background: CLBackgroundActivitySession?
    @ObservationIgnored private var stream: Task<Void, Never>?
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var backgroundEnd: Task<Void, Never>?

    /// The fix time is the one the receiver reported, never the time it arrived here.
    func receive(_ location: CLLocation, now: Date = Date()) {
        heard = now
        // A negative horizontal accuracy means the coordinate is not valid.
        guard location.horizontalAccuracy >= 0 else { return }
        // An older fix never replaces a newer one, unless the newer one is dated ahead of the clock.
        if let fixTime, location.timestamp < fixTime, fixTime <= now + Position.staleAfter { return }
        // A negative vertical accuracy means the altitude is not valid.
        guard let fix = Position(latitude: location.coordinate.latitude,
                                 longitude: location.coordinate.longitude,
                                 courseDegrees: location.course,
                                 speedMetersPerSecond: location.speed,
                                 altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
                                 timestamp: location.timestamp) else { return }
        fixTime = location.timestamp
        wideError = location.horizontalAccuracy > Position.approximateBeyondMeters
        device = fix
        asks = 0
        recheck(now: now)
    }

    /// Takes the stationary and permission state the system sends with each update.
    func report(stationary: Bool, accessOff: Bool, reduced: Bool = false, now: Date = Date()) {
        heard = now
        self.reduced = reduced
        if accessOff != self.accessOff { self.accessOff = accessOff }
        let still = stationary && !accessOff
        if still != isStationary { isStationary = still }
        recheck(now: now)
    }

    // The last fix is held only if it was slow or had no speed, and is still live. A fix at flying
    // speed, or one that already went stale, stays as it is even when the system says not moving.
    private func holding(at now: Date) -> Bool {
        guard isStationary, let device, !device.isStale(at: now) else { return false }
        return (device.groundspeedKt ?? 0) < Self.heldSpeedLimitKt
    }

    func recheck(now: Date = Date()) {
        // A device the system reports as not moving is still at its last fix, so that fix is dated now.
        if holding(at: now) { device?.timestamp = now }
        let stale = device?.isStale(at: now) ?? true
        if stale != deviceStale { deviceStale = stale }
        let approximate = reduced || (device != nil && wideError)
        if approximate != deviceApproximate { deviceApproximate = approximate }
        if session != nil { schedule(now: now) }
    }

    private var quietFor: TimeInterval { min(Self.quietLimit * pow(2, Double(asks)), Self.longestQuiet) }

    /// True when the system went quiet and gave no reason. A new request then brings a fresh fix.
    func shouldAskAgain(now: Date = Date()) -> Bool {
        guard let heard, !holding(at: now), !accessOff else { return false }
        return now.timeIntervalSince(heard) > quietFor
    }

    /// Counted as heard, so a slow answer is not asked for twice, and a stream that brings nothing is asked less often.
    func askedAgain(now: Date = Date()) {
        heard = now
        asks += 1
    }

    /// When the hold, the stale flag or the quiet check next needs a look with no word from the system.
    /// A time already past means at once.
    func nextCheck(now: Date) -> Date? {
        // A held fix is dated again halfway to stale, so it never goes stale between looks.
        if holding(at: now), let device { return device.timestamp + Position.staleAfter / 2 }
        let quiet = accessOff ? nil : heard.map { $0 + quietFor + NextChange.past }
        return [quiet, deviceStale ? nil : device?.staleAt].compactMap { $0 }.min()
    }

    private func schedule(now: Date) {
        wake?.cancel()
        guard let next = nextCheck(now: now) else {
            wake = nil
            return
        }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSince(now), 0)))
            guard let self, !Task.isCancelled else { return }
            let now = Date()
            if self.shouldAskAgain(now: now) {
                self.askedAgain(now: now)
                self.listen()
            }
            self.recheck(now: now)
        }
    }

    /// Starts live fixes, looked at again at each deadline. Calling it twice does nothing more.
    func start() {
        guard session == nil else { return }
        session = CLServiceSession(authorization: .whenInUse)
        listen()
        recheck()
    }

    /// True while a background session keeps fixes coming with the app out of the front.
    var runsInBackground: Bool { background != nil }

    /// Holds a background session until the given time, then lets it go. A new one is made only in the front,
    /// the one place the system lets it begin.
    func keepRunning(until: Date?, inFront: Bool, now: Date = Date()) {
        backgroundEnd?.cancel()
        guard let until, until > now else {
            background?.invalidate()
            (background, backgroundEnd) = (nil, nil)
            return
        }
        if background == nil, inFront { background = CLBackgroundActivitySession() }
        backgroundEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(until.timeIntervalSince(now)))
            if !Task.isCancelled { self?.keepRunning(until: nil, inFront: false) }
        }
    }

    // A device that is not moving can get one fix and then none. A new stream starts with a fresh one.
    private func listen() {
        stream?.cancel()
        stream = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.airborne) {
                    guard let self, !Task.isCancelled else { return }
                    let off = update.authorizationDenied || update.authorizationDeniedGlobally
                        || update.authorizationRestricted
                    self.report(stationary: update.stationary, accessOff: off, reduced: update.accuracyLimited)
                    if let location = update.location { self.receive(location) }
                }
            } catch {
                // A failed stream is handled below like one that ended.
            }
            // A canceled stream was replaced or stopped, and its successor owns the hold.
            if !Task.isCancelled { self?.streamEnded() }
        }
    }

    /// A stream that ended on its own can no longer say the device moved, so the hold is dropped.
    func streamEnded(now: Date = Date()) {
        if isStationary { isStationary = false }
        recheck(now: now)
    }

    func stop() {
        stream?.cancel()
        wake?.cancel()
        session?.invalidate()
        keepRunning(until: nil, inFront: false)
        (stream, wake, session) = (nil, nil, nil)
    }
}
