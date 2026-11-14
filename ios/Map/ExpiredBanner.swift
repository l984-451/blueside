import FlightCore
import SwiftUI

/// Says the charts on the map are out of date or not yet in effect. Draws nothing when they are current.
struct ExpiredBanner: View {
    let currency: ChartCurrency?
    var subject = "Charts"

    var body: some View {
        if let text = MapPlan.banner(currency, subject: subject) {
            MapBanner(text: text, identifier: "chart-banner")
        }
    }
}
