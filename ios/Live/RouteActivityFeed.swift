// Activity is not marked Sendable, though its update and end are made to be called from any task.
@preconcurrency import ActivityKit
import FlightCore
import SwiftUI

/// Starts, updates and ends the route's Live Activity as the core's rule says. Making one starts nothing.
@MainActor final class RouteActivityController {
    private var activity: Activity<RouteActivity>?
    private var showing: LiveLeg.Shown?
    private var sent: Date?
    /// The background rule's latest live fix at flying speed, carried from fix to fix.
    private var lastFast: Date?
    private var ending: Task<Void, Never>?
    private var leftoversEnded = false

    /// "activity active" or "activity none", for UI tests.
    var probe: String { activity.map { "activity \($0.activityState)" } ?? "activity none" }

    func feed(plan: RoutePlan?, position: Position?, approximate: Bool, heard: Date?, inFront: Bool, now: Date = Date()) {
        if !leftoversEnded {
            leftoversEnded = true
            // Only an earlier launch can have left one running.
            for old in Activity<RouteActivity>.activities { Task { await old.end(nil, dismissalPolicy: .immediate) } }
        }
        // Swiped away by the pilot, or ended by the system.
        if let state = activity?.activityState, state == .ended || state == .dismissed { (activity, showing) = (nil, nil) }
        let rule = BackgroundPolicy.runsUntil(position: position, lastFast: lastFast, receiverHeard: heard, now: now)
        lastFast = rule.lastFast
        switch LiveLeg.step(showing: showing, sent: sent, plan: plan, position: position, approximate: approximate,
                            until: rule.until, inFront: inFront, now: now) {
        case .start(let shown)?:
            sent = now
            // With Live Activities off in Settings the app does nothing and says nothing.
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { break }
            activity = try? Activity.request(attributes: RouteActivity(), content: content(shown, until: rule.until))
            showing = activity == nil ? nil : shown
        case .update(let shown)?:
            (sent, showing) = (now, shown)
            if let activity {
                let content = content(shown, until: rule.until)
                Task { await activity.update(content) }
            }
        case .end?:
            end()
        case nil:
            break
        }
        endOnTime(rule.until)
    }

    /// The system marks it stale once the app would have stopped, should the end not get through.
    private func content(_ shown: LiveLeg.Shown, until: Date?) -> ActivityContent<RouteActivity.ContentState> {
        ActivityContent(state: .init(ident: shown.ident, distance: shown.distance, arrival: shown.arrival), staleDate: until)
    }

    // Nothing new may arrive before the app stops running, so the end is set for then; each feed moves it.
    private func endOnTime(_ until: Date?) {
        ending?.cancel()
        guard activity != nil, let until else { return }
        ending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(until.timeIntervalSinceNow, 0)))
            if !Task.isCancelled { self?.end() }
        }
    }

    private func end() {
        if let activity { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
        (activity, showing) = (nil, nil)
    }
}

/// Feeds the route's Live Activity from the route, the fix and the receiver, observed outside any view body.
struct RouteActivityFeed: ViewModifier {
    let nav: NavModel
    let location: LocationProvider
    let traffic: TrafficReceiver
    @State private var controller = RouteActivityController()
    @State private var probe = "activity none"
    @Environment(\.scenePhase) private var scenePhase
    private static let probes = LaunchOptions.current.flag("probes")

    func body(content: Content) -> some View {
        content.task(id: scenePhase) { [nav, location, traffic, controller] in
            let front = scenePhase == .active
            for await (plan, fix, approximate, heard) in Observations({
                (nav.route, location.position, location.isApproximate, traffic.status.lastMessage)
            }) {
                controller.feed(plan: plan, position: fix, approximate: approximate, heard: heard, inFront: front)
                if Self.probes, probe != controller.probe { probe = controller.probe }
            }
        }
        .overlay(alignment: .topTrailing) {
            if Self.probes {
                Text(probe).font(.caption2).foregroundStyle(.clear).allowsHitTesting(false).accessibilityIdentifier("map-activity")
            }
        }
    }
}
