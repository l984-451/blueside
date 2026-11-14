/// Answers whether chart packs hold a tile under a point, by reading each pack's own tile index.
public final class PackCoverage {
    public init() {}

    private struct Entry {
        var id: UInt64
        var run: UInt64
        var length: UInt64
        var offset: UInt64
    }

    private final class Pack {
        let file: Reader
        let zooms: ClosedRange<Int>
        let leafStart: UInt64
        let gzipped: Bool
        var root: [Entry] = []
        var leaves: [UInt64: [Entry]] = [:]

        init?(_ url: URL) {
            guard let file = Reader(url), let head = file.read(at: 0, count: 127),
                  head.starts(with: Array("PMTiles".utf8)), head[7] == 3, head[100] <= head[101] else { return nil }
            self.file = file
            zooms = Int(head[100])...Int(head[101])
            leafStart = PackCoverage.number(head, at: 40)
            gzipped = head[97] == 2
            guard gzipped || head[97] == 1,
                  let entries = read(at: PackCoverage.number(head, at: 8), length: PackCoverage.number(head, at: 16))
            else { return nil }
            root = entries
        }

        func read(at offset: UInt64, length: UInt64) -> [Entry]? {
            // An index part is a few kilobytes. Anything huge is a damaged file.
            guard length < 1 << 24, let raw = file.read(at: offset, count: Int(length)) else { return nil }
            return (gzipped ? Inflate.gunzip(raw) : raw).flatMap(PackCoverage.entries)
        }

        func has(_ tile: UInt64) -> Bool {
            var entries = root
            // The index is at most a few parts deep.
            for _ in 0..<4 {
                guard let entry = entries.last(where: { $0.id <= tile }) else { return false }
                if entry.run > 0 { return tile - entry.id < entry.run }
                if leaves[entry.offset] == nil {
                    let (at, over) = leafStart.addingReportingOverflow(entry.offset)
                    leaves[entry.offset] = over ? [] : read(at: at, length: entry.length) ?? []
                }
                entries = leaves[entry.offset] ?? []
            }
            return false
        }
    }

    private var packs: [URL: Pack?] = [:]

    /// True when the map has a tile to draw at the point from any of the packs, at this camera zoom.
    /// A pack named in limited may be stretched one zoom past its last; the others without limit.
    // Known limit: a tile that is there but see-through at the point still counts. Its pixels are not read.
    public func covers(_ files: [URL], limited: Set<URL> = [], latitude: Double, longitude: Double, zoom: Double) -> Bool {
        // Tiles are drawn 256 points wide, so the map asks for one zoom deeper than the camera, rounded.
        let ideal = Int((zoom + 1).rounded())
        // A pack no longer on the map is let go, so a deleted file gives its room back.
        packs = packs.filter { files.contains($0.key) }
        return files.contains { url in
            if packs[url] == nil { packs[url] = .some(Pack(url)) }
            // A limited pack counts only while stretched by at most one zoom past its last.
            guard let pack = packs[url] ?? nil, ideal >= pack.zooms.lowerBound,
                  !limited.contains(url) || ideal - pack.zooms.upperBound <= 1 else { return false }
            // Only the zoom the map asks for counts: a wider tile filling in for a missing one is empty there.
            return pack.has(Self.tileID(zoom: min(ideal, pack.zooms.upperBound), latitude: latitude,
                                        longitude: longitude))
        }
    }

    public enum Gap: Equatable, Sendable {
        case chart, detail

        /// The words shown over the map.
        public var text: String { self == .chart ? "No chart coverage here" : "No detailed chart downloaded here" }
    }

    /// What the packs lack under the point: nothing, any chart at all, or only a chart sharp enough to read.
    public func gap(_ files: [URL], overviews: Set<URL>, latitude: Double, longitude: Double, zoom: Double) -> Gap? {
        guard covers(files, latitude: latitude, longitude: longitude, zoom: zoom) else { return .chart }
        return covers(files, limited: overviews, latitude: latitude, longitude: longitude, zoom: zoom) ? nil : .detail
    }

    /// The file format's number for the tile over a point: zooms in order, each along a Hilbert curve.
    public static func tileID(zoom: Int, latitude: Double, longitude: Double) -> UInt64 {
        let side = Double(1 << zoom)
        let radians = min(max(latitude, -85.0511), 85.0511) * .pi / 180
        var x = Int(min(max((longitude + 180) / 360 * side, 0), side - 1))
        var y = Int(min(max((1 - asinh(tan(radians)) / .pi) / 2 * side, 0), side - 1))
        var id = (0..<zoom).reduce(UInt64(0)) { $0 + 1 << (2 * UInt64($1)) }
        var step = (1 << zoom) >> 1
        while step > 0 {
            let right = x & step > 0 ? 1 : 0, down = y & step > 0 ? 1 : 0
            id += UInt64(step * step * ((3 * right) ^ down))
            if down == 0 {
                if right == 1 { (x, y) = (step - 1 - x, step - 1 - y) }
                swap(&x, &y)
            }
            step >>= 1
        }
        return id
    }

    /// A pack's extent, read from the bounds in its file header.
    public static func bounds(_ url: URL) -> MapStyleSpec.Box? {
        guard let head = Reader(url)?.read(at: 0, count: 127), head.starts(with: Array("PMTiles".utf8)) else { return nil }
        let degrees = { (at: Int) in Double(Int32(truncatingIfNeeded: number(head, at: at))) / 1e7 }
        return MapStyleSpec.Box(minLatitude: degrees(106), minLongitude: degrees(102),
                                maxLatitude: degrees(114), maxLongitude: degrees(110))
    }

    private static func number(_ data: [UInt8], at index: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[index + $1]) << (8 * UInt64($1)) }
    }

    // One index part: a count, then that many id steps, run lengths, sizes and offsets, as variable-length numbers.
    private static func entries(_ data: [UInt8]) -> [Entry]? {
        var numbers: [UInt64] = []
        var value: UInt64 = 0
        var shift: UInt64 = 0
        for byte in data {
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 {
                numbers.append(value)
                (value, shift) = (0, 0)
            } else {
                shift += 7
            }
        }
        guard let first = numbers.first, first < UInt64(numbers.count), numbers.count == 1 + 4 * Int(first)
        else { return nil }
        let count = Int(first)
        var entries: [Entry] = []
        var id: UInt64 = 0
        for index in 0..<count {
            id &+= numbers[1 + index]
            let stored = numbers[1 + 3 * count + index]
            // A stored zero means the data starts where the entry before it ends.
            let offset = stored > 0 ? stored - 1 : entries.last.map { $0.offset &+ $0.length } ?? 0
            entries.append(Entry(id: id, run: numbers[1 + count + index], length: numbers[1 + 2 * count + index],
                                 offset: offset))
        }
        return entries
    }
}

/// A file read at offsets with POSIX calls, closed when let go. FileHandle is not in every platform's Foundation.
private final class Reader {
    let descriptor: Int32

    init?(_ url: URL) {
        descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    /// Nil when the bytes are not all there, or the offset is past any file.
    func read(at offset: UInt64, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        guard let at = off_t(exactly: offset) else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let got = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!, count, at) }
        return got == count ? bytes : nil
    }
}
