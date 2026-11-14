import FlightCore
import MapLibre
import SwiftUI

/// The map and its base layer. Other parts of the app plug in through the closures.
struct MapView: View {
    let model: AppModel
    /// Returns a style file for the street base, given the pack files, the night flag and the nav style to merge in.
    /// Runs off the main thread.
    var streetStyle: @Sendable ([URL], Bool, URL?) -> URL? = { _, _, _ in nil }
    /// Returns a new aerial imagery source.
    var aerialSource: @MainActor () -> MLNRasterTileSource? = { nil }
    /// A style file that carries the navigation overlay, used in place of the empty style. Nil for none.
    var navStyle: URL?
    /// Runs after every style load, for anything drawn above the base.
    var onStyleLoaded: @MainActor (MLNMapView, MLNStyle) -> Void = { _, _ in }
    /// Runs when the model's position changes.
    var onPosition: @MainActor (MLNMapView, Position?) -> Void = { _, _ in }
    /// Runs when the user drags the map.
    var onUserPan: @MainActor () -> Void = {}
    /// Runs after the camera settles, with text such as "heading 90 zoom 11".
    var onCamera: @MainActor (String) -> Void = { _ in }
    /// Runs on a tap with the airports, navaids and fixes under the finger, closest first. Empty for open map.
    var onTap: @MainActor ([WaypointMatch]) -> Void = { _ in }
    /// Runs when one finger is held still on the map, with the point under it.
    var onHold: @MainActor (Coordinate) -> Void = { _ in }
    /// The dropped pin to draw. Nil for none.
    var pin: Coordinate?
    /// The drawn route's points, and the first of them with a dot. Read when a held finger bends them.
    var route: @MainActor () -> (points: [Coordinate], firstDot: Int) = { ([], 0) }
    /// Runs when a rubber band is let go, with what was grabbed, what it snaps to and the point under the finger.
    var onBend: @MainActor (RouteGrab, MapPick.Snap, Coordinate) -> Void = { _, _, _ in }

    @State private var street = StreetPacks()
    // The last street style made and what it was made from. It stays up while the next one is made.
    @State private var built: (key: StreetKey, file: URL?)?
    // Goes up when the camera settles where the street style lacks packs.
    @State private var streetMoves = 0
    // What the charts on the map lack under the middle of the screen, if anything.
    @State private var gap: PackCoverage.Gap?
    @State private var ruler: MapRuler?
    @State private var band: RouteBand?

    var body: some View {
        // Read so a settle over new street packs draws again.
        let _ = streetMoves
        let made = street.spec(base: model.baseLayer, installed: model.installedPacks, night: model.nightMode, now: Date())
        let key = StreetKey(made, nav: navStyle)
        let file = key == nil ? nil : built?.file
        // "Unavailable" only once the style for these packs has failed.
        let spec = built?.key == key ? made.resolved(streetStyle: file) : made
        MapCanvas(owner: self, spec: spec, streetFile: file, position: model.position, street: street, gap: $gap,
                  streetMoves: $streetMoves, ruler: $ruler, band: $band)
            .task(id: key) { await build(key) }
            .overlay { if let ruler { RulerOverlay(ruler: ruler) } }
            .overlay { if let band { RouteBandOverlay(band: band) } }
            .overlay {
                if case .nothing(let message) = spec.content {
                    MapNotice(text: message)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("no-chart-label")
                } else if let gap {
                    MapNotice(text: gap.text)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(gap == .chart ? "no-coverage-label" : "no-detail-label")
                }
            }
    }

    // Makes the street style off the main thread with the weather merged in. A failed one is made again only
    // when the packs change or the street base is chosen again. Leaving the street base drops the last one, so
    // coming back never shows a style made for other packs or the other time of day.
    private func build(_ key: StreetKey?) async {
        guard let key else { if built != nil { built = nil }; return }
        guard built?.key != key || built?.file == nil else { return }
        let make = streetStyle
        let file = await Task.detached(priority: .userInitiated) {
            make(key.packs, key.night, key.nav).map { WeatherLayers.styleFile($0) ?? $0 }
        }.value
        if !Task.isCancelled { built = (key, file) }
    }
}

// What a street style file is made from. Nil for any other base.
private struct StreetKey: Equatable, Sendable {
    var packs: [URL]
    var night: Bool
    var nav: URL?

    init?(_ spec: MapStyleSpec, nav: URL?) {
        guard case .street(let packs) = spec.content else { return nil }
        (self.packs, night, self.nav) = (packs, spec.night, nav)
    }
}

/// The street packs on show and where the camera last settled, kept out of view state so a settle redraws nothing.
@MainActor final class StreetPacks {
    private(set) var view: MapStyleSpec.Box?
    private(set) var shown: [URL] = []
    private var boxes: [URL: MapStyleSpec.Box?] = [:]

    /// A pack's extent, read from its file once.
    func bounds(_ pack: URL) -> MapStyleSpec.Box? {
        if let box = boxes[pack] { return box }
        let box = PackCoverage.bounds(pack)
        boxes[pack] = box
        return box
    }

    /// The spec for the last settled view, keeping the street packs on show while they serve it.
    func spec(base: BaseLayer, installed: [PackFile], night: Bool, now: Date) -> MapStyleSpec {
        let made = MapStyleSpec.make(base: base, installed: installed, night: night, now: now, view: view, bounds: bounds)
        guard case .street(let wanted) = made.content else { return made }
        shown = Self.kept(shown, wanted: wanted, installed: Set(installed.map(\.url)))
        return MapStyleSpec(content: .street(shown), night: night)
    }

    /// Notes where the camera settled. True when the street packs on show change for it.
    func settled(on box: MapStyleSpec.Box, base: BaseLayer, installed: [PackFile], night: Bool) -> Bool {
        view = box
        guard base == .street else { return false }
        let before = shown
        _ = spec(base: base, installed: installed, night: night, now: Date())
        return shown != before
    }

    /// The packs on show stay while they hold every pack wanted and are all still installed, so a border
    /// crossed back and forth reloads the style once, not on every crossing.
    static func kept(_ shown: [URL], wanted: [URL], installed: Set<URL>) -> [URL] {
        Set(wanted).isSubset(of: shown) && shown.allSatisfy(installed.contains) ? shown : wanted
    }
}

private struct MapCanvas: UIViewRepresentable {
    let owner: MapView
    let spec: MapStyleSpec
    let streetFile: URL?
    let position: Position?
    let street: StreetPacks
    @Binding var gap: PackCoverage.Gap?
    @Binding var streetMoves: Int
    @Binding var ruler: MapRuler?
    @Binding var band: RouteBand?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: WeatherLayers.styleFile(Coordinator.emptyStyle) ?? Coordinator.emptyStyle)
        map.delegate = context.coordinator
        map.accessibilityIdentifier = "map"
        // The tracking button is the only way to turn the map.
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        // The map buttons carry their own compass.
        map.compassView.compassVisibility = .hidden
        // The settings buttons sit in that corner; MapLibre is credited under Legal.
        map.logoView.isHidden = true
        // Where the map was left, or where an option says, until a position says otherwise.
        let camera = owner.model.launch.camera
        map.setCenter(CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude),
                      zoomLevel: camera.zoom, animated: false)
        // A single tap must wait for the map's own double tap to fail, or zooming would open pages.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        for other in map.gestureRecognizers ?? [] where other is UITapGestureRecognizer {
            tap.require(toFail: other)
        }
        // Touch and hold drops a pin; a tap waits for it to fail, which happens as the finger lifts.
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.5
        tap.require(toFail: hold)
        map.addGestureRecognizer(hold)
        map.addGestureRecognizer(tap)
        // Two fingers held still measure; fingers that move first stay a pinch or a pan.
        let measure = UILongPressGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.measured(_:)))
        measure.numberOfTouchesRequired = 2
        measure.minimumPressDuration = 0.3
        map.addGestureRecognizer(measure)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.owner = owner
        coordinator.gap = $gap
        coordinator.street = street
        coordinator.streetMoves = $streetMoves
        coordinator.ruler = $ruler
        coordinator.band = $band
        coordinator.showPin(owner.pin, on: map)
        coordinator.show(spec, streetFile: streetFile, base: owner.navStyle ?? Coordinator.emptyStyle, on: map)
        if coordinator.lastPosition != position {
            coordinator.lastPosition = position
            owner.onPosition(map, position)
        }
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        // A nil style URL would load a remote demo style, so a missing file must stop here.
        static var emptyStyle: URL {
            Bundle.main.url(forResource: "empty", withExtension: "json", subdirectory: "MapAssets")!
        }

        var owner: MapView?
        var lastPosition: Position?
        private var wanted: MapStyleSpec?
        private var drawn: MapStyleSpec?
        private var styleFile = Coordinator.emptyStyle
        private var isStreet = false
        private var added: [String] = []
        var gap: Binding<PackCoverage.Gap?>?
        var street: StreetPacks?
        var streetMoves: Binding<Int>?
        var ruler: Binding<MapRuler?>?
        var band: Binding<RouteBand?>?
        private var grab: RouteGrab?
        private var pinMark: MLNPointAnnotation?
        private let coverage = PackCoverage()
        // The newest coverage answer, kept here until it is written to the view.
        private var missing: PackCoverage.Gap?

        // Works out what the charts on the map lack under the middle of the screen.
        private func checkCoverage(_ map: MLNMapView) {
            if case .charts(let rasters) = drawn?.content {
                let center = map.centerCoordinate
                // The wide-area pack under the state packs is too coarse to stand in for them up close.
                let overviews = rasters.filter { $0.identifier.hasSuffix(":" + ChartLibrary.overviewRegion) }
                missing = coverage.gap(rasters.map(\.url), overviews: Set(overviews.map(\.url)),
                                       latitude: center.latitude, longitude: center.longitude, zoom: map.zoomLevel)
            } else {
                missing = nil
            }
            // Set a moment later, because the camera can settle in the middle of a view update.
            // The write reads the newest answer, so two camera moves in one pass cannot leave an old one behind.
            Task { @MainActor in
                if self.gap?.wrappedValue != self.missing { self.gap?.wrappedValue = self.missing }
            }
        }

        func show(_ spec: MapStyleSpec, streetFile: URL?, base: URL, on map: MLNMapView) {
            wanted = spec
            // A street style still being made leaves the map as it is. One that failed arrives as a label.
            if case .street = spec.content, streetFile == nil { return }
            let file = streetFile ?? base
            if file != styleFile {
                // A new style file reloads everything. Drawing continues when it has loaded.
                styleFile = file
                isStreet = streetFile != nil
                drawn = nil
                added = []
                // The street style comes with the weather already merged in.
                map.styleURL = isStreet ? file : WeatherLayers.styleFile(file) ?? file
                return
            }
            guard spec != drawn else { return }
            if let style = map.style { draw(spec, on: style) }
            checkCoverage(map)
        }

        private func draw(_ spec: MapStyleSpec, on style: MLNStyle) {
            for identifier in added {
                if let layer = style.layer(withIdentifier: identifier) { style.removeLayer(layer) }
                if let source = style.source(withIdentifier: identifier) { style.removeSource(source) }
            }
            added = []
            // The street styles bring their own background, so only the other base styles are recolored.
            if !isStreet,
               let background = style.layer(withIdentifier: "background") as? MLNBackgroundStyleLayer {
                let white = NightPaint.backgroundWhite(night: spec.night)
                background.backgroundColor = NSExpression(forConstantValue: UIColor(white: white, alpha: 1)) // design-lint: allow ground value until it moves into MapInk
            }
            var sources: [MLNRasterTileSource] = []
            var paint: NightPaint.Values?
            func packs(_ rasters: [MapStyleSpec.Raster]) {
                for raster in rasters {
                    guard let url = URL(string: "pmtiles://" + raster.url.absoluteString) else { continue }
                    // Tile size 256 makes the top zoom of a pack appear 1.5 camera zooms earlier than 512 would.
                    sources.append(MLNRasterTileSource(identifier: raster.identifier, configurationURL: url,
                                                       tileSize: 256))
                }
            }
            switch spec.content {
            case .charts(let rasters):
                paint = NightPaint.values(night: spec.night)
                packs(rasters)
            case .terrain(let rasters):
                paint = NightPaint.terrainValues(night: spec.night)
                packs(rasters)
            case .aerial:
                if let source = owner?.aerialSource() { sources.append(source) }
            case .street, .nothing:
                break
            }
            for (index, source) in sources.enumerated() {
                style.addSource(source)
                let layer = MLNRasterStyleLayer(identifier: source.identifier, source: source)
                layer.rasterFadeDuration = NSExpression(forConstantValue: 0)
                if let paint { NightPaint.apply(paint, to: layer) }
                // Index 0 is the background. Base rasters sit straight above it, under everything else.
                style.insertLayer(layer, at: UInt(index + 1))
                added.append(source.identifier)
            }
            drawn = spec
        }

        func mapView(_ map: MLNMapView, didFinishLoading style: MLNStyle) {
            if let wanted { draw(wanted, on: style) }
            checkCoverage(map)
            owner?.onStyleLoaded(map, style)
        }

        func mapView(_ map: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            if MapFollow.breaks(reason) { owner?.onUserPan() }
        }

        // The map view reports its own accessibility value, so the heading and zoom go out through a closure.
        func mapView(_ map: MLNMapView, regionDidChangeAnimated animated: Bool) {
            owner?.onCamera("heading \(Int(map.direction.rounded())) zoom \(Int(map.zoomLevel.rounded()))")
            checkCoverage(map)
            let seen = map.visibleCoordinateBounds
            let box = MapStyleSpec.Box(minLatitude: seen.sw.latitude, minLongitude: seen.sw.longitude,
                                       maxLatitude: seen.ne.latitude, maxLongitude: seen.ne.longitude)
            // Only a change of street packs redraws, so following the aircraft draws once per fix.
            guard let owner, street?.settled(on: box, base: owner.model.baseLayer, installed: owner.model.installedPacks,
                                             night: owner.model.nightMode) == true else { return }
            Task { @MainActor in self.streetMoves?.wrappedValue &+= 1 }
        }

        @objc func tapped(_ sender: UITapGestureRecognizer) {
            guard let map = sender.view as? MLNMapView else { return }
            owner?.onTap(MapPick.here(hits(at: sender.location(in: map), on: map)))
        }

        // The airports, navaids and fixes around a point, with their distance from it in points.
        private func hits(at point: CGPoint, on map: MLNMapView) -> [(WaypointMatch, Double)] {
            // A finger is wider than the symbol, so the box searched is 44 points across.
            let side = NavPages.pickBox
            let box = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
            let found = map.visibleFeatures(in: box, styleLayerIdentifiers: Set(NavPages.pickLayers))
            let hits = found.compactMap { feature -> (WaypointMatch, Double)? in
                guard let ident = feature.attribute(forKey: "ident") as? String,
                      let kind = (feature.attribute(forKey: "kind") as? String).flatMap(WaypointKind.init) else { return nil }
                let at = map.convert(feature.coordinate, toPointTo: map)
                let place = WaypointMatch(kind: kind, ident: ident, icao: feature.attribute(forKey: "icao") as? String,
                                          name: feature.attribute(forKey: "name") as? String ?? ident,
                                          coordinate: Coordinate(latitude: feature.coordinate.latitude,
                                                                 longitude: feature.coordinate.longitude))
                return (place, Double(hypot(at.x - point.x, at.y - point.y)))
            }
            // A station dot opens its airport, unless the airport's own dot was hit too.
            let stations = map.visibleFeatures(in: box, styleLayerIdentifiers: ["wx-stations-dot"]).compactMap {
                feature -> (WaypointMatch, Double)? in
                guard let station = feature.attribute(forKey: "station") as? String,
                      !hits.contains(where: { $0.0.kind == .airport && ($0.0.icao == station || $0.0.ident == station) })
                else { return nil }
                let at = map.convert(feature.coordinate, toPointTo: map)
                let place = WaypointMatch(kind: .airport, ident: station, icao: station, name: station,
                                          coordinate: Coordinate(latitude: feature.coordinate.latitude,
                                                                 longitude: feature.coordinate.longitude))
                return (place, Double(hypot(at.x - point.x, at.y - point.y)))
            }
            return hits + stations
        }

        // A hold on the route line bends it with the finger; anywhere else it drops a pin.
        @objc func held(_ sender: UILongPressGestureRecognizer) {
            guard let map = sender.view as? MLNMapView, let owner else { return }
            let finger = sender.location(in: map)
            let ground = map.convert(finger, toCoordinateFrom: map)
            let at = Coordinate(latitude: ground.latitude, longitude: ground.longitude)
            switch sender.state {
            case .began:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let route = owner.route()
                let points = route.points.map {
                    map.convert(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude), toPointTo: map)
                }
                guard let grabbed = MapPick.grab(points.map { ScreenPoint(x: $0.x, y: $0.y) }, firstDot: route.firstDot,
                                                 at: ScreenPoint(x: finger.x, y: finger.y)) else {
                    return owner.onHold(at)
                }
                grab = grabbed
                // The map holds still while the line is bent.
                map.isScrollEnabled = false
                let anchors = MapPick.anchors(grabbed, count: points.count).map { points[$0] }
                band?.wrappedValue = RouteBand(anchors: anchors, finger: finger)
                bend(to: finger, on: map)
            case .changed:
                if grab != nil { bend(to: finger, on: map) }
            case .ended:
                guard let grabbed = grab else { return }
                let snap = MapPick.snap(hits(at: finger, on: map))
                letGo(map)
                owner.onBend(grabbed, snap, at)
            default:
                letGo(map)
            }
        }

        private func bend(to finger: CGPoint, on map: MLNMapView) {
            band?.wrappedValue?.finger = finger
            let snap = MapPick.snap(hits(at: finger, on: map))
            band?.wrappedValue?.label = snap.label
            band?.wrappedValue?.target = if case .one(let place) = snap {
                map.convert(CLLocationCoordinate2D(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
                            toPointTo: map)
            } else { nil }
        }

        private func letGo(_ map: MLNMapView) {
            grab = nil
            map.isScrollEnabled = true
            band?.wrappedValue = nil
        }

        @objc func measured(_ sender: UILongPressGestureRecognizer) {
            guard let map = sender.view as? MLNMapView else { return }
            guard sender.state == .began || sender.state == .changed, sender.numberOfTouches >= 2 else {
                ruler?.wrappedValue = nil
                return
            }
            let start = sender.location(ofTouch: 0, in: map)
            let end = sender.location(ofTouch: 1, in: map)
            func ground(_ point: CGPoint) -> Coordinate {
                let at = map.convert(point, toCoordinateFrom: map)
                return Coordinate(latitude: at.latitude, longitude: at.longitude)
            }
            ruler?.wrappedValue = MapRuler(start: start, end: end, from: ground(start), to: ground(end))
        }

        // One pin at most: moved by removing the old mark and adding a new one.
        func showPin(_ pin: Coordinate?, on map: MLNMapView) {
            let shown = pinMark.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            guard shown != pin else { return }
            if let pinMark { map.removeAnnotation(pinMark) }
            pinMark = nil
            guard let pin else { return }
            let mark = MLNPointAnnotation()
            mark.coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
            map.addAnnotation(mark)
            pinMark = mark
        }

        func mapView(_ map: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            if let image = map.dequeueReusableAnnotationImage(withIdentifier: "pin") { return image }
            let look = UIImage.SymbolConfiguration(textStyle: .title1)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed])) // design-lint: allow pin glyph on its red disc
            return UIImage(systemName: "mappin.circle.fill", withConfiguration: look)
                .map { MLNAnnotationImage(image: $0, reuseIdentifier: "pin") }
        }

        // UI tests wait for this identifier before taking a screenshot.
        func mapViewDidFinishLoadingMap(_ map: MLNMapView) {
            map.accessibilityIdentifier = "mapLoaded"
        }
    }
}
