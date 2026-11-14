import Foundation
import Testing
@testable import FlightCore

@Suite struct InflateTests {
    // NSData.compressed is Apple-only.
    #if canImport(Darwin)
    // The system's deflate is the reference; it writes fixed, dynamic and stored blocks depending on the input.
    @Test func inflatesWhatTheSystemDeflates() throws {
        var generator = SystemRandomNumberGenerator()
        let text = Array(String(repeating: "PMTiles directory entry 12345 ", count: 400).utf8)
        let noise = (0..<70000).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let small = (0..<300).map { _ in UInt8.random(in: 0...3, using: &generator) }
        for input in [text, noise, small, [], [7]] {
            let packed = try (Data(input) as NSData).compressed(using: .zlib) as Data
            #expect(Inflate.raw([UInt8](packed)) == input)
        }
    }

    @Test func gzipChecksTheHeaderAndTheLength() throws {
        let input = Array("hello hello hello".utf8)
        let body = [UInt8](try (Data(input) as NSData).compressed(using: .zlib) as Data)
        let header: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]
        let length = (0..<4).map { UInt8(truncatingIfNeeded: input.count >> (8 * $0)) }
        #expect(Inflate.gunzip(header + body + [0, 0, 0, 0] + length) == input)
        #expect(Inflate.gunzip(header + body + [0, 0, 0, 0, 1, 0, 0, 0]) == nil)
        #expect(Inflate.gunzip(Array("not gzip at all, not at all".utf8)) == nil)
        #expect(Inflate.raw([0xFF, 0xFF]) == nil)
    }

    // Zeros pack about a thousand to one. A whole, honest file past the ceiling is still refused.
    @Test func aFileLargerThanTheCeilingIsRefused() throws {
        let zeros = Data(count: Inflate.ceiling + 1)
        let body = [UInt8](try (zeros as NSData).compressed(using: .zlib) as Data)
        let header: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]
        let length = (0..<4).map { UInt8(truncatingIfNeeded: zeros.count >> (8 * $0)) }
        #expect(body.count < 100_000 && Inflate.gunzip(header + body + [0, 0, 0, 0] + length) == nil)
    }

    // gunzip passes the trailer's length as the limit, so a stream never grows past what it declares.
    @Test func inflatingStopsAtTheLimit() throws {
        let zeros = [UInt8](repeating: 0, count: 1 << 20)
        let body = [UInt8](try (Data(zeros) as NSData).compressed(using: .zlib) as Data)
        #expect(Inflate.raw(body, limit: zeros.count) == zeros)
        #expect(Inflate.raw(body, limit: zeros.count - 1) == nil)
        #expect(Inflate.raw(body, limit: 1000) == nil)
    }
    #endif
}
