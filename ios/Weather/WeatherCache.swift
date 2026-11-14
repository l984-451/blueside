import FlightCore
import Foundation

/// One answer from the weather host.
struct WeatherReply: Sendable {
    var status: Int
    var data: Data
    var etag: String?
}

/// Fetches one address. The second value is the tag of the copy on hand, sent so an unchanged file is not resent.
typealias WeatherLoad = @Sendable (URL, String?) async throws -> WeatherReply

/// Owns the weather folder and the network. An actor, so none of its work runs on the main thread.
actor WeatherCache {
    static var standardRoot: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Weather", isDirectory: true)
    }

    private typealias Held = WeatherPolicy.Held

    private let root: URL
    private let base: URL?
    private let load: WeatherLoad
    private var held: [String: Held] = [:]
    private var data = WeatherData()
    private var isRead = false
    private var loop: RadarLoop?

    /// A nil base means the folder is only read and nothing is ever fetched.
    init(root: URL, base: URL?, load: @escaping WeatherLoad = WeatherCache.http()) {
        self.root = root
        self.base = base
        self.load = load
    }

    private func file(_ source: WeatherSource) -> URL { root.appendingPathComponent("\(source.rawValue).json") }
    private var indexFile: URL { root.appendingPathComponent("index.json") }
    private var heldFile: URL { root.appendingPathComponent("held.json") }
    private var radarFolder: URL { root.appendingPathComponent("radar", isDirectory: true) }

    /// What is on disk. The files are read on the first call only.
    func read() -> WeatherData {
        guard !isRead else { return data }
        isRead = true
        try? FileManager.default.createDirectory(at: radarFolder, withIntermediateDirectories: true)
        // Weather is fetched again in seconds, so it stays out of device backups.
        var folder = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        held = (try? Data(contentsOf: heldFile)).flatMap { try? JSONDecoder().decode([String: Held].self, from: $0) } ?? [:]
        for source in WeatherSource.allCases where source.fileName != nil {
            guard let entry = held[source.rawValue], let json = try? Data(contentsOf: file(source)),
                  (try? data.take(source, json: json)) != nil else {
                held[source.rawValue] = nil
                continue
            }
            data.checkedAt[source] = entry.checkedAt
        }
        data.index = (try? Data(contentsOf: indexFile)).flatMap { try? WeatherIndex.decode($0) }
        data.frames = framesOnDisk()
        data.satellite = satelliteOnDisk()
        return data
    }

    private static func reason(_ error: any Error) -> String {
        if let reason = WeatherPolicy.reason(error) { return reason }
        guard let url = error as? URLError else { return error.localizedDescription }
        switch url.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return "No connection"
        case .timedOut, .cancelled: return WeatherPolicy.timedOut
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "Secure connection failed"
        default: return "Server not reachable"
        }
    }

    /// One pass: the index, then every file whose check time moved on. Returns what is held afterwards.
    func refresh(now: Date) async -> WeatherData {
        _ = read()
        guard let base else { return data }
        data.failures = [:]
        let index: WeatherIndex
        do {
            let reply = try await load(base.appendingPathComponent(WeatherPolicy.indexPath), nil)
            index = try WeatherPolicy.index(status: reply.status, body: reply.data)
            // A disk that cannot take the copy does not stop the fetch.
            try? reply.data.write(to: indexFile, options: .atomic)
        } catch {
            // Without a good index nothing can be dated, so every copy on hand stays as it is.
            for source in WeatherSource.allCases { data.failures[source] = Self.reason(error) }
            return data
        }
        data.index = index
        data.frames = framesOnDisk()
        data.satellite = satelliteOnDisk()
        let jobs = WeatherPolicy.jobs(index: index, held: held)
        // All files at once, so a slow or broken one never holds up another.
        let replies = await withTaskGroup(of: (WeatherSource, Result<WeatherReply, any Error>).self) { group in
            for job in jobs {
                let url = base.appendingPathComponent(job.path)
                group.addTask { [load] in
                    do { return (job.source, .success(try await load(url, job.etag))) } catch {
                        return (job.source, .failure(error))
                    }
                }
            }
            var all: [(WeatherSource, Result<WeatherReply, any Error>)] = []
            for await one in group { all.append(one) }
            return all
        }
        for (source, result) in replies {
            guard let checked = index.checkedAt[source] else { continue }
            do {
                let reply = try result.get()
                switch try WeatherPolicy.source(status: reply.status, body: reply.data, isHeld: held[source.rawValue] != nil) {
                case .unchanged:
                    held[source.rawValue]?.checkedAt = checked
                case .file(let json):
                    // Decoded before it is written, so a bad file never replaces the last good one.
                    try data.take(source, json: json)
                    // Unsaved, the new copy is still shown; the disk keeps the old one and its old time.
                    if (try? json.write(to: file(source), options: .atomic)) != nil {
                        held[source.rawValue] = Held(checkedAt: checked, etag: reply.etag)
                    }
                }
                data.checkedAt[source] = checked
            } catch {
                data.failures[source] = Self.reason(error)
            }
        }
        if let text = try? JSONEncoder().encode(held) { try? text.write(to: heldFile, options: .atomic) }
        return data
    }

    private func frameFile(_ frame: RadarFrame) -> URL {
        radarFolder.appendingPathComponent(WeatherPolicy.frameName(frame))
    }

    /// Radar pictures of the last good index that are on disk, oldest first.
    private func framesOnDisk() -> [RadarLoopFrame] {
        (data.index?.frames ?? []).map { RadarLoopFrame(valid: $0.valid, file: frameFile($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.file.path) }
    }

    /// The index's satellite picture when it is on disk. It shares the radar folder under its own prefix.
    private func satelliteOnDisk() -> RadarLoopFrame? {
        data.index?.satellite.map { RadarLoopFrame(valid: $0.valid, file: frameFile($0)) }
            .flatMap { FileManager.default.fileExists(atPath: $0.file.path) ? $0 : nil }
    }

    /// Second half of a pass: deletes pictures the index dropped, then downloads the loop's missing ones, newest first.
    func fetchFrames(now: Date) async -> WeatherData {
        _ = read()
        guard let base, let index = data.index else { return data }
        let plan = WeatherPolicy.framePlan(index: index, now: now, onDisk: namesOnDisk(), keeping: loop?.names ?? [])
        for name in plan.delete { try? FileManager.default.removeItem(at: radarFolder.appendingPathComponent(name)) }
        for frame in plan.fetch {
            do {
                let reply = try await load(base.appendingPathComponent(frame.path), nil)
                try WeatherPolicy.frame(status: reply.status, body: reply.data)
                try reply.data.write(to: frameFile(frame), options: .atomic)
            } catch {
                data.failures[frame.source] = Self.reason(error)
                // One failure ends the pass, so a dead link costs one timeout. The next pass tries again.
                break
            }
        }
        data.frames = framesOnDisk()
        data.satellite = satelliteOnDisk()
        return data
    }

    private func namesOnDisk() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: radarFolder.path)) ?? []
    }

    /// Starts the radar loop and downloads its missing pictures, telling `progress` before each one.
    /// Returns the pictures to play, oldest first; empty when there is nothing to loop or it was stopped.
    func startLoop(now: Date, progress: @Sendable (_ done: Int, _ total: Int) async -> Void) async -> [RadarLoopFrame] {
        _ = read()
        guard let base, let index = data.index, let started = RadarLoop(index: index, now: now) else { return [] }
        loop = started
        let missing = started.toFetch(onDisk: namesOnDisk())
        for (done, frame) in missing.enumerated() {
            await progress(done, missing.count)
            do {
                let reply = try await load(base.appendingPathComponent(frame.path), nil)
                try WeatherPolicy.frame(status: reply.status, body: reply.data)
                // Stopped while downloading: nothing written, so nothing is left behind.
                guard loop?.started == started.started, !Task.isCancelled else { return [] }
                try reply.data.write(to: frameFile(frame), options: .atomic)
                loop?.kept(frame)
            } catch {
                break
            }
        }
        guard let loop, !Task.isCancelled else { return [] }
        return loop.playable(onDisk: namesOnDisk()).map { RadarLoopFrame(valid: $0.valid, file: frameFile($0)) }
    }

    func isLoopExpired(now: Date) -> Bool { loop?.isExpired(at: now) ?? true }

    /// Deletes the pictures the loop downloaded.
    func stopLoop() {
        for name in loop?.cleanup(index: data.index) ?? [] {
            try? FileManager.default.removeItem(at: radarFolder.appendingPathComponent(name))
        }
        loop = nil
    }

    /// The plain loader: a conditional GET with no local cache in between.
    static func http(_ configuration: URLSessionConfiguration = .ephemeral) -> WeatherLoad {
        configuration.urlCache = nil
        // The request timeout restarts with every byte; this caps the whole download.
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        return { url, etag in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return WeatherReply(status: http?.statusCode ?? 0, data: data,
                                etag: http?.value(forHTTPHeaderField: "ETag"))
        }
    }
}
