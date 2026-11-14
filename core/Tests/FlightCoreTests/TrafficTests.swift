import Foundation
import Testing
@testable import FlightCore

private let t0 = Date(timeIntervalSince1970: 1_790_812_800)

// The spec's own examples: a heartbeat frame and a traffic report (N825V, 44.90708 -122.99488, 5,000 ft).
private let specHeartbeat: [UInt8] = [0x7E, 0x00, 0x81, 0x41, 0xDB, 0xD0, 0x08, 0x02, 0xB3, 0x8B, 0x7E]
private let specTraffic: [UInt8] = [0x14, 0x00, 0xAB, 0x45, 0x49, 0x1F, 0xEF, 0x15, 0xA8, 0x89, 0x78, 0x0F, 0x09, 0xA9,
                                    0x07, 0xB0, 0x01, 0x20, 0x01, 0x4E, 0x38, 0x32, 0x35, 0x56, 0x20, 0x20, 0x20, 0x00]

/// Builds a report the way a receiver does, for the cases the spec example does not cover.
func gdl90Report(id: UInt8 = 0x14, address: UInt32, latitude: Double, longitude: Double, altitudeFt: Int?,
                 track: Double? = nil, knots: Int? = nil, fpm: Int? = nil, callsign: String = "", nic: UInt8 = 8) -> [UInt8] {
    func semicircles(_ degrees: Double) -> [UInt8] {
        let v = Int((degrees * Double(1 << 23) / 180).rounded()) & 0xFF_FFFF
        return [UInt8(v >> 16), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
    let alt = altitudeFt.map { ($0 + 1000) / 25 } ?? 0xFFF
    let misc: UInt8 = 0x08 | (track == nil ? 0 : 1)
    let h = knots ?? 0xFFF
    let v = fpm.map { ($0 / 64) & 0xFFF } ?? 0x800
    let name = Array((callsign + "        ").utf8.prefix(8))
    return [id, 0x00, UInt8(address >> 16), UInt8(address >> 8 & 0xFF), UInt8(address & 0xFF)]
        + semicircles(latitude) + semicircles(longitude)
        + [UInt8(alt >> 4), UInt8(alt & 0x0F) << 4 | misc, nic << 4 | 9,
           UInt8(h >> 4), UInt8(h & 0x0F) << 4 | UInt8(v >> 8), UInt8(v & 0xFF),
           UInt8((track ?? 0) * 256 / 360) , 1] + name + [0]
}

func gdl90Heartbeat(gps: Bool) -> [UInt8] { [0x00, gps ? 0x81 : 0x01, 0x01, 0, 0, 0, 0] }

@Suite struct GDL90Tests {
    @Test func crcMatchesTheSpecExample() {
        #expect(GDL90.crc([0x00, 0x81, 0x41, 0xDB, 0xD0, 0x08, 0x02]) == 0x8BB3)
        #expect(GDL90.frame([0x00, 0x81, 0x41, 0xDB, 0xD0, 0x08, 0x02]) == specHeartbeat)
    }

    @Test func heartbeatDecodes() {
        let messages = GDL90.messages(in: specHeartbeat)
        #expect(messages.count == 1)
        #expect(GDL90.decode(messages[0]) == .heartbeat(.init(gpsValid: true, utcValid: true, secondsOfDay: 53_467)))
        // Bit 7 of the second status byte is bit 16 of the time stamp.
        #expect(GDL90.decode([0x00, 0x01, 0x80, 0x00, 0x00, 0, 0]) == .heartbeat(.init(gpsValid: false, utcValid: false, secondsOfDay: 65_536)))
    }

    @Test func specTrafficReportDecodes() throws {
        guard case .traffic(let r) = GDL90.decode(GDL90.messages(in: GDL90.frame(specTraffic))[0]) else { Issue.record(); return }
        #expect(r.address == 0xAB4549)
        #expect(abs(try #require(r.coordinate).latitude - 44.90708) < 0.0001)
        #expect(abs(try #require(r.coordinate).longitude - -122.99488) < 0.0001)
        #expect(r.altitudeFt == 5000)
        #expect(r.airborne)
        #expect(r.nic == 10 && r.nacp == 9)
        #expect(r.groundspeedKt == 123)
        #expect(r.verticalFpm == 64)
        #expect(r.track == 45)
        #expect(r.emitter == 1)
        #expect(r.callsign == "N825V")
        #expect(!r.alert)
    }

    @Test func reportFieldsAtTheirLimits() {
        var m = gdl90Report(address: 1, latitude: -33.5, longitude: 151.25, altitudeFt: nil, fpm: -1280)
        guard case .traffic(let r) = GDL90.decode(m) else { Issue.record(); return }
        #expect(r.altitudeFt == nil && r.groundspeedKt == nil && r.track == nil)
        #expect(r.verticalFpm == -1280)
        #expect(abs(r.coordinate!.latitude - -33.5) < 0.0001 && abs(r.coordinate!.longitude - 151.25) < 0.0001)
        m[11] = 0; m[12] &= 0x0F // -1,000 ft, the lowest altitude
        m[15] = 0x08; m[16] = 0x00 // 0x800: no vertical rate
        guard case .traffic(let low) = GDL90.decode(m) else { Issue.record(); return }
        #expect(low.altitudeFt == -1000 && low.verticalFpm == nil)
        // NIC 0 at 0,0 is a report with no position.
        guard case .traffic(let none) = GDL90.decode(gdl90Report(address: 2, latitude: 0, longitude: 0, altitudeFt: 1000, nic: 0)) else { Issue.record(); return }
        #expect(none.coordinate == nil)
        #expect(GDL90.decode(Array(m.prefix(27))) == nil)
    }

    // The low two bits of the misc field: 1 true track, 2 magnetic heading, 3 true heading.
    @Test func onlyATrueTrackIsATrack() {
        let m = gdl90Report(address: 1, latitude: 33.5, longitude: -86.8, altitudeFt: 3000, track: 90)
        func track(_ kind: UInt8) -> Double? {
            var r = m
            r[12] = r[12] & 0xFC | kind
            guard case .traffic(let report) = GDL90.decode(r) else { return -1 }
            return report.track
        }
        #expect(track(1) == 90 && track(0) == nil && track(2) == nil && track(3) == nil)
    }

    @Test func geometricAltitudeAndDevice() {
        #expect(GDL90.decode([0x0B, 0x02, 0x58, 0x00, 0x0A]) == .ownshipAltitude(3000))
        #expect(GDL90.decode([0x0B, 0xFF, 0xF6, 0x00, 0x0A]) == .ownshipAltitude(-50))
        let id: [UInt8] = [0x65, 0x00, 0x01] + [UInt8](repeating: 0xFF, count: 8) + Array("Stratux ".utf8)
            + Array("Stratux 3       ".utf8) + [0, 0, 0, 1]
        #expect(GDL90.decode(id) == .device(.init(name: "Stratux", longName: "Stratux 3", serial: nil, altitudeMSL: true)))
        #expect(GDL90.decode([0x65, 0x01, 0, 0]) == .other(0x65))
        #expect(GDL90.decode([0xCC, 1, 2]) == .other(0xCC))
    }

    @Test func stuffingRoundTripsFlagAndEscapeBytes() {
        let message: [UInt8] = [0x14, 0x7E, 0x7D, 0x20, 0x5E, 0x5D]
        let framed = GDL90.frame(message)
        #expect(!framed.dropFirst().dropLast().contains(0x7E))
        #expect(framed.contains(0x7D))
        #expect(GDL90.messages(in: framed) == [message])
        // A CRC whose own bytes need escaping: search for one and round-trip it.
        let escapedCRC = (0..<256).lazy.map { [0x14, UInt8($0)] }.first { m in
            let c = GDL90.crc(m)
            return [UInt8(c & 0xFF), UInt8(c >> 8)].contains { $0 == 0x7E || $0 == 0x7D }
        }!
        #expect(GDL90.messages(in: GDL90.frame(escapedCRC)) == [escapedCRC])
    }

    @Test func badFramesAreDropped() {
        var corrupt = specHeartbeat
        corrupt[3] ^= 0x01
        #expect(GDL90.messages(in: corrupt).isEmpty)
        // A dangling escape right before the flag.
        #expect(GDL90.messages(in: [0x7E, 0x00, 0x7D, 0x7E]).isEmpty)
        // Too short to hold a CRC, and noise between flags.
        #expect(GDL90.messages(in: [0x7E, 0x00, 0x7E, 0x7E, 0x7E]).isEmpty)
        // Several frames in one datagram, with a bad one between, keep the good ones.
        let two = specHeartbeat + corrupt + GDL90.frame(specTraffic)
        #expect(GDL90.messages(in: two).count == 2)
    }
}

@Suite struct TrafficStoreTests {
    let bhm = Coordinate(latitude: 33.5629, longitude: -86.7535)
    var me: Position { Position(latitude: bhm.latitude, longitude: bhm.longitude, courseDegrees: 90, speedMetersPerSecond: 50,
                                altitudeMeters: 3000 / 3.28084, timestamp: t0)! }

    func feed(_ store: inout TrafficStore, _ messages: [UInt8]..., at: Date = t0) {
        store.receive(datagram: messages.flatMap(GDL90.frame), at: at)
    }

    @Test func mergesByAddressAndAgesOut() {
        var store = TrafficStore()
        feed(&store, gdl90Report(address: 0xA1, latitude: 33.6, longitude: -86.7, altitudeFt: 4000))
        feed(&store, gdl90Report(address: 0xA1, latitude: 33.61, longitude: -86.7, altitudeFt: 4100), at: t0 + 1)
        feed(&store, gdl90Report(address: 0xA2, latitude: 33.7, longitude: -86.7, altitudeFt: 4100), at: t0 + 1)
        #expect(store.targetCount == 2)
        #expect(store.shown(reference: nil, now: t0 + 1).first { $0.address == 0xA1 }?.coordinate.latitude ?? 0 > 33.605)
        #expect(store.nextChange(after: t0 + 1) == t0 + 1 + TrafficStore.staleAfter + NextChange.past)
        #expect(store.shown(reference: nil, now: t0 + 11.1).allSatisfy { $0.isStale })
        #expect(store.shown(reference: nil, now: t0 + 61.1).isEmpty)
        #expect(store.nextChange(after: t0 + 30) == t0 + 1 + TrafficStore.dropAfter + NextChange.past)
        store.prune(now: t0 + 62)
        #expect(store.targetCount == 0)
        #expect(store.nextChange(after: t0 + 62) == nil)
    }

    // A flood of addresses stops at the cap; messages never prune, the once-a-second batch does.
    @Test func newAddressesPastTheCapAreIgnoredAndMessagesDoNotPrune() {
        var store = TrafficStore()
        for n in 0..<(TrafficStore.targetLimit + 100) {
            feed(&store, gdl90Report(address: UInt32(0x100 + n), latitude: 33.6, longitude: -86.7, altitudeFt: 4000))
        }
        #expect(store.targetCount == TrafficStore.targetLimit)
        // A target already held still updates at the cap.
        feed(&store, gdl90Report(address: 0x100, latitude: 33.7, longitude: -86.7, altitudeFt: 4000), at: t0 + 30)
        #expect(store.shown(reference: nil, now: t0 + 30).first { $0.address == 0x100 }?.coordinate.latitude ?? 0 > 33.65)
        feed(&store, gdl90Report(address: 0xA1, latitude: 33.6, longitude: -86.7, altitudeFt: 4000), at: t0 + 61)
        #expect(store.targetCount == TrafficStore.targetLimit)
        store.prune(now: t0 + 61)
        #expect(store.targetCount == 1)
        feed(&store, gdl90Report(address: 0xA1, latitude: 33.6, longitude: -86.7, altitudeFt: 4000), at: t0 + 61)
        #expect(store.targetCount == 2)
    }

    @Test func receiverOwnAircraftIsNotTraffic() {
        var store = TrafficStore()
        feed(&store, gdl90Report(id: 0x0A, address: 0xC0FFEE, latitude: 33.56, longitude: -86.75, altitudeFt: 3000),
             gdl90Report(address: 0xC0FFEE, latitude: 33.56, longitude: -86.75, altitudeFt: 3000),
             gdl90Report(address: 0xA1, latitude: 0, longitude: 0, altitudeFt: 3000, nic: 0))
        #expect(store.shown(reference: me, now: t0).isEmpty)
    }

    @Test func relativeAltitudeAndDataBlock() {
        var store = TrafficStore()
        feed(&store, gdl90Report(id: 0x0A, address: 0x1, latitude: bhm.latitude, longitude: bhm.longitude, altitudeFt: 3000),
             gdl90Report(address: 0xA1, latitude: 33.9, longitude: -86.75, altitudeFt: 3500, fpm: 640),
             gdl90Report(address: 0xA2, latitude: 33.9, longitude: -86.70, altitudeFt: 1800, fpm: -1000),
             gdl90Report(address: 0xA3, latitude: 33.9, longitude: -86.65, altitudeFt: 3025))
        let shown = Dictionary(uniqueKeysWithValues: store.shown(reference: me, now: t0).map { ($0.address, $0) })
        #expect(shown[0xA1]?.relativeFt == 500 && shown[0xA1]?.label == "+05↑")
        #expect(shown[0xA2]?.label == "-12↓")
        #expect(shown[0xA3]?.label == "00")
    }

    // Targets report pressure altitude. GPS or geometric altitude for ownship would be off by the altimeter setting.
    @Test func relativeAltitudeNeedsOwnshipPressureAltitude() {
        var bare = TrafficStore()
        feed(&bare, gdl90Report(address: 0xA1, latitude: 33.9, longitude: -86.75, altitudeFt: 2000), [0x0B, 0x02, 0x6C, 0x00, 0x0A])
        #expect(bare.shown(reference: me, now: t0).first.map { $0.relativeFt == nil && $0.label == "" } == true)
        feed(&bare, gdl90Report(id: 0x0A, address: 0x1, latitude: bhm.latitude, longitude: bhm.longitude, altitudeFt: nil))
        #expect(bare.shown(reference: me, now: t0).first?.relativeFt == nil)
        feed(&bare, gdl90Report(id: 0x0A, address: 0x1, latitude: bhm.latitude, longitude: bhm.longitude, altitudeFt: 3000))
        #expect(bare.shown(reference: me, now: t0).first?.label == "-10")
    }

    @Test func alertLevels() {
        var store = TrafficStore()
        let east1 = Geo.destination(from: bhm, bearingTrue: 90, distanceNM: 1.5)!
        let north5 = Geo.destination(from: bhm, bearingTrue: 0, distanceNM: 5)!
        let north10 = Geo.destination(from: bhm, bearingTrue: 0, distanceNM: 10)!
        let west3 = Geo.destination(from: bhm, bearingTrue: 270, distanceNM: 3)!
        feed(&store, gdl90Report(id: 0x0A, address: 0x1, latitude: bhm.latitude, longitude: bhm.longitude, altitudeFt: 3000),
             gdl90Report(address: 0xA1, latitude: east1.latitude, longitude: east1.longitude, altitudeFt: 3400),
             gdl90Report(address: 0xA2, latitude: east1.latitude, longitude: east1.longitude, altitudeFt: 4000),
             gdl90Report(address: 0xA3, latitude: north5.latitude, longitude: north5.longitude, altitudeFt: 3900),
             gdl90Report(address: 0xA4, latitude: north10.latitude, longitude: north10.longitude, altitudeFt: 3000),
             // Overtaking from 3 nm behind at 300 kt against ownship's 97 kt: about 53 s to meet.
             gdl90Report(address: 0xA5, latitude: west3.latitude, longitude: west3.longitude, altitudeFt: 3200, track: 90, knots: 300))
        let alerts = Dictionary(uniqueKeysWithValues: store.shown(reference: me, now: t0).map { ($0.address, $0.alert) })
        #expect(alerts[0xA1] == .alert)
        #expect(alerts[0xA2] == .proximate)
        #expect(alerts[0xA3] == .proximate)
        #expect(alerts[0xA4] == .other)
        #expect(alerts[0xA5] == .alert)
        // Most urgent last, so the map draws it on top.
        #expect(store.shown(reference: me, now: t0).last?.alert == .alert)
        #expect(store.shown(reference: nil, now: t0).allSatisfy { $0.alert == .other })
    }

    @Test func receiverStatusAndPosition() throws {
        var store = TrafficStore()
        #expect(!store.status.isConnected(at: t0))
        #expect(store.status.lastMessageText(at: t0) == "Never")
        let id: [UInt8] = [0x65, 0x00, 0x01] + [UInt8](repeating: 0, count: 8) + Array("Sentry  ".utf8)
            + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 0]
        feed(&store, gdl90Heartbeat(gps: false), id,
             gdl90Report(id: 0x0A, address: 0x1, latitude: 33.5, longitude: -86.8, altitudeFt: 3000, track: 180, knots: 100),
             [0x0B, 0x02, 0x6C, 0x00, 0x0A])
        #expect(store.status.name == "Sentry")
        #expect(store.status.isConnected(at: t0 + 5))
        #expect(!store.status.isConnected(at: t0 + 5.1))
        #expect(store.status.nextChange(after: t0) == t0 + 5 + NextChange.past)
        #expect(store.receiverPosition == nil)
        feed(&store, gdl90Heartbeat(gps: true))
        let fix = store.receiverPosition
        #expect(fix?.coordinate.latitude ?? 0 < 33.51)
        // Geometric altitude is above the WGS-84 ellipsoid unless the ID message says MSL; the geoid lies below it here.
        let at = try #require(fix?.coordinate)
        let geoid = try #require(Geoid.height(latitude: at.latitude, longitude: at.longitude))
        #expect(abs((fix?.altitudeFtMSL ?? 0) - (3100 - geoid * 3.28084)) < 0.01)
        #expect((fix?.altitudeFtMSL ?? 0) > 3180)
        var msl = id
        msl[38] = 1
        feed(&store, msl)
        #expect(abs((store.receiverPosition?.altitudeFtMSL ?? 0) - 3100) < 1)
        #expect(abs((fix?.groundspeedKt ?? 0) - 100) < 0.01)
        #expect(abs((fix?.trackTrue ?? 0) - 180) < 2)
        #expect(store.status.lastMessageText(at: t0 + 2) == "Now")
        #expect(store.status.lastMessageText(at: t0 + 30) == "Under a minute ago")
        #expect(store.status.lastMessageText(at: t0 + 125) == "2 min ago")
        #expect(store.status.lastMessageChange(after: t0 + 2) == t0 + 5 + NextChange.past)
        #expect(store.status.lastMessageChange(after: t0 + 30) == t0 + 60 + NextChange.past)
    }

    @Test func ownshipSourceChoice() {
        let device = me
        var receiver = me
        receiver.coordinate.latitude += 0.01
        #expect(OwnshipSource.auto.choose(device: device, receiver: receiver, now: t0) == receiver)
        #expect(OwnshipSource.auto.choose(device: device, receiver: receiver, now: t0 + 6) == device)
        #expect(OwnshipSource.auto.choose(device: device, receiver: nil, now: t0) == device)
        #expect(OwnshipSource.device.choose(device: device, receiver: receiver, now: t0) == device)
        #expect(OwnshipSource.receiver.choose(device: device, receiver: nil, now: t0) == nil)
    }

    @Test func geoJSONCarriesTheSymbolFields() throws {
        var store = TrafficStore()
        feed(&store, gdl90Report(id: 0x0A, address: 0x1, latitude: bhm.latitude, longitude: bhm.longitude, altitudeFt: 3000),
             gdl90Report(address: 0xA1, latitude: 33.6, longitude: -86.7, altitudeFt: 3500, track: 45, callsign: "N12AB"))
        let json = String(decoding: TrafficStore.geoJSON(store.shown(reference: me, now: t0)), as: UTF8.self)
        #expect(json.contains(#""callsign":"N12AB""#))
        #expect(json.contains(#""label":"+05""#))
        #expect(json.contains(#""track":45"#))
        #expect(json.contains(#""stale":0"#))
        #expect(json.contains(#""labelIcon":"traffic-label-proximate-+05""#))
        #expect(json.contains(#""icon":"traffic-proximate""#))
    }

    // A target with no true track gets a circle that never turns, whatever kind of heading it reports.
    @Test func aTargetWithNoTrackGetsACircle() throws {
        var heading = gdl90Report(address: 0xA3, latitude: 33.6, longitude: -86.7, altitudeFt: 3500, track: 120)
        heading[12] = heading[12] & 0xFC | 3
        var store = TrafficStore()
        feed(&store, gdl90Report(id: 0x0A, address: 0x1, latitude: bhm.latitude, longitude: bhm.longitude, altitudeFt: 3000),
             gdl90Report(address: 0xA1, latitude: 33.6, longitude: -86.7, altitudeFt: 3500, track: 45),
             gdl90Report(address: 0xA2, latitude: 33.6, longitude: -86.7, altitudeFt: 3500), heading)
        let shown = store.shown(reference: me, now: t0).reduce(into: [UInt32: TrafficShown]()) { $0[$1.address] = $1 }
        #expect(shown[0xA1].map(TrafficStore.icon) == "traffic-proximate" && shown[0xA1]?.track == 45)
        for address: UInt32 in [0xA2, 0xA3] {
            #expect(shown[address].map(TrafficStore.icon) == "traffic-proximate-circle" && shown[address]?.track == nil)
        }
        #expect(TrafficStore.icon(.other, directed: false) == "traffic-other-circle")
        let json = String(decoding: TrafficStore.geoJSON(Array(shown.values)), as: UTF8.self)
        #expect(json.components(separatedBy: #""track":0"#).count == 3)
    }
}
