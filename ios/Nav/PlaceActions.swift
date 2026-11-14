import FlightCore
import SwiftUI

/// The one action row for any place: Direct To, the one prominent button, on its own line, then Add and Show on Map
/// side by side, bordered, each a glyph over its title. Where those two do not fit, as at large text, all stack full width.
struct PlaceActionRow: View {
    let addTitle: String?
    let onDirect: (() -> Void)?
    var onAdd: (() -> Void)?
    var onShowOnMap: (() -> Void)?
    @Environment(\.isNight) private var night

    var body: some View {
        ViewThatFits(in: .horizontal) {
            VStack { direct; HStack { others(tiles: true) } }
            VStack { direct; others(tiles: false) }
        }
        .controlSize(.large)
    }

    @ViewBuilder private var direct: some View {
        if let onDirect {
            Button(action: onDirect) {
                Label(NavPages.Action.direct, systemImage: "arrow.up.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Color(.white)) // design-lint: allow white label on the route fill
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(MapInk.routeFill(night: night)))
            .accessibilityIdentifier("direct-to-button")
        }
    }

    @ViewBuilder private func others(tiles: Bool) -> some View {
        if let onAdd {
            Button(action: onAdd) { label(addTitle ?? NavPages.Action.add, "plus", tile: tiles) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("add-to-route-button")
        }
        if let onShowOnMap {
            Button(action: onShowOnMap) { label(NavPages.Action.showOnMap, "map", tile: tiles) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("show-on-map-button")
        }
    }

    // A glyph over the title as a tile, or beside it, free to wrap, full width. Only the title is spoken.
    private func label(_ title: String, _ symbol: String, tile: Bool) -> some View {
        let layout = tile ? AnyLayout(VStackLayout()) : AnyLayout(HStackLayout())
        return layout {
            Image(systemName: symbol).font(tile ? .title3 : .headline).accessibilityHidden(true)
            Text(title).font(tile ? .footnote.weight(.semibold) : .headline)
                .lineLimit(tile ? 1 : nil).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Where a place is from the aircraft, then its action row. The airport page and the place card share it.
struct PlaceHeader: View {
    let coordinate: Coordinate
    /// The Add button's title, which can follow the fix along a route. Nil leaves Add out.
    let addTitle: ((Fix) -> String)?
    let onDirect: (() -> Void)?
    var onAdd: (() -> Void)?
    var onShowOnMap: (() -> Void)?

    // No container of its own, so it takes the spacing of the stack or list it sits in.
    // Each piece reads the fix in its own leaf, so a new fix never redraws the page around it.
    var body: some View {
        FixReader { fix in
            let direct = NavText.directTo(from: fix.position, to: coordinate, approximate: fix.approximate, now: fix.now)
            DirectLine(distance: direct.distance, bearing: direct.bearing).equatable()
        }
        FixReader { fix in
            PlaceActionRow(addTitle: addTitle?(fix), onDirect: onDirect, onAdd: onAdd, onShowOnMap: onShowOnMap)
                .padding(.top, 4)
        }
    }
}

/// Distance and bearing from the aircraft. Equatable, so a fix that rounds the same skips it.
private struct DirectLine: View, Equatable {
    let distance: String
    let bearing: String

    var body: some View {
        HStack(spacing: 6) {
            Text(distance).accessibilityIdentifier("direct-distance")
            Text("·")
            Text(bearing).accessibilityIdentifier("direct-bearing")
        }
        .font(.body.monospacedDigit())
    }
}

/// A place's code over its name, with a closed mark and kind beside the code.
struct PlaceLabel: View {
    let row: NavPages.Row
    var identifier = ""

    /// A route point, which has no database row of its own.
    init(ident: String, name: String?, closed: Bool = false, identifier: String = "") {
        row = NavPages.Row(kind: .user, ident: ident, title: ident, name: name.flatMap { NavPages.name($0, ident: ident) },
                           closed: closed ? NavPages.closed : nil, coordinate: Coordinate(latitude: 0, longitude: 0))
        self.identifier = identifier
    }

    init(row: NavPages.Row) { self.row = row }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(row.title).font(.headline).accessibilityIdentifier(identifier)
                if let closed = row.closed { StateWord(.danger, closed, systemImage: "xmark.octagon.fill") }
                if let kind = row.kindLabel { Text(kind).font(.caption.weight(.bold)).foregroundStyle(.secondary) }
            }
            if let name = row.name { Text(name).detail().lineLimit(1) }
        }
    }
}

/// Distance over bearing and time, at the trailing edge of a row. Equatable, so a fix that rounds the same skips it.
struct RangeColumn: View, Equatable {
    let distance: String
    let bearing: String
    var time: String?
    /// Identifiers for the distance, bearing and time, for tests.
    var ids = ("", "", "")

    nonisolated static func == (a: Self, b: Self) -> Bool {
        (a.distance, a.bearing, a.time) == (b.distance, b.bearing, b.time) && a.ids == b.ids
    }

    var body: some View {
        VStack(alignment: .trailing) {
            Text(distance).font(.headline.monospacedDigit()).accessibilityIdentifier(ids.0)
            HStack {
                Text(bearing).accessibilityIdentifier(ids.1)
                if let time { Text(time).accessibilityIdentifier(ids.2) }
            }
            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
        // Numbers never wrap; in a narrow row the name beside them gives way.
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension View {
    /// The swipe and long-press actions of every place row. A nil action is left out.
    func placeRowActions(direct: (() -> Void)? = nil, add: (() -> Void)? = nil, showOnMap: (() -> Void)? = nil,
                         remove: (() -> Void)? = nil) -> some View {
        modifier(PlaceRowActions(direct: direct, add: add, showOnMap: showOnMap, remove: remove))
    }
}

private struct PlaceRowActions: ViewModifier {
    let direct: (() -> Void)?
    let add: (() -> Void)?
    let showOnMap: (() -> Void)?
    let remove: (() -> Void)?
    @Environment(\.isNight) private var night

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) {
                if let add { Button(NavPages.Action.add, systemImage: "plus.circle", action: add).tint(.accentColor) }
            }
            .swipeActions(edge: .trailing) {
                if let remove { Button(NavPages.Action.remove, systemImage: "trash", role: .destructive, action: remove) }
                if let showOnMap { Button(NavPages.Action.showOnMap, systemImage: "map", action: showOnMap).tint(.accentColor) }
                if let direct {
                    Button(NavPages.Action.direct, systemImage: "arrow.up.right", action: direct)
                        .tint(Color(MapInk.routeFill(night: night)))
                }
            }
            .contextMenu {
                if let direct { Button(NavPages.Action.direct, systemImage: "arrow.up.right", action: direct) }
                if let add { Button(NavPages.Action.add, systemImage: "plus.circle", action: add) }
                if let showOnMap { Button(NavPages.Action.showOnMap, systemImage: "map", action: showOnMap) }
                if let remove { Button(NavPages.Action.remove, systemImage: "trash", role: .destructive, action: remove) }
            }
    }
}
