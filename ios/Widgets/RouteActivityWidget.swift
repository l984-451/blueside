import ActivityKit
import SwiftUI
import WidgetKit

/// The route in flight: the next waypoint, the distance to it and the time to it, with no words.
@main struct RouteActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RouteActivity.self) { context in
            HStack(alignment: .firstTextBaseline) {
                Glyph()
                Text(context.state.ident)
                Spacer()
                Text(context.state.distance)
                Countdown(state: context.state, stale: context.isStale)
            }
            .font(.title2.weight(.semibold).monospacedDigit())
            .foregroundStyle(context.isStale ? .secondary : .primary)
            .lineLimit(1)
            .padding()
            .accessibilityElement(children: .combine)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(alignment: .firstTextBaseline) {
                        Glyph()
                        Text(context.state.ident)
                    }
                    .font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(context.state.distance)
                        Countdown(state: context.state, stale: context.isStale)
                    }
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
            } compactLeading: {
                Text(context.state.ident)
            } compactTrailing: {
                // Below the speed that gives a time, the distance stands in for it.
                if context.state.arrival == nil || context.isStale {
                    Text(context.state.distance).monospacedDigit()
                } else {
                    Countdown(state: context.state, stale: false)
                }
            } minimal: {
                if context.state.arrival == nil || context.isStale { Glyph() } else { Countdown(state: context.state, stale: false) }
            }
        }
    }
}

/// The route's active-leg mark, in the app's route ink.
private struct Glyph: View {
    var body: some View {
        Image(systemName: "arrowtriangle.right.fill")
            .imageScale(.small)
            .foregroundStyle(routeInk)
            .accessibilityHidden(true)
    }
}

/// The time to the waypoint, counted down by the system between updates. None once the values are stale.
private struct Countdown: View {
    let state: RouteActivity.ContentState
    let stale: Bool

    var body: some View {
        if let arrival = state.arrival, !stale {
            let now = Date.now
            let left = arrival.timeIntervalSince(now)
            // The timer takes every point it is offered, so hidden digits of its present length set its width.
            Text(left >= 3600 ? "0:00:00" : left >= 600 ? "00:00" : "0:00")
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(timerInterval: now...max(arrival, now), countsDown: true).multilineTextAlignment(.trailing)
                }
                .monospacedDigit()
        }
    }
}

/// The app's route ink (`MapInk.route`): its night value where the system is dark.
private let routeInk = Color(UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0xf0 / 255, green: 0x60 / 255, blue: 0xd6 / 255, alpha: 1) // design-lint: allow MapInk.route night
        : UIColor(red: 0xd1 / 255, green: 0x1f / 255, blue: 0xb6 / 255, alpha: 1) // design-lint: allow MapInk.route day
})
