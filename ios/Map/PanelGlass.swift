import FlightCore
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// Night mode, which dims chrome and weighs the card's glass more than the dark appearance does.
    @Entry var isNight = false
    /// A fixed time set by tests. Nil means the real clock.
    @Entry var fixedNow: Date? = nil
    /// Fits a georeferenced drawing on the map, such as an airport sketch.
    @Entry var showArea: (PlateGeo) -> Void = { _ in }
}

/// Redraws its content only when the time-based words can change: at the core's next deadline, never on a tick.
/// With the test's fixed time it draws once.
struct Clock<Content: View>: View {
    let next: (Date) -> Date?
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.fixedNow) private var fixedNow
    @State private var wakes = 0

    var body: some View {
        let now = fixedNow ?? Date()
        let deadline = fixedNow == nil ? next(now) : nil
        content(now)
            .task(id: Wake(deadline: deadline, count: wakes)) {
                guard let deadline else { return }
                try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
                if !Task.isCancelled { wakes &+= 1 }
            }
    }

    private struct Wake: Equatable { var deadline: Date?; var count: Int }
}

/// The live fix as a leaf reads it. `now` is the test's fixed time or the moment of drawing.
struct Fix {
    var position: Position?
    var approximate: Bool
    var accessOff: Bool
    var now: Date
}

/// Reads the live fix in its own body, so a new fix, or a fix going stale, redraws only this leaf.
/// Never wrap a list or page in it.
struct FixReader<Content: View>: View {
    @ViewBuilder let content: (Fix) -> Content
    @Environment(LocationProvider.self) private var location: LocationProvider?
    @Environment(\.fixedNow) private var fixedNow

    var body: some View {
        // Read so that the stale flip redraws with no new fix.
        let _ = location?.isStale
        content(Fix(position: location?.position, approximate: location?.isApproximate ?? false,
                    accessOff: location?.accessOff ?? false, now: fixedNow ?? Date()))
    }
}

/// The one inset of every piece of chrome from the safe area, so their edges line up.
let chromeInset: CGFloat = 12

/// The panel card's glass: tinted with the system background, heavier in the dark and at night.
struct PanelGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isNight) private var night

    static let shape = ConcentricRectangle(corners: .concentric(minimum: 20), isUniform: true)

    static func tint(dark: Bool, night: Bool) -> Double { night ? 0.70 : dark ? 0.55 : 0.50 }

    func body(content: Content) -> some View {
        content
            .containerShape(.rect(cornerRadius: 20))
            .glassEffect(.card(dark: scheme == .dark, night: night), in: Self.shape)
    }
}

extension Glass {
    /// Glass tinted with the system background, so text on it stays readable whatever the map shows.
    static func card(dark: Bool, night: Bool) -> Glass {
        .regular.tint(Color(.systemBackground).opacity(PanelGlass.tint(dark: dark, night: night)))
    }
}

/// Night dims every ink on the chrome by one rule.
struct NightDim: ViewModifier {
    @Environment(\.isNight) private var night
    func body(content: Content) -> some View { content.opacity(night ? 0.85 : 1) }
}

extension Text {
    /// A row's second line.
    func detail() -> some View { font(.subheadline).foregroundStyle(.secondary) }
    /// Small print under or between rows.
    func note() -> some View { font(.footnote).foregroundStyle(.secondary) }
}

/// Text inks for states, where the system's orange and red fail on white.
enum PanelInk {
    static let warningColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0x85 / 255, green: 0x40 / 255, blue: 0, alpha: 1)
    }
    static let warning = Color(warningColor)
    static let dangerColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0x80 / 255, blue: 0x78 / 255, alpha: 1)
                                           : UIColor(red: 0xa8 / 255, green: 0x08 / 255, blue: 0x08 / 255, alpha: 1)
    }
    static let danger = Color(dangerColor)

    /// The contrast ratio between two colors, from 1 to 21.
    static func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: nil)
            func linear(_ value: CGFloat) -> Double {
                value <= 0.04045 ? Double(value) / 12.92 : pow((Double(value) + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        let pair = [luminance(a), luminance(b)].sorted()
        return (pair[1] + 0.05) / (pair[0] + 0.05)
    }
}

/// Inks the app draws on the map. MapLibre takes fixed colors, so night is a flag, not a trait.
enum MapInk {
    static func route(night: Bool) -> UIColor {
        night ? UIColor(red: 0xf0 / 255, green: 0x60 / 255, blue: 0xd6 / 255, alpha: 1)
              : UIColor(red: 0xd1 / 255, green: 0x1f / 255, blue: 0xb6 / 255, alpha: 1)
    }
    static func routeCasing(night: Bool) -> UIColor {
        night ? UIColor(red: 0x1e / 255, green: 0x1d / 255, blue: 0x1b / 255, alpha: 1) : .white
    }
    /// The Direct To button's ground, under a white label.
    static func routeFill(night: Bool) -> UIColor {
        night ? UIColor(red: 0x8a / 255, green: 0x14 / 255, blue: 0x78 / 255, alpha: 1) : route(night: false)
    }
    /// The ring at the place the panel shows: the app's accent, dimmer at night.
    static func place(night: Bool) -> UIColor {
        UIColor.tintColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: night ? .dark : .light))
            .withAlphaComponent(night ? 0.75 : 1)
    }
    static let ownshipLive = UIColor.systemBlue
    static let ownshipStale = UIColor.systemGray
}

/// A state in words with its symbol, in the state's ink.
struct StateWord: View {
    enum Kind { case warning, danger }
    let kind: Kind
    let text: String
    let systemImage: String
    init(_ kind: Kind, _ text: String, systemImage: String) {
        self.kind = kind
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(kind == .warning ? PanelInk.warning : PanelInk.danger)
    }
}

/// Numbers read in flight: larger on a wide screen, capped so they never push the strip off screen.
struct InstrumentText: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    func body(content: Content) -> some View {
        content.font((sizeClass == .regular ? Font.title : .title3).weight(.semibold).monospacedDigit())
    }
}

/// A round glass button on the map, 56 points so it can be hit in turbulence.
struct MapButton: View {
    static let size: CGFloat = 56
    let symbol: String
    let label: String
    let identifier: String
    var value = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .modifier(NightDim())
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }
}

/// Amber news about the charts or data on the map, on orange-tinted glass.
struct MapBanner: View {
    let text: String
    let identifier: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text(text).accessibilityIdentifier(identifier)
        }
        .font(.headline)
        .modifier(NightDim())
        .padding(.horizontal)
        .padding(.vertical, chromeInset)
        .glassEffect(.regular.tint(.orange.opacity(0.35)), in: Capsule())
    }
}

/// A plain notice in the middle of the map, such as no chart here.
struct MapNotice: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isNight) private var night

    var body: some View {
        Text(text)
            .font(.headline)
            .modifier(NightDim())
            .padding()
            .glassEffect(.card(dark: scheme == .dark, night: night), in: Capsule())
    }
}

/// Test probe: names the appearance a panel is drawn in. Shown only under the probes launch option.
struct AppearanceProbe: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text("Appearance").font(.caption2).foregroundStyle(.clear)
            .accessibilityValue(scheme == .dark ? "dark" : "light")
            .accessibilityIdentifier("appearance-probe")
    }
}

extension View {
    /// A panel page's inline title and the close button that puts the panel away.
    func panelPage(_ title: String, onClose: @escaping () -> Void) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // The card's glass shows through; a sheet keeps its own background.
            .containerBackground(.clear, for: .navigation)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .close, action: onClose).accessibilityIdentifier("panel-close")
                }
            }
    }
    func panelGlass() -> some View { modifier(PanelGlass()) }
    func instrument() -> some View { modifier(InstrumentText()).dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
    /// The list paints no background of its own, so the glass shows through.
    func panelList() -> some View { scrollContentBackground(.hidden) }
}
