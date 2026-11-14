import FlightCore
import MapLibre
import SwiftUI

/// What the panel over the map can hold. Raw values are the names used by the show launch option.
enum MapPanel: String, Identifiable, Sendable {
    case layers
    case nav
    case place
    case route

    var id: String { rawValue }
    var title: String {
        switch self {
        case .layers: "Layers"
        case .nav: "Airports"
        case .place: "Place"
        case .route: "Route"
        }
    }
}

/// What a map control and its keyboard command both ask of the map screen, which alone decides what each does.
enum MapCommand: CaseIterable, Sendable {
    case search
    case layers
    case route
    case nightMode
    case centerOnAircraft
    /// The tracking button's own three-step cycle. It has no menu item.
    case cycleTracking

    var title: String? {
        switch self {
        case .search: "Search"
        case .layers: MapPanel.layers.title
        case .route: RoutePages.routeTitle
        case .nightMode: "Night Mode"
        case .centerOnAircraft: "Center on Aircraft"
        case .cycleTracking: nil
        }
    }

    /// The panel the command opens, or closes when it is already open.
    var panel: MapPanel? {
        switch self {
        case .search: .nav
        case .layers: .layers
        case .route: .route
        case .nightMode, .centerOnAircraft, .cycleTracking: nil
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .search: KeyboardShortcut("f")
        case .layers: KeyboardShortcut("l")
        case .route: KeyboardShortcut("r")
        case .nightMode: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .centerOnAircraft: KeyboardShortcut("0")
        case .cycleTracking: nil
        }
    }
}

/// When the map keeps the aircraft in the middle.
enum MapFollow {
    /// Only a pan stops following. A pinch zooms around the aircraft.
    static func breaks(_ reason: MLNCameraChangeReason) -> Bool { reason.contains(.gesturePan) }
}

/// The tracking button's symbol. Its states and label come from MapPlan.
enum Tracking {
    static func symbol(following: Bool, orientation: MapOrientation) -> String {
        !following ? "location" : orientation == .northUp ? "location.fill" : "location.north.line.fill"
    }
}

/// The column of map buttons at the leading edge, in glass groups. The panel card grows out of its button.
struct MapControls: View {
    let model: AppModel
    let following: Bool
    let panel: MapPanel?
    let glass: Namespace.ID
    let perform: (MapCommand) -> Void
    let onSettings: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isNight) private var night

    // Tinted as the card is: untinted glass in the dark appearance left glyphs at 2.5 to 1 over a day chart.
    private var look: Glass { .card(dark: scheme == .dark, night: night).interactive() }

    var body: some View {
        VStack(spacing: chromeInset) {
            VStack(spacing: 0) {
                opener(.search, "magnifyingglass", "Search airports", "search-button")
                opener(.route, "point.topleft.down.to.point.bottomright.curvepath", RoutePages.routeTitle, "route-button")
            }
            MapButton(symbol: Tracking.symbol(following: following, orientation: model.orientation),
                      label: "Tracking", identifier: "tracking-button",
                      value: MapPlan.trackingLabel(following: following, orientation: model.orientation)) {
                perform(.cycleTracking)
            }
            .pointerHighlight()
            .glassEffect(look, in: .circle)
            Spacer()
            VStack(spacing: 0) {
                opener(.layers, "square.3.layers.3d", "Layers", "layers-button", group: "app")
                MapButton(symbol: model.nightMode ? "moon.fill" : "sun.max.fill", label: "Night mode",
                          identifier: "night-button", value: model.nightMode ? "On" : "Off") {
                    perform(.nightMode)
                }
                .glassed("app", glass, look)
                settings.glassed("app", glass, look)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var settings: MapButton {
        MapButton(symbol: "gearshape", label: "Settings", identifier: "settings-button", action: onSettings)
    }

    // While its card is open the button takes a second identity, so the card alone carries the button's.
    @ViewBuilder private func opener(_ command: MapCommand, _ symbol: String, _ label: String, _ identifier: String,
                                     group: String = "top") -> some View {
        if let shown = command.panel {
            MapButton(symbol: symbol, label: label, identifier: identifier,
                      value: panel == shown ? "Open" : "") { perform(command) }
                .glassed(group, glass, look)
                .glassEffectID(panel == shown ? shown.rawValue + "-open" : shown.rawValue, in: glass)
        }
    }
}

private extension View {
    /// Interactive glass joined with the rest of its group into one capsule.
    func glassed(_ group: String, _ glass: Namespace.ID, _ look: Glass) -> some View {
        pointerHighlight().glassEffect(look, in: .capsule).glassEffectUnion(id: group, namespace: glass)
    }

    /// The system's pointer highlight, round like the button.
    func pointerHighlight() -> some View { contentShape(.hoverEffect, .circle).hoverEffect(.highlight) }
}
