import FlightCore
import Foundation
import Testing
@testable import Blueside

@Suite @MainActor struct WeatherLayersTests {
    @Test func overlaySwitchesPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: "WeatherLayersTests"))
        defaults.removePersistentDomain(forName: "WeatherLayersTests")
        let groups = [NavOverlay.layerGroup, WeatherSwitches.layerGroup]
        let catalog = LayerCatalog(groups: WeatherLayers.restore(groups, from: defaults))
        #expect(catalog.overlay("weather-radar")?.isOn == false)
        catalog.setOverlay("weather-radar", on: true)
        catalog.setOverlay(NavOverlay.obstaclesID, on: true)
        catalog.setOverlay("nav-airports", on: false)
        WeatherLayers.save(catalog.groups, to: defaults)
        let again = LayerCatalog(groups: WeatherLayers.restore(groups, from: defaults))
        #expect(again.overlay("weather-radar")?.isOn == true)
        #expect(again.overlay(NavOverlay.obstaclesID)?.isOn == true)
        #expect(again.overlay("nav-airports")?.isOn == false)
        #expect(WeatherLayers.shown(again) == [.radar])
    }
}
