import FlightCore
import SwiftUI

/// One Downloads category and the store behind it.
struct DownloadSection: Identifiable {
    let category: DownloadCategory
    let model: DownloadsModel
    var id: String { category.id }

    @MainActor func summary(online: Bool) -> DownloadSummary {
        let rows = model.rows
        return DownloadSummary(states: rows.map(\.state), sizes: rows.map(\.bytes), unit: category.unit, waiting: !online)
    }

    /// The SF Symbol and tile color on the category row, as in the system Settings list.
    var symbol: (name: String, color: Color) {
        switch category.id {
        case DownloadCategory.nav.id: ("location.north.line.fill", .green)
        case DownloadCategory.procedures.id: ("doc.text.fill", .orange)
        case DownloadCategory.street.id: ("car.fill", .gray)
        case DownloadCategory.terrain.id: ("mountain.2.fill", .brown)
        default: ("map.fill", .blue)
        }
    }

    /// Prefix that keeps row identifiers apart; charts keep the bare ones the tests have always read.
    var tag: String { category == .charts ? "" : "\(category.id)-" }
}

/// The Downloads page, laid out like the system's storage page: space used, a row per category, then the
/// actions for everything. With no network the chart list says it is the last known one.
struct DownloadsSheet: View {
    let sections: [DownloadSection]
    var online = true

    @State private var confirmsDelete = false

    var body: some View {
        let summaries = sections.map { $0.summary(online: online) }
        List {
            Section {
                LabeledContent("Used", value: DownloadSummary.used(summaries))
                    .accessibilityIdentifier("downloads-used")
                if let charts = sections.first(where: { $0.category == .charts })?.model,
                   let notice = DownloadPolicy.listNotice(charts.listFailure, hasList: charts.manifest != nil) {
                    Text(notice).note().accessibilityIdentifier("downloads-offline")
                }
            }
            Section {
                ForEach(Array(zip(sections, summaries)), id: \.0.id) { section, summary in
                    NavigationLink(value: section.category) { CategoryRow(section: section, summary: summary) }
                        .accessibilityIdentifier("downloads-\(section.id)")
                }
            }
            Section {
                if summaries.contains(where: { if case .failed = $0.state { true } else { $0.state == .expired } }) {
                    Button("Update All", action: updateAll).accessibilityIdentifier("downloads-update-all")
                }
                Button("Delete All", role: .destructive) { confirmsDelete = true }
                    .accessibilityIdentifier("downloads-delete-all")
                    .confirmationDialog("Delete all downloads?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                        Button("Delete All", role: .destructive, action: deleteAll)
                    } message: {
                        Text("Charts, procedures, street and terrain maps are removed from this device. Navigation data stays.")
                    }
            }
        }
        .accessibilityIdentifier("downloads-sheet")
        .task {
            // Navigation data refreshes with the map; the rest fetch their lists when the page opens.
            for section in sections where section.category != .nav { Task { await section.model.refresh() } }
        }
    }

    private func updateAll() {
        Task {
            for section in sections {
                for row in section.model.rows {
                    if case .failed = row.state { await section.model.retry(row.id) }
                }
                await section.model.refresh()
            }
        }
    }

    private func deleteAll() {
        Task {
            for section in sections where section.category != .nav {
                for row in section.model.rows where row.state != .notDownloaded { await section.model.remove(row.id) }
            }
        }
    }
}

/// A top-level row: the category's symbol on a colored tile, its name, and the core's summary at the end.
struct CategoryRow: View {
    let section: DownloadSection
    let summary: DownloadSummary
    @ScaledMetric private var tile: CGFloat = 29

    var body: some View {
        HStack {
            Image(systemName: section.symbol.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white) // design-lint: allow glyph on its colored tile, as in Settings
                .frame(width: tile, height: tile)
                .background(section.symbol.color.gradient, in: .rect(cornerRadius: tile * 0.25, style: .continuous))
            Text(section.category.title)
            Spacer()
            if case .downloading(let progress) = summary.state {
                ProgressRing(progress: progress)
            }
            summaryText
        }
    }

    @ViewBuilder private var summaryText: some View {
        let id = "downloads-summary-\(section.id)"
        switch summary.state {
        case .failed: StateWord(.danger, summary.text, systemImage: "xmark.octagon.fill").accessibilityIdentifier(id)
        case .expired: StateWord(.warning, summary.text, systemImage: "exclamationmark.triangle.fill").accessibilityIdentifier(id)
        default: Text(summary.text).foregroundStyle(.secondary).monospacedDigit().accessibilityIdentifier(id)
        }
    }
}

/// One category's regions with their actions, the list's notice above and what the category holds below.
struct CategoryPage: View {
    let section: DownloadSection
    var online = true

    var body: some View {
        let model = section.model
        List {
            if section.category != .nav {
                Picker("Show", selection: Bindable(model).downloadedOnly) {
                    Text("All").tag(false)
                    Text("Downloaded").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("downloads-filter")
            }
            Section {
                if section.category == .nav {
                    NavDataRow(model: model, online: online)
                } else {
                    if let notice = DownloadPolicy.listNotice(model.listFailure, hasList: model.manifest != nil) {
                        Text(notice).note().accessibilityIdentifier("\(section.tag)list-notice")
                    }
                    if let message = model.message {
                        StateWord(.danger, message, systemImage: "xmark.octagon.fill")
                            .accessibilityIdentifier("downloads-message")
                    }
                    let rows = model.rows.filter { !model.downloadedOnly || DownloadSummary.isDownloaded($0.state) }
                    ForEach(rows) { row in
                        PackRow(row: row,
                                onDownload: { Task { await model.choose(row.id) } },
                                onRetry: { Task { await model.retry(row.id) } },
                                onRemove: { Task { await model.remove(row.id) } },
                                waiting: !online, tag: section.tag)
                    }
                    if rows.isEmpty, model.downloadedOnly {
                        ContentUnavailableView {
                            Label("Nothing downloaded yet", systemImage: "arrow.down.circle")
                        } actions: {
                            Button("Show All") { model.downloadedOnly = false }
                                .accessibilityIdentifier("\(section.tag)show-all")
                        }
                    }
                }
            } footer: {
                Text(section.category.footer)
            }
        }
        .accessibilityIdentifier("downloads-\(section.id)-page")
        .navigationTitle(section.category.title)

    }
}

/// The navigation data line: both files as one row, in the same words as a chart pack.
struct NavDataRow: View {
    let model: DownloadsModel
    var online = true

    var body: some View {
        let state = model.state(of: NavFiles.region)
        let row = model.rows.first { $0.id == NavFiles.region }
        HStack {
            VStack(alignment: .leading) {
                Text("Airports, navaids and airspace").font(.headline)
                if let bytes = row?.bytes, bytes > 0 {
                    Text(DownloadPolicy.byteCount(Int64(bytes))).detail()
                }
                PackRow.stateLine(state, effective: row?.effective, waiting: !online, identifier: "nav-state")
                if let notice = NavText.downloadNotice(model.listFailure, hasList: model.manifest != nil) {
                    Text(notice).note().accessibilityIdentifier("nav-list-notice")
                }
            }
            Spacer()
            PackRow.action(state, effective: row?.effective, identifier: { "nav-row-\($0)" }, onDownload: again, onRetry: again)
        }
    }

    // Clears a failure, fetches the list and starts whatever is missing.
    private func again() {
        Task {
            await model.retry(NavFiles.region)
            await model.refresh()
        }
    }
}

/// The full screen settings page: downloads and the rest of what is set on the ground.
struct SettingsPage: View {
    enum Page: String, CaseIterable, Identifiable {
        case downloads = "Downloads", aircraft = "Aircraft", devices = "Devices", about = "About", legal = "Legal"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .downloads: "arrow.down.circle"
            case .aircraft: "airplane"
            case .devices: "antenna.radiowaves.left.and.right"
            case .about: "info.circle"
            case .legal: "doc.text"
            }
        }
    }

    let model: AppModel
    let downloads: DownloadsModel
    let navDownloads: DownloadsModel
    var procedures: DownloadsModel?
    var street: DownloadsModel?
    var terrain: DownloadsModel?
    var online = true
    var opensDownloads = false
    let aircraft: AircraftStore
    var traffic: TrafficReceiver?
    let onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var page: Page?
    @State private var path = NavigationPath()
    @ScaledMetric private var markSize: CGFloat = 40

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(Page.allCases, selection: $page) { page in
                NavigationLink(value: page) { Label(page.rawValue, systemImage: page.symbol) }
                    .accessibilityIdentifier("settings-\(page.id)")
            }
            .navigationTitle("Settings")
            .toolbar(removing: .sidebarToggle)
            // Here too while no page is chosen, as on a phone turned on its side: the detail is then empty.
            .toolbar { if sizeClass == .compact || page == nil { close } }
        } detail: {
            NavigationStack(path: $path) {
                if let page {
                    detail(page)
                        .navigationTitle(page.rawValue)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { if sizeClass != .compact { close } }
                }
            }
            .id(page)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            if page == nil, opensDownloads || sizeClass != .compact { page = .downloads }
            // A launch can open one category, such as -downloads charts.
            if opensDownloads, let category = DownloadCategory.all.first(where: { $0.id == model.options.string("downloads") }) {
                path.append(category)
            }
        }
        .onChange(of: page) { old, _ in if old != nil { path = NavigationPath() } }
        .overlay(alignment: .bottomLeading) { if model.options.flag("probes") { AppearanceProbe() } }
    }

    private var close: some ToolbarContent {
        // Primary action keeps it after any page's own trailing buttons, as on every panel.
        ToolbarItem(placement: .primaryAction) {
            Button(role: .close, action: onClose).accessibilityIdentifier("panel-close")
        }
    }

    /// Each store with its category, in the core's order.
    private var downloadSections: [DownloadSection] {
        let models: [String: DownloadsModel?] = [DownloadCategory.nav.id: navDownloads, DownloadCategory.charts.id: downloads,
                                                 DownloadCategory.procedures.id: procedures, DownloadCategory.street.id: street,
                                                 DownloadCategory.terrain.id: terrain]
        return DownloadCategory.all.compactMap { category in
            (models[category.id] ?? nil).map { DownloadSection(category: category, model: $0) }
        }
    }

    @ViewBuilder private func detail(_ page: Page) -> some View {
        switch page {
        case .downloads:
            let sections = downloadSections
            DownloadsSheet(sections: sections, online: online)
                .navigationDestination(for: DownloadCategory.self) { category in
                    if let section = sections.first(where: { $0.category == category }) {
                        CategoryPage(section: section, online: online)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { if sizeClass != .compact { close } }
                    }
                }
        case .aircraft:
            AircraftList(store: aircraft)
        case .devices:
            if let traffic { ReceiverPage(receiver: traffic) }
        case .about:
            Form {
                HStack {
                    Image("Mark").resizable().frame(width: markSize, height: markSize).foregroundStyle(.tint)
                    Text("Blueside").font(.title2.weight(.semibold))
                }
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Text("Blueside is free for noncommercial use under the PolyForm Noncommercial license.")
            }
        case .legal:
            Form {
                Text("Charts and navigation data: FAA. Not for use as the sole means of navigation.")
                Text("Street map: © OpenStreetMap contributors.")
                Text("Airport taxiways, aprons, buildings and FBOs: © OpenStreetMap contributors.")
                Text("Terrain: elevation from Mapzen Terrain Tiles (USGS 3DEP, NASA SRTM, NOAA ETOPO1).")
                Text("Map rendering: MapLibre Native, BSD license.")
                Text("Fonts: Noto Sans, SIL Open Font License. Map style and icons: Protomaps, BSD license.")
                Text(AerialSource.credit)
            }
        }
    }
}
