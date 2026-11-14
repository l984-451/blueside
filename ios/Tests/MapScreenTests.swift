import FlightCore
import Foundation
import MapLibre
import Testing
import UIKit
@testable import Blueside

// Statics on views belong to the main actor, so the whole suite runs there.
@MainActor @Suite struct MapScreenTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // A store in a fresh folder, and one small file standing in for a bundled pack.
    private func storeAndFile() throws -> (PackStore, PackFile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PackStore(root: root)
        let source = root.appendingPathComponent("source.pmtiles")
        try Data("pack".utf8).write(to: source)
        let id = PackID(cycle: "test", layer: "vfr", region: "test")
        let pack = InstalledPack(id: id, effective: .distantPast, expires: .distantFuture)
        return (store, PackFile(pack: pack, url: source))
    }

    @Test func onlyAPanStopsFollowing() {
        #expect(MapFollow.breaks(.gesturePan))
        #expect(MapFollow.breaks([.gesturePan, .gesturePinch]))
        #expect(!MapFollow.breaks(.gesturePinch))
        #expect(!MapFollow.breaks(.programmatic))
    }

    @Test func trackingButtonCyclesAppleStates() {
        #expect(MapPlan.nextTracking(following: false, orientation: .trackUp).following == true)
        #expect(MapPlan.nextTracking(following: false, orientation: .trackUp).orientation == .northUp)
        #expect(MapPlan.nextTracking(following: true, orientation: .northUp).following == true)
        #expect(MapPlan.nextTracking(following: true, orientation: .northUp).orientation == .trackUp)
        #expect(MapPlan.nextTracking(following: true, orientation: .trackUp).following == false)
        #expect(MapPlan.nextTracking(following: true, orientation: .trackUp).orientation == .northUp)
        #expect(MapPlan.trackingLabel(following: false, orientation: .northUp) == "Not following")
        #expect(MapPlan.trackingLabel(following: true, orientation: .northUp) == "Following, north up")
        #expect(MapPlan.trackingLabel(following: true, orientation: .trackUp) == "Following, track up")
        #expect(Tracking.symbol(following: true, orientation: .trackUp) == "location.north.line.fill")
    }

    @Test func panelNamesMatchTheShowOption() {
        #expect(MapPanel(rawValue: "layers") == .layers)
        #expect(MapPanel(rawValue: "downloads") == nil)
        #expect(MapPanel(rawValue: "other") == nil)
        #expect(MapPanel(rawValue: "nav") == .nav)
        #expect(MapPanel.nav.title == "Airports")
        #expect(MapPanel.layers.title == "Layers")
    }

    @Test func screenStaysAwakeWhileTheMapShows() async throws {
        try await Task.sleep(for: .seconds(1))
        #expect(UIApplication.shared.isIdleTimerDisabled)
    }

    @Test func seededExpiredPackReplacesTheStoreAndReadsAsExpired() throws {
        let (store, file) = try storeAndFile()
        let now = date("2026-10-13T04:00:00Z")
        PackSeed.apply("current", store: store, files: [file], now: now)
        PackSeed.apply("expired", store: store, files: [file], now: now)
        let installed = store.installedFiles().map(\.pack)
        #expect(installed.map(\.id) == [PackID(cycle: "seed-expired", layer: "vfr", region: "TX")])
        #expect(MapPlan.currency(layers: ["vfr"], installed: installed, now: now)
            == .expired(now.addingTimeInterval(-86_400)))
        #expect(store.regions.isEmpty)
    }

    @Test func seededUpcomingPackIsNotYetInEffect() throws {
        let (store, file) = try storeAndFile()
        let now = date("2026-10-13T04:00:00Z")
        PackSeed.apply("upcoming", store: store, files: [file], now: now)
        let installed = store.installedFiles().map(\.pack)
        #expect(MapPlan.currency(layers: ["vfr"], installed: installed, now: now)
            == .notYetEffective(now.addingTimeInterval(7 * 86_400)))
        // The pack is still the one to draw, so the map is not blank.
        #expect(ChartLibrary.packToShow(layer: "vfr", region: "TX", installed: installed, now: now) != nil)
    }

    @Test func emptySeedClearsTheStore() throws {
        let (store, file) = try storeAndFile()
        PackSeed.apply("current", store: store, files: [file])
        #expect(store.installedFiles().count == 1)
        PackSeed.apply("empty", store: store, files: [file])
        #expect(store.installedFiles().isEmpty)
    }

    @Test func unknownSeedLeavesTheStoreAlone() throws {
        let (store, file) = try storeAndFile()
        PackSeed.apply("current", store: store, files: [file])
        PackSeed.apply("typo", store: store, files: [file])
        #expect(store.installedFiles().map(\.pack.id.cycle) == ["seed-current"])
    }
}
