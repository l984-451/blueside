import FlightCore
import SwiftUI

/// The active route's legs, as a list hanging under the strip. The active leg is marked; a tap opens the editor.
struct RouteDrawer: View {
    let plan: RoutePlan
    var onEdit: () -> Void = {}
    var isClosed: (RouteWaypoint) -> Bool = { _ in false }
    /// The selected aircraft's cruise true airspeed.
    var speed: Double?
    @Environment(\.isNight) private var night
    @Environment(\.fixedNow) private var fixedNow
    /// How tall the rows shown before scrolling are, measured, so large type grows the drawer.
    @State private var shownHeight: CGFloat = 0

    /// Rows shown before the list scrolls.
    static let visibleRows = 4

    var body: some View {
        // Planned values; only the active row's numbers follow the fix, in their own leaf.
        let rows = plan.rows(position: nil, now: fixedNow ?? Date(), trueAirspeedKt: speed)
        let lastShown = min(rows.count, Self.visibleRows) - 1
        VStack(spacing: 0) {
            HStack {
                Label(RoutePages.title(plan),
                      systemImage: plan.isDirect ? "arrow.up.right" : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.headline)
                    .foregroundStyle(Color(MapInk.route(night: night)))
                Spacer()
                Button(RoutePages.edit, action: onEdit).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("route-edit")
            }
            .padding(.horizontal)
            .padding(.vertical, chromeInset / 2)
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            legRow(row)
                                .onGeometryChange(for: CGFloat.self, of: { row.id == lastShown ? $0.frame(in: .named("legs")).maxY : 0 }) {
                                    if $0 > 0 { shownHeight = $0 }
                                }
                            if row.id != rows.last?.id { Divider().padding(.leading) }
                        }
                    }
                    .coordinateSpace(.named("legs"))
                }
                // Grows with its rows up to the shown ones, and gives way first when the map is short of room.
                .frame(maxHeight: shownHeight)
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: plan.activeLeg, initial: true) { _, leg in scroller.scrollTo(leg, anchor: .top) }
            }
        }
        .modifier(NightDim())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("direct-readout")
    }

    // The active row keeps the Direct To identifiers, so it reads the same for one leg or many.
    private func legRow(_ row: RoutePlan.LegRow) -> some View {
        let active = row.isActive
        return HStack {
            Image(systemName: "arrowtriangle.right.fill")
                .foregroundStyle(Color(MapInk.route(night: night)))
                .opacity(active ? 1 : 0)
                .accessibilityHidden(true)
            PlaceLabel(ident: row.waypoint.ident, name: row.waypoint.name, closed: isClosed(row.waypoint),
                       identifier: active ? "map-direct-ident" : "leg-ident-\(row.id)")
            Spacer()
            if active {
                FixReader { fix in
                    let live = plan.rows(position: fix.position, approximate: fix.approximate, now: fix.now,
                                         trueAirspeedKt: speed)[safe: row.id] ?? row
                    ActiveLeg(distance: live.distance, bearing: live.course, time: live.time, id: row.id)
                        .equatable()
                }
            } else {
                RangeColumn(distance: row.distance, bearing: row.course, time: row.time,
                            ids: ("leg-distance-\(row.id)", "leg-course-\(row.id)", "leg-time-\(row.id)"))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, chromeInset / 2)
        .background(active ? Color(MapInk.route(night: night)).opacity(0.12) : Color.clear)
        .contentShape(.rect)
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Edit Route", onEdit)
        .accessibilityValue(active ? "Active leg" : "")
        .accessibilityIdentifier(active ? "direct-row" : "route-leg-\(row.id)")
        .id(row.id)
    }
}

/// Distance and time to the next point at the strip's instrument size, the course under them.
private struct ActiveLeg: View, Equatable {
    let distance: String
    let bearing: String
    let time: String?
    let id: Int

    nonisolated static func == (a: Self, b: Self) -> Bool {
        (a.distance, a.bearing, a.time, a.id) == (b.distance, b.bearing, b.time, b.id)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(distance).accessibilityIdentifier("map-direct-distance")
                if let time { Text(time).accessibilityIdentifier("leg-time-\(id)") }
            }
            .instrument()
            Text(bearing).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("map-direct-bearing")
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The route in one line, for the strip when its drawer is tucked away: the next waypoint and where it ends.
struct RouteSummary: View {
    let plan: RoutePlan
    /// The selected aircraft's cruise true airspeed.
    var speed: Double?
    @Environment(\.isNight) private var night

    var body: some View {
        FixReader { fix in
            let rows = plan.rows(position: fix.position, approximate: fix.approximate, now: fix.now,
                                 trueAirspeedKt: speed)
            if let summary = RoutePages.summary(rows) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "arrowtriangle.right.fill").foregroundStyle(Color(MapInk.route(night: night)))
                    Text(summary.ident).font(.headline)
                    Text(summary.detail).instrument()
                    if let end = summary.end {
                        Text(end).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .modifier(NightDim())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("route-summary")
            }
        }
    }
}
