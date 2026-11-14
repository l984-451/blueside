/// When words that depend on the clock can next differ, so a screen wakes then rather than on a tick.
public enum NextChange {
    /// Just past a boundary that still counts on its own side, such as an age of exactly the limit.
    public static let past: TimeInterval = 0.001

    /// The earliest of the dates after now. Nil when none is.
    public static func earliest(after now: Date, _ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.filter { $0 > now }.min()
    }

    /// When an age counted in whole minutes from a time next ticks over.
    public static func minute(since time: Date, after now: Date) -> Date {
        let minutes = (now.timeIntervalSince(time) / 60).rounded(.down)
        return time.addingTimeInterval((minutes + 1) * 60 + past)
    }
}

extension NavMetadata {
    /// The next time `currency(at:)` can differ: the cycle starting or ending.
    public func nextChange(after now: Date) -> Date? { NextChange.earliest(after: now, [effective, expires]) }
}

extension Position {
    /// The instant `isStale(at:)` turns true for a fix that is live now.
    public var staleAt: Date { timestamp.addingTimeInterval(Self.staleAfter + NextChange.past) }
}

extension MapPlan {
    /// The next time `currency(layers:installed:now:)` can differ.
    public static func nextChange(layers: [String], installed: [InstalledPack], after now: Date) -> Date? {
        NextChange.earliest(after: now, installed.filter { layers.contains($0.id.layer) }.flatMap { [$0.effective, $0.expires] })
    }
}

extension WeatherData {
    /// The next time the stale labels, the clock or the winds label for these overlays can differ with no new data.
    public func nextChange(_ on: [WeatherOverlay], after now: Date) -> Date? {
        var dates: [Date] = on.contains(.winds) ? (winds?.forecasts.flatMap { [$0.from, $0.to] } ?? []) : []
        for overlay in on {
            let source = overlay.source
            let fallback = overlay == .radar ? index?.frames.last?.valid : overlay == .satellite ? index?.satellite?.valid : nil
            for time in [time(of: source), fallback].compactMap({ $0 }) {
                // Known from the clock allowance, stale past its life, and the label's day form at 1 and 27 days.
                dates += [time.addingTimeInterval(-WeatherIndex.clockAllowance),
                          time.addingTimeInterval(source.currentFor + NextChange.past)]
                dates += [1.0, 27].flatMap { [time.addingTimeInterval($0 * 86_400), time.addingTimeInterval(-$0 * 86_400)] }
            }
        }
        return NextChange.earliest(after: now, dates)
    }
}

extension NavPages {
    /// The next time an airport page's weather can change with no new report: its METAR turning fresh or stale.
    public static func airportWeatherChange(metar: Metar?, after now: Date) -> Date? {
        guard let metar else { return nil }
        return NextChange.earliest(after: now, [metar.time.addingTimeInterval(-WeatherIndex.clockAllowance),
                                                metar.time.addingTimeInterval(WeatherGeoJSON.reportLife + NextChange.past)])
    }
}

extension RoutePages {
    /// The next time `planInputs` gives another departure: just after the one it gives now.
    public static func planInputsChange(stored: Data?, after now: Date) -> Date {
        planInputs(stored: stored, now: now).departure.addingTimeInterval(NextChange.past)
    }

    /// The next time the plan page can differ with no new data: the departure rolling on, or a winds use window ending.
    public static func planChange(stored: Data?, winds: WindsAloft?, after now: Date) -> Date {
        let inputs = planInputsChange(stored: stored, after: now)
        return NextChange.earliest(after: now, [inputs] + (winds?.forecasts.map(\.to) ?? [])) ?? inputs
    }
}
