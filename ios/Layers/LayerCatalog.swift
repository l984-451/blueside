import FlightCore
import Observation

/// What the picker offers: one base at a time, kept in the app model, and any number of overlays.
@MainActor @Observable final class LayerCatalog {
    private(set) var list: OverlayList
    var groups: [LayerGroup] { list.groups }

    init(groups: [LayerGroup] = []) { list = OverlayList(groups: groups) }

    func overlay(_ id: String) -> OverlayLayer? { list.overlay(id) }
    func setOverlay(_ id: String, on: Bool) { list.setOverlay(id, on: on) }
    /// Opacity from 0 to 1. Ignored for overlays that are not images.
    func setOpacity(_ id: String, to value: Double) { list.setOpacity(id, to: value) }
}
