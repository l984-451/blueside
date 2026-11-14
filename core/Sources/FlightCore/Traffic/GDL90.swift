/// GDL 90 as ADS-B receivers send it over UDP port 4000 (FAA 560-1058-00 Rev A, plus device ID message 0x65).
public enum GDL90 {
    public static let port: UInt16 = 4000

    /// Heartbeat (0x00).
    public struct Heartbeat: Equatable, Sendable {
        public var gpsValid: Bool
        public var utcValid: Bool
        /// Seconds since 0000Z.
        public var secondsOfDay: Int
    }

    /// Ownship (0x0A) or traffic (0x14) report.
    public struct Report: Equatable, Sendable {
        public var address: UInt32
        public var addressType: UInt8
        public var alert: Bool
        /// Nil when the report carries no position (NIC 0 with zero latitude and longitude).
        public var coordinate: Coordinate?
        /// Pressure altitude, nil when invalid.
        public var altitudeFt: Int?
        public var airborne: Bool
        public var nic: UInt8
        public var nacp: UInt8
        public var groundspeedKt: Int?
        public var verticalFpm: Int?
        /// Degrees true, nil unless the report gives a true track (not a heading).
        public var track: Double?
        public var emitter: UInt8
        public var callsign: String
        public var priority: UInt8
    }

    /// Device ID, message 0x65 with sub-ID 0x00: the device's names, serial number and altitude datum.
    public struct Device: Equatable, Sendable {
        public var name: String
        public var longName: String
        public var serial: UInt64?
        /// True when the device's geometric altitude is MSL; false means WGS-84 ellipsoid.
        public var altitudeMSL: Bool
    }

    public enum Message: Equatable, Sendable {
        case heartbeat(Heartbeat)
        case ownship(Report)
        /// Ownship geometric altitude in feet (0x0B).
        case ownshipAltitude(Int)
        case traffic(Report)
        case device(Device)
        /// FIS-B weather from a ground station (0x07).
        case uplink(FISB.Uplink)
        /// A message this decoder reads past, by ID.
        case other(UInt8)
    }

    // MARK: Framing

    private static let table: [UInt16] = (0..<256).map { i in
        var crc = UInt16(i) << 8
        for _ in 0..<8 { crc = (crc << 1) ^ (crc & 0x8000 != 0 ? 0x1021 : 0) }
        return crc
    }

    /// The spec's CRC-16-CCITT over a clear message (ID and data).
    public static func crc(_ bytes: some Sequence<UInt8>) -> UInt16 {
        bytes.reduce(UInt16(0)) { crc, byte in table[Int(crc >> 8)] ^ (crc << 8) ^ UInt16(byte) }
    }

    /// One message framed for the wire: CRC appended LSB first, 0x7D and 0x7E escaped, flags around it.
    public static func frame(_ message: [UInt8]) -> [UInt8] {
        let crc = crc(message)
        var out: [UInt8] = [0x7E]
        for byte in message + [UInt8(crc & 0xFF), UInt8(crc >> 8)] {
            if byte == 0x7E || byte == 0x7D { out += [0x7D, byte ^ 0x20] } else { out.append(byte) }
        }
        return out + [0x7E]
    }

    /// The clear messages in a datagram. Frames with a bad CRC or a dangling escape are dropped.
    public static func messages(in datagram: some Sequence<UInt8>) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var frame: [UInt8] = []
        var escaped = false
        for byte in datagram {
            if byte == 0x7E {
                if !escaped, frame.count >= 3 {
                    let body = Array(frame.dropLast(2))
                    if crc(body) == UInt16(frame[frame.count - 2]) | UInt16(frame[frame.count - 1]) << 8 { out.append(body) }
                }
                (frame, escaped) = ([], false)
            } else if escaped {
                frame.append(byte ^ 0x20)
                escaped = false
            } else if byte == 0x7D {
                escaped = true
            } else {
                frame.append(byte)
            }
        }
        return out
    }

    // MARK: Messages

    public static func decode(_ m: [UInt8]) -> Message? {
        guard let id = m.first else { return nil }
        switch id {
        case 0x00:
            guard m.count >= 7 else { return nil }
            let seconds = Int(m[2] >> 7) << 16 | Int(m[4]) << 8 | Int(m[3])
            return .heartbeat(Heartbeat(gpsValid: m[1] & 0x80 != 0, utcValid: m[2] & 0x01 != 0, secondsOfDay: seconds))
        case 0x0A, 0x14:
            guard m.count >= 28 else { return nil }
            let report = report(m)
            return id == 0x0A ? .ownship(report) : .traffic(report)
        case 0x0B:
            guard m.count >= 3 else { return nil }
            return .ownshipAltitude(Int(Int16(bitPattern: UInt16(m[1]) << 8 | UInt16(m[2]))) * 5)
        case 0x07:
            return FISB.uplink(m).map { .uplink($0) } ?? .other(id)
        case 0x65:
            guard m.count >= 39, m[1] == 0x00 else { return .other(id) }
            let serial = m[3...10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return .device(Device(name: text(m[11...18]), longName: text(m[19...34]),
                                  serial: serial == .max ? nil : serial, altitudeMSL: m[38] & 0x01 != 0))
        default:
            return .other(id)
        }
    }

    private static func report(_ m: [UInt8]) -> Report {
        let latitude = degrees(m[5], m[6], m[7])
        let longitude = degrees(m[8], m[9], m[10])
        let nic = m[13] >> 4
        let altitude = Int(m[11]) << 4 | Int(m[12] >> 4)
        let misc = m[12] & 0x0F
        let speed = Int(m[14]) << 4 | Int(m[15] >> 4)
        let vertical = Int(m[15] & 0x0F) << 8 | Int(m[16])
        let place = nic == 0 && latitude == 0 && longitude == 0 ? nil : Coordinate(latitude: latitude, longitude: longitude)
        return Report(address: UInt32(m[2]) << 16 | UInt32(m[3]) << 8 | UInt32(m[4]),
                      addressType: m[1] & 0x0F, alert: m[1] >> 4 == 1,
                      coordinate: place.flatMap { (-90...90).contains($0.latitude) ? $0 : nil },
                      altitudeFt: altitude == 0xFFF ? nil : altitude * 25 - 1000,
                      airborne: misc & 0x08 != 0, nic: nic, nacp: m[13] & 0x0F,
                      groundspeedKt: speed == 0xFFF ? nil : speed,
                      // 12-bit two's complement in 64 fpm steps; 0x800 means no data.
                      verticalFpm: vertical == 0x800 ? nil : (vertical >= 0x800 ? vertical - 0x1000 : vertical) * 64,
                      // Type 1 is true track. Types 2 and 3 are headings, left out: closure and ownship course use track.
                      track: misc & 0x03 == 1 ? Double(m[17]) * 360 / 256 : nil,
                      emitter: m[18], callsign: text(m[19...26]), priority: m[27] >> 4)
    }

    // 24-bit two's complement semicircles.
    private static func degrees(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Double {
        var value = Int(a) << 16 | Int(b) << 8 | Int(c)
        if value & 0x80_0000 != 0 { value -= 0x100_0000 }
        return Double(value) * 180 / Double(1 << 23)
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self).trimmed
    }
}
