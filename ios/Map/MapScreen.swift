import FlightCore
import MapLibre
import Network
import SwiftUI

/// Watches whether the device has any network path.
@MainActor @Observable final class NetworkPath {
    private(set) var isSatisfied = true
    /// Goes up on every path change, such as joining another Wi-Fi network.
    private(set) var changes = 0
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.isSatisfied = satisfied
                self?.changes += 1
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }
}

/// Holds the map view so a button can move the camera without waiting for the next fix.
@MainActor private final class MapHandle {
    weak var map: MLNMapView?
    var zoomedToFirstFix = false
    var weatherShapes: Task<Void, Never>?
    /// The place last moved into view; a pan clears it, so turning the device leaves the map alone.
    var revealed: Coordinate?
    /// Where the strip and its route end, in map points.
    var stripBottom: CGFloat = 0
    /// The nav overlay groups the map shows, for the test probe.
    var navShown: [String] = []
    var remembered = Date.distantPast
    /// The latest live fix at flying speed, which the background rule carries from fix to fix.
    var lastFast: Date?
    /// The traffic socket is to be opened afresh: at launch and after the app was in the background.
    var listenAgain = true
}

/// When the aerial base is checked again: a new base, a return to the front or a new network path.
private struct AerialCheck: Equatable {
    var base: BaseLayer
    var front: Bool
    var path: Int
}

/// The whole screen: the map, with the data strip, banner, buttons and one panel drawn over it.
struct MapScreen: View {
    let model: AppModel
    let downloads: DownloadsModel
    let navDownloads: DownloadsModel
    let streetDownloads: DownloadsModel
    let terrainDownloads: DownloadsModel

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Moves the camera at once instead of flying it there.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    @Environment(\.scenePhase) private var scenePhase
    @State private var location = LocationProvider()
    @State private var ownship = OwnshipLayer()
    @State private var traffic = TrafficReceiver()
    @AppStorage(OwnshipSource.key) private var ownshipSource = OwnshipSource.auto
    @State private var routeLine = RouteLine()
    @State private var ring = PlaceRing()
    /// The place a place card or Show on Map shows, while its panel stays open.
    @State private var focus: Coordinate?
    @State private var placeProbe = ""
    @State private var catalog = LayerCatalog(groups: WeatherLayers.restore([WeatherSwitches.withTfrs(NavOverlay.layerGroup), WeatherSwitches.layerGroup,
                                                                             TrafficStore.layerGroup], from: .standard))
    @State private var weather = WeatherStore.make(options: .current)
    @AppStorage(StationShow.key) private var stationShow = StationShow.category
    /// 0 until the pilot picks a winds aloft level.
    @AppStorage(WindsMap.levelKey) private var chosenWindsLevel = 0
    @AppStorage(RoutePages.planInputsKey) private var storedInputs = Data()
    @State private var nav: NavModel
    @State private var plates: Plates
    // Empty until the map has reported once, so a test can tell that it has.
    @State private var navProbe = ""
    @State private var network = NetworkPath()
    @State private var handle = MapHandle()
    @State private var isFollowing: Bool
    @State private var aerialReachable = true
    @State private var panel: MapPanel?
    @State private var place: PlaceRoot?
    @State private var showsSettings: Bool
    @State private var cameraText = ""
    @State private var windowWidth: CGFloat = 0
    @State private var sheetHeight: CGFloat = 0
    /// Where the strip starts and where the banners and credit start, in the window, so the route drawer stops above them.
    @State private var stripTop: CGFloat = 0
    @State private var bannersTop = CGFloat.infinity
    @State private var drawerOpen = true
    @Environment(\.colorScheme) private var scheme
    @State private var detent: PresentationDetent = .medium
    @State private var cardForm = false
    @State private var heldForm: Bool?
    // Pages pushed in the panel, kept here so the turn from sheet to card keeps them.
    @State private var panelPath = NavigationPath()
    // Set while a let-go rubber band waits for one of several places.
    @State private var bendPick: ((WaypointMatch) -> Void)?
    // The route panel grown into the planning page; map taps then open a popover over the map.
    @State private var routeWide = false
    @State private var widePlace: PlaceRoot?
    /// After a bend drops a plain point, the places near it that could take its place.
    @State private var bendSuggest: (target: Int, places: [WaypointMatch], at: CGPoint)?

    init(model: AppModel, downloads: DownloadsModel, navDownloads: DownloadsModel, streetDownloads: DownloadsModel,
         terrainDownloads: DownloadsModel, plateDownloads: DownloadsModel) {
        self.model = model
        self.downloads = downloads
        self.navDownloads = navDownloads
        self.streetDownloads = streetDownloads
        self.terrainDownloads = terrainDownloads
        // Nothing here reads what these models hold: the parent watches what an init reads, so a model's own later
        // change would build the screen again, with new models, without end. They are put to work in onAppear.
        let nav = NavModel()
        nav.configure(options: model.options, savedRoute: model.launch.route)
        nav.mapPacks = { [model] in model.installedPacks }
        _nav = State(initialValue: nav)
        _plates = State(initialValue: Plates(options: model.options, placed: model.launch.plates, downloads: plateDownloads))
        _isFollowing = State(initialValue: model.launch.following)
        _panel = State(initialValue: model.options.string("show").flatMap(MapPanel.init(rawValue:)))
        _showsSettings = State(initialValue: model.options.string("show") == "downloads")
    }

    private var installedPacks: [PackFile] {
        bundled + (offline ? [] : downloadedPacks)
    }

    private var downloadedPacks: [PackFile] {
        downloads.installed + streetDownloads.installed + terrainDownloads.installed
    }

    private var bundled: [PackFile] {
        model.options.string("basePack").map(AppModel.bundledPacks(named:)) ?? []
    }

    // Tests pass -offline 1: no manifest fetch, no download, no imagery, and no downloaded pack on the map.
    private var offline: Bool { model.options.flag("offline") }
    private var gdl90Port: UInt16 { model.options.string("gdl90Port").flatMap(UInt16.init) ?? GDL90.port }
    // The one place the panel's form is chosen: a card beside the buttons, or the system sheet.
    // It holds while a chart is open: the panel presents the reader, so a turn that changed the form would close both.
    private var usesCard: Bool { heldForm ?? (sizeClass == .regular || verticalSizeClass == .compact) }
    private var probes: Bool { model.options.flag("probes") }

    // Launches with bundled packs, and unit test runs, stay off the network.
    private var fetchesCharts: Bool {
        bundled.isEmpty && !offline && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    // Seconds between fetches of the chart list while the app stays open. A test shortens it.
    private var listRefresh: Double { max(model.options.double("listRefresh") ?? 3600, 1) }

    var body: some View {
        MapView(model: model,
                streetStyle: { packs, night, nav in StreetStyle.styleURL(packs: packs, dark: night, nav: nav) },
                aerialSource: { offline ? nil : AerialSource.make() },
                navStyle: nav.styleFile,
                onStyleLoaded: { map, style in
                    handle.map = map
                    ownship.install(on: style, map: map, night: model.nightMode)
                    routeLine.install(on: style, night: model.nightMode)
                    ring.install(on: style, night: model.nightMode)
                    traffic.layer.install(on: style, night: model.nightMode)
                    traffic.layer.show(trafficOn)
                    NavOverlay.paint(night: model.nightMode, style: style)
                    WeatherLayers.paint(night: model.nightMode, style: style)
                    PlateOverlay.show(plates.onMap, on: style, night: model.nightMode)
                    refreshNavLayers()
                    refreshWeather()
                },
                onPosition: { map, position in
                    ownship.approximate = location.isApproximate
                    ownship.update(position)
                    advanceRoute(position)
                    drawRoute()
                    if let position {
                        if isFollowing { follow(map, position) } else { turn(map, position) }
                    }
                },
                onUserPan: { isFollowing = false; handle.revealed = nil },
                onCamera: { text in
                    // Following moves the camera with every fix, so then it is saved at most once a minute.
                    let saves = !isFollowing || Date().timeIntervalSince(handle.remembered) > 60
                    guard saves || probes else { return }
                    // Set a moment later, because the camera can settle in the middle of a view update.
                    Task { @MainActor in
                        if saves { remember() }
                        guard probes else { return }
                        if cameraText != text { cameraText = text }
                        probePlace()
                    }
                },
                onTap: tapped,
                onHold: { point in
                    bendPick = nil
                    if routeWide && panel == .route { widePlace = .one(NavPages.pin(at: point)); return }
                    place = .one(NavPages.pin(at: point))
                    open(.place)
                },
                pin: widePlace?.pin ?? (panel == .place ? place?.pin : nil),
                route: { drawnRoute.map { ($0.route.waypoints.map(\.coordinate), $0.firstDot) } ?? ([], 0) },
                onBend: bent)
            .ignoresSafeArea()
            .overlay { if let offer = bendSuggest { suggestion(offer) } }
            // UI tests read the map's heading and zoom, and what the map holds, from these.
            .overlay(alignment: .bottomLeading) { if probes { probe(cameraText, "map-camera") } }
            .overlay(alignment: .bottomTrailing) { if probes { probe(navProbe, "map-nav") } }
            .overlay(alignment: .topLeading) { if probes { probe(placeProbe, "map-place") } }
            .overlay { aerialNotice }
            // Notices sit above the sheet when one is up, else above MapLibre's attribution button.
            .overlay(alignment: .bottomTrailing) {
                bottomStack
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { bannersTop = $0 }
                    .padding(chromeInset).padding(.bottom, sheetHeight > 0 ? sheetHeight : 28)
                    // Clear of the control column, and of the card when one is open.
                    .padding(.leading, MapButton.size + chromeInset + (usesCard && panel != nil ? cardWidth + chromeInset : 0))
            }
            // The strip stays at the trailing edge, so an open panel never moves it.
            .overlay(alignment: .topTrailing) {
                topStack
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                        stripTop = frame.minY
                        handle.stripBottom = frame.maxY + chromeInset
                    }
                    // The route drawer gives way before it reaches the banners or the sheet.
                    .frame(maxHeight: max(bannersTop - stripTop - chromeInset, 0), alignment: .top)
                    .padding(chromeInset)
            }
            .overlay(alignment: .topLeading) {
                GlassEffectContainer {
                    HStack(alignment: .top, spacing: chromeInset) {
                        controls
                        if usesCard, let panel { card(panel) }
                    }
                }
                .padding(chromeInset)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { windowWidth = $0 }
            // Turning to the card form dismisses the sheet, so a dismissal is acted on only if the form is still a sheet.
            .sheet(item: Binding(get: { usesCard ? nil : panel },
                                 set: { new in Task { @MainActor in if !cardForm { panel = new } } })) { shown in
                panelBody(shown)
                    .presentationDetents([.medium, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { sheetHeight = $0 }
                    .onDisappear { sheetHeight = 0 }
            }
            .fullScreenCover(isPresented: $showsSettings) {
                SettingsPage(model: model, downloads: downloads, navDownloads: navDownloads, procedures: plates.downloads,
                             street: streetDownloads, terrain: terrainDownloads,
                             online: network.isSatisfied, opensDownloads: model.options.string("show") == "downloads",
                             aircraft: nav.aircraft, traffic: traffic, onClose: { showsSettings = false })
            }
            .onChange(of: plates.reading) { _, reading in heldForm = reading ? usesCard : nil }
            .onChange(of: usesCard, initial: true) { _, card in
                cardForm = card
                if !card { routeWide = false }
            }
            .onChange(of: routeWide) { _, wide in
                if wide { fitRoute() } else { widePlace = nil; bendPick = nil; focus = nil }
            }
            .environment(\.isNight, model.nightMode)
            .environment(\.fixedNow, nav.fixedNow)
            .environment(\.showArea, { showOnMap($0) })
            .preferredColorScheme(model.forcesDark ? .dark : nil)
            // The screen stays awake while the map is showing. Before the first frame: the packs on the device, so
            // no chart is named as missing, and the nav tile style, which the data's open sets at once.
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                model.installedPacks = installedPacks
                openNavFiles()
                plates.start()
            }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .task {
                location.start()
                weather.start()
            }
            // A socket left open in a suspended app can be taken away, so each return from the background listens
            // afresh. A pass through inactive alone, as for Control Center, keeps the socket.
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active, handle.listenAgain {
                    handle.listenAgain = false
                    traffic.start(port: gdl90Port)
                }
                guard phase == .background else { return }
                handle.listenAgain = true
                remember()
                if !location.runsInBackground { traffic.stop() }
            }
            // Out of the front the app keeps running while flying or while a receiver talks, and sleeps on the ground.
            .task(id: scenePhase) { [location, traffic] in
                let front = scenePhase == .active
                // A session made without location access may never start, so each return to the front makes a new one.
                if front { location.keepRunning(until: nil, inFront: true) }
                for await (fix, heard) in Observations({ (location.position, traffic.status.lastMessage) }) {
                    let rule = BackgroundPolicy.runsUntil(position: fix, lastFast: handle.lastFast, receiverHeard: heard, now: Date())
                    handle.lastFast = rule.lastFast
                    location.keepRunning(until: rule.until, inFront: front)
                }
            }
            // The chart list is fetched at launch, on every return to the front, and then on a slow timer,
            // so an app left open still learns of the next cycle.
            .task(id: scenePhase) {
                guard scenePhase == .active, fetchesCharts else { return }
                while !Task.isCancelled {
                    // Run on its own, so leaving the app mid-fetch is not reported as no connection.
                    for list in [downloads, navDownloads, plates.downloads, streetDownloads, terrainDownloads] {
                        await Task { await list.refresh() }.value
                    }
                    try? await Task.sleep(for: .seconds(listRefresh))
                }
            }
            // A joined network with no internet still reports a path, so one tile is asked for.
            .task(id: AerialCheck(base: model.baseLayer, front: scenePhase == .active, path: network.changes)) {
                guard model.baseLayer == .aerial, !offline else {
                    aerialReachable = true
                    return
                }
                guard scenePhase == .active else { return }
                let reachable = await AerialSource.isReachable(model.options.string("aerialProbe"))
                if !Task.isCancelled, reachable != aerialReachable { aerialReachable = reachable }
            }
            // Copied outside the body, so a new fix does not redraw the whole screen.
            .task { [location, traffic] in
                for await fix in Observations({ location.position }) {
                    model.position = fix
                    traffic.setReference(fix)
                }
            }
            .task { [location, traffic] in for await fix in Observations({ traffic.position }) { location.receiver = fix } }
            .modifier(RouteActivityFeed(nav: nav, location: location, traffic: traffic))
            // The flags read the receiver's fix, so they too are copied outside the body.
            .task { [location] in
                var last: [Bool] = []
                for await flags in Observations({ [location.isStale, location.isApproximate] }) where flags != last {
                    last = flags
                    ownship.approximate = flags[1]
                    ownship.update(model.position)
                    drawRoute()
                }
            }
            .onChange(of: ownshipSource, initial: true) { _, source in location.source = source }
            .onChange(of: nav.route) { _, _ in drawRoute() }
            .onChange(of: downloadedPacks) { _, _ in model.installedPacks = installedPacks }
            .onChange(of: model.orientation) { _, _ in settleCamera(following: isFollowing) }
            .onChange(of: plates.onMap) { _, shown in
                if let style = handle.map?.style { PlateOverlay.show(shown, on: style, night: model.nightMode) }
            }
            .onChange(of: model.nightMode) { _, night in
                ownship.paint(night: night)
                routeLine.paint(night: night)
                ring.paint(night: night)
                traffic.layer.paint(night: night)
                if let style = handle.map?.style {
                    PlateOverlay.show(plates.onMap, on: style, night: night)
                    NavOverlay.paint(night: night, style: style)
                    WeatherLayers.paint(night: night, style: style)
                }
            }
            .onChange(of: memory) { _, _ in remember() }
            .onChange(of: catalog.groups) { _, groups in
                traffic.layer.show(trafficOn)
                refreshNavLayers()
                refreshWeather()
                WeatherLayers.save(groups, to: .standard)
            }
            .onChange(of: navDownloads.installed) { _, _ in openNavFiles() }
            .environment(plates)
            .environment(weather)
            .environment(location)
    }

    /// The map setup as it stands. It is saved as it changes, so a relaunch puts it back.
    private var memory: MapMemory {
        let camera = handle.map.map {
            MapMemory.Camera(latitude: $0.centerCoordinate.latitude, longitude: $0.centerCoordinate.longitude, zoom: $0.zoomLevel)
        }
        return MapMemory(base: model.baseLayer, night: model.nightMode, orientation: model.orientation, following: isFollowing,
                         camera: camera ?? model.launch.camera, route: nav.route?.text ?? nav.savedRoute,
                         plates: plates.placed)
    }

    private func remember() {
        UserDefaults.standard.set(memory.text, forKey: MapMemory.key)
        handle.remembered = Date()
    }

    private func refreshWeather() {
        guard let style = handle.map?.style else { return }
        let (on, data, show, level) = (WeatherLayers.shown(catalog), weather.data, stationShow, windsLevel)
        let now = nav.fixedNow ?? Date()
        WeatherLayers.apply(catalog, data: data, show: show, now: now, to: style)
        // The newest call wins; an older one still building is dropped when it finishes.
        handle.weatherShapes?.cancel()
        handle.weatherShapes = Task {
            // Built off the main thread in this task, so cancelling it stops a superseded build.
            let shapes = await WeatherLayers.build(on, data: data, show: show, windsLevel: level, now: now)
            // A cancelled build returns only part of the shapes.
            guard !Task.isCancelled, let style = handle.map?.style else { return }
            WeatherLayers.fill(shapes, on: style)
        }
        if !on.contains(.radar) { weather.stopLoop() }
        drawLoop()
    }

    private var windsLevel: Int {
        WindsMap.level(chosen: chosenWindsLevel == 0 ? nil : chosenWindsLevel,
                       cruiseFt: nav.route == nil ? nil : RoutePages.planInputs(stored: storedInputs, now: Date()).cruiseAltitudeFt)
    }

    private func radarClock(_ newest: Date) -> String {
        switch weather.loop {
        case .off: RadarLoop.clock(newest)
        case .loading(let text): text
        case .playing(let frames, let showing): RadarLoop.clock(frames[showing].valid)
        }
    }

    private func drawLoop() {
        guard let style = handle.map?.style else { return }
        if case .playing(let frames, let showing) = weather.loop {
            WeatherLayers.loop(frames, showing: showing, on: style)
        } else {
            WeatherLayers.loop([], showing: 0, on: style)
        }
    }

    // Each switched-on source that is not current says so, and a small clock gives the time of what is drawn.
    private func weatherNotices(_ now: Date) -> some View {
        let on = WeatherLayers.shown(catalog)
        return VStack(alignment: .trailing) {
            ForEach(on, id: \.self) { overlay in
                if let text = weather.data.staleLabel(for: overlay, at: now) {
                    MapBanner(text: text, identifier: "wx-notice-\(overlay.rawValue)")
                }
            }
            if let time = weather.data.clock(on, at: now) {
                let radar = on.contains(.radar)
                HStack(spacing: chromeInset) {
                    if radar {
                        Button(weather.loop == .off ? "Play Radar Loop" : "Stop Radar Loop",
                               systemImage: weather.loop == .off ? "play.fill" : "stop.fill") { weather.toggleLoop() }
                            .labelStyle(.iconOnly)
                            .font(.footnote.weight(.semibold))
                            .accessibilityIdentifier("wx-loop")
                    }
                    VStack(alignment: .trailing) {
                        Text(radar ? radarClock(time) : "Weather \(WeatherText.zulu(time))")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                        ForEach(WeatherText.legends(on), id: \.self) { Text($0).font(.caption) }
                        if on.contains(.winds), let winds = WindsMap.label(weather.data.winds, level: windsLevel, at: now) {
                            Text(winds).font(.caption)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("wx-clock")
                }
                .modifier(NightDim())
                .padding(.horizontal)
                .padding(.vertical, chromeInset / 2)
                .glassEffect(.regular, in: .rect(cornerRadius: chromeInset))
            }
        }
    }

    private var trafficOn: Bool { catalog.overlay(TrafficStore.switchID)?.isOn != false }

    private var overlayWanted: Bool {
        NavOverlay.groups.contains { catalog.overlay($0.id)?.isOn == true }
    }

    private func openNavFiles() {
        nav.use(NavFiles.pick(options: model.options, installed: navDownloads.installed, now: Date()))
    }

    // Applies the switches to the loaded style, then draws the route.
    private func refreshNavLayers() {
        guard let style = handle.map?.style else { return }
        handle.navShown = NavOverlay.apply(catalog, to: style)
        drawRoute()
    }

    // Draws the route from the newest fix and tells the tests what the map now holds.
    private func drawRoute() {
        guard handle.map?.style != nil else { return }
        routeLine.update(nav.route, position: model.position, approximate: location.isApproximate)
        guard probes else { return }
        // The start of the drawn line is in the text, so a test can see it follow the aircraft.
        let direct = routeLine.start.map { String(format: "on %.3f,%.3f", $0.latitude, $0.longitude) } ?? "off"
        let shown = handle.navShown
        let text = "overlay \(shown.isEmpty ? "none" : shown.joined(separator: ",")) direct \(direct)"
        // Set a moment later, because this can run in the middle of a view update.
        Task { @MainActor in
            if navProbe != text { navProbe = text }
        }
    }

    private var controls: some View {
        MapControls(model: model, following: isFollowing, panel: usesCard ? panel : nil,
                    glass: glass, perform: perform,
                    onSettings: { panel = nil; showsSettings = true })
        // A keyboard command is taken from the model and cleared, so the next one reads as a change.
        .task { [model] in
            for await command in Observations({ model.command }) {
                guard let command else { continue }
                model.command = nil
                perform(command)
            }
        }
        // Escape closes the open panel, unless a plate or the brief covers it. The button is never seen or heard.
        .background {
            if panel != nil, !showsSettings {
                Button("", action: { if !plates.reading, nav.brief == nil { open(nil) } })
                    .keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
        }
        // A new panel or place starts with no pages pushed; a turn changes neither.
        .onChange(of: panel) { _, now in
            panelPath = NavigationPath()
            if now != .route { routeWide = false }
        }
        .onChange(of: place) { _, _ in panelPath = NavigationPath() }
        .onChange(of: shownPlace) { _, shown in
            // A dropped pin has its own mark.
            ring.show(shown == place?.pin ? nil : shown)
            if let shown { if shown != handle.revealed { reveal(shown) } } else { handle.revealed = nil }
            probePlace()
        }
        .onChange(of: nav.detail?.airport.ident) { _, _ in focus = nil }
        .onChange(of: detent) { _, _ in revealAgain() }
        .onChange(of: windowWidth) { _, _ in revealAgain() }
    }

    // What a control and its keyboard command both do. The map is out of reach under Settings, a chart or the brief.
    private func perform(_ command: MapCommand) {
        guard !showsSettings, !plates.reading, nav.brief == nil else { return }
        switch command {
        case .search, .layers, .route: open(panel == command.panel ? nil : command.panel)
        case .nightMode: model.nightMode.toggle()
        case .centerOnAircraft:
            if let next = MapPlan.centerTracking(following: isFollowing, orientation: model.orientation) { track(next) }
        case .cycleTracking:
            track(MapPlan.nextTracking(following: isFollowing, orientation: model.orientation))
        }
    }

    private func track(_ next: (following: Bool, orientation: MapOrientation)) {
        isFollowing = next.following
        model.orientation = next.orientation
        settleCamera(following: isFollowing)
    }

    // The card grows out of its button and shrinks back into it.
    private func open(_ shown: MapPanel?) {
        if shown != panel { focus = nil }
        withAnimation(.snappy(duration: 0.3)) { panel = shown }
    }

    /// The place the open panel shows: the airport page, else the place card or the last Show on Map.
    private var shownPlace: Coordinate? {
        guard let panel else { return nil }
        if panel == .nav, let detail = nav.detail { return detail.airport.coordinate }
        return focus
    }

    // The part of the map no panel or strip covers, in map points. A sheet at the medium detent covers half.
    private func openArea(_ map: MLNMapView) -> ScreenRect {
        let size = map.bounds.size
        var (left, bottom) = (CGFloat(0), size.height)
        if panel != nil {
            if usesCard { left = map.safeAreaInsets.left + chromeInset * 3 + MapButton.size + cardWidth }
            else { bottom -= detent == .medium ? size.height / 2 : max(sheetHeight, size.height / 2) }
        }
        let top = min(handle.stripBottom, bottom)
        return ScreenRect(x: left, y: top, width: size.width - left, height: bottom - top)
    }

    // Eases the place into the middle of the open part when it is not there already; force is Show on Map.
    private func reveal(_ point: Coordinate, force: Bool = false) {
        guard let map = handle.map, map.bounds.width > 0 else { return }
        handle.revealed = point
        let at = map.convert(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), toPointTo: map)
        guard let camera = MapReveal.camera(place: point, at: ScreenPoint(x: at.x, y: at.y), open: openArea(map),
                                            size: ScreenPoint(x: map.bounds.width, y: map.bounds.height),
                                            zoom: map.zoomLevel, bearing: map.direction, force: force) else { return }
        // Moving off the aircraft stops following, as a pan does.
        isFollowing = false
        map.setCenter(CLLocationCoordinate2D(latitude: camera.center.latitude, longitude: camera.center.longitude),
                      zoomLevel: camera.zoom, direction: map.direction, animated: !reduceMotion, completionHandler: nil)
    }

    // A turn or a new detent moves the open part; the place follows once the panel settles, unless the map was panned.
    private func revealAgain() {
        guard let shown = shownPlace, handle.revealed == shown else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.4))
            if shownPlace == shown, handle.revealed == shown { reveal(shown) }
        }
    }

    // Tells the tests whether the ring is drawn and whether its place sits in the middle of the open part.
    private func probePlace() {
        guard probes else { return }
        var text = "ring off"
        if let shown = ring.shown, let map = handle.map {
            let at = map.convert(CLLocationCoordinate2D(latitude: shown.latitude, longitude: shown.longitude), toPointTo: map)
            let centered = MapReveal.camera(place: shown, at: ScreenPoint(x: at.x, y: at.y), open: openArea(map),
                                            size: ScreenPoint(x: map.bounds.width, y: map.bounds.height),
                                            zoom: map.zoomLevel, bearing: map.direction) == nil
            text = "ring on " + (centered ? "centered" : "covered")
        }
        Task { @MainActor in if placeProbe != text { placeProbe = text } }
    }

    private func probe(_ text: String, _ identifier: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.clear).accessibilityIdentifier(identifier)
    }

    // Sequences the active leg; a write only on a change keeps the drawer from redrawing on every fix.
    private func advanceRoute(_ position: Position?) {
        guard var plan = nav.route else { return }
        plan.advance(position: position, approximate: location.isApproximate, now: Date())
        guard plan != nav.route else { return }
        let sequenced = !plan.sameLeg(as: nav.route)
        nav.route = plan
        // A sequenced leg means the route is being flown, so it goes in Recent.
        guard sequenced else { return }
        let inputs = RoutePages.planInputs(stored: UserDefaults.standard.data(forKey: RoutePages.planInputsKey), now: Date())
        nav.savedRoutes.update { $0.noting(plan, inputs: inputs) }
    }

    /// The strip, with the route's legs below it in one glass shape. The tab slides it in and out.
    // Beside a card: 340 points, never past 45 percent of the window, or 45 percent at accessibility sizes.
    // Over a sheet, all but the control column, so the three fields stay in one row and leg names stay readable.
    private var widgetWidth: CGFloat {
        // Beside the planning page the strip fits the map left open.
        if routeWide && panel == .route { return windowWidth - cardWidth - MapButton.size - chromeInset * 4 }
        guard usesCard else { return windowWidth - MapButton.size - chromeInset * 3 }
        return typeSize.isAccessibilitySize ? windowWidth * 0.45 : min(340, windowWidth * 0.45)
    }

    private var flightSpeed: Double? {
        nav.aircraft.aircraft(for: RoutePages.planInputs(stored: storedInputs, now: .now).aircraftID)?.cruiseTASKt
    }

    private var stripAndDrawer: some View {
        VStack(spacing: 0) {
            DataStrip(glassed: false)
                .frame(maxWidth: .infinity)
                // Its own height always, so a short map takes room from the legs below, never from the fields.
                .fixedSize(horizontal: false, vertical: true)
            // The planning page already lists the route, so the strip keeps only its numbers.
            if !(routeWide && panel == .route), let plan = nav.route {
                Divider()
                if drawerOpen {
                    RouteDrawer(plan: plan, onEdit: { open(.route) }, isClosed: nav.isClosed,
                                speed: flightSpeed)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    RouteSummary(plan: plan,
                                 speed: flightSpeed)
                        .padding(.horizontal).padding(.top, 8) // design-lint: allow matches the strip inset
                        .contentShape(.rect)
                        .onTapGesture { open(.route) }
                        .accessibilityAction(named: "Edit Route") { open(.route) }
                }
                let name = plan.isDirect ? "Direct To" : "Route"
                Button(drawerOpen ? "Hide \(name)" : "Show \(name)",
                       systemImage: drawerOpen ? "chevron.compact.up" : "chevron.compact.down") {
                    withAnimation(.snappy(duration: 0.25)) { drawerOpen.toggle() }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                // 44 pt target hangs 16 pt under the card, so the card stays slim.
                .frame(minHeight: 44, alignment: .top) // design-lint: allow touch target
                .contentShape(.rect)
                .padding(.bottom, -16) // design-lint: allow touch target under card
                .gesture(DragGesture(minimumDistance: 8).onEnded { drag in
                    withAnimation(.snappy(duration: 0.25)) { drawerOpen = drag.translation.height > 0 }
                })
                .accessibilityIdentifier("direct-drawer-tab")
            }
        }
        // One width in every state, so the strip and its route read as one widget.
        .frame(width: widgetWidth)
        .stripGlass(.card(dark: scheme == .dark, night: model.nightMode))
        .onChange(of: nav.route?.targets) { _, targets in if targets != nil { drawerOpen = true } }
    }

    private var topStack: some View {
        VStack(alignment: .trailing) {
            stripAndDrawer
            ReceiverBadge(receiver: traffic)
            if probes { TrafficProbe(receiver: traffic) }
            if nav.undoRoute != nil {
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    withAnimation(.snappy(duration: 0.25)) { nav.undoEdit() }
                }
                .font(.headline)
                .buttonStyle(.glass)
                .accessibilityIdentifier("route-undo")
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        // Here rather than on the body, which is at the type checker's limit.
        // Each pass redraws even unchanged data, so reports age out on time; the disk copy arrives as a data change.
        .onChange(of: weather.passes) { _, _ in refreshWeather() }
        .onChange(of: weather.data) { _, _ in refreshWeather() }
        // Read outside the body, so a playing loop does not redraw the whole screen with each picture.
        .task { [weather] in for await _ in Observations({ weather.loop }).dropFirst() { drawLoop() } }
        .onChange(of: stationShow) { _, _ in refreshWeather() }
        .onChange(of: windsLevel) { _, _ in refreshWeather() }
        // Undo stays 10 seconds after each map edit.
        .task(id: nav.undoRoute) {
            guard nav.undoRoute != nil, (try? await Task.sleep(for: .seconds(RoutePages.undoSeconds))) != nil else { return }
            withAnimation(.snappy(duration: 0.25)) { nav.dropUndo() }
        }
    }

    // Weather on top, data warnings nearest the corner, credit last.
    private var bottomStack: some View {
        VStack(alignment: .trailing) {
            // Each clock wakes only when its words can change with nothing else on screen changing.
            Clock(next: { weather.data.nextChange(WeatherLayers.shown(catalog), after: $0) }) { now in weatherNotices(now) }
            Clock(next: { nav.database?.metadata.nextChange(after: $0) }) { now in
                // While the data opens at launch there is nothing to say about it yet.
                if !nav.isOpeningFirst, let text = NavText.mapNotice(metadata: nav.database?.metadata,
                                                unreadable: nav.files != nil && nav.database == nil,
                                                hasTiles: nav.styleFile != nil, overlayWanted: overlayWanted,
                                                now: now) {
                    MapBanner(text: text, identifier: "nav-banner")
                }
            }
            Clock(next: { MapPlan.nextChange(layers: model.baseLayer.packLayers, installed: model.installedPacks.map(\.pack),
                                             after: $0) }) { now in
                ExpiredBanner(currency: MapPlan.currency(layers: model.baseLayer.packLayers,
                                                               installed: model.installedPacks.map(\.pack),
                                                               now: now))
            }
            credit
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder private var aerialNotice: some View {
        if model.baseLayer == .aerial, offline || !network.isSatisfied || !aerialReachable {
            MapNotice(text: "Aerial imagery needs an internet connection")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("aerial-offline-label")
        }
    }

    // Every base carries the OpenStreetMap credit: the street map, or the airports' taxiways and buildings.
    @ViewBuilder private var credit: some View {
        HStack {
            switch model.baseLayer {
            case .aerial:
                Text(AerialSource.credit)
                    .accessibilityIdentifier("aerial-credit")
            case .terrain:
                Text(MapStyleSpec.terrainCredit)
                    .accessibilityIdentifier("terrain-credit")
            case .street, .vfr, .vfrFlyway, .ifrLow, .ifrHigh:
                EmptyView()
            }
            Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                .frame(minHeight: 44) // design-lint: allow 44 pt hit area for the credit link
                .accessibilityIdentifier(model.baseLayer == .street ? "street-credit" : "osm-credit")
        }
        .font(.caption2)
    }

    private func panelBody(_ shown: MapPanel) -> some View {
        NavigationStack(path: $panelPath) {
            switch shown {
            case .layers:
                LayerPicker(model: model, catalog: catalog, plates: plates, onShowPlate: showOnMap,
                            tfrsWithoutArea: WeatherGeoJSON.tfrsWithoutArea(weather.data.tfrs, now: nav.fixedNow ?? Date()),
                            windsLevel: windsLevel)
                    .panelPage(shown.title) { open(nil) }
            case .nav:
                NavPanel(model: nav, downloads: navDownloads, online: network.isSatisfied,
                         onClose: { open(nil) }, onDirect: { open(nil) }, onShowOnMap: { showOnMap($0.coordinate) })
            case .place:
                if let place {
                    PlacePanel(root: place, nav: nav,
                               actions: PlaceActions(onClose: { open(nil) }, onDirect: directTo,
                                                     onShowOnMap: { showOnMap($0) }, onAddToRoute: addToRoute,
                                                     onPick: bendPick, onShown: { focus = $0?.coordinate }))
                }
            case .route:
                RoutePanel(model: nav, path: $panelPath, onClose: { open(nil) }, onShowOnMap: showOnMap,
                           wide: usesCard ? $routeWide : nil)
            }
        }
        // Each panel, and each new place, starts afresh rather than under pages pushed from the last one.
        .id(shown == .place ? AnyHashable(place) : AnyHashable(shown))
        .modifier(ChartReader())
        .modifier(NightDim())
        .overlay(alignment: .bottomLeading) { if probes { AppearanceProbe() } }
    }

    // 380 points, 320 on a phone on its side, never past 45 percent of the window; no cap at accessibility sizes.
    private var cardWidth: CGFloat {
        // The planning page leaves a third of the window for the map.
        if routeWide && panel == .route { return windowWidth * 0.67 - MapButton.size - chromeInset * 3 }
        return typeSize.isAccessibilitySize ? windowWidth * 0.45
            : min(verticalSizeClass == .compact ? 320 : 380, windowWidth * 0.45)
    }

    private func card(_ shown: MapPanel) -> some View {
        panelBody(shown)
            .frame(width: cardWidth)
            .frame(maxHeight: .infinity)
            .panelGlass()
            .glassEffectID(shown.rawValue, in: glass)
            .popover(isPresented: Binding(get: { widePlace != nil }, set: { if !$0 { widePlace = nil; bendPick = nil; focus = nil } }),
                     arrowEdge: .trailing) {
                if let widePlace {
                    NavigationStack {
                        PlacePanel(root: widePlace, nav: nav,
                                   actions: PlaceActions(onClose: { self.widePlace = nil }, onDirect: nil,
                                                         onShowOnMap: { showOnMap($0) }, onAddToRoute: addToRoute,
                                                         onPick: bendPick, onShown: { focus = $0?.coordinate }))
                    }
                    .frame(idealWidth: 380, idealHeight: 520)
                    .modifier(ChartReader())
                    .modifier(NightDim())
                }
            }
    }

    // Fits the drawn route into the map left open beside the card.
    private func fitRoute() {
        guard let map = handle.map, let points = drawnRoute?.route.waypoints.map(\.coordinate), points.count > 1 else { return }
        let (lats, lons) = (points.map(\.latitude), points.map(\.longitude))
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!),
                                         ne: CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!))
        let open = openArea(map), pad: CGFloat = 32
        let edges = UIEdgeInsets(top: open.y + pad, left: open.x + pad, bottom: map.bounds.height - open.y - open.height + pad,
                                 right: map.bounds.width - open.x - open.width + pad)
        isFollowing = false
        map.setVisibleCoordinateBounds(bounds, edgePadding: edges, animated: !reduceMotion, completionHandler: nil)
    }

    // A single airport opens its page as before; anything else opens the place card, and open map closes the panel.
    private func tapped(_ places: [WaypointMatch]) {
        bendPick = nil
        // On the planning page the map never closes it or swaps the route panel out.
        if routeWide && panel == .route {
            if !places.isEmpty { widePlace = places.count == 1 ? .one(places[0]) : .here(places) }
            return
        }
        switch NavPages.tap(places) {
        case .nothing: open(nil)
        case .airport(let ident):
            nav.show(ident: ident)
            if nav.detail != nil { open(.nav) }
        case .place(let one):
            place = .one(one)
            open(.place)
        case .here(let list):
            place = .here(list)
            open(.place)
        }
    }

    // Where a card's Direct To and Add to Route meet the route model.
    private func directTo(_ point: WaypointMatch) {
        nav.directTo(RouteWaypoint(match: point))
        open(nil)
    }

    private func addToRoute(_ point: WaypointMatch) {
        nav.add(RouteWaypoint(match: point), position: model.position, approximate: location.isApproximate)
    }

    private var drawnRoute: RoutePages.Drawn? {
        RoutePages.drawn(nav.route, position: model.position, approximate: location.isApproximate, now: Date())
    }

    // A let-go rubber band edits the route; places about equally near are picked from the panel first.
    private func bent(_ grab: RouteGrab, _ snap: MapPick.Snap, _ at: Coordinate) {
        guard let plan = nav.route, let count = drawnRoute?.route.waypoints.count else { return }
        switch RoutePages.bend(plan, grab, drawnCount: count, snap: snap, at: at) {
        case .edit(let edited, let offer)?:
            nav.edit(edited)
            if let offer { offerPlaces(near: at, for: offer) }
        case .choose(let places)?:
            if routeWide && panel == .route {
                bendPick = { nav.edit(plan.bending(grab, drawnCount: count, to: RouteWaypoint(match: $0))); bendPick = nil; widePlace = nil }
                widePlace = .here(places)
                return
            }
            bendPick = { nav.edit(plan.bending(grab, drawnCount: count, to: RouteWaypoint(match: $0))); bendPick = nil; open(nil) }
            place = .here(places)
            open(.place)
        case nil: break
        }
    }

    private func offerPlaces(near at: Coordinate, for target: Int) {
        guard let map = handle.map else { return }
        let places = nav.database?.useInstead(near: at, metersPerPoint: map.metersPerPoint(atLatitude: at.latitude)) ?? []
        guard !places.isEmpty else { return }
        let spot = map.convert(CLLocationCoordinate2D(latitude: at.latitude, longitude: at.longitude), toPointTo: map)
        withAnimation(.snappy(duration: 0.25)) { bendSuggest = (target, places, spot) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(RoutePages.offerSeconds))
            if bendSuggest?.target == target { withAnimation { bendSuggest = nil } }
        }
    }

    // A small card beside the dropped point: use one of the places instead, or keep the point.
    private func suggestion(_ offer: (target: Int, places: [WaypointMatch], at: CGPoint)) -> some View {
        VStack(alignment: .leading) {
            Text(RoutePages.useInstead).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(offer.places, id: \.self) { place in
                Button {
                    nav.route = nav.route?.replacing(target: offer.target, with: RouteWaypoint(match: place)) ?? nav.route
                    withAnimation { bendSuggest = nil }
                } label: {
                    PlaceLabel(ident: RouteWaypoint(match: place).ident, name: place.name)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("use-instead-\(place.ident)")
            }
            Button(RoutePages.keepPoint) { withAnimation { bendSuggest = nil } }
                .font(.subheadline).accessibilityIdentifier("keep-point")
        }
        .padding()
        .frame(maxWidth: 260)
        .panelGlass()
        .fixedSize()
        .position(x: offer.at.x, y: offer.at.y + 90)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private func showOnMap(_ airport: Airport) { showOnMap(airport.coordinate) }

    private func showOnMap(_ plate: Plate) { if let geo = plate.geo { showOnMap(geo) } }

    // Fits a placed plate's plan view, or a sketch's drawing, into the map left visible by the card or sheet.
    private func showOnMap(_ geo: PlateGeo) {
        guard let map = handle.map, geo.corners.count == 4, geo.corners.allSatisfy({ $0.count == 2 }) else { return }
        isFollowing = false
        detent = .medium
        let (lons, lats) = (geo.corners.map { $0[0] }, geo.corners.map { $0[1] })
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!),
                                         ne: CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!))
        let pad: CGFloat = 24
        let edges = usesCard ? UIEdgeInsets(top: pad, left: cardWidth + chromeInset * 2 + MapButton.size + pad, bottom: pad, right: pad)
                             : UIEdgeInsets(top: pad, left: pad, bottom: map.bounds.height / 2 + pad, right: pad)
        map.setVisibleCoordinateBounds(bounds, edgePadding: edges, animated: !reduceMotion, completionHandler: nil)
    }

    // Stops following, rings the point and puts it in the middle of the map left open by the card or sheet.
    private func showOnMap(_ point: Coordinate) {
        isFollowing = false
        detent = .medium
        focus = point
        reveal(point, force: true)
    }

    private func follow(_ map: MLNMapView, _ position: Position) {
        // Only the first fix moves the whole-country view in; a later pinch out is left alone.
        if let zoom = MapPlan.firstFixZoom(current: map.zoomLevel, alreadyZoomed: handle.zoomedToFirstFix) {
            map.zoomLevel = zoom
        }
        handle.zoomedToFirstFix = true
        ownship.follow(map, position: position, orientation: model.orientation)
    }

    // Keeps the chosen orientation true while the map is panned away from the aircraft.
    private func turn(_ map: MLNMapView, _ position: Position) {
        let camera = map.camera
        let heading = MapPlan.heading(for: position, orientation: model.orientation, current: camera.heading)
        // A fix that changes nothing leaves the camera alone.
        guard heading != camera.heading else { return }
        camera.heading = heading
        map.setCamera(camera, animated: false)
    }

    // Applies a new orientation or a recenter at once.
    private func settleCamera(following: Bool) {
        guard let map = handle.map else { return }
        if following, let position = model.position {
            follow(map, position)
        } else if let position = model.position {
            turn(map, position)
        } else if model.orientation == .northUp {
            let camera = map.camera
            camera.heading = 0
            map.setCamera(camera, animated: false)
        }
    }
}
