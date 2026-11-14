import Charts
import FlightCore
import SwiftUI

/// Weight and balance for one aircraft: the load, the core's verdict, its four points and the envelope.
struct WeightBalancePage: View {
    @Bindable var store: AircraftStore
    let profile: AircraftProfile
    /// The route's trip fuel, which with taxi fuel is the default fuel burned.
    var tripFuelGal: Double?
    @Environment(LocationProvider.self) private var location: LocationProvider?
    @Environment(\.fixedNow) private var fixedNow
    /// Airborne by the core's rule on the fix when the page opened, so no fuel burned is assumed.
    @State private var airborne = false

    private var load: Binding<AircraftStore.Load> {
        Binding(get: { store.loads[profile.id] ?? .init() }, set: { store.loads[profile.id] = $0 })
    }

    private var balance: WeightBalance? {
        Self.balance(profile, load.wrappedValue, tripFuelGal: tripFuelGal, airborne: airborne)
    }

    /// The core's verdict for a typed load; the brief uses it too.
    static func balance(_ profile: AircraftProfile, _ l: AircraftStore.Load, tripFuelGal: Double?,
                        airborne: Bool) -> WeightBalance? {
        let weights = profile.stations.indices.map { l.weights[safe: $0].flatMap { $0 } ?? 0 }
        return WeightBalance(profile: profile, stationWeightsLb: weights, startFuelGal: l.startFuel,
                             burnedGal: l.burned ?? AircraftPages.burnedDefault(profile, tripFuelGal: tripFuelGal,
                                                                                startFuelGal: l.startFuel, airborne: airborne))
    }

    var body: some View {
        Form {
            if let needs = AircraftPages.needs(WeightBalance.missing(profile)) {
                Section { Text(needs).foregroundStyle(.secondary) }
            } else if let wb = balance {
                verdict(wb)
                Section { EnvelopeChart(balance: wb) }
            }
            loadSection
            if let wb = balance {
                Section(AircraftPages.resultsTitle) {
                    ForEach(wb.rows, id: \.title) { row in
                        LabeledContent {
                            Text(row.value ?? NavText.dashes)
                        } label: {
                            Text(row.title)
                            if let detail = row.detail { Text(detail) }
                        }
                        .accessibilityIdentifier("wb-row-\(row.title.lowercased())")
                    }
                }
                .monospacedDigit()
            }
        }
        .navigationTitle(AircraftPages.weightBalance)
        .navigationBarTitleDisplayMode(.inline)
        // Read once here, so the page does not follow the fix.
        .onAppear {
            airborne = RoutePages.airborne(location?.position, approximate: location?.isApproximate ?? false,
                                           now: fixedNow ?? Date())
        }
    }

    // No verdict when the core gives none, as with no landing point.
    @ViewBuilder private func verdict(_ wb: WeightBalance) -> some View {
        if wb.status != nil || !wb.notes.isEmpty {
            Section {
                // Good is a green glyph by a primary word, as green text fails contrast; out of limits is the danger ink.
                if let status = wb.status {
                    Label {
                        Text(status).foregroundStyle(wb.ok ? Color.primary : PanelInk.danger)
                    } icon: {
                        Image(systemName: wb.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(wb.ok ? Color.green : PanelInk.danger)
                    }
                    .font(.headline)
                    .accessibilityIdentifier("wb-status")
                }
                ForEach(wb.problems, id: \.self) { Text($0).foregroundStyle(PanelInk.danger) }
                ForEach(wb.notes, id: \.self) { StateWord(.warning, $0, systemImage: "exclamationmark.triangle.fill") }
            }
        }
    }

    private var loadSection: some View {
        Section {
            ForEach(Array(profile.stations.enumerated()), id: \.offset) { i, station in
                NumberRow((station.name, AircraftPages.lb), weight(i), "wb-station-\(i)")
            }
            NumberRow((AircraftPages.startFuel, AircraftPages.gal), Binding(get: { load.wrappedValue.startFuel ?? profile.usableFuelGal },
                                                       set: { load.wrappedValue.startFuel = $0 }), "wb-fuel-start")
            NumberRow((AircraftPages.burnedFuel, AircraftPages.gal),
                      Binding(get: { load.wrappedValue.burned ?? AircraftPages.burnedDefault(profile, tripFuelGal: tripFuelGal,
                                                                                             startFuelGal: load.wrappedValue.startFuel,
                                                                                             airborne: airborne) },
                              set: { load.wrappedValue.burned = $0 }), "wb-fuel-burned")
        } header: {
            Text(AircraftPages.loadTitle)
        } footer: {
            if let note = AircraftPages.burnedFooter(airborne: airborne) { Text(note) }
        }
    }

    private func weight(_ i: Int) -> Binding<Double?> {
        Binding(get: { load.wrappedValue.weights[safe: i].flatMap { $0 } }, set: { value in
            var weights = load.wrappedValue.weights
            if weights.count <= i { weights += Array(repeating: nil, count: i + 1 - weights.count) }
            weights[i] = value
            load.wrappedValue.weights = weights
        })
    }
}

/// The CG envelope with the burn line from takeoff to landing; T filled, L hollow, red when out of limits. No L
/// without a fuel burned.
struct EnvelopeChart: View {
    let balance: WeightBalance

    private struct Mark: Identifiable {
        let id: Int
        let series: String
        let point: AircraftProfile.EnvelopePoint
    }

    var body: some View {
        let ring = balance.envelope + balance.envelope.prefix(1)
        let edge = ring.enumerated().map { Mark(id: $0.offset, series: "envelope", point: $0.element) }
        let burn = balance.burnLine.enumerated().map { Mark(id: edge.count + $0.offset, series: "burn", point: $0.element) }
        let takeoff = AircraftProfile.EnvelopePoint(armIn: balance.takeoff.cgIn, weightLb: balance.takeoff.weightLb)
        let landing = balance.landing.map { AircraftProfile.EnvelopePoint(armIn: $0.cgIn, weightLb: $0.weightLb) }
        let all = balance.envelope + [takeoff] + (landing.map { [$0] } ?? [])
        Chart {
            ForEach(edge) { mark in
                LineMark(x: .value(AircraftPages.chartArm, mark.point.armIn),
                         y: .value(AircraftPages.chartWeight, mark.point.weightLb),
                         series: .value("Series", mark.series))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            ForEach(burn) { mark in
                LineMark(x: .value(AircraftPages.chartArm, mark.point.armIn),
                         y: .value(AircraftPages.chartWeight, mark.point.weightLb),
                         series: .value("Series", mark.series))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            dot(takeoff, WeightBalance.takeoffLabel, filled: true, ok: balance.takeoffInLimits)
            if let landing { dot(landing, WeightBalance.landingLabel, filled: false, ok: balance.landingInLimits) }
        }
        .chartXScale(domain: Self.domain(all.map(\.armIn), pad: 1))
        .chartYScale(domain: Self.domain(all.map(\.weightLb), pad: 50))
        .chartXAxisLabel(AircraftPages.chartArm, alignment: .center)
        .chartYAxisLabel(AircraftPages.chartWeight)
        .frame(height: 260) // design-lint: allow chart room
        .padding(.vertical, 8) // design-lint: allow chart breathing room
        .accessibilityIdentifier("wb-chart")
    }

    @ChartContentBuilder
    private func dot(_ point: AircraftProfile.EnvelopePoint, _ label: String, filled: Bool, ok: Bool) -> some ChartContent {
        let ink = ok ? Color.primary : PanelInk.danger
        PointMark(x: .value(AircraftPages.chartArm, point.armIn), y: .value(AircraftPages.chartWeight, point.weightLb))
            .symbol(filled ? AnyChartSymbolShape(.circle) : AnyChartSymbolShape(.circle.strokeBorder(lineWidth: 2)))
            .symbolSize(90)
            .foregroundStyle(ink)
            .annotation(position: .trailing) { Text(label).font(.caption.weight(.bold)).foregroundStyle(ink) }
    }

    private static func domain(_ values: [Double], pad: Double) -> ClosedRange<Double> {
        let low = (values.min() ?? 0) - pad
        let high = (values.max() ?? 1) + pad
        return low...max(high, low + 1)
    }
}
