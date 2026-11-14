import Foundation

enum WeatherFixture {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("pipeline/tests/fixtures/wx/out")

    /// A sample the worker wrote. A .gz file is inflated first, as the app does after a download.
    static func data(_ name: String) throws -> Data {
        let url = folder.appendingPathComponent(name)
        guard name.hasSuffix(".gz") else { return try Data(contentsOf: url) }
        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzip.arguments = ["-c", url.path]
        let pipe = Pipe()
        gunzip.standardOutput = pipe
        try gunzip.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        gunzip.waitUntilExit()
        guard gunzip.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    /// The check time written in the sample index.
    static let checked = date("2026-10-13T00:35:00Z")
    /// One minute after the samples were written.
    static let now = date("2026-10-13T00:36:00Z")

    /// A sample file exactly as the server sends it.
    static func raw(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name)) }

    /// Wraps bytes as a gzip file. The checksum is left as zeros; only the length at the end is real.
    static func gzip(_ data: Data) -> Data {
        #if canImport(Darwin)
        let deflated = try! (data as NSData).compressed(using: .zlib) as Data
        #else
        // No system deflate off Apple: stored blocks of up to 65535 bytes are valid deflate.
        var deflated = Data()
        var rest = data[...]
        repeat {
            let chunk = rest.prefix(0xFFFF)
            rest = rest.dropFirst(chunk.count)
            let n = UInt16(chunk.count)
            deflated += [rest.isEmpty ? 1 : 0, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8(~n >> 8)] + chunk
        } while !rest.isEmpty
        #endif
        var size = UInt32(data.count).littleEndian
        return Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]) + deflated + Data(count: 4)
            + Data(bytes: &size, count: 4)
    }

    static func framePath(_ valid: Date) -> String { "wx/radar/f\(Int(valid.timeIntervalSince1970)).pmtiles" }

    /// An index in the worker's format: one check time for every source, and the frames given.
    static func index(checked: Date?, frames: [Date] = [], version: Int = 1) -> Data {
        let iso = ISO8601DateFormatter()
        let time: Any = checked.map { iso.string(from: $0) as Any } ?? NSNull()
        let names = ["metars", "tafs", "sigmets", "gairmets", "pireps", "tfrs", "radar"]
        let object: [String: Any] = [
            "version": version,
            "checked_at": Dictionary(uniqueKeysWithValues: names.map { ($0, time) }),
            "frames": frames.map { ["valid": iso.string(from: $0), "path": framePath($0)] },
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
