import CoreLocation
import FlightCore
import MapLibre
import UIKit

/// The aircraft symbol. Blue with a live fix, gray when the fix is stale, hidden with no fix.
/// An arrow along the track, a dot when the fix has no track, or a wide ring when the fix is not precise.
@MainActor final class OwnshipLayer {
    struct Symbol: Equatable, Sendable {
        var coordinate: Coordinate
        var track: Double?
        var isStale: Bool
        /// The core's choice of arrow, dot or ring, live or stale.
        var imageName: String
    }

    nonisolated static func symbol(for position: Position?, approximate: Bool = false, now: Date) -> Symbol? {
        guard let position else { return nil }
        return Symbol(coordinate: position.coordinate, track: position.trackTrue, isStale: position.isStale(at: now),
                      imageName: MapPlan.ownshipImage(for: position, approximate: approximate, now: now))
    }

    /// Room around the map within which a symbol counts as on screen: half the widest symbol, the ring.
    static let offScreenMargin: CGFloat = 70

    /// Whether drawing `next` would show anything the drawn symbol does not. Each point is where its coordinate falls
    /// on screen now. Every map redraw costs a whole frame, so a move under half a point, or one that is and stays
    /// outside `visible`, is not drawn; a new look, heading or staleness always is.
    nonisolated static func redraws(_ drawn: Symbol?, at drawnPoint: CGPoint?, _ next: Symbol?, at nextPoint: CGPoint?,
                                    visible: CGRect) -> Bool {
        guard let drawn, let next, let drawnPoint, let nextPoint else { return drawn != next }
        guard drawn.track == next.track, drawn.isStale == next.isStale, drawn.imageName == next.imageName else { return true }
        if !visible.contains(drawnPoint), !visible.contains(nextPoint) { return false }
        return hypot(nextPoint.x - drawnPoint.x, nextPoint.y - drawnPoint.y) >= 0.5
    }

    // The map owns the style and drops it on reload. Source and layer are looked up on each update.
    private weak var style: MLNStyle?
    private weak var map: MLNMapView?
    private var last: Position?
    /// What the source holds. Its coordinate is the one drawn, so drift too small to draw cannot add up unseen.
    private var shown: Symbol?
    /// Set when the fix is not precise. The next update then draws a ring in place of the arrow.
    var approximate = false

    /// Adds the symbol to a freshly loaded style. Call it after every style load.
    /// Without the map, any change is drawn.
    func install(on style: MLNStyle, map: MLNMapView? = nil, night: Bool) {
        self.map = map
        paint(style, night: night)
        let source = MLNShapeSource(identifier: "ownship", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNSymbolStyleLayer(identifier: "ownship", source: source)
        layer.iconImageName = NSExpression(forConstantValue: "ownship-stale")
        layer.iconRotation = NSExpression(forKeyPath: "track")
        layer.iconRotationAlignment = NSExpression(forConstantValue: "map")
        layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
        style.addLayer(layer)
        self.style = style
        shown = nil
        update(last)
    }

    /// Bakes the symbol images in the day or night values. Run again when night mode changes.
    func paint(_ style: MLNStyle? = nil, night: Bool) {
        guard let style = style ?? self.style else { return }
        let traits = UITraitCollection(userInterfaceStyle: night ? .dark : .light)
        let live = MapInk.ownshipLive.resolvedColor(with: traits)
        let stale = MapInk.ownshipStale.resolvedColor(with: traits)
        style.setImage(Self.image("location.north.fill", live), forName: "ownship-live")
        style.setImage(Self.image("location.north.fill", stale), forName: "ownship-stale")
        style.setImage(Self.image("circle.circle.fill", live), forName: "ownship-live-dot")
        style.setImage(Self.image("circle.circle.fill", stale), forName: "ownship-stale-dot")
        style.setImage(Self.ring(live), forName: "ownship-live-ring")
        style.setImage(Self.ring(stale), forName: "ownship-stale-ring")
    }

    func update(_ position: Position?, now: Date = Date()) {
        last = position
        let symbol = Self.symbol(for: position, approximate: approximate, now: now)
        let onScreen = { [map] (symbol: Symbol?) in
            symbol.flatMap { symbol in map.map { $0.convert(CLLocationCoordinate2D(latitude: symbol.coordinate.latitude,
                                                                                   longitude: symbol.coordinate.longitude), toPointTo: $0) } }
        }
        let visible = map?.bounds.insetBy(dx: -Self.offScreenMargin, dy: -Self.offScreenMargin) ?? .null
        guard Self.redraws(shown, at: onScreen(shown), symbol, at: onScreen(symbol), visible: visible),
              let style, let source = style.source(withIdentifier: "ownship") as? MLNShapeSource,
              let layer = style.layer(withIdentifier: "ownship") as? MLNSymbolStyleLayer else { return }
        let before = shown
        shown = symbol
        guard let symbol else {
            source.shape = nil
            return
        }
        let point = MLNPointFeature()
        point.coordinate = CLLocationCoordinate2D(latitude: symbol.coordinate.latitude,
                                                  longitude: symbol.coordinate.longitude)
        point.attributes = ["track": symbol.track ?? 0]
        source.shape = point
        if symbol.imageName != before?.imageName { layer.iconImageName = NSExpression(forConstantValue: symbol.imageName) }
    }

    /// Centers the map on the fix and turns it for the chosen orientation. A fix under half a point from the center
    /// with the same heading moves nothing: each camera move redraws the whole map.
    func follow(_ map: MLNMapView, position: Position, orientation: MapOrientation) {
        let camera = map.camera
        let center = CLLocationCoordinate2D(latitude: position.coordinate.latitude, longitude: position.coordinate.longitude)
        let heading = MapPlan.heading(for: position, orientation: orientation, current: camera.heading)
        let (from, to) = (map.convert(camera.centerCoordinate, toPointTo: map), map.convert(center, toPointTo: map))
        guard heading != camera.heading || hypot(to.x - from.x, to.y - from.y) >= 0.5 else { return }
        camera.centerCoordinate = center
        camera.heading = heading
        map.setCamera(camera, animated: false)
    }

    private static func image(_ name: String, _ tint: UIColor) -> UIImage {
        let glyph = UIImage(systemName: name,
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44))!
            .withTintColor(tint, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: glyph.size).image { _ in glyph.draw(at: .zero) }
    }

    // A dashed ring with a faint fill. It is a fixed size on screen, not the true error radius.
    private static func ring(_ tint: UIColor) -> UIImage {
        let size = CGSize(width: 132, height: 132)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4))
            path.lineWidth = 5
            path.setLineDash([12, 8], count: 2, phase: 0)
            tint.withAlphaComponent(0.2).setFill()
            tint.setStroke()
            path.fill()
            path.stroke()
        }
    }
}
