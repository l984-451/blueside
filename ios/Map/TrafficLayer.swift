import FlightCore
import MapLibre
import UIKit

/// ADS-B targets: a chevron along the track (a circle when there is none), hollow for other traffic, filled
/// when proximate, orange on alert; the relative altitude beside it and the callsign below from zoom 9.
/// Stale targets are faded.
@MainActor final class TrafficLayer {
    static let callsignZoom = 9.0

    private weak var style: MLNStyle?
    private var night = false
    private var images: Set<String> = []
    private var isOn = true
    private var last: (shown: [TrafficShown], shapes: Data)?
    /// What the source holds, so a batch with nothing new is not parsed again.
    private var drawn: Data?

    /// Adds the layers under the ownship symbol. Call it after every style load.
    func install(on style: MLNStyle, night: Bool) {
        let source = MLNShapeSource(identifier: "traffic", shape: nil, options: nil)
        style.addSource(source)
        let fade = NSExpression(format: "TERNARY(stale == 1, 0.4, 1)")
        let chevrons = MLNSymbolStyleLayer(identifier: "traffic", source: source)
        chevrons.iconImageName = NSExpression(forKeyPath: "icon")
        chevrons.iconRotation = NSExpression(forKeyPath: "track")
        chevrons.iconRotationAlignment = NSExpression(forConstantValue: "map")
        let label = MLNSymbolStyleLayer(identifier: "traffic-label", source: source)
        label.iconImageName = NSExpression(forKeyPath: "labelIcon")
        label.iconAnchor = NSExpression(forConstantValue: "left")
        label.iconOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 14, dy: 0)))
        let callsign = MLNSymbolStyleLayer(identifier: "traffic-callsign", source: source)
        callsign.iconImageName = NSExpression(forKeyPath: "callsignIcon")
        callsign.iconAnchor = NSExpression(forConstantValue: "top")
        callsign.iconOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 14)))
        callsign.minimumZoomLevel = Float(Self.callsignZoom)
        for layer in [chevrons, label, callsign] {
            layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            layer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            layer.iconOpacity = fade
            layer.isVisible = isOn
            if let ownship = style.layer(withIdentifier: "ownship") { style.insertLayer(layer, below: ownship) }
            else { style.addLayer(layer) }
        }
        self.style = style
        images = []
        drawn = nil
        paint(night: night)
        if let last { update(last.shown, shapes: last.shapes) }
    }

    func paint(night: Bool) {
        self.night = night
        guard let style else { return }
        for alert in [TrafficAlert.other, .proximate, .alert] {
            for directed in [true, false] {
                style.setImage(Self.symbol(alert, directed: directed, night: night), forName: TrafficStore.icon(alert, directed: directed))
            }
        }
        let names = images
        images = []
        for name in names { draw(name, on: style) }
    }

    func show(_ on: Bool) {
        isOn = on
        for id in TrafficStore.layers { style?.layer(withIdentifier: id)?.isVisible = on }
    }

    func update(_ shown: [TrafficShown], shapes: Data) {
        last = (shown, shapes)
        guard shapes != drawn, let style, let source = style.source(withIdentifier: "traffic") as? MLNShapeSource else { return }
        drawn = shapes
        let names = Set(shown.flatMap { [TrafficStore.labelIcon($0), TrafficStore.callsignIcon($0)] }.filter { !$0.isEmpty })
        for name in names.subtracting(images) { draw(name, on: style) }
        source.shape = try? MLNShape(data: shapes, encoding: String.Encoding.utf8.rawValue)
        // Tags no target shows any more are dropped, so a long flight does not keep every callsign it heard.
        for name in images.subtracting(names) { style.removeImage(forName: name) }
        images.formIntersection(names)
    }

    // Image names carry what they show: "traffic-label-<alert>-<text>" or "traffic-callsign-<text>".
    private func draw(_ name: String, on style: MLNStyle) {
        images.insert(name)
        if name.hasPrefix("traffic-callsign-") {
            style.setImage(Self.tag(String(name.dropFirst("traffic-callsign-".count)), ink: Self.ink(.other, night: night), night: night),
                           forName: name)
        } else {
            let rest = name.dropFirst("traffic-label-".count)
            guard let dash = rest.firstIndex(of: "-"), let alert = TrafficAlert(rawValue: String(rest[..<dash])) else { return }
            style.setImage(Self.tag(String(rest[rest.index(after: dash)...]), ink: Self.ink(alert, night: night), night: night),
                           forName: name)
        }
    }

    private static func ink(_ alert: TrafficAlert, night: Bool) -> UIColor {
        let traits = UITraitCollection(userInterfaceStyle: night ? .dark : .light)
        return (alert == .alert ? UIColor.systemOrange : UIColor.label).resolvedColor(with: traits)
    }

    private static func casing(night: Bool) -> UIColor {
        MapInk.routeCasing(night: night)
    }

    // An arrowhead pointing up, or a circle 18 pt across for a target with no track; hollow for other traffic.
    private static func symbol(_ alert: TrafficAlert, directed: Bool, night: Bool) -> UIImage {
        let size = CGSize(width: 30, height: 30)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let path = UIBezierPath()
            if directed {
                path.move(to: CGPoint(x: 15, y: 3))
                path.addLine(to: CGPoint(x: 26, y: 26))
                path.addLine(to: CGPoint(x: 15, y: 20))
                path.addLine(to: CGPoint(x: 4, y: 26))
                path.close()
            } else {
                path.append(UIBezierPath(ovalIn: CGRect(x: 6, y: 6, width: 18, height: 18)))
            }
            path.lineJoinStyle = .round
            casing(night: night).setStroke()
            path.lineWidth = 5
            path.stroke()
            ink(alert, night: night).set()
            path.lineWidth = 2
            if alert == .other { path.stroke() } else { path.fill() }
        }
    }

    // Text in the target's ink on a casing capsule, as the route labels are drawn.
    private static func tag(_ text: String, ink: UIColor, night: Bool) -> UIImage {
        let font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .bold)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
        let size = string.size()
        let box = CGRect(x: 0, y: 0, width: ceil(size.width) + 8, height: ceil(size.height) + 2)
        return UIGraphicsImageRenderer(size: box.size).image { _ in
            casing(night: night).withAlphaComponent(0.85).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: box.height / 2).fill()
            string.draw(at: CGPoint(x: 4, y: 1))
        }
    }
}
