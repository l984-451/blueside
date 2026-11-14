import FlightCore
import SwiftUI

/// Airport search and the airport page, in one panel drawn over the map.
struct NavPanel: View {
    let model: NavModel
    let downloads: DownloadsModel
    var online = true
    var onClose: () -> Void = {}
    var onDirect: () -> Void = {}
    var onShowOnMap: (Airport) -> Void = { _ in }

    @Environment(LocationProvider.self) private var location: LocationProvider?
    @FocusState private var searching: Bool
    @State private var focusedOnce = false

    var body: some View {
        search
            .panelPage(NavPages.searchTitle, onClose: onClose)
            .searchable(text: Binding(get: { model.query }, set: { model.search($0) }),
                        placement: .navigationBarDrawer(displayMode: .always), prompt: NavPages.searchPrompt)
            .searchFocused($searching)
            // Searching keeps the title and close button, so the panel can always be put away.
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            // The field takes focus when the panel opens, not on every return from an airport page.
            .onAppear { if !focusedOnce { focusedOnce = true; searching = true } }
            .navigationDestination(isPresented: Binding(get: { model.detail != nil && model.database != nil },
                                                        set: { if !$0 { model.closePage() } })) {
                if let detail = model.detail, let database = model.database {
                    AirportPage(detail: detail, metadata: database.metadata,
                                favorites: model.favorites,
                                onDirect: { direct(detail.airport) },
                                onAddToRoute: { add(detail.airport) },
                                addTitle: { model.addSpot(detail.airport.coordinate, position: $0.position,
                                                          approximate: $0.approximate, now: Date()).title },
                                onShowOnMap: { onShowOnMap(detail.airport) }, onClose: onClose)
                        .panelPage(NavText.title(detail.airport), onClose: onClose)
                }
            }
            // Every new fix, the fix turning exact, and the database opening work the nearest list out again.
            // Watched outside the body, so a fix never redraws the panel.
            .task { [location] in
                guard let location else { return }
                for await (fix, approximate) in Observations({ (location.position, location.isApproximate) }) {
                    model.updateNearest(from: fix, approximate: approximate, now: Date())
                }
            }
            .onChange(of: model.database == nil) { _, _ in
                model.updateNearest(from: location?.position, approximate: location?.isApproximate ?? false, now: Date())
            }
    }

    @ViewBuilder private var search: some View {
        if let database = model.database {
            List {
                if let problem = model.problem {
                    StateWord(.danger, problem, systemImage: "xmark.octagon.fill")
                        .accessibilityIdentifier("nav-problem")
                }
                if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    favorites
                    FixReader { nearest($0) }
                } else if model.results.isEmpty, model.problem == nil {
                    Text(NavPages.noMatch).note().accessibilityIdentifier("nav-no-results")
                } else {
                    ForEach(model.results) { airport in
                        Button { model.show(airport) } label: { NavResultRow(airport: airport, quick: model.quickLine(airport)) }
                            .placeRowActions(direct: { direct(airport) }, add: { add(airport) },
                                             showOnMap: { onShowOnMap(airport) })
                            .accessibilityIdentifier("nav-result-\(airport.ident)")
                    }
                }
            }
            .listStyle(.plain)
            .panelList()
            // Out-of-cycle data is marked here, above the results and the nearest list.
            .safeAreaInset(edge: .top) {
                NavDataWarning(metadata: database.metadata, identifier: "nav-data-warning")
                    .padding(.horizontal)
            }
        } else {
            VStack(alignment: .leading) {
                if let problem = model.problem {
                    StateWord(.danger, problem, systemImage: "xmark.octagon.fill")
                        .accessibilityIdentifier("nav-problem")
                }
                downloadOffer
                Spacer()
            }
            .padding()
        }
    }

    // With no data on the device the panel says so and offers the download, with its progress in words.
    private var downloadOffer: some View {
        VStack(alignment: .leading) {
            Text(DownloadPolicy.statusText(downloads.state(of: NavFiles.region), waiting: !online))
                .accessibilityIdentifier("nav-download-state")
            Button {
                Task {
                    await downloads.retry(NavFiles.region)
                    await downloads.refresh()
                }
            } label: {
                Text(NavPages.Action.download).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("Download navigation data")
            .accessibilityIdentifier("nav-download")
            // Says why the button does nothing when the list cannot be fetched.
            if let notice = NavText.downloadNotice(downloads.listFailure, hasList: downloads.manifest != nil) {
                Text(notice).note().accessibilityIdentifier("nav-download-notice")
            }
        }
    }

    @ViewBuilder private var favorites: some View {
        let airports = model.favoriteAirports()
        if !airports.isEmpty {
            Section(NavPages.favoritesTitle) {
                ForEach(airports) { airport in
                    Button { model.show(airport) } label: { NavResultRow(airport: airport, quick: model.quickLine(airport)) }
                        .placeRowActions(direct: { direct(airport) }, add: { add(airport) },
                                         showOnMap: { onShowOnMap(airport) },
                                         remove: { model.favorites.remove(airport.ident) })
                        .accessibilityIdentifier("favorite-\(airport.ident)")
                }
            }
        }
    }

    // Its own leaf: a fix redraws this section only.
    private func nearest(_ fix: Fix) -> some View {
        let list = model.nearestList(position: fix.position, approximate: fix.approximate, now: fix.now)
        return Section {
            ForEach(list.rows) { row in
                Button { model.show(row.airport) } label: {
                    HStack {
                        NavResultRow(airport: row.airport, quick: model.quickLine(row.airport))
                        Spacer()
                        RangeColumn(distance: row.distance, bearing: row.bearing).equatable()
                        if let turn = row.turn {
                            Image(systemName: "location.north.fill").rotationEffect(.degrees(turn))
                                .foregroundStyle(.tint).accessibilityHidden(true)
                        }
                    }
                }
                .placeRowActions(direct: { direct(row.airport) }, add: { add(row.airport) },
                                 showOnMap: { onShowOnMap(row.airport) })
                .accessibilityIdentifier("nearest-\(row.airport.ident)")
            }
        } header: {
            Text(list.header).accessibilityIdentifier("nearest-header")
        }
    }

    private func direct(_ airport: Airport) { model.directTo(RouteWaypoint(airport: airport)); onDirect() }

    private func add(_ airport: Airport) {
        model.add(RouteWaypoint(airport: airport), position: location?.position,
                  approximate: location?.isApproximate ?? false)
    }
}

/// One line of a result list: the airport's code, a closed mark, and its name.
struct NavResultRow: View {
    let airport: Airport
    var quick: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let row = NavPages.row(airport, quick: quick)
            PlaceLabel(row: row)
            if let quick = row.quick { Text(quick).font(.footnote.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75) }
        }
    }
}
