import FlightCore
import MapLibre
import SwiftUI

extension Color {
    /// A core category color name: green, blue, red, magenta or gray.
    static func category(_ name: String?) -> Color {
        switch name {
        case "green": .green
        case "blue": .blue
        case "red": .red
        case "magenta": .pink
        default: .gray
        }
    }
}

/// The counts, then the worst items in red or amber.
struct BriefHazards: View {
    let graphics: BriefGraphics

    var body: some View {
        VStack(alignment: .leading) {
            Text(graphics.counts).font(.subheadline)
            ForEach(Array(graphics.hazards.enumerated()), id: \.offset) { _, hazard in
                StateWord(hazard.severe ? .danger : .warning, hazard.text, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("brief-hazards")
    }
}

/// A map snapshot, or a gray box with a spinner until it is drawn.
struct BriefPicture: View {
    let title: String
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading) {
            Group {
                if let image {
                    Image(uiImage: image).resizable()
                } else {
                    Rectangle().fill(.quaternary).overlay { ProgressView() }
                }
            }
            .aspectRatio(BriefMap.width / BriefMap.height, contentMode: .fit)
            .clipShape(.rect(cornerRadius: BriefLayout.corner))
            if !title.isEmpty { Text(title).note() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isImage)
    }
}

enum BriefLayout {
    static let corner = 8.0
    static let profileAspect = 2.4
}

/// The side view: ground, clouds by category, the 0°C line, cruise and its winds, waypoints below.
struct BriefProfileChart: View {
    let profile: BriefProfile

    var body: some View {
        VStack(alignment: .leading) {
            Canvas { context, size in draw(&context, size) }
                .aspectRatio(BriefLayout.profileAspect, contentMode: .fit)
            Text(profile.caption).note()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BriefGraphics.profileTitle)
        .accessibilityValue(profile.caption)
        .accessibilityIdentifier("brief-profile")
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let labels = 16.0
        let plot = CGRect(x: 0, y: 0, width: size.width, height: size.height - labels)
        let length = max(profile.lengthNM, 1), top = Double(profile.topFt)
        func x(_ nm: Double) -> Double { plot.minX + nm / length * plot.width }
        func y(_ ft: Double) -> Double { plot.maxY - ft / top * plot.height }
        context.clip(to: Path(CGRect(origin: .zero, size: size)))

        context.fill(Path(plot), with: .color(.secondary.opacity(0.08)))
        for tick in profile.grid {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(tick.value)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(tick.value)))
            context.stroke(line, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
            context.draw(Text(tick.text).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: plot.minX + 2, y: y(tick.value) - 1), anchor: .bottomLeading)
        }
        for g in profile.ground {
            let box = CGRect(x: x(g.fromNM), y: y(Double(g.ft)), width: x(g.toNM) - x(g.fromNM), height: plot.maxY - y(Double(g.ft)))
            context.fill(Path(box), with: .color(.gray.opacity(0.55)))
        }
        for run in profile.freezing where run.count > 0 {
            var line = Path()
            line.move(to: CGPoint(x: x(run[0][0]), y: y(run[0][1])))
            for p in run.dropFirst() { line.addLine(to: CGPoint(x: x(p[0]), y: y(p[1]))) }
            context.stroke(line, with: .color(.blue), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
        for cloud in profile.clouds {
            let color = Color.category(cloud.color)
            context.fill(Path(ellipseIn: CGRect(x: x(cloud.nm) - 4, y: plot.maxY - 4, width: 8, height: 8)), with: .color(color))
            guard let ft = cloud.ft else { continue }
            let bar = CGRect(x: x(cloud.nm) - 10, y: y(Double(ft)) - 2, width: 20, height: 4)
            context.fill(Path(roundedRect: bar, cornerSize: CGSize(width: 2, height: 2)), with: .color(color.opacity(cloud.ceiling ? 1 : 0.5)))
        }
        var cruise = Path()
        cruise.move(to: CGPoint(x: plot.minX, y: y(Double(profile.cruiseFt))))
        cruise.addLine(to: CGPoint(x: plot.maxX, y: y(Double(profile.cruiseFt))))
        context.stroke(cruise, with: .color(Color(MapInk.route(night: false))), lineWidth: 2.5)
        for barb in profile.winds {
            let at = CGPoint(x: x(barb.nm), y: y(Double(barb.ft)))
            var path = Path()
            for l in barb.lines where l.count == 4 {
                path.move(to: CGPoint(x: at.x + l[0], y: at.y + l[1]))
                path.addLine(to: CGPoint(x: at.x + l[2], y: at.y + l[3]))
            }
            context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: barb.lineWidth * 1.6, lineCap: .round))
            for t in barb.triangles where t.count == 6 {
                var flag = Path()
                flag.move(to: CGPoint(x: at.x + t[0], y: at.y + t[1]))
                flag.addLine(to: CGPoint(x: at.x + t[2], y: at.y + t[3]))
                flag.addLine(to: CGPoint(x: at.x + t[4], y: at.y + t[5]))
                flag.closeSubpath()
                context.fill(flag, with: .color(.primary))
            }
            if let r = barb.ring {
                context.stroke(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)), with: .color(.primary))
            }
        }
        for (n, mark) in profile.waypoints.enumerated() {
            var tick = Path()
            tick.move(to: CGPoint(x: x(mark.value), y: plot.maxY))
            tick.addLine(to: CGPoint(x: x(mark.value), y: plot.maxY + 4))
            context.stroke(tick, with: .color(.secondary), lineWidth: 1)
            let anchor: UnitPoint = n == 0 ? .topLeading : n == profile.waypoints.count - 1 ? .topTrailing : .top
            context.draw(Text(mark.text).font(.caption2.weight(.semibold)), at: CGPoint(x: x(mark.value), y: plot.maxY + 3),
                         anchor: anchor)
        }
    }
}

/// An airport's category, weather rows, best runways and the TAF across its time.
struct BriefAirportPanel: View {
    let airport: BriefAirport
    @ScaledMetric private var bar = 10.0

    var body: some View {
        let wx = airport.weather
        VStack(alignment: .leading) {
            HStack {
                Text(airport.title).font(.headline)
                Spacer()
                if let category = wx.category?.value {
                    Text(category).font(.caption.weight(.bold)).foregroundStyle(.background)
                        .padding(.horizontal).background(Color.category(wx.color), in: .capsule)
                }
            }
            if wx.lines.isEmpty { Text(wx.note).note() }
            ForEach(Array(wx.lines.enumerated()), id: \.offset) { _, line in
                LabeledContent(line.title, value: line.value ?? NavText.dashes).font(.subheadline)
            }
            ForEach(Array(wx.runways.prefix(2).enumerated()), id: \.offset) { _, runway in
                LabeledContent("Runway \(runway.end)", value: runway.wind).font(.subheadline)
            }
            if let note = airport.tafNote {
                Text(note).note()
            } else {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.15)))
                    for span in airport.spans {
                        let box = CGRect(x: span.from * size.width, y: 0, width: (span.to - span.from) * size.width, height: size.height)
                        context.fill(Path(box), with: .color(Color.category(span.color)))
                    }
                    let mark = CGRect(x: airport.mark * size.width - 1, y: 0, width: 2, height: size.height)
                    context.fill(Path(mark), with: .color(.primary))
                }
                .frame(height: bar)
                .clipShape(.capsule)
                HStack {
                    ForEach(Array(airport.times.enumerated()), id: \.offset) { n, time in
                        if n > 0 { Spacer() }
                        Text(time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Snapshots one core style over the brief's box. MapLibre renders off the main thread.
@MainActor enum BriefSnapshot {
    @MainActor private final class Shot {
        var snapshotter: MLNMapSnapshotter?
        var done: CheckedContinuation<UIImage?, Never>?
        func finish(_ image: UIImage?) {
            done?.resume(returning: image)
            done = nil
            snapshotter = nil
        }
    }

    static func take(_ picture: BriefMap.Picture, bounds: MapStyleSpec.Box, scale: CGFloat) async -> UIImage? {
        let file = URL.temporaryDirectory.appending(path: "brief-\(picture.id).json")
        let style = picture.style
        guard (try? await Task.detached { try style.write(to: file, atomically: true, encoding: .utf8) }.value) != nil else { return nil }
        let options = MLNMapSnapshotOptions(styleURL: file, camera: MLNMapCamera(),
                                            size: CGSize(width: BriefMap.width, height: BriefMap.height))
        options.coordinateBounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: bounds.minLatitude, longitude: bounds.minLongitude),
            ne: CLLocationCoordinate2D(latitude: bounds.maxLatitude, longitude: bounds.maxLongitude))
        options.scale = scale
        options.showsLogo = false
        let shot = Shot()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                shot.done = continuation
                let snapshotter = MLNMapSnapshotter(options: options)
                shot.snapshotter = snapshotter
                snapshotter.start { snapshot, _ in
                    let image = snapshot?.image
                    MainActor.assumeIsolated { shot.finish(image) }
                }
            }
        } onCancel: {
            Task { @MainActor in
                shot.snapshotter?.cancel()
                shot.finish(nil)
            }
        }
    }
}
