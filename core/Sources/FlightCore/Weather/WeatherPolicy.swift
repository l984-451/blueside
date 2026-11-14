/// Weather fetch decisions and words. A platform only makes requests and keeps files, then hands each reply here.
public enum WeatherPolicy {
    /// Seconds between passes while the app is open.
    public static let refreshInterval: TimeInterval = 60
    /// A pass still running after this many seconds is cut off.
    public static let passLimit: TimeInterval = 90
    /// Path of the index below the server address.
    public static let indexPath = "wx/index.json"
    public static let noAddress = "No server address in this build"
    public static let timedOut = "Timed out"

    /// A source file on disk: the server's check time it was downloaded under, and its tag.
    public struct Held: Codable, Equatable, Sendable {
        public var checkedAt: Date
        public var etag: String?

        public init(checkedAt: Date, etag: String?) {
            self.checkedAt = checkedAt
            self.etag = etag
        }
    }

    /// A failure with the words to show.
    public struct Failure: Error, Equatable {
        public var reason: String
    }

    /// One file to fetch: the path below the server address, and the tag of the copy on hand.
    public struct Job: Equatable, Sendable {
        public var source: WeatherSource
        public var path: String
        public var etag: String?
    }

    public enum Reply: Equatable, Sendable {
        /// The copy on hand is the file the server checked at this time.
        case unchanged
        /// The new file, inflated and ready to decode.
        case file(Data)
    }

    /// Every source whose check time moved on since the copy on hand. Held is keyed by the source's raw value.
    public static func jobs(index: WeatherIndex, held: [String: Held]) -> [Job] {
        WeatherSource.allCases.compactMap { source in
            guard let name = source.fileName, let checked = index.checkedAt[source],
                  checked != held[source.rawValue]?.checkedAt else { return nil }
            return Job(source: source, path: "wx/" + name, etag: held[source.rawValue]?.etag)
        }
    }

    private static func answered(_ status: Int) -> Failure { Failure(reason: "Server answered \(status)") }

    /// The index in a reply. Throws a Failure or WeatherError.
    public static func index(status: Int, body: Data) throws -> WeatherIndex {
        guard status == 200 else { throw answered(status) }
        return try WeatherIndex.decode(body)
    }

    /// What a source reply holds. A 304 counts only when a copy is on hand.
    public static func source(status: Int, body: Data, isHeld: Bool) throws -> Reply {
        if status == 304, isHeld { return .unchanged }
        guard status == 200 else { throw answered(status) }
        guard let json = Inflate.gunzip([UInt8](body)) else { throw Failure(reason: "Not a gzip file") }
        return .file(Data(json))
    }

    /// Checks a radar picture reply before it is written.
    public static func frame(status: Int, body: Data) throws {
        guard status == 200 else { throw answered(status) }
        guard isWholePack(body) else { throw Failure(reason: "Not a whole radar picture") }
    }

    /// The file name a picture is kept under. The index decoder has checked the path, so its last part is plain.
    /// Satellite pictures share the folder, so theirs carry a prefix.
    public static func frameName(_ frame: RadarFrame) -> String {
        let name = frame.path.split(separator: "/").last.map(String.init) ?? frame.path
        return frame.source == .satellite ? "satellite-" + name : name
    }

    /// Pictures on disk the index dropped, to delete, and the newest radar and satellite pictures when missing, to fetch.
    /// Only the newest is drawn. Nothing is fetched for a source that is not current. A playing loop's pictures are kept.
    public static func framePlan(index: WeatherIndex, now: Date, onDisk: [String], keeping: Set<String> = [])
        -> (delete: [String], fetch: [RadarFrame]) {
        let named = Set((index.frames + [index.satellite].compactMap { $0 }).map(frameName)).union(keeping)
        let have = Set(onDisk)
        let satellite = index.status(of: .satellite, at: now) == .current ? [index.satellite].compactMap { $0 } : []
        return (onDisk.filter { !named.contains($0) },
                (index.radarLoop(at: now).suffix(1) + satellite).filter { !have.contains(frameName($0)) })
    }

    /// A pack file whose every section, as its header gives them, is inside the bytes. A body cut short fails.
    public static func isWholePack(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(127))
        guard bytes.count == 127, bytes.starts(with: Array("PMTiles".utf8)) else { return false }
        func number(_ at: Int) -> UInt64 { bytes[at..<at + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }
        // Offset and length pairs: root directory, metadata, leaf directories, tile data.
        return stride(from: 8, to: 72, by: 16).allSatisfy { at in
            let (end, over) = number(at).addingReportingOverflow(number(at + 8))
            return !over && end <= UInt64(data.count)
        }
    }

    /// The words for a failure the core knows. Nil for a platform's network error, which the platform words.
    public static func reason(_ error: any Error) -> String? {
        if let failure = error as? Failure { return failure.reason }
        if case WeatherError.unsupportedVersion = error { return "Needs a newer app" }
        if error is WeatherError { return "File could not be read" }
        if error is CancellationError { return timedOut }
        return nil
    }
}
