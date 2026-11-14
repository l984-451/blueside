import FlightCore
import SwiftUI

/// What the place card opens on: the places under a finger, or one place. A dropped pin is a user place.
enum PlaceRoot: Hashable {
    case here([WaypointMatch])
    case one(WaypointMatch)

    /// The dropped pin, drawn on the map while its card is open.
    var pin: Coordinate? {
        if case .one(let place) = self, place.kind == .user { place.coordinate } else { nil }
    }
}

/// What a place card's buttons do, supplied by the screen.
struct PlaceActions {
    var onClose: () -> Void
    /// Nil leaves Direct To out, as on the planning page, where it would replace the route.
    var onDirect: ((WaypointMatch) -> Void)?
    var onShowOnMap: (Coordinate) -> Void
    /// The Add to Route button shows only when this is set.
    var onAddToRoute: ((WaypointMatch) -> Void)?
    /// Set while a rubber band waits for one of several places; the Here list's rows then pick.
    var onPick: ((WaypointMatch) -> Void)?
    /// Told the place on top as each page shows, or nil for a list, so the map can ring it.
    var onShown: (WaypointMatch?) -> Void = { _ in }
}

extension View {
    /// A place list row's swipe and long-press actions, from the card's buttons.
    func placeRowActions(_ actions: PlaceActions, _ place: WaypointMatch) -> some View {
        placeRowActions(direct: actions.onDirect.map { d in { d(place) } }, add: actions.onAddToRoute.map { add in { add(place) } },
                        showOnMap: { actions.onShowOnMap(place.coordinate) })
    }
}

/// The place card in the panel slot. Rows push the place they name.
struct PlacePanel: View {
    let root: PlaceRoot
    let nav: NavModel
    let actions: PlaceActions

    var body: some View {
        Group {
            switch root {
            case .here(let places) where actions.onPick != nil:
                List(places, id: \.self) { place in
                    Button { actions.onPick?(place) } label: { PlaceRow(place: place, nav: nav) }
                        .accessibilityIdentifier("pick-\(place.kind.rawValue)-\(place.ident)")
                }
                .listStyle(.plain)
                .panelList()
                .panelPage(NavPages.bendTitle, onClose: actions.onClose)
                .onAppear { actions.onShown(nil) }
            case .here(let places):
                List(places, id: \.self) { place in
                    NavigationLink(value: place) { PlaceRow(place: place, nav: nav) }
                        .placeRowActions(actions, place)
                        .accessibilityIdentifier("place-\(place.kind.rawValue)-\(place.ident)")
                }
                .listStyle(.plain)
                .panelList()
                .panelPage(NavPages.hereTitle, onClose: actions.onClose)
                .onAppear { actions.onShown(nil) }
            case .one(let place):
                page(place)
            }
        }
        .navigationDestination(for: WaypointMatch.self) { page($0) }
    }

    private func page(_ place: WaypointMatch) -> some View {
        pageBody(place).onAppear { actions.onShown(place) }
    }

    @ViewBuilder private func pageBody(_ place: WaypointMatch) -> some View {
        if place.kind == .airport, let database = nav.database, let (airport, detail) = nav.airportDetail(place.ident) {
            AirportPage(detail: detail, metadata: database.metadata, favorites: nav.favorites,
                        onDirect: actions.onDirect.map { d in { d(place) } }, onAddToRoute: { actions.onAddToRoute?(place) },
                        addTitle: { nav.addSpot(place.coordinate, position: $0.position, approximate: $0.approximate,
                                                now: Date()).title },
                        onShowOnMap: { actions.onShowOnMap(place.coordinate) }, onClose: actions.onClose)
                .panelPage(NavText.title(airport), onClose: actions.onClose)
        } else {
            PlaceCard(place: place, nav: nav, actions: actions)
        }
    }
}

/// One row of the Here and Nearby lists: an airport's usual row, or a navaid or fix by name and kind.
struct PlaceRow: View {
    let place: WaypointMatch
    let nav: NavModel
    /// The pin the distance is measured from, for the Nearby list.
    var from: Coordinate?

    var body: some View {
        HStack {
            if place.kind == .airport, let airport = try? nav.database?.airport(identifier: place.ident) {
                NavResultRow(airport: airport, quick: nav.quickLine(airport))
            } else {
                PlaceLabel(row: NavPages.row(place))
            }
            Spacer()
            if let distance = NavPages.row(place, from: from).distance {
                Text(distance).detail().monospacedDigit()
            }
        }
    }
}

/// A navaid, fix or dropped pin: where it is from the aircraft, its frequency, and what to do with it.
struct PlaceCard: View {
    let place: WaypointMatch
    let nav: NavModel
    let actions: PlaceActions
    @Environment(\.isNight) private var night

    var body: some View {
        let database = nav.database
        let card = NavPages.placeCard(place, navaid: place.kind == .navaid ? database?.navaid(for: place) : nil,
                                      fix: place.kind == .fix ? database?.fix(for: place) : nil)
        List {
            Section {
                PlaceHeader(
                    coordinate: place.coordinate,
                    addTitle: actions.onAddToRoute == nil ? nil : {
                        nav.addSpot(place.coordinate, position: $0.position, approximate: $0.approximate, now: Date()).title
                    },
                    onDirect: actions.onDirect.map { d in { d(place) } },
                    onAdd: actions.onAddToRoute.map { add in { add(place) } },
                    onShowOnMap: card.showOnMap ? { actions.onShowOnMap(place.coordinate) } : nil)
            }
            .listRowBackground(Color.clear)
            Section {
                ForEach(card.lines, id: \.title) { LabeledContent($0.title, value: $0.value ?? "") }
            }
            if let title = card.nearbyTitle {
                let nearby = database?.nearby(place.coordinate) ?? []
                Section(title) {
                    if nearby.isEmpty, let empty = card.nearbyEmpty { Text(empty).note() }
                    ForEach(nearby, id: \.self) { near in
                        NavigationLink(value: near) { PlaceRow(place: near, nav: nav, from: place.coordinate) }
                            .placeRowActions(actions, near)
                            .accessibilityIdentifier("nearby-\(near.kind.rawValue)-\(near.ident)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 0, for: .scrollContent)
        .panelList()
        .panelPage(card.title, onClose: actions.onClose)
        .navigationSubtitle(card.subtitle)
    }
}
