import CoreGraphics
import FlightCore
import Foundation
import SwiftUI

/// The rubber band while it is dragged, in map points: the fixed ends, the finger, and what it would snap to.
struct RouteBand: Equatable {
    var anchors: [CGPoint]
    var finger: CGPoint
    var target: CGPoint?
    var label: String?
}

/// The two fingers of a ruler, in map points and on the ground.
struct MapRuler: Equatable {
    var start: CGPoint
    var end: CGPoint
    var from: Coordinate
    var to: Coordinate
}

/// A marker at each finger, the line between them, and the reading at its middle.
struct RulerOverlay: View {
    let ruler: MapRuler

    var body: some View {
        let mid = CGPoint(x: (ruler.start.x + ruler.end.x) / 2, y: (ruler.start.y + ruler.end.y) / 2)
        ZStack {
            Path { path in
                path.move(to: ruler.start)
                path.addLine(to: ruler.end)
            }
            .stroke(.tint, lineWidth: 3)
            Image(systemName: "circle.fill").foregroundStyle(.tint).position(ruler.start)
            Image(systemName: "circle.fill").foregroundStyle(.tint).position(ruler.end)
            // Only the reading follows the fix, for its time en route.
            FixReader { fix in
                MapNotice(text: NavText.ruler(from: ruler.from, to: ruler.to, position: fix.position,
                                              approximate: fix.approximate, now: fix.now))
                    .monospacedDigit()
                    .accessibilityIdentifier("ruler-label")
            }
            .position(mid)
        }
        .allowsHitTesting(false)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// The bent leg in route ink, the 44 point ring at the finger, and what it would snap to above it.
struct RouteBandOverlay: View {
    let band: RouteBand
    @Environment(\.isNight) private var night

    var body: some View {
        let ink = Color(MapInk.route(night: night))
        ZStack {
            Path { path in
                for anchor in band.anchors {
                    path.move(to: anchor)
                    path.addLine(to: band.finger)
                }
            }
            .stroke(ink, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 6]))
            if let target = band.target {
                Image(systemName: "circle.fill").foregroundStyle(ink).position(target)
            }
            Circle()
                .stroke(ink, lineWidth: 3)
                .background(Circle().fill(ink.opacity(band.label == nil ? 0 : 0.2)))
                .frame(width: 44, height: 44) // design-lint: allow ring matches the 44 point snap box
                .position(band.finger)
            if let label = band.label {
                MapNotice(text: label)
                    .position(x: band.finger.x, y: band.finger.y - 60)
                    .accessibilityIdentifier("band-label")
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("route-band")
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
