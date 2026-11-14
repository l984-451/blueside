import CoreLocation
import FlightCore
import Foundation
import MapLibre
import SwiftUI
import Testing
import UIKit
@testable import Blueside

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func location(at time: Date, latitude: Double = 32.9, longitude: Double = -97.04,
                      course: Double = 52, speed: Double = 100, altitude: Double = 1000,
                      horizontalAccuracy: Double = 5, verticalAccuracy: Double = 5) -> CLLocation {
    CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
               altitude: altitude, horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy,
               course: course, speed: speed, timestamp: time)
}

private let liveLocation = ProcessInfo.processInfo.environment["LIVE_LOCATION"] == "1"
private let liveParked = ProcessInfo.processInfo.environment["LIVE_PARKED"] == "1"

@Suite @MainActor struct PositionTests {
    @Test func noFixIsStale() {
        let provider = LocationProvider()
        #expect(provider.position == nil)
        #expect(provider.isStale)
    }

    @Test func adsbReceiverFixStandsInAsTheSourceSays() throws {
        let provider = LocationProvider()
        let start = Date()
        provider.receive(location(at: start, horizontalAccuracy: 900), now: start)
        #expect(provider.isApproximate)
        let receiver = try #require(Position(latitude: 33.6, longitude: -86.75, courseDegrees: 90, speedMetersPerSecond: 50,
                                             altitudeMeters: 1000, timestamp: start))
        provider.receiver = receiver
        #expect(provider.position == receiver)
        #expect(!provider.isApproximate && !provider.isStale)
        provider.source = .device
        #expect(provider.position?.coordinate.latitude == 32.9)
        #expect(provider.isApproximate)
        provider.source = .receiver
        provider.receiver = nil
        #expect(provider.position == nil)
    }

    @Test func fixTimeIsTheReceiversNotTheArrivalTime() {
        let provider = LocationProvider()
        provider.receive(location(at: now - 60), now: now)
        #expect(provider.position?.timestamp == now - 60)
        #expect(provider.isStale)
    }

    @Test func freshFixGoesStaleAfterFiveSeconds() {
        let provider = LocationProvider()
        provider.receive(location(at: now), now: now)
        #expect(!provider.isStale)
        provider.recheck(now: now + 4.9)
        #expect(!provider.isStale)
        provider.recheck(now: now + 5.1)
        #expect(provider.isStale)
        #expect(NavText.readout(for: provider.position, now: now + 5.1).groundspeed == "---")
        provider.receive(location(at: now + 6), now: now + 6)
        #expect(!provider.isStale)
    }

    @Test func unknownCourseSpeedAndAltitudeAreNotShownAsZero() {
        let provider = LocationProvider()
        provider.receive(location(at: now, course: -1, speed: -1, verticalAccuracy: -1), now: now)
        #expect(provider.position?.trackTrue == nil)
        #expect(provider.position?.groundspeedKt == nil)
        #expect(provider.position?.altitudeFtMSL == nil)
        #expect(NavText.readout(for: provider.position, now: now)
            == NavText.Readout(groundspeed: "---", track: "---", altitude: "---"))
    }

    @Test func readoutShowsValuesForALiveFix() throws {
        let provider = LocationProvider()
        provider.receive(location(at: now), now: now)
        let fix = try #require(provider.position)
        let shown = NavText.readout(for: fix, now: now + 1)
        #expect(shown.groundspeed == "194" && shown.altitude == "3281")
        // 52 true at this fix, less a few degrees of east variation.
        #expect(shown.track == NavText.bearing(try #require(fix.trackTrue), from: fix.coordinate,
                                               altitudeFt: fix.altitudeFtMSL ?? 0, date: now + 1))
        #expect(shown.track.hasSuffix("°M"))
        let degrees = try #require(Int(shown.track.prefix(3)))
        #expect((46...51).contains(degrees))
    }

    @Test func trackIsMagneticInThreeDigitsWithNorthAs360() throws {
        let provider = LocationProvider()
        let here = Coordinate(latitude: 32.9, longitude: -97.04)
        let east = MagneticModel.declination(at: here, altitudeFt: 1000 / 0.3048, date: now)
        for (course, expected) in [(east + 359.7, "360°M"), (east + 0.2, "360°M"), (east + 7.2, "007°M")] {
            provider.receive(location(at: now, course: course.truncatingRemainder(dividingBy: 360)), now: now)
            let fix = try #require(provider.position)
            let track = NavText.readout(for: fix, now: now).track
            #expect(track == expected)
            #expect(track == NavText.bearing(try #require(fix.trackTrue), from: fix.coordinate,
                                             altitudeFt: fix.altitudeFtMSL ?? 0, date: now))
        }
    }

    @Test func readoutShowsDashesWhenStaleOrMissing() {
        let dashes = NavText.Readout(groundspeed: "---", track: "---", altitude: "---")
        #expect(NavText.readout(for: nil, now: now) == dashes)
        let provider = LocationProvider()
        provider.receive(location(at: now), now: now)
        #expect(NavText.readout(for: provider.position, now: now + 6) == dashes)
    }

    @Test func symbolIsGrayWhenStaleAndAbsentWithNoFix() throws {
        #expect(OwnshipLayer.symbol(for: nil, now: now) == nil)
        let provider = LocationProvider()
        provider.receive(location(at: now), now: now)
        let live = try #require(OwnshipLayer.symbol(for: provider.position, now: now + 1))
        #expect(!live.isStale)
        #expect(live.track == 52)
        #expect(live.coordinate == Coordinate(latitude: 32.9, longitude: -97.04))
        let stale = try #require(OwnshipLayer.symbol(for: provider.position, now: now + 6))
        #expect(stale.isStale)
        #expect(stale.coordinate == live.coordinate)
    }

    // Installs inside a helper, so the source and layer objects made there are gone before the update.
    @MainActor private func installed(_ ownship: OwnshipLayer) async throws -> (UIWindow, MLNMapView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let empty = try #require(Bundle.main.url(forResource: "empty", withExtension: "json", subdirectory: "MapAssets"))
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), styleURL: empty)
        let host = UIViewController()
        host.view.addSubview(map)
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<100 where map.style == nil { try await Task.sleep(for: .milliseconds(100)) }
        ownship.install(on: try #require(map.style, "the empty style did not load in 10 s"), night: false)
        return (window, map)
    }

    // A source object looked up again has forgotten its shape, so the map is asked what it holds.
    // The answer follows a change by a frame or two, and one point can come back once per tile.
    @MainActor private func mapHoldsSymbol(_ map: MLNMapView, _ wanted: Bool) async throws -> Bool {
        for _ in 0..<100 {
            let source = map.style?.source(withIdentifier: "ownship") as? MLNShapeSource
            if source?.features(matching: nil).isEmpty == !wanted { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test @MainActor func symbolKeepsUpdatingAfterInstallReturns() async throws {
        let ownship = OwnshipLayer()
        // The window is held so the map keeps drawing.
        let (window, map) = try await installed(ownship)
        defer { window.isHidden = true }
        #expect(map.style?.source(withIdentifier: "ownship") is MLNShapeSource)
        #expect(try await mapHoldsSymbol(map, false))
        let provider = LocationProvider()
        provider.receive(location(at: now), now: now)
        ownship.update(provider.position, now: now + 1)
        #expect(try await mapHoldsSymbol(map, true), "the symbol stopped updating once install returned")
        let icon = { String(describing: (map.style?.layer(withIdentifier: "ownship") as? MLNSymbolStyleLayer)?.iconImageName) }
        #expect(icon().contains("ownship-live"))
        ownship.update(provider.position, now: now + 6)
        #expect(icon().contains("ownship-stale"), "the symbol stayed blue with a stale fix")
        ownship.update(nil)
        #expect(try await mapHoldsSymbol(map, false), "the symbol stayed on the map with no fix")
    }

    @Test func northUpZeroesTheHeadingAndTrackUpFollowsTheTrack() throws {
        let provider = LocationProvider()
        provider.receive(location(at: now), now: now)
        let fix = try #require(provider.position)
        #expect(MapPlan.heading(for: fix, orientation: .northUp, current: 140) == 0)
        #expect(MapPlan.heading(for: fix, orientation: .trackUp, current: 140) == 52)
        provider.receive(location(at: now, course: -1), now: now)
        let noTrack = try #require(provider.position)
        #expect(MapPlan.heading(for: noTrack, orientation: .trackUp, current: 140) == 140)
    }

    @Test func fixWithInvalidHorizontalAccuracyIsRejected() {
        let provider = LocationProvider()
        provider.receive(location(at: now, horizontalAccuracy: -1), now: now)
        #expect(provider.position == nil)
        provider.receive(location(at: now), now: now)
        provider.receive(location(at: now + 1, latitude: 10, horizontalAccuracy: -1), now: now + 1)
        #expect(provider.position?.coordinate.latitude == 32.9)
    }

    @Test func olderFixDoesNotReplaceTheCurrentOne() {
        let provider = LocationProvider()
        provider.receive(location(at: now), now: now)
        provider.receive(location(at: now - 2, latitude: 10), now: now)
        #expect(provider.position?.coordinate.latitude == 32.9)
        #expect(provider.position?.timestamp == now)
        // A held fix dated well after the clock means the clock moved back, so ordering starts again.
        provider.receive(location(at: now - 3600, latitude: 20), now: now - 3600)
        #expect(provider.position?.coordinate.latitude == 20)
    }

    @Test func stationaryDeviceKeepsItsLastFixLive() {
        let provider = LocationProvider()
        provider.receive(location(at: now, speed: 0), now: now)
        provider.report(stationary: true, accessOff: false, now: now + 1)
        // The hold lasts only while the checks keep coming; the app looks every 2.5 seconds, this test every second.
        for second in 2...60 { provider.recheck(now: now + Double(second)) }
        #expect(!provider.isStale)
        #expect(NavText.readout(for: provider.position, now: now + 60).groundspeed == "0")
        #expect(OwnshipLayer.symbol(for: provider.position, now: now + 60)?.isStale == false)
        // A fix measured just before the last tick of the hold is still newer than the held one.
        provider.receive(location(at: now + 59.5, latitude: 33), now: now + 60.1)
        #expect(provider.position?.coordinate.latitude == 33)
        provider.report(stationary: false, accessOff: false, now: now + 60.1)
        provider.recheck(now: now + 66)
        #expect(provider.isStale)
    }

    @Test func oldCachedFixIsNotHeldLive() {
        let provider = LocationProvider()
        provider.report(stationary: true, accessOff: false, now: now)
        provider.receive(location(at: now - 600, speed: 0), now: now)
        #expect(provider.isStale)
        #expect(provider.position?.timestamp == now - 600)
        #expect(NavText.readout(for: provider.position, now: now).groundspeed == "---")
    }

    @Test func staleFixIsNotRevivedByAStationaryReport() {
        let provider = LocationProvider()
        provider.receive(location(at: now, speed: 0.5), now: now)
        provider.recheck(now: now + 300)
        #expect(provider.isStale)
        provider.report(stationary: true, accessOff: false, now: now + 300)
        #expect(provider.isStale)
        #expect(OwnshipLayer.symbol(for: provider.position, now: now + 300)?.isStale == true)
    }

    @Test func holdEndsAfterAGapInTheChecks() {
        let provider = LocationProvider()
        provider.receive(location(at: now, speed: 0), now: now)
        provider.report(stationary: true, accessOff: false, now: now + 1)
        provider.recheck(now: now + 2)
        #expect(!provider.isStale)
        // Twenty minutes with no check, as when the app was suspended and the device moved on.
        provider.recheck(now: now + 1202)
        #expect(provider.isStale)
        #expect(NavText.readout(for: provider.position, now: now + 1202).groundspeed == "---")
        #expect(provider.shouldAskAgain(now: now + 1202))
        provider.recheck(now: now + 1203)
        #expect(provider.isStale)
        // A new slow fix is held again.
        provider.receive(location(at: now + 1204, speed: 0), now: now + 1204)
        for second in 1205...1215 { provider.recheck(now: now + Double(second)) }
        #expect(!provider.isStale)
    }

    @Test func endedStreamReleasesTheHold() {
        let provider = LocationProvider()
        provider.receive(location(at: now, speed: 0), now: now)
        provider.report(stationary: true, accessOff: false, now: now + 1)
        provider.streamEnded(now: now + 2)
        #expect(!provider.isStationary)
        provider.recheck(now: now + 8)
        #expect(provider.isStale)
        #expect(provider.shouldAskAgain(now: now + 8))
    }

    @Test func stationaryDeviceWithNoSpeedKeepsItsLastFixLive() {
        let provider = LocationProvider()
        provider.receive(location(at: now, course: -1, speed: -1), now: now)
        provider.report(stationary: true, accessOff: false, now: now + 1)
        for second in 2...60 { provider.recheck(now: now + Double(second)) }
        #expect(!provider.isStale)
        #expect(!provider.shouldAskAgain(now: now + 60))
        #expect(NavText.readout(for: provider.position, now: now + 60).groundspeed == "---")
        #expect(OwnshipLayer.symbol(for: provider.position, now: now + 60)?.imageName == "ownship-live-dot")
    }

    @Test func stationaryReportDoesNotHoldAFixThatWasMoving() {
        let provider = LocationProvider()
        provider.receive(location(at: now, speed: 50), now: now)
        provider.report(stationary: true, accessOff: false, now: now + 1)
        provider.recheck(now: now + 6)
        #expect(provider.isStale)
        #expect(provider.position?.timestamp == now)
        #expect(provider.shouldAskAgain(now: now + 6))
    }

    @Test func anyWordFromTheSystemCountsAsHeard() {
        let provider = LocationProvider()
        provider.receive(location(at: now), now: now)
        provider.report(stationary: false, accessOff: false, now: now + 2)
        #expect(!provider.shouldAskAgain(now: now + 3))
        #expect(provider.shouldAskAgain(now: now + 4.1))
    }

    @Test func quietStreamIsAskedAgainUnlessStationaryOrOff() {
        let provider = LocationProvider()
        #expect(!provider.shouldAskAgain(now: now))
        provider.receive(location(at: now, speed: 0), now: now)
        #expect(!provider.shouldAskAgain(now: now + 1.9))
        #expect(provider.shouldAskAgain(now: now + 2.1))
        provider.report(stationary: true, accessOff: false, now: now + 2.1)
        for second in 3...9 { provider.recheck(now: now + Double(second)) }
        #expect(!provider.shouldAskAgain(now: now + 10))
        provider.report(stationary: false, accessOff: true, now: now + 10)
        #expect(!provider.shouldAskAgain(now: now + 20))
    }

    @Test func noCourseDrawsASymbolThatDoesNotPoint() throws {
        let provider = LocationProvider()
        provider.receive(location(at: now, course: -1), now: now)
        let dot = try #require(OwnshipLayer.symbol(for: provider.position, now: now))
        #expect(dot.track == nil)
        #expect(dot.imageName == "ownship-live-dot")
        #expect(OwnshipLayer.symbol(for: provider.position, now: now + 6)?.imageName == "ownship-stale-dot")
        provider.receive(location(at: now + 7), now: now + 7)
        #expect(OwnshipLayer.symbol(for: provider.position, now: now + 7)?.imageName == "ownship-live")
        #expect(OwnshipLayer.symbol(for: provider.position, now: now + 13)?.imageName == "ownship-stale")
    }

    @Test func accessOffIsSaidInWords() {
        let provider = LocationProvider()
        #expect(!provider.accessOff)
        #expect(NavText.readout(for: nil, now: now).message == nil)
        provider.report(stationary: true, accessOff: true, now: now)
        #expect(provider.accessOff)
        #expect(!provider.isStationary)
        #expect(NavText.readout(for: provider.position, accessOff: provider.accessOff, now: now).message
            == "Location access is off")
    }

    @Test func fixWorseThanFiveHundredMetersIsApproximate() {
        let provider = LocationProvider()
        provider.receive(location(at: now, horizontalAccuracy: 499), now: now)
        #expect(!provider.isApproximate)
        provider.receive(location(at: now + 1, horizontalAccuracy: 3000), now: now + 1)
        #expect(provider.isApproximate)
        provider.receive(location(at: now + 2, horizontalAccuracy: 10), now: now + 2)
        #expect(!provider.isApproximate)
    }

    @Test func reducedAccuracyPermissionIsApproximateWhateverTheFixSays() {
        let provider = LocationProvider()
        // Said before the first fix too, which can be minutes away with this permission.
        provider.report(stationary: false, accessOff: false, reduced: true, now: now)
        #expect(provider.isApproximate)
        #expect(NavText.readout(for: nil, approximate: provider.isApproximate, now: now).message
            == "Approximate location")
        provider.receive(location(at: now, horizontalAccuracy: 5), now: now)
        #expect(provider.isApproximate)
        provider.report(stationary: false, accessOff: false, reduced: false, now: now + 1)
        #expect(!provider.isApproximate)
    }

    @Test func approximateFixIsSaidInWordsAndDrawnAsARing() throws {
        let provider = LocationProvider()
        provider.receive(location(at: now, horizontalAccuracy: 3000), now: now)
        let readout = NavText.readout(for: provider.position, approximate: provider.isApproximate, now: now)
        #expect(readout.message == "Approximate location")
        let live = try #require(OwnshipLayer.symbol(for: provider.position, approximate: true, now: now))
        #expect(live.imageName == "ownship-live-ring")
        let stale = try #require(OwnshipLayer.symbol(for: provider.position, approximate: true, now: now + 6))
        #expect(stale.imageName == "ownship-stale-ring")
        // A precise fix keeps the arrow and says nothing.
        #expect(OwnshipLayer.symbol(for: provider.position, now: now)?.imageName == "ownship-live")
        #expect(NavText.readout(for: provider.position, now: now).message == nil)
        // Access being off is the more useful thing to say.
        #expect(NavText.readout(for: nil, accessOff: true, approximate: true, now: now).message
            == "Location access is off")
    }

    @Test @MainActor func approximateFixIsDrawnAsARingOnTheMap() async throws {
        let ownship = OwnshipLayer()
        let (window, map) = try await installed(ownship)
        defer { window.isHidden = true }
        #expect(map.style?.image(forName: "ownship-live-ring") != nil)
        #expect(map.style?.image(forName: "ownship-stale-ring") != nil)
        let provider = LocationProvider()
        provider.receive(location(at: now, horizontalAccuracy: 3000), now: now)
        ownship.approximate = true
        ownship.update(provider.position, now: now + 1)
        let icon = String(describing: (map.style?.layer(withIdentifier: "ownship") as? MLNSymbolStyleLayer)?
            .iconImageName)
        #expect(icon.contains("ownship-live-ring"), "an approximate fix kept the precise symbol: \(icon)")
        // The ring and the words, saved so they can be looked at.
        let words = DataStrip.Fields(readout: NavText.readout(for: provider.position, approximate: true, now: now))
        let renderer = ImageRenderer(content: words.padding(20))
        renderer.scale = 2
        if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            let base = URL(fileURLWithPath: folder)
            try renderer.uiImage?.pngData()?.write(to: base.appendingPathComponent("data-strip-approximate.png"))
            try map.style?.image(forName: "ownship-live-ring")?.pngData()?
                .write(to: base.appendingPathComponent("ownship-approximate.png"))
        }
    }

    @Test func valuesThatRoundToZeroNeverReadMinusZero() {
        let provider = LocationProvider()
        provider.receive(location(at: now, speed: -0.0, altitude: -0.1), now: now)
        let readout = NavText.readout(for: provider.position, now: now)
        #expect(readout.altitude == "0")
        #expect(readout.groundspeed == "0")
        provider.receive(location(at: now, altitude: -100), now: now)
        #expect(NavText.readout(for: provider.position, now: now).altitude == "-328")
    }

    // Needs `simctl location set` on a fixed point and location access granted, so it is off by default.
    @Test(.enabled(if: liveParked)) func parkedDeviceStaysLive() async throws {
        let provider = LocationProvider()
        provider.start()
        defer { provider.stop() }
        for _ in 0..<20 where provider.position == nil { try await Task.sleep(for: .milliseconds(500)) }
        try #require(provider.position != nil, "no fix arrived in 10 s")
        var staleChecks = 0
        var sawStationary = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(500))
            if provider.isStale { staleChecks += 1 }
            if provider.isStationary { sawStationary = true }
        }
        print("parked: system reported stationary = \(sawStationary)")
        #expect(staleChecks == 0, "a parked device went stale")
        let symbol = try #require(OwnshipLayer.symbol(for: provider.position, now: Date()))
        #expect(!symbol.isStale)
    }

    // Needs `simctl location start` running and location access granted, so it is off by default.
    @Test(.enabled(if: liveLocation)) func liveFixesChangeTheReadout() async throws {
        let provider = LocationProvider()
        provider.start()
        defer { provider.stop() }
        var readouts: [NavText.Readout] = []
        var coordinates: Set<Coordinate> = []
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, coordinates.count < 3 {
            try await Task.sleep(for: .milliseconds(500))
            guard let fix = provider.position, !provider.isStale else { continue }
            coordinates.insert(fix.coordinate)
            readouts.append(NavText.readout(for: fix, now: Date()))
        }
        #expect(coordinates.count >= 3, "fewer than three different fixes arrived")
        let last = try #require(readouts.last)
        #expect(last.groundspeed != "---")
        #expect(last.track != "---")
        let renderer = ImageRenderer(content: DataStrip.Fields(readout: last).padding(20))
        renderer.scale = 2
        let png = try #require(renderer.uiImage?.pngData())
        if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("data-strip-live.png"))
        }
    }
}
