import Network
import XCTest

final class TrafficUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // One second of a receiver near KBHM, from tools/gdl90sim.py: heartbeat with GPS, device ID, ownship at
    // 3,500 ft and four targets, one of them 1.2 nm away and 300 ft above. The proximate one reports no track.
    static let datagram = Data(hex: """
        7e00810100000000bc9c7e7e650001ffffffffffffffff53696d2047444c20426c7565736964652053696d2020202000000001f74d7e\
        7e0a00c0ffee17ea13c24f020b498906400040014e314253202020200075047e7e0b02bc000acef07e7e1400a1b2c317e841c252cb0c\
        098906eff5ce014e313233414220200042637e7e1400a2b3c417f496c2564c0d888908c00040014e3435364344202000b0ee7e7e1400\
        a3b4c517dc6cc2329b05c9890dc0125c01535741313233342000f2737e7e1400a4b5c6180af2c2480c16898912c000c00144414c3838\
        202020007c927e
        """)

    /// Sends the datagram to the app once a second, as a receiver on the Wi-Fi would.
    private func transmit(port: UInt16, seconds: Int) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection.start(queue: .global())
        for _ in 0..<seconds {
            connection.send(content: Self.datagram, completion: .idempotent)
            sleep(1)
        }
        connection.cancel()
    }

    @MainActor func testReceiverTrafficShowsOnTheMapAndInSettings() throws {
        let port: UInt16 = 4321
        let app = Screen.launch(["-offline", "1", "-center", "33.6296,-86.7535", "-zoom", "10", "-gdl90Port", "\(port)"])
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        let probe = app.staticTexts["map-traffic"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        DispatchQueue.global().async { [self] in transmit(port: port, seconds: 12) }
        XCTAssertTrue(Screen.wait(10) { probe.label == "traffic 4 alert 1" }, probe.label)
        XCTAssertTrue(app.images["receiver-badge"].exists || app.otherElements["receiver-badge"].exists)
        try Screen.save("traffic-map")

        app.buttons["settings-button"].tap()
        let devices = app.descendants(matching: .any)["settings-Devices"]
        XCTAssertTrue(devices.waitForExistence(timeout: 5))
        devices.tap()
        let name = app.descendants(matching: .any)["receiver-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        sleep(1)
        try Screen.save("traffic-settings")
        let text = app.descendants(matching: .any).matching(identifier: "receiver-name").allElementsBoundByIndex.map(\.label)
            + app.descendants(matching: .any).matching(identifier: "receiver-gps").allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(text.contains { $0.contains("Blueside Sim") } && text.contains { $0.contains("Valid") }, "\(text)")
    }
}

private extension Data {
    init(hex: String) {
        let digits = Array(hex.filter(\.isHexDigit))
        self.init(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }
}
