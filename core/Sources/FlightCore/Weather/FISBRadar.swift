/// One block of a NEXRAD picture: 128 bins in 4 rows of 32, positioned by latitude and longitude.
public struct RadarBlock: Equatable, Sendable, WeatherTimed {
    public static let columns = 32, rows = 4

    /// The block's product: 63 regional or 64 CONUS.
    public var productID: Int
    /// 0 for the finest bins, 1 for bins 5 times larger, 2 for 9 times larger.
    public var scale: Int
    public var blockNumber: Int
    public var southern: Bool
    /// Degrees. The block spans `latSize` south of `north` and `lonSize` east of `west`; west is -180 up to 180.
    public var north: Double
    public var west: Double
    public var latSize: Double
    public var lonSize: Double
    /// Intensity 0 to 7, row by row from the north-west corner. 0 and 1 are background and 2 to 7 are echoes;
    /// levels 1 to 7 start at 5, 20, 30, 40, 45, 50 and 55 dBZ.
    public var bins: [UInt8]
    /// When the product was made.
    public var time: Date

    public func intensity(row: Int, column: Int) -> UInt8 { bins[row * Self.columns + column] }

    /// The block's key: blocks with the same one replace each other.
    var key: Int { productID << 24 | scale << 22 | (southern ? 1 << 21 : 0) | blockNumber }
}

extension FISB {
    private static let blockHeight = 4.0 / 60, blockWidth = 48.0 / 60, wideWidth = 96.0 / 60
    private static let wideFrom = 405_000, blocksPerRing = 450

    /// The blocks in a NEXRAD APDU (product 63 or 64), by the Global Block Representation. A run-length block gives
    /// one block; an empty-element block gives the blocks it marks, all at intensity 0. Bad payloads give none.
    public static func radarBlocks(_ apdu: APDU, near now: Date) -> [RadarBlock] {
        let p = apdu.payload
        guard apdu.productID == regionalRadar || apdu.productID == conusRadar, p.count >= 4 else { return [] }
        let runLength = p[0] & 0x80 != 0
        let southern = p[0] & 0x40 != 0
        let scale = Int(p[0] & 0x30) >> 4
        let number = Int(p[0] & 0x0F) << 16 | Int(p[1]) << 8 | Int(p[2])
        let time = apdu.stamp.date(near: now)
        func block(_ n: Int, _ bins: [UInt8]) -> RadarBlock {
            // Past 60 degrees blocks are twice as wide and only the even numbers are used.
            let n = n >= wideFrom ? n & ~1 : n
            let factor = scale == 1 ? 5.0 : scale == 2 ? 9.0 : 1.0
            // A block number past the last ring would put the block beyond the pole.
            let raw = min(blockHeight * Double(n / blocksPerRing), 90 - blockHeight)
            var west = Double(n % blocksPerRing) * blockWidth
            if west >= 180 { west -= 360 }
            return RadarBlock(productID: apdu.productID, scale: scale, blockNumber: n, southern: southern,
                              north: southern ? -raw : raw + blockHeight, west: west, latSize: blockHeight * factor,
                              lonSize: (n >= wideFrom ? wideWidth : blockWidth) * factor, bins: bins, time: time)
        }
        if runLength {
            var bins: [UInt8] = []
            for byte in p[3...] { bins += Array(repeating: byte & 7, count: Int(byte >> 3) + 1) }
            return bins.count == RadarBlock.columns * RadarBlock.rows ? [block(number, bins)] : []
        }
        // Empty blocks: the low nibble of byte 3 counts the bytes after it. Bit 3 of that byte is the block named,
        // bits 4 to 7 the next four to its east, and each later byte marks eight more. Marks stay on the row.
        let extra = Int(p[3] & 0x0F)
        guard p.count >= 4 + extra else { return [] }
        guard number < wideFrom else { return [block(number, empty)] }
        let rowStart = number - number % blocksPerRing
        var out: [RadarBlock] = []
        for i in 0...extra {
            let bits = i == 0 ? Int(p[3] & 0xF0) | 0x08 : Int(p[3 + i])
            for j in 0..<8 where bits & (1 << j) != 0 {
                let column = (number - rowStart + 8 * i + j - 3) % blocksPerRing
                out.append(block(rowStart + column, empty))
            }
        }
        return out
    }

    private static let empty = [UInt8](repeating: 0, count: RadarBlock.columns * RadarBlock.rows)
}
