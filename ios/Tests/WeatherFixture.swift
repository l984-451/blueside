import FlightCore
import Foundation
import Testing
@testable import Blueside

private final class BundleMarker {}

enum WeatherFixture {
    /// The check time written in the sample index.
    static let checked = date("2026-10-13T00:35:00Z")
    /// One minute after the samples were written.
    static let now = date("2026-10-13T00:36:00Z")
    static let base = URL(string: "http://127.0.0.1:9")!

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// A sample file exactly as the server sends it.
    static func raw(_ name: String) throws -> Data {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        let bundled = Bundle(for: BundleMarker.self).url(forResource: parts[0], withExtension: parts[1])
        let beside = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wx/\(name)")
        return try Data(contentsOf: bundled ?? beside)
    }

    /// A sample file inflated, as the decoders take it.
    static func json(_ name: String) throws -> Data {
        Data(try #require(Inflate.gunzip([UInt8](try raw(name))), "\(name) did not inflate"))
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Wraps bytes as a gzip file. The checksum is left as zeros; only the length at the end is real.
    static func gzip(_ data: Data) -> Data {
        let deflated = try! (data as NSData).compressed(using: .zlib) as Data
        var size = UInt32(data.count).littleEndian
        return Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]) + deflated + Data(count: 4)
            + Data(bytes: &size, count: 4)
    }

    /// A small pack file: a header whose one tile section is the tag's bytes, right after it.
    static func pack(_ tag: String) -> Data {
        let body = Data(tag.utf8)
        var header = Data("PMTiles".utf8) + Data([3]) + Data(count: 119)
        func put(_ value: Int, at: Int) { for i in 0..<8 { header[at + i] = UInt8((value >> (8 * i)) & 0xFF) } }
        for at in [8, 24, 40] { put(127, at: at) }
        put(127, at: 56)
        put(body.count, at: 64)
        return header + body
    }

    static func framePath(_ valid: Date) -> String { "wx/radar/f\(Int(valid.timeIntervalSince1970)).pmtiles" }
    /// The same frame as the fake host files it, below wx/.
    static func frameName(_ valid: Date) -> String { "radar/f\(Int(valid.timeIntervalSince1970)).pmtiles" }

    /// An index in the worker's format: one check time for every source, and the frames given.
    static func index(checked: Date?, frames: [Date] = [], version: Int = 1) -> Data {
        let iso = ISO8601DateFormatter()
        let time: Any = checked.map { iso.string(from: $0) as Any } ?? NSNull()
        let names = ["metars", "tafs", "sigmets", "gairmets", "cwas", "pireps", "tfrs", "radar"]
        let object: [String: Any] = [
            "version": version,
            "checked_at": Dictionary(uniqueKeysWithValues: names.map { ($0, time) }),
            "frames": frames.map { ["valid": iso.string(from: $0), "path": framePath($0)] },
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static let files = ["metars.json.gz", "tafs.json.gz", "pireps.json.gz",
                        "sigmets.geojson.gz", "gairmets.geojson.gz", "cwas.geojson.gz", "tfrs.geojson.gz"]

    /// A host holding the seven sample files, an index, and one small pack file per frame.
    static func host(checked: Date = WeatherFixture.checked, frames: [Date] = []) throws -> WeatherFakeHost {
        let host = WeatherFakeHost()
        for name in files { host.put(name, try raw(name)) }
        for frame in frames { host.put(frameName(frame), pack("frame-\(frame)")) }
        host.put("index.json", index(checked: checked, frames: frames))
        return host
    }
}

/// Stands in for the weather host: answers from a table and keeps a list of what was asked.
final class WeatherFakeHost: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var down: [String: URLError.Code] = [:]
    private var log: [(name: String, tag: String?, onMain: Bool)] = []

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Files a body under its path below wx/. The tag follows the bytes, as the real host's does.
    func put(_ name: String, _ data: Data) { locked { files[name] = data } }
    /// Makes one path fail, by default like a dropped connection, or work again.
    func fail(_ name: String, _ failing: Bool = true, with code: URLError.Code = .networkConnectionLost) {
        locked { down[name] = failing ? code : nil }
    }

    var asked: [String] { locked { log.map(\.name) } }
    /// The tag sent with the last request for a path.
    func tag(sentFor name: String) -> String? { locked { log.last { $0.name == name }?.tag } }
    var usedMainThread: Bool { locked { log.contains { $0.onMain } } }
    func forget() { locked { log = [] } }

    var load: WeatherLoad {
        { [self] url, tag in try self.answer(url, tag) }
    }

    private func answer(_ url: URL, _ tag: String?) throws -> WeatherReply {
        let name = url.path.components(separatedBy: "/wx/").last ?? url.path
        return try locked { () throws -> WeatherReply in
            log.append((name, tag, Thread.isMainThread))
            if let code = down[name] { throw URLError(code) }
            guard let body = files[name] else { return WeatherReply(status: 404, data: Data(), etag: nil) }
            let etag = "\"\(body.count)-\(body.hashValue)\""
            if tag == etag { return WeatherReply(status: 304, data: Data(), etag: etag) }
            return WeatherReply(status: 200, data: body, etag: etag)
        }
    }
}
