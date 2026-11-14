/// The radar loop played on request: which pictures it fetches and shows, how long each stays up,
/// and which files go when it stops. Platforms download, write, delete and draw.
public struct RadarLoop: Equatable, Sendable {
    /// Pictures this far behind the newest are left out.
    public static let span: TimeInterval = 60 * 60
    public static let frameSeconds: TimeInterval = 0.5
    public static let newestSeconds: TimeInterval = 1.5
    /// A loop left this long stops, so its pictures do not stay on disk.
    public static let keepSeconds: TimeInterval = 30 * 60

    /// Oldest first.
    public let frames: [RadarFrame]
    public let started: Date
    /// File names this loop downloaded, deleted when it stops.
    public private(set) var fetched: Set<String> = []

    /// Nil when radar is not current or there are fewer than two pictures to cycle.
    public init?(index: WeatherIndex, now: Date) {
        let all = index.radarLoop(at: now)
        guard let newest = all.last?.valid else { return nil }
        let frames = all.filter { newest.timeIntervalSince($0.valid) <= Self.span }
        guard frames.count > 1 else { return nil }
        self.frames = frames
        started = now
    }

    public var names: Set<String> { Set(frames.map(WeatherPolicy.frameName)) }

    /// The pictures not on disk, oldest first.
    public func toFetch(onDisk: [String]) -> [RadarFrame] {
        let have = Set(onDisk)
        return frames.filter { !have.contains(WeatherPolicy.frameName($0)) }
    }

    /// Notes a picture this loop wrote to disk.
    public mutating func kept(_ frame: RadarFrame) { fetched.insert(WeatherPolicy.frameName(frame)) }

    /// The pictures to show, oldest first: those on disk.
    public func playable(onDisk: [String]) -> [RadarFrame] {
        let have = Set(onDisk)
        return frames.filter { have.contains(WeatherPolicy.frameName($0)) }
    }

    /// Seconds picture `i` of `count` stays up. The newest is held longer.
    public static func hold(_ i: Int, of count: Int) -> TimeInterval { i == count - 1 ? newestSeconds : frameSeconds }

    public func isExpired(at now: Date) -> Bool { now.timeIntervalSince(started) >= Self.keepSeconds }

    /// Files to delete when the loop stops. The newest picture stays, since the map draws it.
    public func cleanup(index: WeatherIndex?) -> [String] {
        let newest = index?.frames.last.map(WeatherPolicy.frameName)
        return fetched.filter { $0 != newest }.sorted()
    }

    /// "Loading 3 of 8" while picture `done + 1` downloads.
    public static func loading(_ done: Int, of total: Int) -> String { "Loading \(min(done + 1, total)) of \(total)" }

    /// The clock label while the picture valid at this time shows.
    public static func clock(_ valid: Date) -> String { "Radar " + WeatherText.zulu(valid) }
}
