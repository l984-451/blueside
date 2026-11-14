import ActivityKit
import Foundation

/// A route in flight on the Lock Screen and in the Dynamic Island. Shared by the app and the widget extension.
struct RouteActivity: ActivityAttributes {
    /// The next waypoint, the distance to it, and when the aircraft gets there, which the time counts down to.
    struct ContentState: Codable, Hashable {
        var ident: String
        var distance: String
        var arrival: Date?
    }
}
