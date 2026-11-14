/// Deflate and gzip decoding in plain Swift, so every platform reads compressed data the same way.
public enum Inflate {
    /// The most any stream may inflate to, so a few kilobytes cannot ask for gigabytes.
    static let ceiling = 64 << 20

    /// The contents of a gzip file, or nil when the bytes are not a whole one or would inflate past `ceiling`.
    public static func gunzip(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B else { return nil }
        var start = 10
        if bytes[3] & 4 != 0 { start += 2 + Int(bytes[10]) + Int(bytes[11]) << 8 }
        // An optional file name and comment, each ending in a zero byte.
        for bit: UInt8 in [8, 16] where bytes[3] & bit != 0 {
            while start < bytes.count, bytes[start] != 0 { start += 1 }
            start += 1
        }
        if bytes[3] & 2 != 0 { start += 2 }
        guard start < bytes.count - 8 else { return nil }
        // The last four bytes give the inflated length, which catches a file cut short and caps the output.
        let length = bytes.suffix(4).reversed().reduce(0) { $0 << 8 | Int($1) }
        guard length <= ceiling else { return nil }
        let inflated = raw(Array(bytes[start..<(bytes.count - 8)]), limit: length)
        return inflated?.count == length ? inflated : nil
    }

    /// A bare deflate stream (RFC 1951) inflated. Nil when it is damaged or would pass `ceiling`.
    public static func raw(_ input: [UInt8]) -> [UInt8]? { raw(input, limit: ceiling) }

    /// Nil when the stream is damaged or would pass `limit` bytes.
    static func raw(_ input: [UInt8], limit: Int) -> [UInt8]? {
        var reader = Reader(bytes: input, limit: limit)
        var out: [UInt8] = []
        out.reserveCapacity(min(input.count * 4, limit))
        while true {
            guard let last = reader.bits(1), let type = reader.bits(2) else { return nil }
            switch type {
            case 0:
                guard reader.stored(into: &out) else { return nil }
            case 1:
                guard reader.codes(fixed.lengths, fixed.distances, into: &out) else { return nil }
            case 2:
                guard let (lengths, distances) = reader.dynamicTables(),
                      reader.codes(lengths, distances, into: &out) else { return nil }
            default:
                return nil
            }
            if last == 1 { return out }
        }
    }

    private static let fixed: (lengths: Huffman, distances: Huffman) = {
        let lengths = Array(repeating: 8, count: 144) + Array(repeating: 9, count: 112)
            + Array(repeating: 7, count: 24) + Array(repeating: 8, count: 8)
        return (Huffman(lengths)!, Huffman(Array(repeating: 5, count: 30))!)
    }()

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99,
                                     115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025,
                                       1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
                                        12, 12, 13, 13]

    /// Canonical Huffman code: how many codes of each length, and the symbols in code order.
    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init?(_ lengths: [Int]) {
            for length in lengths { counts[length] += 1 }
            counts[0] = 0
            // An over-subscribed set of lengths is not a code.
            var left = 1
            for length in 1...15 {
                left = left * 2 - counts[length]
                if left < 0 { return nil }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        let limit: Int
        var position = 0
        var buffer = 0
        var count = 0

        init(bytes: [UInt8], limit: Int) { (self.bytes, self.limit) = (bytes, limit) }

        mutating func bits(_ wanted: Int) -> Int? {
            while count < wanted {
                guard position < bytes.count else { return nil }
                buffer |= Int(bytes[position]) << count
                position += 1
                count += 8
            }
            let value = buffer & ((1 << wanted) - 1)
            buffer >>= wanted
            count -= wanted
            return value
        }

        mutating func stored(into out: inout [UInt8]) -> Bool {
            (buffer, count) = (0, 0)
            guard position + 4 <= bytes.count else { return false }
            let length = Int(bytes[position]) | Int(bytes[position + 1]) << 8
            let check = Int(bytes[position + 2]) | Int(bytes[position + 3]) << 8
            position += 4
            guard length == ~check & 0xFFFF, position + length <= bytes.count, out.count + length <= limit else { return false }
            out += bytes[position..<(position + length)]
            position += length
            return true
        }

        mutating func decode(_ code: Huffman) -> Int? {
            var (value, first, index) = (0, 0, 0)
            for length in 1...15 {
                guard let bit = bits(1) else { return nil }
                value |= bit
                let count = code.counts[length]
                if value - count < first { return code.symbols[index + value - first] }
                index += count
                first = (first + count) << 1
                value <<= 1
            }
            return nil
        }

        mutating func dynamicTables() -> (Huffman, Huffman)? {
            guard let literals = bits(5).map({ $0 + 257 }), let distances = bits(5).map({ $0 + 1 }),
                  let codeCount = bits(4).map({ $0 + 4 }), literals <= 286, distances <= 30 else { return nil }
            let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            var codeLengths = [Int](repeating: 0, count: 19)
            for index in 0..<codeCount {
                guard let length = bits(3) else { return nil }
                codeLengths[order[index]] = length
            }
            guard let lengthCode = Huffman(codeLengths) else { return nil }
            var lengths: [Int] = []
            while lengths.count < literals + distances {
                guard let symbol = decode(lengthCode) else { return nil }
                switch symbol {
                case 0..<16: lengths.append(symbol)
                case 16:
                    guard let previous = lengths.last, let repeats = bits(2) else { return nil }
                    lengths += Array(repeating: previous, count: 3 + repeats)
                case 17:
                    guard let repeats = bits(3) else { return nil }
                    lengths += Array(repeating: 0, count: 3 + repeats)
                default:
                    guard let repeats = bits(7) else { return nil }
                    lengths += Array(repeating: 0, count: 11 + repeats)
                }
            }
            guard lengths.count == literals + distances, lengths[256] != 0,
                  let literal = Huffman(Array(lengths[..<literals])),
                  let distance = Huffman(Array(lengths[literals...])) else { return nil }
            return (literal, distance)
        }

        mutating func codes(_ literal: Huffman, _ distance: Huffman, into out: inout [UInt8]) -> Bool {
            while true {
                guard let symbol = decode(literal) else { return false }
                if symbol < 256 {
                    guard out.count < limit else { return false }
                    out.append(UInt8(symbol))
                } else if symbol == 256 {
                    return true
                } else {
                    let index = symbol - 257
                    guard index < 29, let extra = bits(Inflate.lengthExtra[index]),
                          let code = decode(distance), code < 30,
                          let far = bits(Inflate.distanceExtra[code]) else { return false }
                    let length = Inflate.lengthBase[index] + extra
                    let back = Inflate.distanceBase[code] + far
                    guard back <= out.count, out.count + length <= limit else { return false }
                    let from = out.count - back
                    for step in 0..<length { out.append(out[from + step]) }
                }
            }
        }
    }
}
