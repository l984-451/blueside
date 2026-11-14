import FlightCore
import MapLibre
import Observation
import PDFKit
import PencilKit
import SwiftUI

/// Airport diagrams and procedures from the plates packs, which follow the chart regions chosen in Downloads.
@MainActor @Observable final class Plates {
    let downloads: DownloadsModel
    @ObservationIgnored private let bundled: URL?
    /// Every chart in the packs in force, by airport. Nil until the first index is read.
    private var byAirport: [String: [Plate]]?
    @ObservationIgnored private var indexed: [URL]?
    /// Georeferenced plates drawn on the map, in the order placed.
    var onMap: [Plate] = []
    /// A chart is open full screen over the map.
    var reading = false
    // The plates saved with the map and the one a launch names by file, until start restores them.
    @ObservationIgnored private var restore: (placed: [MapMemory.PlacedPlate], file: String?)?
    // The saved plates, kept for the map memory until they are back on the map.
    private var unrestored: [MapMemory.PlacedPlate]?

    /// The plates the map memory saves.
    var placed: [MapMemory.PlacedPlate] { unrestored ?? onMap.map(\.placed) }

    /// Builds and stores only: a view's initializer may build one, and a read here would tie the view to its state.
    init(options: LaunchOptions, placed: [MapMemory.PlacedPlate] = [], downloads: DownloadsModel) {
        self.downloads = downloads
        bundled = options.string("basePack") == "nav"
            ? Bundle.main.url(forResource: "plates-test", withExtension: "sqlite", subdirectory: "MapAssets") : nil
        restore = (placed, options.string("plateOnMap"))
        unrestored = placed
    }

    /// Reads the index off the main thread, then restores the plates saved with the map. Once, when the map appears.
    func start() {
        guard let (placed, file) = restore else { return }
        restore = nil
        guard let reading = index(), !placed.isEmpty || file != nil else { unrestored = nil; return }
        Task {
            let byAirport = await reading.value
            var restored = placed.compactMap { p in byAirport[p.airport]?.first { $0.file == p.file && $0.geo != nil } }
            if let found = byAirport.values.joined().first(where: { $0.file == file }), !restored.contains(found) {
                restored.append(found)
            }
            onMap = restored + onMap.filter { !restored.contains($0) }
            unrestored = nil
        }
    }

    // Reads the index again, off the main thread, when the packs in force change.
    @discardableResult private func index() -> Task<[String: [Plate]], Never>? {
        let packs = packs
        guard packs != indexed else { return nil }
        indexed = packs
        return Task {
            let found = await Task.detached(priority: .userInitiated) { PlateLibrary.byAirport(packs) }.value
            if indexed == packs { byAirport = found }
            return found
        }
    }

    /// A chart to read full screen: a plate, or the sketch drawn where the FAA publishes no diagram.
    enum Reader: Identifiable {
        case plate(Plate), sketch(AirportSketch)
        var id: String { if case .plate(let plate) = self { plate.id } else { AirportSketch.title } }
    }

    func toggle(_ plate: Plate) {
        if let i = onMap.firstIndex(of: plate) { onMap.remove(at: i) } else { onMap.append(plate) }
    }

    static var root: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plates", isDirectory: true)
    }

    /// The pack in force for each region on disk, or the bundled test pack.
    var packs: [URL] {
        if let bundled { return [bundled] }
        return PlateLibrary.packs(installed: downloads.installed, now: Date())
    }

    /// Every chart for the airport, in the FAA's order. Nil until the index is read.
    func charts(for airport: Airport) -> [Plate]? {
        index()
        return byAirport.map { $0[airport.ident] ?? [] }
    }

    /// The amber line over plates out of date or not yet in effect, worded as the map's banner. Nil when current.
    nonisolated static func warning(installed: [InstalledPack], now: Date) -> String? {
        MapPlan.banner(MapPlan.currency(layers: [PlateLibrary.layer], installed: installed, now: now),
                       subject: PlateLibrary.subject)
    }

    /// The warning for the plates on disk. The bundled test pack has no cycle.
    func warning(now: Date) -> String? {
        bundled == nil ? Self.warning(installed: downloads.installed.map(\.pack), now: now) : nil
    }

    /// When the warning can next change: a plates cycle starting or ending.
    func nextChange(after now: Date) -> Date? {
        MapPlan.nextChange(layers: [PlateLibrary.layer], installed: downloads.installed.map(\.pack), after: now)
    }

    /// The chart's PDF, read and opened off the main thread.
    @concurrent nonisolated static func document(_ plate: Plate) async -> sending PDFDocument? {
        PlateLibrary.pdf(plate).flatMap(PDFDocument.init(data:))
    }

    /// The plan view drawn as an image, the airport sketch and insets cleared since they are not to scale.
    /// At most 2,048 pixels on its long side in 8-bit color, so one plate costs 16 MB at worst.
    nonisolated static func planImage(_ plate: Plate) -> UIImage? {
        guard let geo = plate.geo, geo.plan.count == 4, geo.plan[2] > geo.plan[0], geo.plan[3] > geo.plan[1],
              let page = PlateLibrary.pdf(plate).flatMap(PDFDocument.init(data:))?.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let plan = CGRect(x: geo.plan[0] * box.width, y: geo.plan[1] * box.height,
                          width: (geo.plan[2] - geo.plan[0]) * box.width, height: (geo.plan[3] - geo.plan[1]) * box.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(4, 2048 / max(plan.width, plan.height, 1))
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: plan.size, format: format).image { context in
            let cg = context.cgContext
            UIColor.white.setFill() // design-lint: allow, the chart paper
            cg.fill(CGRect(origin: .zero, size: plan.size))
            cg.saveGState()
            // PDF space runs bottom up.
            cg.translateBy(x: -plan.minX, y: box.height - plan.minY)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
            for s in geo.masksInPlan {
                cg.clear(CGRect(x: s[0] * plan.width, y: s[1] * plan.height,
                                width: (s[2] - s[0]) * plan.width, height: (s[3] - s[1]) * plan.height))
            }
        }
    }
}

/// Plates on the map: each plan view stretched over its true corners, above the base chart, the last placed on top.
@MainActor enum PlateOverlay {
    static let prefix = "plate-overlay"
    // Plan images by plate, so placing one more plate or turning night on does not draw every PDF again.
    private static var images: [String: UIImage] = [:]
    // Counts calls, so a render that finishes after a newer call draws nothing.
    private static var calls = 0

    /// Draws the plates whose images are ready at once; the rest are rendered off the main thread, then all are drawn.
    static func show(_ plates: [Plate], on style: MLNStyle, night: Bool) {
        calls &+= 1
        let call = calls
        images = images.filter { id, _ in plates.contains { $0.id == id } }
        place(plates, on: style, night: night)
        let missing = plates.filter { images[$0.id] == nil && quad($0) != nil }
        guard !missing.isEmpty else { return }
        Task { [weak style] in
            let drawn = await Task.detached(priority: .userInitiated) {
                missing.compactMap { plate in Plates.planImage(plate).map { (plate.id, $0) } }
            }.value
            guard call == calls, let style else { return }
            for (id, image) in drawn { images[id] = image }
            place(plates, on: style, night: night)
        }
    }

    private static func place(_ plates: [Plate], on style: MLNStyle, night: Bool) {
        for layer in style.layers where layer.identifier.hasPrefix(prefix) { style.removeLayer(layer) }
        for source in style.sources where source.identifier.hasPrefix(prefix) { style.removeSource(source) }
        // Over the base, under airspace, weather, route and ownship. On the street map the base is vector layers too.
        let above = style.layers.first { ($0 as? MLNForegroundStyleLayer)?.sourceIdentifier == "nav" || $0.identifier.hasPrefix("wx-") }
            ?? style.layers.first { !($0 is MLNRasterStyleLayer || $0 is MLNBackgroundStyleLayer) }
        for (i, plate) in plates.enumerated() {
            guard let quad = quad(plate), let image = images[plate.id] else { continue }
            let source = MLNImageSource(identifier: "\(prefix)-\(i)", coordinateQuad: quad, image: image)
            style.addSource(source)
            let layer = MLNRasterStyleLayer(identifier: source.identifier, source: source)
            layer.rasterFadeDuration = NSExpression(forConstantValue: 0)
            NightPaint.apply(night: night, to: layer)
            if let above { style.insertLayer(layer, below: above) } else { style.addLayer(layer) }
        }
    }

    static func quad(_ plate: Plate) -> MLNCoordinateQuad? {
        guard let corners = plate.geo?.corners, corners.count == 4, corners.allSatisfy({ $0.count == 2 }) else { return nil }
        let at = corners.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
        return MLNCoordinateQuad(topLeft: at[0], bottomLeft: at[3], bottomRight: at[2], topRight: at[1])
    }
}

extension DownloadsModel {
    /// The plates list and files. Quiet, like navigation data, when the launch or a test asks for no network.
    static func plates(options: LaunchOptions) -> DownloadsModel {
        let store = PackStore(root: Plates.root)
        let quiet = options.flag("offline") || options.string("basePack") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let client = quiet ? nil : ManifestClient.baseURL(options: options).map {
            ManifestClient(base: $0, cache: store.root.appendingPathComponent("manifest.json"),
                           list: options.string("platesList") ?? "plates/manifest.json")
        }
        return DownloadsModel(store: store, client: client,
                              configuration: PackDownloader.backgroundConfiguration(identifier: "plates"))
    }
}

/// The airport page's diagram and procedures rows, with a drawn sketch where the FAA publishes no diagram.
struct PlatesSection: View {
    let airport: Airport
    let detail: AirportDetail
    /// Puts the panel away from the procedures list.
    var onClose: (() -> Void)?
    @Environment(Plates.self) private var plates: Plates?

    var body: some View {
        // Nothing until the index is read, so an airport with a diagram never shows its sketch first.
        if let charts = plates == nil ? [] : plates?.charts(for: airport) {
            let procedures = charts.filter { !$0.isDiagram }
            let diagram = charts.first(where: \.isDiagram)
            let sketch = diagram == nil ? NavPages.airportSketch(detail) : nil
            if !charts.isEmpty || sketch != nil {
                Section {
                    if let diagram {
                        ReaderLink(title: "Airport Diagram", systemImage: "map.circle", reader: .plate(diagram))
                            .accessibilityIdentifier("airport-diagram")
                    } else if let sketch {
                        ReaderLink(title: AirportSketch.title, systemImage: "map.circle", reader: .sketch(sketch))
                            .accessibilityIdentifier("airport-sketch")
                    }
                    if !procedures.isEmpty { proceduresRow(procedures) }
                }
            }
        }
    }

    private func proceduresRow(_ procedures: [Plate]) -> some View {
        NavigationLink { ProcedureList(airport: airport, charts: procedures, onClose: onClose) } label: {
            LabeledContent {
                Text(procedures.count, format: .number)
            } label: {
                Label("Procedures", systemImage: "list.bullet.rectangle.portrait")
            }
        }
        .accessibilityIdentifier("airport-procedures")
    }
}

/// Procedures grouped approaches, departures, arrivals, other, under the plates warning when they are not current.
struct ProcedureList: View {
    let airport: Airport
    let charts: [Plate]
    var onClose: (() -> Void)?
    @Environment(Plates.self) private var plates: Plates?

    var body: some View {
        // Wakes only when a plates cycle starts or ends.
        Clock(next: { plates?.nextChange(after: $0) }) { now in
            List {
                if let warning = plates?.warning(now: now) {
                    Section {
                        StateWord(.warning, warning, systemImage: "exclamationmark.triangle.fill")
                            .accessibilityIdentifier("plates-warning")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(Plate.Group.allCases, id: \.self) { group in
                    let members = charts.filter { $0.group == group }
                    if !members.isEmpty {
                        Section(group.rawValue) {
                            ForEach(members) { plate in
                                ReaderLink(title: plate.name, reader: .plate(plate))
                                    .accessibilityIdentifier("plate-\(plate.file)")
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .panelList()
        }
        .navigationTitle("Procedures")
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(.clear, for: .navigation)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .close, action: onClose).accessibilityIdentifier("panel-close")
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// Opens a chart full screen from the panel around the row.
    @Entry var openChart: (Plates.Reader) -> Void = { _ in }
}

/// A row that opens its chart full screen at once, the one size a chart can be read at.
private struct ReaderLink: View {
    let title: String
    var systemImage: String?
    let reader: Plates.Reader
    @Environment(\.openChart) private var openChart

    var body: some View {
        Button { openChart(reader) } label: {
            if let systemImage {
                Label { Text(title).foregroundStyle(Color.primary) } icon: { Image(systemName: systemImage) }
            } else {
                Text(title).foregroundStyle(Color.primary)
            }
        }
    }
}

/// Presents the charts its rows open. A panel holds it rather than the row: a list drops the rows it stops showing.
struct ChartReader: ViewModifier {
    @State private var reader: Plates.Reader?
    @Environment(Plates.self) private var plates: Plates?

    func body(content: Content) -> some View {
        content
            .environment(\.openChart) { reader = $0 }
            .fullScreenCover(item: $reader) { reader in
                PlateReader(reader: reader)
                    .onAppear { plates?.reading = true }
                    .onDisappear { plates?.reading = false }
            }
    }
}

/// The open chart full screen, with its close button.
private struct PlateReader: View {
    let reader: Plates.Reader
    @Environment(\.isNight) private var night
    @Environment(\.showArea) private var showArea
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            page
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .close) { dismiss() }.accessibilityIdentifier("plate-close")
                    }
                }
        }
        .environment(\.isNight, night)
        .preferredColorScheme(night ? .dark : nil)
    }

    private var page: PlatePage {
        switch reader {
        case .plate(let plate): PlatePage(plate: plate)
        // Show on Map puts the reader away, so the pilot sees the map it moved.
        case .sketch(let sketch): PlatePage(sketch: sketch, onShowOnMap: { dismiss(); showArea(sketch.geo) })
        }
    }
}

/// One chart, pinch to zoom, with ownship on a georeferenced one. Night mode inverts it, hue turned back, as the map does.
/// A plate shows the plates warning on top while its cycle is not current.
struct PlatePage: View {
    let title: String
    let geo: PlateGeo?
    /// Nil for a sketch or an attached PDF, which have no plan view to place on the map.
    let plate: Plate?
    var onShowOnMap: (() -> Void)?
    private let make: @MainActor () async -> PDFDocument?
    @Environment(\.isNight) private var night
    @Environment(Plates.self) private var plates: Plates?
    // Opened once, so a redraw keeps the zoom.
    @State private var document: PDFDocument?
    @State private var opened = false
    private var searchable = false
    @State private var finding = false
    /// A plate's marks; nil for a sketch or an attached PDF, which take none.
    @State private var markup: PlateMarkup?
    @State private var marking = false

    init(plate: Plate) {
        (title, geo, self.plate) = (plate.name, plate.geo, plate)
        make = { await Plates.document(plate) }
    }

    /// A PDF the pilot attached, such as a POH, with find.
    init(title: String, url: URL) {
        (self.title, geo, plate, searchable) = (title, nil, nil, true)
        make = { PDFDocument(url: url) }
    }

    init(sketch: AirportSketch, onShowOnMap: @escaping () -> Void) {
        (title, geo, plate, self.onShowOnMap) = (AirportSketch.title, sketch.geo, nil, onShowOnMap)
        make = { SketchDocument.make(sketch) }
    }

    var body: some View {
        // Wakes only when a plates cycle starts or ends.
        Clock(next: { plate == nil ? nil : plates?.nextChange(after: $0) }) { now in
            // A stack, not a group, so the page exists while the document is still opening.
            ZStack {
                if let document {
                    sheet(document)
                        .nightInverted(night)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier("plate-view")
                } else if opened {
                    ContentUnavailableView("Chart unavailable", systemImage: "doc.questionmark")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top) {
                if plate != nil, let warning = plates?.warning(now: now) {
                    MapBanner(text: warning, identifier: "plates-banner")
                }
            }
        }
        .task {
            // Marks first, so the sheet is built with its canvases.
            if let plate { markup = await PlateMarkup.open(plate) }
            document = await make()
            opened = true
        }
        .onDisappear { markup?.save() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(.clear, for: .navigation)
        .toolbar {
            if let onShowOnMap {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Show on Map", systemImage: "map", action: onShowOnMap)
                        .accessibilityIdentifier("plate-on-map")
                }
            }
            if let plate, plate.geo != nil, let plates {
                ToolbarItem(placement: .topBarTrailing) {
                    let shown = plates.onMap.contains(plate)
                    Button(shown ? "Hide on Map" : "Show on Map", systemImage: shown ? "map.fill" : "map") { plates.toggle(plate) }
                    .accessibilityIdentifier("plate-on-map")
                }
            }
            if searchable, document != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AircraftPages.find, systemImage: "magnifyingglass") { finding = true }
                        .accessibilityIdentifier("plate-find")
                }
            }
            if markup != nil, document != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    // A toggle, so the bar item is selected while on and VoiceOver says so.
                    Toggle(isOn: $marking) {
                        Label("Markup", systemImage: marking ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    }
                    .accessibilityIdentifier("plate-markup")
                }
            }
        }
    }

    @ViewBuilder private func sheet(_ document: PDFDocument) -> some View {
        if geo != nil {
            // Only the sheet reads the fix, so a new one moves the marker and nothing around it.
            FixReader { PDFSheet(document: document, ownship: OwnshipMark(geo, $0), markup: markup, marking: marking) }
        } else {
            PDFSheet(document: document, finding: $finding, markup: markup, marking: marking)
        }
    }
}

/// Ownship's spot on a plate page, as fractions from top left.
struct OwnshipMark: Equatable {
    var x: Double, y: Double, track: Double, live: Bool

    /// Nil unless a precise fix falls inside the plate's plan view.
    init?(_ geo: PlateGeo?, _ fix: Fix) {
        guard !fix.approximate, let position = fix.position,
              let point = geo?.pagePoint(position.coordinate) else { return nil }
        (x, y, track, live) = (point[0], point[1], position.trackTrue ?? 0, !position.isStale(at: fix.now))
    }
}

private extension View {
    @ViewBuilder func nightInverted(_ on: Bool) -> some View {
        if on { colorInvert().hueRotation(.degrees(180)) } else { self }
    }
}

private struct PDFSheet: UIViewRepresentable {
    let document: PDFDocument
    var ownship: OwnshipMark?
    var finding: Binding<Bool>?
    var markup: PlateMarkup?
    var marking = false

    func makeUIView(context: Context) -> PlateView {
        let view = PlateView()
        // Before the document, so the first layout asks for the canvases.
        view.markup = markup
        view.pdf.document = document
        return view
    }

    func updateUIView(_ view: PlateView, context: Context) {
        if view.pdf.document !== document { view.pdf.document = document }
        view.ownship = ownship
        view.marking = marking
        if let finding, finding.wrappedValue {
            Task { @MainActor in
                view.pdf.findInteraction.presentFindNavigator(showingReplace: false)
                finding.wrappedValue = false
            }
        }
    }
}

/// The PDF view with ownship in a sibling layer: moving a subview of PDFView relays it out, which undoes a pinch.
final class PlateView: UIView, PKToolPickerObserver {
    /// The iPad's docked tool picker's height above the safe area, measured: a picker that can move reports no covered frame.
    static let dockedPicker: CGFloat = 121
    let pdf = ZoomingPDFView()
    private let marker = UIImageView(image: UIImage(systemName: "location.north.fill",
                                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .bold)))
    // PDFView scrolls and zooms in a scroll view of its own; the marker moves when it does, never on a frame clock.
    private var watching: [NSKeyValueObservation] = []

    init() {
        super.init(frame: .zero)
        pdf.displayMode = .singlePageContinuous
        pdf.backgroundColor = .clear
        pdf.isFindInteractionEnabled = true
        pdf.frame = bounds
        pdf.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let doubleTap = UITapGestureRecognizer(target: pdf, action: #selector(ZoomingPDFView.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        pdf.addGestureRecognizer(doubleTap)
        NotificationCenter.default.addObserver(pdf, selector: #selector(ZoomingPDFView.scaled), name: .PDFViewScaleChanged, object: pdf)
        addSubview(pdf)
        marker.accessibilityIdentifier = "plate-ownship"
        marker.isAccessibilityElement = true
        marker.isUserInteractionEnabled = false
        marker.isHidden = true
        addSubview(marker)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var markup: PlateMarkup? {
        didSet {
            pdf.pageOverlayViewProvider = markup
            pencilKitResponderState.activeToolPicker = markup?.picker
            // Set from the start: with none set, the system shows the picker.
            pencilKitResponderState.toolPickerVisibility = marking ? .visible : .inactive
            markup?.picker.addObserver(self)
        }
    }

    /// On, the canvases take the Pencil and the tool picker shows; off, the marks only show.
    var marking = false {
        didSet {
            guard marking != oldValue, let markup else { return }
            markup.marking = marking
            pdf.isInMarkupMode = marking
            pencilKitResponderState.toolPickerVisibility = marking ? .visible : .inactive
            if marking { becomeFirstResponder() }
            clearPicker()
        }
    }

    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) { clearPicker() }
    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) { clearPicker() }

    // While the picker shows for marking, room under the page so its foot scrolls clear of what the picker covers.
    private func clearPicker() {
        guard let scroll, let picker = markup?.picker else { return }
        let covered = picker.frameObscured(in: pdf)
        let under = !marking || !picker.isVisible ? 0
            : covered.isEmpty ? Self.dockedPicker + safeAreaInsets.bottom : max(0, pdf.bounds.maxY - covered.minY)
        // A page shorter than the view stays in its middle until the inset lets it scroll, so the room is at least what it leaves free.
        let room = under > 0 ? max(under, pdf.freeHeight) : 0
        guard scroll.contentInset.bottom != room else { return }
        // The offset is put back, so taking the room away leaves a zoomed page where it is; the next drag settles it.
        let offset = scroll.contentOffset
        scroll.contentInset.bottom = room
        scroll.verticalScrollIndicatorInsets.bottom = room
        scroll.contentOffset = offset
    }

    private var scroll: UIScrollView? { pdf.subviews.lazy.compactMap { $0 as? UIScrollView }.first }

    // The tool picker shows for the first responder, and its undo reaches only this chart's strokes.
    private let undo = UndoManager()
    override var undoManager: UndoManager? { undo }
    override var canBecomeFirstResponder: Bool { markup != nil }

    var ownship: OwnshipMark? {
        didSet {
            guard ownship != oldValue else { return }
            marker.tintColor = ownship?.live == true ? MapInk.ownshipLive : MapInk.ownshipStale
            marker.transform = CGAffineTransform(rotationAngle: (ownship?.track ?? 0) * .pi / 180)
            follow()
            placeMarker()
        }
    }

    // Watches the scroll view only while a marker shows.
    private func follow() {
        guard ownship != nil else { return watching = [] }
        guard watching.isEmpty, let scroll else { return }
        watching = [scroll.observe(\.contentOffset) { [weak self] _, _ in MainActor.assumeIsolated { self?.placeMarker() } },
                    scroll.observe(\.zoomScale) { [weak self] _, _ in MainActor.assumeIsolated { self?.placeMarker() } }]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // What the picker covers also changes with this view's own size.
        clearPicker()
        follow()
        placeMarker()
    }

    private func placeMarker() {
        guard let ownship, let page = pdf.document?.page(at: 0) else { return marker.isHidden = true }
        let box = page.bounds(for: .mediaBox)
        let at = pdf.convert(pdf.convert(CGPoint(x: box.minX + ownship.x * box.width, y: box.maxY - ownship.y * box.height),
                                         from: page), to: self)
        if marker.center != at { marker.center = at }
        marker.isHidden = !bounds.contains(at)
    }
}

/// Opens on the whole page; pinch and pan from there up to 8x; a double tap zooms in on the spot or back to the whole page.
final class ZoomingPDFView: PDFView {
    private static let maxZoom: CGFloat = 8
    private static let doubleTapZoom: CGFloat = 2.5
    // The scale that shows the whole page.
    private var fit: CGFloat = 0

    private var wholePage: CGFloat {
        guard let box = document?.page(at: 0)?.bounds(for: displayBox), box.width > 0, box.height > 0 else { return 0 }
        let room = bounds.inset(by: safeAreaInsets)
        return min(room.width / box.width, room.height / box.height)
    }

    /// The height the whole page leaves free above and below it.
    var freeHeight: CGFloat {
        guard let box = document?.page(at: 0)?.bounds(for: displayBox) else { return 0 }
        return max(0, bounds.height - box.height * wholePage)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Rescales only when the fit itself changes, keeping the reader's zoom; PDFView's autoScales would refit on layout.
        let next = wholePage
        guard next > 0, abs(next - fit) > 0.001 else { return }
        let zoom = fit > 0 ? scaleFactor / fit : 1
        fit = next
        minScaleFactor = fit
        maxScaleFactor = fit * Self.maxZoom
        scaleFactor = fit * min(max(zoom, 1), Self.maxZoom)
    }

    // Zoom over the whole page, for VoiceOver and tests.
    @objc func scaled() {
        accessibilityValue = fit > 0 ? String(format: "%.1fx", scaleFactor / fit) : nil
        superview?.accessibilityValue = accessibilityValue
    }

    @objc func doubleTapped(_ tap: UITapGestureRecognizer) {
        guard fit > 0 else { return }
        guard scaleFactor < fit * 1.01 else { return scaleFactor = fit }
        let point = tap.location(in: self)
        guard let page = page(for: point, nearest: true) else { return }
        let spot = convert(point, to: page)
        scaleFactor = fit * Self.doubleTapZoom
        // Centers the tapped spot.
        let size = convert(bounds, to: page).size
        go(to: CGRect(x: spot.x - size.width / 2, y: spot.y - size.height / 2, width: size.width, height: size.height), on: page)
    }
}
