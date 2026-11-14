/// FIS-B uplink weather as a GDL 90 receiver passes it on (FAA 560-1058-00 Rev A §3.3 and §4, RTCA DO-267/DO-358).
public enum FISB {
    public static let textProduct = 413
    public static let regionalRadar = 63, conusRadar = 64

    /// The time in an APDU header. The month and day come only with some time options.
    public struct Stamp: Equatable, Sendable {
        public var month: Int?
        public var day: Int?
        public var hours: Int
        public var minutes: Int
        public var seconds: Int?

        /// The latest moment with these hours, minutes and seconds that is not ahead of `now` by more than the clock allowance.
        public func date(near now: Date) -> Date {
            let sinceMidnight = Double(hours * 3600 + minutes * 60 + (seconds ?? 0))
            let midnight = (now.timeIntervalSince1970 / 86400).rounded(.down) * 86400
            let today = Date(timeIntervalSince1970: midnight + sinceMidnight)
            return today > now.addingTimeInterval(WeatherIndex.clockAllowance) ? today.addingTimeInterval(-86400) : today
        }
    }

    /// One application protocol data unit: a product and its time, with the payload after the header.
    public struct APDU: Equatable, Sendable {
        public var productID: Int
        public var stamp: Stamp
        public var payload: [UInt8]
    }

    /// The APDUs of one uplink message.
    public struct Uplink: Equatable, Sendable {
        public var apdus: [APDU]
    }

    /// An Uplink Data message (0x07): 3 bytes of reception time, the 8-byte UAT header, then the application data.
    /// Nil when the header (bit 5 of its seventh byte) says the application data is not valid.
    static func uplink(_ message: [UInt8]) -> Uplink? {
        guard message.count >= 12, message[0] == 0x07, message[10] & 0x20 != 0 else { return nil }
        let data = Array(message[12...])
        var apdus: [APDU] = []
        var at = 0
        // Information frames: 9-bit length, 3 reserved bits, 4-bit type. A zero length ends them.
        while at + 2 <= data.count {
            let length = Int(data[at]) << 1 | Int(data[at + 1] >> 7)
            let type = data[at + 1] & 0x0F
            guard length > 0, at + 2 + length <= data.count else { break }
            if type == 0, let apdu = apdu(data[(at + 2)..<(at + 2 + length)]) { apdus.append(apdu) }
            at += 2 + length
        }
        return Uplink(apdus: apdus)
    }

    /// A frame's data as an APDU. The header is 3 flag bits, an 11-bit product ID, a segmentation flag,
    /// a 2-bit time option and the time, padded to a byte. Segmented APDUs are left out; no weather product here uses them.
    static func apdu(_ frame: ArraySlice<UInt8>) -> APDU? {
        let h = Array(frame.prefix(6))
        guard h.count >= 4 else { return nil }
        let id = Int(h[0] & 0x1F) << 6 | Int(h[1] >> 2)
        guard h[1] & 0x02 == 0 else { return nil }
        let stamp: Stamp
        let size: Int
        switch Int(h[1] & 0x01) << 1 | Int(h[2] >> 7) {
        case 0:
            stamp = Stamp(hours: Int(h[2] & 0x7C) >> 2, minutes: Int(h[2] & 0x03) << 4 | Int(h[3] >> 4))
            size = 4
        case 1:
            guard h.count >= 5 else { return nil }
            stamp = Stamp(hours: Int(h[2] & 0x7C) >> 2, minutes: Int(h[2] & 0x03) << 4 | Int(h[3] >> 4),
                          seconds: Int(h[3] & 0x0F) << 2 | Int(h[4] >> 6))
            size = 5
        case 2:
            guard h.count >= 5 else { return nil }
            stamp = Stamp(month: Int(h[2] & 0x78) >> 3, day: Int(h[2] & 0x07) << 2 | Int(h[3] >> 6),
                          hours: Int(h[3] & 0x3E) >> 1, minutes: Int(h[3] & 0x01) << 5 | Int(h[4] >> 3))
            size = 5
        default:
            guard h.count >= 6 else { return nil }
            stamp = Stamp(month: Int(h[2] & 0x78) >> 3, day: Int(h[2] & 0x07) << 2 | Int(h[3] >> 6),
                          hours: Int(h[3] & 0x3E) >> 1, minutes: Int(h[3] & 0x01) << 5 | Int(h[4] >> 3),
                          seconds: Int(h[4] & 0x07) << 3 | Int(h[5] >> 5))
            size = 6
        }
        return APDU(productID: id, stamp: stamp, payload: Array(frame.dropFirst(size)))
    }

    // MARK: DLAC text

    // The 6-bit DLAC alphabet. 0 is the end of text and is skipped; 28 is a tab whose next character counts spaces;
    // 29 is the record separator; 30 a line feed. 27 and 31 have no use in weather text.
    private static let dlac: [Character?] = [nil] + Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ") + [nil, nil, nil, "\n", nil]
        + Array(" !\"#$%&'()*+,-./0123456789:;<=>?")

    /// The text records in an APDU payload. Each record ends at a separator and the next starts on a byte.
    public static func records(_ payload: [UInt8]) -> [String] {
        var out: [String] = []
        var text = ""
        var tab = false
        var bit = 0
        while bit + 6 <= payload.count * 8 {
            let pair = Int(payload[bit / 8]) << 8 | (bit / 8 + 1 < payload.count ? Int(payload[bit / 8 + 1]) : 0)
            let c = pair >> (10 - bit % 8) & 0x3F
            bit += 6
            if tab {
                text += String(repeating: " ", count: c)
                tab = false
            } else if c == 28 {
                tab = true
            } else if c == 29 {
                out.append(text)
                text = ""
                bit = (bit + 7) / 8 * 8
            } else if let ch = dlac[c] {
                text.append(ch)
            }
        }
        return out
    }
}
