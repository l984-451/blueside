import Foundation
import Testing
@testable import FlightCore

@Suite struct MapPlanTests {
    private func date(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

    @Test func bannerSaysExpiredWithTheDate() {
        #expect(MapPlan.banner(.expired(date("2026-10-12T09:01:00Z"))) == "Charts expired 12 Oct 2026 UTC")
    }

    @Test func bannerSaysNotYetInEffectAndNeverExpired() {
        let text = MapPlan.banner(.notYetEffective(date("2026-10-29T09:01:00Z")))
        #expect(text == "Charts not yet in effect until 29 Oct 2026 UTC")
        #expect(text?.contains("expired") == false)
    }

    @Test func trackingCyclesNoneNorthUpTrackUp() {
        #expect(MapPlan.nextTracking(following: false, orientation: .trackUp) == (true, .northUp))
        #expect(MapPlan.nextTracking(following: true, orientation: .northUp) == (true, .trackUp))
        #expect(MapPlan.nextTracking(following: true, orientation: .trackUp) == (false, .northUp))
    }

    @Test func centeringStartsFollowingInTheOrientationInUseAndNeverStopsIt() {
        for orientation in [MapOrientation.northUp, .trackUp] {
            let started = MapPlan.centerTracking(following: false, orientation: orientation)
            #expect(started?.following == true && started?.orientation == orientation)
            // Already following: nothing changes, so it stays on in the same orientation.
            #expect(MapPlan.centerTracking(following: true, orientation: orientation) == nil)
        }
    }

    @Test func ownshipImageAndHeading() {
        let now = Date(timeIntervalSince1970: 1000)
        let fix = Position(latitude: 30, longitude: -97, courseDegrees: 90, speedMetersPerSecond: 50,
                           altitudeMeters: nil, timestamp: now)!
        #expect(MapPlan.ownshipImage(for: fix, approximate: false, now: now) == "ownship-live")
        #expect(MapPlan.ownshipImage(for: fix, approximate: true, now: now + 10) == "ownship-stale-ring")
        #expect(MapPlan.heading(for: fix, orientation: .trackUp, current: 5) == 90)
        #expect(MapPlan.heading(for: fix, orientation: .northUp, current: 5) == 0)
    }

    @Test func bannerIsAbsentForCurrentChartsAndForNone() {
        #expect(MapPlan.banner(.current) == nil)
        #expect(MapPlan.banner(nil) == nil)
    }

    @Test func bannerNamesItsSubject() {
        let text = MapPlan.banner(.expired(date("2026-10-12T09:01:00Z")), subject: "Nav data")
        #expect(text == "Nav data expired 12 Oct 2026 UTC")
    }

    // Texas plates for the cycle ending 29 Oct, opened offline on 10 Dec.
    @Test func platesCurrencyComesFromTheInstalledPlatesPacks() {
        let plates = InstalledPack(id: PackID(cycle: "2026-10-01", layer: PlateLibrary.layer, region: "TX"),
                                   effective: date("2026-10-01T09:01:00Z"), expires: date("2026-10-29T09:01:00Z"))
        let chart = InstalledPack(id: PackID(cycle: "2026-12-01", layer: "vfr", region: "TX"),
                                  effective: date("2026-12-01T09:01:00Z"), expires: date("2027-01-26T09:01:00Z"))
        let layers = [PlateLibrary.layer]
        #expect(MapPlan.currency(layers: layers, installed: [plates, chart], now: date("2026-10-15T00:00:00Z")) == .current)
        let late = MapPlan.currency(layers: layers, installed: [plates, chart], now: date("2026-12-10T00:00:00Z"))
        #expect(late == .expired(plates.expires) && MapPlan.banner(late, subject: "Plates") == "Plates expired 29 Oct 2026 UTC")
        #expect(MapPlan.nextChange(layers: layers, installed: [plates, chart], after: date("2026-10-15T00:00:00Z")) == plates.expires)
        #expect(MapPlan.currency(layers: layers, installed: [chart], now: date("2026-12-10T00:00:00Z")) == nil)
    }

    // A damaged header that still reads as a pack: offsets past any file are a missing index, never a crash.
    @Test func aPackWithOffsetsPastAnyFileCoversNothing() throws {
        // An uncompressed header, then a root index of one entry pointing into the leaves at 126.
        func pack(root: UInt64, leaves: UInt64) throws -> URL {
            var head = [UInt8](repeating: 0, count: 127)
            head.replaceSubrange(0..<7, with: Array("PMTiles".utf8))
            (head[7], head[97], head[100], head[101]) = (3, 1, 0, 14)
            for (at, value) in [(8, root), (16, 5), (40, leaves)] {
                for k in 0..<8 { head[at + k] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(k))) }
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("damaged-\(UUID().uuidString).pmtiles")
            try Data(head + [1, 0, 0, 10, 127]).write(to: file)
            return file
        }
        for file in [try pack(root: 0xFFFF_FFFF_FFFF_FFF0, leaves: 0), try pack(root: 127, leaves: .max - 10)] {
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(!PackCoverage().covers([file], latitude: 30, longitude: -97, zoom: 8))
        }
    }

    @Test func onlyTheFirstFixZoomsAWholeCountryViewIn() {
        #expect(MapPlan.firstFixZoom(current: 4, alreadyZoomed: false) == 10)
        #expect(MapPlan.firstFixZoom(current: 4, alreadyZoomed: true) == nil)
        #expect(MapPlan.firstFixZoom(current: 8, alreadyZoomed: false) == nil)
    }

    @Test func eachBaseHasItsPacksAndAName() {
        #expect(BaseLayer.vfr.packLayers == ["vfr", "vfr-tac"])
        #expect(BaseLayer.ifrLow.packLayers == ["ifr-low", "ifr-area"])
        #expect(BaseLayer.allCases.map(\.title) == ["VFR chart", "VFR Flyway", "IFR Low chart", "IFR High chart", "Street map",
                                                     "Aerial imagery", "Terrain map"])
    }
}

@Suite struct LayerMenuTests {
    @Test func menuShowsEverySwitchAndBaseOnce() {
        let sections = [LayerMenu.aeronautical] + LayerMenu.overlays
        let ids = sections.flatMap(\.rows).compactMap { if case .overlay(let id) = $0 { id } else { nil } }
        let switches = AeronauticalLayers.groups.map(\.id) + [TrafficStore.switchID] + WeatherSwitches.toggles.map(\.id).filter { $0 != WeatherSwitches.stationsID }
        #expect(ids.sorted() == switches.sorted())
        let stations = sections.flatMap(\.rows).filter { if case .station = $0 { true } else { false } }
        #expect(stations.count == StationShow.allCases.count)
        #expect(LayerMenu.bases.flatMap { $0 }.sorted { $0.rawValue < $1.rawValue } == BaseLayer.allCases.sorted { $0.rawValue < $1.rawValue })
    }
}
