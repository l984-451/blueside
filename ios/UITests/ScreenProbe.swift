import Network
import os
import UIKit
import XCTest

/// Steps shared by UI tests: launching, saving pictures, reading pixels, asking for location changes.
@MainActor enum Screen {
    static let dfw = "32.8968,-97.0380"
    // Nothing listens on this port, so a fetch fails at once, as it does with no network.
    static let deadServer = "http://127.0.0.1:1"
    static var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    /// Types capital letters by tapping the screen keyboard's keys where it shows them.
    // Sent keys count as a hardware keyboard and hide the screen keyboard, which can leave the runner waiting.
    static func type(_ text: String, into field: XCUIElement, _ app: XCUIApplication) {
        field.tap()
        let keys = text.map { app.keyboards.keys[String($0)] }
        guard keys[0].waitForExistence(timeout: 3), keys.allSatisfy(\.isHittable) else { return field.typeText(text) }
        keys.forEach { $0.tap() }
    }

    /// Opens Settings at Downloads. On a phone the sidebar shows first.
    static func openDownloads(_ app: XCUIApplication) {
        app.buttons["settings-button"].tap()
        let page = app.buttons["settings-downloads"]
        if page.waitForExistence(timeout: 3), !app.descendants(matching: .any)["downloads-sheet"].exists { page.tap() }
    }

    /// Opens the route editor from the drawer's active row and removes the editor's first waypoint.
    static func removeFirstWaypoint(_ app: XCUIApplication) {
        app.descendants(matching: .any)["direct-row"].tap()
        let point = app.descendants(matching: .any)["route-point-0"]
        XCTAssertTrue(point.waitForExistence(timeout: 10), "the route editor did not open")
        point.swipeLeft()
        app.buttons["Remove"].tap()
    }

    /// Opens one Downloads category, such as charts or nav, from the Downloads list.
    static func openCategory(_ app: XCUIApplication, _ id: String) {
        let row = app.buttons["downloads-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(id) row in Downloads")
        row.tap()
    }

    /// Every button on screen is at least 44 points, and a map button 56. The system sizes its own bars and keyboard.
    // One snapshot of the tree, because asking element by element runs past the test time limit.
    static func assertTargets(_ app: XCUIApplication) {
        guard let root = try? app.snapshot() else { return XCTFail("no snapshot") }
        let map = ["search-button", "route-button", "layers-button", "settings-button", "night-button", "tracking-button"]
        var buttons: [XCUIElementSnapshot] = []
        var system: [CGRect] = []
        func walk(_ node: XCUIElementSnapshot) {
            if [.navigationBar, .keyboard].contains(node.elementType) { system.append(node.frame); return }
            if node.elementType == .button { buttons.append(node) }
            node.children.forEach(walk)
        }
        walk(root)
        let window = root.frame
        // MapLibre keeps its own attribution and hidden compass buttons in the tree; the sheet grabber is the system's.
        for button in buttons where window.contains(button.frame) && !button.frame.isEmpty
            && !button.identifier.hasPrefix("assistant") && !["About this map", "Compass", "Sheet Grabber"].contains(button.label)
            && !system.contains(where: { $0.contains(button.frame) }) {
            let least: CGFloat = map.contains(button.identifier) ? 56 : 44
            XCTAssertGreaterThanOrEqual(min(button.frame.width, button.frame.height), least - 0.5,
                                        "\(button.identifier) \(button.label) is \(button.frame.size)")
        }
    }

    private static var blankSize = 0

    /// Launches in portrait, so a simulator left turned by an earlier run cannot change a result.
    static func launch(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-probes", "1", "-reset", "1"]
        app.launch()
        return app
    }

    /// Saves the screen as <name>-<device>.png in the folder the test run names.
    @discardableResult
    static func save(_ name: String, _ shot: XCUIScreenshot = XCUIScreen.main.screenshot()) throws -> XCUIScreenshot {
        if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try shot.pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(device).png"))
        }
        return shot
    }

    /// PNG size a drawn map must exceed: 2.25 times the same screen with nothing on it. Call it before launching.
    // The palest chart measured, an IFR area chart on a phone, comes to 3.5 times the blank screen.
    static func drawnFloor() -> Int {
        if blankSize == 0 {
            // A fixed view, so the blank never holds a followed aircraft symbol.
            let app = launch(["-offline", "1", "-center", dfw, "-zoom", "10"])
            XCTAssertTrue(app.staticTexts["no-chart-label"].waitForExistence(timeout: 20))
            blankSize = XCUIScreen.main.screenshot().pngRepresentation.count
        }
        return blankSize * 9 / 4
    }

    /// Waits for tiles, saves the screen, and fails if it is no busier than a blank map.
    @discardableResult
    static func chartShot(_ name: String, floor: Int) throws -> XCUIScreenshot {
        var shot = XCUIScreen.main.screenshot()
        let deadline = Date().addingTimeInterval(15)
        while shot.pngRepresentation.count <= floor, Date() < deadline {
            sleep(1)
            shot = XCUIScreen.main.screenshot()
        }
        try save(name, shot)
        print("\(name) png \(shot.pngRepresentation.count) floor \(floor)")
        XCTAssertGreaterThan(shot.pngRepresentation.count, floor, "\(name): the map did not draw")
        return shot
    }

    /// Mean brightness from 0 to 1.
    static func brightness(_ shot: XCUIScreenshot) -> Double {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(shot.image.cgImage!, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(side * side * 255)
    }

    /// Counts strong blue and mid gray pixels in the middle eighth of the screen, where a followed aircraft sits.
    static func centerColors(_ shot: XCUIScreenshot) -> (blue: Int, gray: Int) {
        let image = shot.image.cgImage!
        let side = min(image.width, image.height) / 8
        let box = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        let crop = image.cropping(to: box)!
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        var blue = 0
        var gray = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index]), green = Int(pixels[index + 1]), blueValue = Int(pixels[index + 2])
            if blueValue > 200, red < 100, blueValue - green > 60 { blue += 1 }
            if abs(red - green) < 14, abs(green - blueValue) < 14, (110...180).contains(red) { gray += 1 }
        }
        return (blue, gray)
    }

    /// True when most of the middle of the screen is the flat gray a map shows where it has no tile.
    static func centerIsBlank(_ shot: XCUIScreenshot) -> Bool {
        let image = shot.image.cgImage!
        let side = min(image.width, image.height) / 8
        return centerColors(shot).gray > side * side / 2
    }

    /// Contrast from 1 to 21 between the ink and the ground inside an element's frame, cut in by a share of each side.
    // The ground is the median brightness. The ink is the 2nd or 98th percentile, whichever lies further from it.
    static func contrast(_ element: XCUIElement, in shot: XCUIScreenshot, inset: CGFloat = 0) -> Double {
        let image = upright(shot)
        let scale = shot.image.scale
        let frame = element.frame
        let box = frame.insetBy(dx: frame.width * inset, dy: frame.height * inset)
            .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        guard let crop = image.cropping(to: box), crop.width > 0, crop.height > 0 else { return 1 }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                bytesPerRow: crop.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        func linear(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let values = stride(from: 0, to: pixels.count, by: 4).map {
            0.2126 * linear(pixels[$0]) + 0.7152 * linear(pixels[$0 + 1]) + 0.0722 * linear(pixels[$0 + 2])
        }.sorted()
        let ground = values[values.count / 2]
        let low = values[values.count / 50], high = values[values.count - 1 - values.count / 50]
        let ink = abs(low - ground) > abs(high - ground) ? low : high
        return (max(ink, ground) + 0.05) / (min(ink, ground) + 0.05)
    }

    /// The shot's pixels turned to match element frames, which follow the interface, not the portrait screen.
    static func upright(_ shot: XCUIScreenshot) -> CGImage {
        let raw = shot.image.cgImage!
        let turn: UIImage.Orientation
        switch XCUIDevice.shared.orientation {
        case .landscapeLeft: turn = .left
        case .landscapeRight: turn = .right
        case .portraitUpsideDown: turn = .down
        default: return raw
        }
        guard raw.height > raw.width || turn == .down else { return raw }
        let image = UIImage(cgImage: raw, scale: 1, orientation: turn)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage!
    }

    /// Fails when the words inside an element measure under 4.5 to 1 against what is behind them.
    static func readable(_ element: XCUIElement, _ shot: XCUIScreenshot, inset: CGFloat = 0, minimum: Double = 4.5,
                         file: StaticString = #filePath, line: UInt = #line) {
        let ratio = contrast(element, in: shot, inset: inset)
        print("contrast \(element.identifier) \(String(format: "%.1f", ratio))")
        XCTAssertGreaterThanOrEqual(ratio, minimum, element.identifier, file: file, line: line)
    }

    /// Asks the script running beside the tests to start or clear the simulated track, and waits until it has.
    static func request(_ name: String) throws {
        let folder = try XCTUnwrap(ProcessInfo.processInfo.environment["SHOT_DIR"])
        let file = URL(fileURLWithPath: folder).appendingPathComponent("request-" + name)
        try Data().write(to: file)
        let deadline = Date().addingTimeInterval(15)
        while FileManager.default.fileExists(atPath: file.path), Date() < deadline { usleep(200_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing answered the \(name) request")
    }

    /// Polls until the check holds or the time runs out.
    static func wait(_ seconds: TimeInterval, until check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !check(), Date() < deadline { usleep(200_000) }
        return check()
    }
}

/// A chart host with no list: it answers every request with 404 and counts the asks for the list.
final class EmptyChartHost: Sendable {
    private let listener: NWListener
    private let asked = OSAllocatedUnfairLock(initialState: 0)

    var listRequests: Int { asked.withLock { $0 } }

    /// The address to launch the app with. The port is known once the listener is ready.
    var address: String {
        for _ in 0..<50 where (listener.port?.rawValue ?? 0) == 0 { usleep(100_000) }
        return "http://127.0.0.1:\(listener.port?.rawValue ?? 0)"
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [asked] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                if String(decoding: data ?? Data(), as: UTF8.self).contains("manifest.json") {
                    asked.withLock { $0 += 1 }
                }
                let answer = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(answer.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
    }

    func stop() { listener.cancel() }
}
