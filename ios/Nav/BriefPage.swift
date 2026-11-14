import CoreTransferable
import FlightCore
import SwiftUI
import UniformTypeIdentifiers

/// What a brief is built from, gathered on the main thread. Equal keys give the same brief.
struct BriefJob: Sendable {
    struct Key: Equatable, Sendable {
        var route: Route
        var inputs: FlightPlanInputs
        var plan: FlightPlan
        var aircraft: AircraftProfile?
        var balance: WeightBalance?
        /// The weather's version: each source's check time and the newest pictures.
        var checked: [WeatherSource: Date]
        var radar: Date?
        var satellite: Date?
        var packs: [PackFile]
    }

    var key: Key
    var weather: WeatherData
    var now: Date
    var localOffset: Int?
    var database: NavDatabase?

    init(route: Route, inputs: FlightPlanInputs, plan: FlightPlan, aircraft: AircraftProfile?, balance: WeightBalance?,
         weather: WeatherData, now: Date, localOffset: Int?, database: NavDatabase?, packs: [PackFile]) {
        key = Key(route: route, inputs: inputs, plan: plan, aircraft: aircraft, balance: balance, checked: weather.checkedAt,
                  radar: weather.frames.last?.valid, satellite: weather.satellite?.valid, packs: packs)
        self.weather = weather
        self.now = now
        self.localOffset = localOffset
        self.database = database
    }

    /// The core brief. Slow on long routes, so it runs off the main thread.
    func make(assets: URL?) -> FlightBrief {
        let base = assets.map { folder in
            BriefMapBase(installed: key.packs,
                         streetTemplate: try? String(contentsOf: folder.appending(path: "street-light.json"), encoding: .utf8),
                         assets: "file://" + folder.path)
        }
        return FlightBrief.make(route: key.route, inputs: key.inputs, plan: key.plan, aircraft: key.aircraft,
                                balance: key.balance, weather: weather, now: now, localOffsetSeconds: localOffset,
                                database: database, mapBase: base)
    }

    /// A finished brief and its map pictures by id.
    struct Done: @unchecked Sendable {
        var key: Key
        var brief: FlightBrief
        var images: [String: UIImage]
    }
}

/// The preflight brief as a full screen page: the core's graphics, then its sections, collapsible, with a PDF to share.
/// It builds in the background and fills in; the finished brief is kept so opening it again is instant.
struct BriefPage: View {
    let job: BriefJob
    var cached: BriefJob.Done?
    var onBuilt: (BriefJob.Done) -> Void = { _ in }
    var onClose: () -> Void = {}
    @State private var brief: FlightBrief?
    @State private var images: [String: UIImage] = [:]
    @State private var finished = false
    @State private var collapsed: Set<String> = []
    @Environment(\.displayScale) private var scale

    var body: some View {
        NavigationStack {
            List {
                Section { BriefNotice(text: FlightBrief.notice) }
                if let brief {
                    graphics(brief.graphics)
                    ForEach(brief.sections, id: \.title) { section in
                        Section(isExpanded: Binding(get: { !collapsed.contains(section.title) },
                                                    set: { open in if open { collapsed.remove(section.title) } else { collapsed.insert(section.title) } })) {
                            BriefRows(section: section)
                        } header: {
                            Text(section.title)
                        }
                    }
                } else {
                    Section {
                        ProgressView(BriefGraphics.building).frame(maxWidth: .infinity)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(brief?.title ?? "Brief")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose).accessibilityIdentifier("brief-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    if let brief, finished {
                        ShareLink(item: BriefPDF(brief: brief, images: images), preview: SharePreview(brief.fileName)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("brief-share")
                    }
                }
            }
        }
        .accessibilityIdentifier("brief-page")
        .task { await build() }
    }

    @ViewBuilder private func graphics(_ g: BriefGraphics) -> some View {
        Section(BriefGraphics.hazardsTitle) { BriefHazards(graphics: g) }
        if let route = g.map.pictures.first {
            Section(route.title) {
                BriefPicture(title: "", image: images[route.id]).accessibilityLabel(route.title).accessibilityIdentifier("brief-map")
            }
        }
        Section(BriefGraphics.profileTitle) { BriefProfileChart(profile: g.profile) }
        Section(BriefGraphics.airportsTitle) {
            ForEach(g.airports, id: \.title) { BriefAirportPanel(airport: $0) }
        }
        let weather = g.map.pictures.dropFirst()
        if !weather.isEmpty {
            Section(BriefGraphics.picturesTitle) {
                ForEach(Array(weather), id: \.id) { BriefPicture(title: $0.title, image: images[$0.id]) }
            }
        }
    }

    // The core first, then each picture as it is drawn. Closing the page cancels whatever is left.
    private func build() async {
        if let cached, cached.key == job.key {
            (brief, images, finished) = (cached.brief, cached.images, true)
            return
        }
        let job = job
        let assets = Bundle.main.resourceURL?.appending(path: "MapAssets")
        let made = await Task.detached(priority: .userInitiated) { job.make(assets: assets) }.value
        guard !Task.isCancelled else { return }
        brief = made
        for picture in made.graphics.map.pictures {
            guard let image = await BriefSnapshot.take(picture, bounds: made.graphics.map.bounds, scale: scale) else {
                if Task.isCancelled { return }
                continue
            }
            images[picture.id] = image
        }
        guard !Task.isCancelled else { return }
        finished = true
        onBuilt(BriefJob.Done(key: job.key, brief: made, images: images))
    }
}

private struct BriefNotice: View {
    let text: String
    var body: some View { StateWord(.warning, text, systemImage: "exclamationmark.triangle.fill") }
}

/// One section's rows, its empty text, then its data age and an amber line when the source is not current.
private struct BriefRows: View {
    let section: FlightBrief.Section
    var showsLines = true

    var body: some View {
        ForEach(Array((showsLines ? section.lines : []).enumerated()), id: \.offset) { _, line in
            PlanLine(line: line)
                .listRowBackground(section.adverse ? PanelInk.warning.opacity(0.15) : nil)
        }
        if section.lines.isEmpty, let empty = section.empty { Text(empty).foregroundStyle(.secondary) }
        if let warning = section.warning { StateWord(.warning, warning, systemImage: "clock.badge.exclamationmark") }
        if let age = section.age { Text(age).note() }
    }
}

/// The graphics and rows laid out on US Letter pages under the core's file name, the mark in each footer.
struct BriefPDF: Transferable {
    let brief: FlightBrief
    var images: [String: UIImage] = [:]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { SentTransferredFile(try await $0.write()) }
    }

    @MainActor func write() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: brief.fileName)
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 36, footer: CGFloat = 24
        guard let context = CGContext(url as CFURL, mediaBox: &page, nil) else { throw CocoaError(.fileWriteUnknown) }
        var y = page.height, open = false
        func draw(_ view: some View, at origin: CGPoint, width: CGFloat) -> CGFloat {
            var height: CGFloat = 0
            ImageRenderer(content: view.frame(width: width, alignment: .leading).environment(\.colorScheme, .light))
                .render { size, render in
                    context.saveGState()
                    context.translateBy(x: origin.x, y: page.height - origin.y - size.height)
                    render(context)
                    context.restoreGState()
                    height = size.height
                }
            return height
        }
        // Each block goes whole onto a page, so a row never splits across two.
        // ponytail: a block taller than a page runs off its bottom; split long rows if one ever does.
        for block in blocks() {
            let renderer = ImageRenderer(content: block.frame(width: page.width - 2 * margin, alignment: .leading)
                .environment(\.colorScheme, .light))
            renderer.render { size, render in
                if !open || y + size.height > page.height - margin - footer {
                    if open { context.endPDFPage() }
                    context.beginPDFPage(nil)
                    open = true
                    _ = draw(BriefFooter(), at: CGPoint(x: margin, y: page.height - margin), width: page.width - 2 * margin)
                    y = margin
                }
                context.saveGState()
                context.translateBy(x: margin, y: page.height - y - size.height)
                render(context)
                context.restoreGState()
                y += size.height
            }
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    @MainActor private func blocks() -> [AnyView] {
        let g = brief.graphics
        var out = [AnyView(Text(brief.title).font(.title.bold())), AnyView(BriefNotice(text: brief.notice).padding(.vertical))]
        func heading(_ text: String) -> AnyView { AnyView(Text(text).font(.headline).padding(.top)) }
        // A heading kept on the page with what it names.
        func titled(_ text: String, _ content: some View) -> AnyView {
            AnyView(VStack(alignment: .leading) { Text(text).font(.headline).padding(.top); content })
        }
        out.append(titled(BriefGraphics.hazardsTitle, BriefHazards(graphics: g)))
        if let route = g.map.pictures.first {
            out.append(titled(route.title, BriefPicture(title: "", image: images[route.id])))
        }
        out.append(titled(BriefGraphics.profileTitle, BriefProfileChart(profile: g.profile)))
        out.append(heading(BriefGraphics.airportsTitle))
        out += g.airports.map { airport in AnyView(VStack { BriefAirportPanel(airport: airport); Divider() }) }
        let weather = g.map.pictures.dropFirst()
        if !weather.isEmpty {
            out.append(heading(BriefGraphics.picturesTitle))
            out.append(AnyView(HStack(alignment: .top) {
                ForEach(Array(weather), id: \.id) { BriefPicture(title: $0.title, image: images[$0.id]) }
            }))
        }
        for section in brief.sections {
            out.append(heading(section.title))
            for line in section.lines {
                out.append(AnyView(VStack { PlanLine(line: line); Divider() }
                    .background(section.adverse ? PanelInk.warning.opacity(0.15) : .clear)))
            }
            out.append(AnyView(VStack(alignment: .leading) { BriefRows(section: section, showsLines: false) }))
        }
        return out
    }
}

/// The mark and name, small and gray, at the foot of each PDF page.
private struct BriefFooter: View {
    @ScaledMetric private var mark = 12.0
    var body: some View {
        HStack {
            Image("Mark").resizable().frame(width: mark, height: mark)
            Text("Blueside").font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
