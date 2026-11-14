import FlightCore
import MapLibre
import UIKit

/// A ring at the place the open panel shows, above the nav symbols and under the route points and ownship.
@MainActor final class PlaceRing {
    private weak var style: MLNStyle?
    private(set) var shown: Coordinate?
    private static let id = "place-ring"

    /// Call it after the route is installed, on every style load.
    func install(on style: MLNStyle, night: Bool) {
        let source = MLNShapeSource(identifier: Self.id, shape: nil, options: nil)
        style.addSource(source)
        let ring = MLNCircleStyleLayer(identifier: Self.id, source: source)
        ring.circleRadius = NSExpression(forConstantValue: 0)
        // Grows in once as a place opens; nothing moves after that.
        ring.circleRadiusTransition = MLNTransition(duration: 0.3, delay: 0)
        ring.circleStrokeWidth = NSExpression(forConstantValue: 3)
        ring.circleOpacity = NSExpression(forConstantValue: 0.2)
        if let above = style.layer(withIdentifier: "route-points") ?? style.layer(withIdentifier: "ownship") {
            style.insertLayer(ring, below: above)
        } else {
            style.addLayer(ring)
        }
        self.style = style
        paint(night: night)
        draw()
    }

    func paint(night: Bool) {
        guard let ring = style?.layer(withIdentifier: Self.id) as? MLNCircleStyleLayer else { return }
        let ink = NSExpression(forConstantValue: MapInk.place(night: night))
        ring.circleColor = ink
        ring.circleStrokeColor = ink
    }

    /// Moves the ring to a place, or takes it off the map for nil. The same place twice does nothing.
    func show(_ place: Coordinate?) {
        guard place != shown else { return }
        shown = place
        draw()
    }

    private func draw() {
        guard let style, let source = style.source(withIdentifier: Self.id) as? MLNShapeSource,
              let ring = style.layer(withIdentifier: Self.id) as? MLNCircleStyleLayer else { return }
        source.shape = shown.map {
            let point = MLNPointFeature()
            point.coordinate = CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            return point
        }
        ring.circleRadius = NSExpression(forConstantValue: shown == nil ? 0 : 22)
    }
}
