import FlightCore
import SwiftUI
import Testing
@testable import Blueside

@MainActor @Suite struct MapCommandTests {
    @Test func commandsCarryTheApprovedTitlesAndReuseTheControlsNames() {
        #expect(MapCommand.allCases.compactMap(\.title) == ["Search", "Layers", "Route", "Night Mode", "Center on Aircraft"])
        #expect(MapCommand.layers.title == MapPanel.layers.title)
        #expect(MapCommand.route.title == RoutePages.routeTitle)
        // The tracking button's own cycle has no menu item.
        #expect(MapCommand.cycleTracking.title == nil)
        #expect(MapCommand.cycleTracking.shortcut == nil)
    }

    @Test func eachCommandHasItsOwnKeys() {
        let keys = MapCommand.allCases.compactMap(\.shortcut)
        #expect(keys.count == 5)
        #expect(Set(keys).count == keys.count)
        #expect(MapCommand.search.shortcut == KeyboardShortcut("f", modifiers: .command))
        #expect(MapCommand.layers.shortcut == KeyboardShortcut("l", modifiers: .command))
        #expect(MapCommand.route.shortcut == KeyboardShortcut("r", modifiers: .command))
        #expect(MapCommand.nightMode.shortcut == KeyboardShortcut("n", modifiers: [.command, .shift]))
        #expect(MapCommand.centerOnAircraft.shortcut == KeyboardShortcut("0", modifiers: .command))
    }

    // The control column and the screen both read the panel from the command, so a key opens what its button opens.
    @Test func panelCommandsOpenTheirControlsPanelAndTheRestOpenNone() {
        #expect(MapCommand.search.panel == .nav)
        #expect(MapCommand.layers.panel == .layers)
        #expect(MapCommand.route.panel == .route)
        #expect(MapCommand.nightMode.panel == nil)
        #expect(MapCommand.centerOnAircraft.panel == nil)
        #expect(MapCommand.cycleTracking.panel == nil)
    }
}
