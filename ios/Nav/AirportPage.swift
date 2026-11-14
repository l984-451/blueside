import FlightCore
import SwiftUI

/// The amber not current line. Its clock wakes at the cycle's edges, so it appears at expiry with no tap or new fix.
struct NavDataWarning: View {
    let metadata: NavMetadata
    let identifier: String

    var body: some View {
        Clock(next: metadata.nextChange) { now in
            if let warning = NavText.dataDates(metadata, now: now).warning {
                StateWord(.warning, warning, systemImage: "exclamationmark.triangle.fill")
                    .accessibilityIdentifier(identifier)
            }
        }
    }
}

/// One airport: its code and name in the bar, then runways, frequencies, remarks and details in one list.
struct AirportPage: View {
    let detail: AirportDetail
    let metadata: NavMetadata
    var favorites: Favorites?
    var onDirect: (() -> Void)? = {}
    var onAddToRoute: () -> Void = {}
    /// "Insert after" a leg's start when the airport sits beside the route.
    var addTitle: (Fix) -> String = { _ in "Add to Route" }
    var onShowOnMap: () -> Void = {}
    /// The panel's close, for the pages pushed from this one.
    var onClose: (() -> Void)?
    @State private var copied = 0
    @Environment(\.isNight) private var night
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(WeatherStore.self) private var weather: WeatherStore?

    private var station: String { detail.airport.icao ?? detail.airport.ident }

    // The core's weather rows, then the newest raw METAR and TAF when the weather store holds them.
    private func weatherSection(_ wx: NavPages.AirportWeather, metar: Metar?) -> some View {
        let taf = weather?.data.tafs.filter { $0.station == station }.max { $0.issued < $1.issued }
        return Section {
            if let category = wx.category {
                LabeledContent(category.title) {
                    HStack {
                        Image(systemName: "circle.fill")
                        Text(category.value ?? "")
                    }
                    .font(.headline).foregroundStyle(Color.category(wx.color))
                }
                ForEach(wx.lines, id: \.title) { line in
                    LabeledContent(line.title, value: line.value ?? "").monospacedDigit()
                }
                ForEach(wx.runways, id: \.end) { runwayWind($0) }
            } else {
                Text(wx.note).foregroundStyle(.secondary)
            }
            ForEach([wx.raw, taf?.raw].compactMap { $0 }, id: \.self) { raw in
                Text(raw).font(.footnote.monospaced()).textSelection(.enabled)
            }
        } header: {
            Text(wx.title)
        } footer: {
            // The age alone moves each minute, in this one line.
            if wx.category != nil, let metar {
                Clock(next: { NextChange.minute(since: metar.observed, after: $0) }) { Text(NavPages.observed(metar, at: $0)) }
            }
        }
        .accessibilityIdentifier("airport-weather")
    }

    private var currentMetar: Metar? {
        weather?.data.metars.filter { $0.station == station }.max { $0.observed < $1.observed }
    }

    private func runwayWind(_ line: NavPages.RunwayWindLine) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(line.end).font(.headline.monospacedDigit())
            if let tag = line.tag {
                Text(tag).font(.caption.weight(.semibold)).foregroundStyle(.tint)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(line.wind).monospacedDigit()
                if let gust = line.gust { Text(gust).font(.footnote).monospacedDigit().foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // The page is rebuilt only when its METAR turns fresh or stale; the age line and warning keep their own clocks.
    var body: some View {
        let metar = currentMetar
        Clock(next: { NavPages.airportWeatherChange(metar: metar, after: $0) }) { now in content(now, metar: metar) }
    }

    private func content(_ now: Date, metar: Metar?) -> some View {
        let airport = detail.airport
        let page = NavPages.airportPage(detail, metadata: metadata, metar: metar, now: now)
        return List {
            Section { header(page) }.listRowBackground(Color.clear)
            if !page.glance.isEmpty { Section { glanceRow(page.glance) } }
            weatherSection(page.weather, metar: metar)
            PlatesSection(airport: airport, detail: detail, onClose: onClose)
            Section {
                if page.runways.lines.isEmpty { nonePublished(page.runways) }
                ForEach(page.runways.lines, id: \.title) { runway in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(runway.title).font(.headline.monospacedDigit())
                            Spacer()
                            if let tag = runway.tag {
                                StateWord(.danger, tag, systemImage: "xmark.octagon.fill")
                                    .accessibilityIdentifier("runway-note-\(runway.title)")
                            }
                        }
                        if let line = runway.detail { Text(line).font(.subheadline).foregroundStyle(.secondary) }
                        if let alert = runway.alert {
                            Text(alert).font(.footnote).foregroundStyle(PanelInk.danger)
                                .accessibilityIdentifier("runway-note-\(runway.title)")
                        }
                    }
                }
            } header: {
                Text(page.runways.title)
            }
            Section {
                if page.frequencies.lines.isEmpty { nonePublished(page.frequencies) }
                ForEach(Array(page.frequencies.lines.enumerated()), id: \.offset) { index, frequency in
                    frequencyRow(frequency, index: index)
                }
            } header: {
                Text(page.frequencies.title)
            }
            if !page.remarks.lines.isEmpty {
                Section {
                    NavigationLink(page.remarks.title) { remarks(page.remarks) }.accessibilityIdentifier("airport-remarks")
                }
            }
            Section {
                ForEach(page.details.lines, id: \.title) { fact($0.title, $0.value ?? "") }
            } header: {
                Text(page.details.title)
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(page.footer.enumerated()), id: \.offset) { index, line in
                        Text(line).accessibilityIdentifier(index == 0 ? "airport-data-dates" : "airport-sua-date")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 0, for: .scrollContent)
        .panelList()
        .navigationSubtitle(page.subtitle)
        .sensoryFeedback(.success, trigger: copied)
        .toolbar {
            if let favorites {
                let on = favorites.contains(airport.ident)
                ToolbarItem(placement: .topBarTrailing) {
                    Button(on ? NavPages.Action.removeFavorite : NavPages.Action.addFavorite,
                           systemImage: on ? "star.fill" : "star") { favorites.toggle(airport.ident) }
                        .accessibilityIdentifier("favorite-button")
                }
            }
        }
    }

    private func header(_ page: NavPages.AirportPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let closed = page.closed {
                StateWord(.danger, closed, systemImage: "xmark.octagon.fill")
                    .accessibilityIdentifier(detail.airport.isOperational ? "airport-runway-closed" : "airport-closed")
            }
            NavDataWarning(metadata: metadata, identifier: "airport-data-warning")
            Text(page.place).font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("airport-place")
            PlaceHeader(coordinate: detail.airport.coordinate, addTitle: addTitle, onDirect: onDirect, onAdd: onAddToRoute, onShowOnMap: onShowOnMap)
        }
    }

    // The at-a-glance items side by side, as a place card shows hours and distance; a frequency copies on tap.
    private func glanceRow(_ items: [NavPages.Line]) -> some View {
        HStack(alignment: .top) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                Button {
                    if let text = item.copy { UIPasteboard.general.string = text; copied += 1 }
                } label: {
                    VStack {
                        Text(item.title).font(.caption).foregroundStyle(.secondary)
                        Text(item.value ?? "").font(.headline.monospacedDigit()).foregroundStyle(Color.primary)
                    }
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.75)
                    // A phone's half-height sheet draws its page about 4 percent small, so 46 there shows as 44.
                    .frame(maxWidth: .infinity, minHeight: sizeClass == .compact ? 46 : 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("glance-\(index)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // Tapping a row copies the frequency.
    private func frequencyRow(_ frequency: NavPages.Line, index: Int) -> some View {
        Button {
            UIPasteboard.general.string = frequency.copy
            copied += 1
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(frequency.title).foregroundStyle(Color.primary)
                    Spacer()
                    Text(frequency.value ?? "").monospacedDigit().foregroundStyle(Color.primary)
                }
                if let alert = frequency.alert {
                    StateWord(.danger, alert, systemImage: "xmark.octagon.fill")
                        .accessibilityIdentifier("frequency-note-\(index)")
                }
                if let remark = frequency.detail { Text(remark).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .accessibilityHint(NavPages.Action.copyHint)
        .accessibilityIdentifier("frequency-\(index)")
    }

    private func remarks(_ section: NavPages.Section) -> some View {
        List {
            // The FAA repeats some remarks word for word, so the position is the identity.
            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, remark in
                Text(remark.title).font(.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .panelList()
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(.clear, for: .navigation)
    }

    private func nonePublished(_ section: NavPages.Section) -> some View {
        Text(section.empty ?? "").foregroundStyle(.secondary)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
