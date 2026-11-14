import FlightCore
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Blueside

private let weather = LayerGroup(id: "weather-areas", title: "Weather areas", overlays: [
    OverlayLayer(id: "radar", title: "Radar", isImage: true),
    OverlayLayer(id: "tfr", title: "TFRs", isImage: false),
])

@Suite @MainActor struct LayerCatalogTests {
    @Test func everyBaseLayerHasItsOwnTitle() {
        let titles = BaseLayer.allCases.map(\.title)
        #expect(titles == ["VFR chart", "VFR Flyway", "IFR Low chart", "IFR High chart", "Street map", "Aerial imagery", "Terrain map"])
        #expect(Set(titles).count == BaseLayer.allCases.count)
    }

    @Test func onlyTheBaseGroupIsFilledForNow() {
        #expect(LayerCatalog().groups.isEmpty)
    }

    @Test func overlaysSwitchOnAndOffWithoutTouchingEachOther() {
        let catalog = LayerCatalog(groups: [weather])
        catalog.setOverlay("radar", on: true)
        #expect(catalog.overlay("radar")?.isOn == true)
        #expect(catalog.overlay("tfr")?.isOn == false)
        catalog.setOverlay("tfr", on: true)
        catalog.setOverlay("radar", on: false)
        #expect(catalog.overlay("radar")?.isOn == false)
        #expect(catalog.overlay("tfr")?.isOn == true)
    }

    @Test func opacityIsClampedAndOnlyImageOverlaysHaveIt() {
        let catalog = LayerCatalog(groups: [weather])
        catalog.setOpacity("radar", to: 0.4)
        #expect(catalog.overlay("radar")?.opacity == 0.4)
        catalog.setOpacity("radar", to: 1.7)
        #expect(catalog.overlay("radar")?.opacity == 1)
        catalog.setOpacity("radar", to: -2)
        #expect(catalog.overlay("radar")?.opacity == 0)
        catalog.setOpacity("tfr", to: 0.3)
        #expect(catalog.overlay("tfr")?.opacity == 1)
    }

    @Test func unknownOverlayIsIgnored() {
        let catalog = LayerCatalog(groups: [weather])
        catalog.setOverlay("lightning", on: true)
        catalog.setOpacity("lightning", to: 0.5)
        #expect(catalog.overlay("lightning") == nil)
        #expect(catalog.groups == [weather])
    }

    @Test func overlaysNeverChangeTheBaseLayer() {
        let model = AppModel(options: LaunchOptions(arguments: ["-base", "street"]))
        let catalog = LayerCatalog(groups: [weather])
        catalog.setOverlay("radar", on: true)
        #expect(model.baseLayer == .street)
    }

    // Puts the picker in a window of the running app and saves what it draws.
    @Test func pickerMarksTheSelectedBase() async throws {
        func capture(base: String, name: String) async throws -> Data {
            let model = AppModel(options: LaunchOptions(arguments: ["-base", base]))
            let catalog = LayerCatalog(groups: [weather])
            catalog.setOverlay("radar", on: true)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
            window.rootViewController = UIHostingController(rootView: LayerPicker(model: model, catalog: catalog))
            window.isHidden = false
            try await Task.sleep(for: .milliseconds(700))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            let png = try #require(image.pngData())
            if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
            }
            return png
        }
        let street = try await capture(base: "street", name: "layer-picker")
        let aerial = try await capture(base: "aerial", name: "layer-picker-aerial")
        #expect(street.count > 20_000, "the picker drew nothing")
        #expect(aerial.count > 20_000, "the picker drew nothing")
        #expect(street != aerial, "the picker looks the same whichever base is selected")
    }
}
