import FlightCore
import SwiftUI

/// Groundspeed, track and GPS altitude. Dashes when there is no fix or it is stale.
/// Says so in words when location access is off or the fix is only approximate.
struct DataStrip: View {
    /// Off when the strip sits inside a larger glass shape, such as with the Direct To drawer.
    var glassed = true

    var body: some View {
        FixReader { fix in
            Fields(readout: NavText.readout(for: fix.position, accessOff: fix.accessOff, approximate: fix.approximate,
                                         now: fix.now), glassed: glassed)
                // Skips the fitting pass below when a fix leaves the words unchanged.
                .equatable()
        }
    }

    struct Fields: View, Equatable {
        let readout: NavText.Readout
        var glassed = true

        nonisolated static func == (a: Self, b: Self) -> Bool { a.readout == b.readout && a.glassed == b.glassed }
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isNight) private var night

        var body: some View {
            VStack {
                // Two rows when one does not fit the width at a large text size.
                ViewThatFits {
                    HStack(spacing: chromeInset / 2) { fields }
                    VStack { fields }
                }
                if let message = readout.message {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PanelInk.warning)
                        .accessibilityIdentifier("strip-message")
                }
            }
            .modifier(NightDim())
            .padding(.horizontal)
            .padding(.vertical, chromeInset)
            .stripGlass(glassed ? Glass.card(dark: scheme == .dark, night: night) : nil)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("data-strip")
        }

        @ViewBuilder private var fields: some View {
            field("GS", "Groundspeed", readout.groundspeed, unit: " kt", spoken: "knots", identifier: "strip-groundspeed")
            field("TRK", "Track", readout.track, unit: "", spoken: "", identifier: "strip-track")
            field("ALT", "Altitude", readout.altitude, unit: " ft", spoken: "feet", identifier: "strip-altitude")
        }

        // Every column is sized by one template, so the values never move the layout; longer ones shrink to fit.
        private func field(_ title: String, _ name: String, _ value: String, unit: String, spoken: String,
                           identifier: String) -> some View {
            VStack(spacing: 0) {
                Text(title).font(.footnote.weight(.semibold)).accessibilityHidden(true)
                Text(verbatim: "000 kt").instrument().hidden()
                    .overlay {
                        Text(value == "---" ? value : value + unit)
                            .instrument()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .accessibilityIdentifier(identifier)
                            .accessibilityLabel(value == "---" ? "\(name) unknown"
                                                                : [name, value, spoken].filter { !$0.isEmpty }.joined(separator: " "))
                    }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

extension View {
    /// The strip's glass shape, shared with the Direct To drawer when it hangs below.
    @ViewBuilder func stripGlass(_ glass: Glass?) -> some View {
        if let glass {
            glassEffect(glass, in: ConcentricRectangle(corners: .concentric(minimum: 16), isUniform: true))
        } else {
            self
        }
    }
}
