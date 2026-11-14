import CoreLocation
import FlightCore
import MapLibre
import UIKit

/// The cased magenta route line under the point symbols, the active leg brighter, each waypoint labeled.
@MainActor final class RouteLine {
    /// The route as drawn and its active leg's index in it. Nil leaves nothing to draw.
    /// A leg from the aircraft is drawn only from a live, exact fix, so no line starts at a guess.
    nonisolated static func drawn(_ plan: RoutePlan?, position: Position?, approximate: Bool = false,
                                  now: Date) -> (route: Route, active: Int?)? {
        RoutePages.drawn(plan, position: position, approximate: approximate, now: now).map { ($0.route, $0.active) }
    }

    nonisolated static func path(from start: Coordinate, to end: Coordinate) -> [Coordinate] {
        RoutePages.path(from: start, to: end)
    }

    // The map owns the style and drops it on reload. Sources and layers are looked up on each update.
    private weak var style: MLNStyle?
    private var night = false
    private var labels: Set<String> = []
    /// What the sources hold, so a fix that moves nothing redraws nothing.
    private var shown: RoutePages.Drawn?
    /// Where the drawn line begins. Nil when no line is drawn.
    private(set) var start: Coordinate?

    /// Adds the line in the route slot, above airspace and under point symbols, and the labels under ownship.
    /// Call it after every style load.
    func install(on style: MLNStyle, night: Bool) {
        let points = style.layers.first { ($0 is MLNSymbolStyleLayer || $0 is MLNCircleStyleLayer) }
        for name in ["route", "route-active"] {
            let source = MLNShapeSource(identifier: name, shape: nil, options: nil)
            style.addSource(source)
            let casing = MLNLineStyleLayer(identifier: name + "-casing", source: source)
            casing.lineWidth = NSExpression(forConstantValue: name == "route" ? 6 : 7)
            let core = MLNLineStyleLayer(identifier: name, source: source)
            core.lineWidth = NSExpression(forConstantValue: name == "route" ? 3 : 4)
            for layer in [casing, core] {
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                if let points { style.insertLayer(layer, below: points) } else { style.addLayer(layer) }
            }
        }
        // Legs not being flown are dimmer, so the active one stands out.
        for id in ["route", "route-casing"] {
            (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: 0.55)
        }
        let source = MLNShapeSource(identifier: "route-points", shape: nil, options: nil)
        style.addSource(source)
        let dots = MLNCircleStyleLayer(identifier: "route-points", source: source)
        dots.circleRadius = NSExpression(forConstantValue: 4)
        dots.circleStrokeWidth = NSExpression(forConstantValue: 2)
        let tags = MLNSymbolStyleLayer(identifier: "route-labels", source: source)
        tags.iconImageName = NSExpression(forKeyPath: "label")
        tags.iconAnchor = NSExpression(forConstantValue: "left")
        tags.iconOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 6, dy: 0)))
        tags.iconAllowsOverlap = NSExpression(forConstantValue: true)
        for layer in [dots, tags] {
            if let ownship = style.layer(withIdentifier: "ownship") { style.insertLayer(layer, below: ownship) }
            else { style.addLayer(layer) }
        }
        self.style = style
        labels = []
        paint(night: night)
        start = nil
        shown = nil
    }

    /// Sets the day or night inks.
    func paint(night: Bool) {
        self.night = night
        guard let style else { return }
        for id in ["route-casing", "route-active-casing"] {
            (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineColor =
                NSExpression(forConstantValue: MapInk.routeCasing(night: night))
        }
        for id in ["route", "route-active"] {
            (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineColor =
                NSExpression(forConstantValue: MapInk.route(night: night))
        }
        let dots = style.layer(withIdentifier: "route-points") as? MLNCircleStyleLayer
        dots?.circleColor = NSExpression(forConstantValue: MapInk.route(night: night))
        dots?.circleStrokeColor = NSExpression(forConstantValue: MapInk.routeCasing(night: night))
        for ident in labels { style.setImage(Self.label(ident, night: night), forName: "route-label-" + ident) }
    }

    /// Draws the route again from the newest fix, or removes it.
    func update(_ plan: RoutePlan?, position: Position?, approximate: Bool = false, now: Date = Date()) {
        guard let style, let all = style.source(withIdentifier: "route") as? MLNShapeSource,
              let active = style.source(withIdentifier: "route-active") as? MLNShapeSource,
              let points = style.source(withIdentifier: "route-points") as? MLNShapeSource else {
            start = nil
            return
        }
        let drawn = RoutePages.drawn(plan, position: position, approximate: approximate, now: now)
        let last = shown
        guard drawn != last else { return }
        shown = drawn
        guard let drawn else {
            for source in [all, active, points] { source.shape = nil }
            start = nil
            return
        }
        let route = drawn.route
        start = route.waypoints[0].coordinate
        if route != last?.route { all.shape = Self.line(route.linePoints()) }
        active.shape = drawn.active.map {
            Self.line(Self.path(from: route.waypoints[$0].coordinate, to: route.waypoints[$0 + 1].coordinate))
        }
        // A line from the aircraft moves its first point only, which has no dot.
        guard drawn.dots != last?.dots else { return }
        points.shape = MLNShapeCollectionFeature(shapes: drawn.dots.map { waypoint in
            if !labels.contains(waypoint.ident) {
                labels.insert(waypoint.ident)
                style.setImage(Self.label(waypoint.ident, night: night), forName: "route-label-" + waypoint.ident)
            }
            let point = MLNPointFeature()
            point.coordinate = CLLocationCoordinate2D(latitude: waypoint.coordinate.latitude,
                                                      longitude: waypoint.coordinate.longitude)
            point.attributes = ["label": "route-label-" + waypoint.ident]
            return point
        })
    }

    private static func line(_ path: [Coordinate]) -> MLNPolylineFeature {
        var points = path.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        return MLNPolylineFeature(coordinates: &points, count: UInt(points.count))
    }

    // The identifier in route ink on a casing capsule, so it reads over any chart.
    private static func label(_ ident: String, night: Bool) -> UIImage {
        let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .bold)
        let text = NSAttributedString(string: ident, attributes: [.font: font,
                                                                 .foregroundColor: MapInk.route(night: night)])
        let size = text.size()
        let box = CGRect(x: 0, y: 0, width: ceil(size.width) + 10, height: ceil(size.height) + 4)
        return UIGraphicsImageRenderer(size: box.size).image { _ in
            MapInk.routeCasing(night: night).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: box.height / 2).fill()
            text.draw(at: CGPoint(x: 5, y: 2))
        }
    }
}
