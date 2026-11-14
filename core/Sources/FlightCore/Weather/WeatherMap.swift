/// One radar picture on disk.
public struct RadarLoopFrame: Equatable, Sendable {
    public var valid: Date
    public var file: URL

    public init(valid: Date, file: URL) {
        self.valid = valid
        self.file = file
    }
}

/// Everything the phone holds. Plain data: every question about it takes the time.
public struct WeatherData: Equatable, Sendable {
    public var metars: [Metar] = []
    public var tafs: [Taf] = []
    public var sigmets: [Sigmet] = []
    public var gairmets: [GAirmet] = []
    public var cwas: [Cwa] = []
    public var pireps: [Pirep] = []
    public var tfrs: [Tfr] = []
    public var winds: WindsAloft?
    public var lightning: [LightningGroup] = []
    /// The server's check time each held file was downloaded under.
    public var checkedAt: [WeatherSource: Date] = [:]
    /// The last good index.
    public var index: WeatherIndex?
    /// Radar pictures on disk that the last good index names, oldest first.
    public var frames: [RadarLoopFrame] = []
    /// The newest satellite picture on disk that the last good index names.
    public var satellite: RadarLoopFrame?
    /// Why the newest try at a source left the copy on hand in place.
    public var failures: [WeatherSource: String] = [:]

    public init() {}

    /// Decodes a source file and keeps its items. Throws and changes nothing when the bytes are bad.
    public mutating func take(_ source: WeatherSource, json: Data) throws {
        switch source {
        case .metars: metars = try Metar.decode(json)
        case .tafs: tafs = try Taf.decode(json)
        case .sigmets: sigmets = try Sigmet.decode(json)
        case .gairmets: gairmets = try GAirmet.decode(json)
        case .cwas: cwas = try Cwa.decode(json)
        case .pireps: pireps = try Pirep.decode(json)
        case .tfrs: tfrs = try Tfr.decode(json)
        case .winds: winds = try WindsAloft.decode(json)
        case .lightning: lightning = try LightningGroup.decode(json)
        case .radar, .satellite: break
        }
    }

    /// The time a source's data dates from: its check time, or for pictures the newest one on disk.
    public func time(of source: WeatherSource) -> Date? {
        switch source {
        case .radar: frames.last?.valid
        case .satellite: satellite?.valid
        default: checkedAt[source]
        }
    }

    /// The satellite picture to draw, nil unless it is current.
    public func satelliteShown(at now: Date) -> RadarLoopFrame? {
        status(of: .satellite, at: now) == .current ? satellite : nil
    }

    public func status(of source: WeatherSource, at now: Date) -> SourceStatus {
        source.status(checkedAt: time(of: source), at: now)
    }

    /// Seconds since the source's data was last known good. Nil when nothing is held.
    public func age(of source: WeatherSource, at now: Date) -> TimeInterval? {
        time(of: source).map { now.timeIntervalSince($0) }
    }

    /// Pictures to animate, oldest first. Empty exactly when radar is not current, so never without its label.
    public func radarLoop(at now: Date) -> [RadarLoopFrame] {
        guard status(of: .radar, at: now) == .current, let newest = frames.last?.valid else { return [] }
        return frames.filter { newest.timeIntervalSince($0.valid) <= WeatherIndex.loopSpan }
    }

    /// The label an overlay must show, or nil while its source is current.
    public func staleLabel(for overlay: WeatherOverlay, at now: Date) -> String? {
        // With no picture on disk, radar is dated by the newest one the index names.
        let time = time(of: overlay.source)
            ?? (overlay == .radar ? index?.frames.last?.valid : overlay == .satellite ? index?.satellite?.valid : nil)
        return WeatherText.notUpdated(overlay.name, status: status(of: overlay.source, at: now), time: time, now: now)
    }

    /// The time of what is drawn: the radar picture when radar is on, else the newest check or picture among the sources on.
    public func clock(_ on: [WeatherOverlay], at now: Date) -> Date? {
        if on.contains(.radar) { return radarLoop(at: now).last?.valid }
        return on.compactMap { $0 == .satellite ? satelliteShown(at: now)?.valid : checkedAt[$0.source] }.max()
    }
}

/// The weather layers the map can show.
public enum WeatherOverlay: String, CaseIterable, Sendable {
    case stations, sigmets, gairmets, cwas, tfrs, pireps, radar, winds, satellite, lightning

    public var name: String {
        switch self {
        case .stations: "METARs"
        case .sigmets: "SIGMETs"
        case .gairmets: "G-AIRMETs"
        case .cwas: "CWAs"
        case .tfrs: "TFRs"
        case .pireps: "PIREPs"
        case .radar: "Radar"
        case .winds: "Winds Aloft"
        case .satellite: "Satellite"
        case .lightning: "Lightning"
        }
    }

    public var source: WeatherSource {
        switch self {
        case .stations: .metars
        case .sigmets: .sigmets
        case .gairmets: .gairmets
        case .cwas: .cwas
        case .tfrs: .tfrs
        case .pireps: .pireps
        case .radar: .radar
        case .winds: .winds
        case .satellite: .satellite
        case .lightning: .lightning
        }
    }
}

/// The weather switches in the layer picker and the overlays each one shows.
public enum WeatherSwitches {
    public static let groupID = "weather"
    /// TFRs are airspace, so their switch sits in the Aeronautical group.
    public static let tfrsID = "weather-tfrs"
    /// Station dots: the picker shows one row per readout in place of this switch.
    public static let stationsID = "weather-stations"
    public static let toggles: [(id: String, title: String, overlays: [WeatherOverlay])] = [
        ("weather-radar", "Radar", [.radar]),
        ("weather-satellite", "Satellite", [.satellite]),
        (stationsID, "Stations", [.stations]),
        ("weather-airsigmet", "AIR/SIGMET/CWA", [.gairmets, .sigmets, .cwas]),
        (tfrsID, "TFRs", [.tfrs]),
        ("weather-pireps", "PIREPs", [.pireps]),
        ("weather-lightning", "Lightning", [.lightning]),
        (WindsMap.switchID, "Winds Aloft", [.winds]),
    ]

    public static var layerGroup: LayerGroup {
        LayerGroup(id: groupID, title: "Weather", overlays: toggles.filter { $0.id != tfrsID }
            .map { OverlayLayer(id: $0.id, title: $0.title, isImage: false) })
    }

    /// The Aeronautical group with the TFR switch at its end.
    public static func withTfrs(_ group: LayerGroup) -> LayerGroup {
        var group = group
        group.overlays.append(OverlayLayer(id: tfrsID, title: "TFRs", isImage: false))
        return group
    }

    /// Switches kept across launches: weather, TFRs, traffic and every aeronautical one.
    public static let saved = Set(toggles.map(\.id) + AeronauticalLayers.groups.map(\.id) + [TrafficStore.switchID])

    /// The overlays the switches that are on show.
    public static func shown(_ list: OverlayList) -> [WeatherOverlay] {
        toggles.filter { list.overlay($0.id)?.isOn == true }.flatMap(\.overlays)
    }
}

/// What a station dot shows beside its flight category color.
public enum StationShow: String, CaseIterable, Sendable {
    case category, wind, temperature, spread, visibility, ceiling, sky

    public static let key = "weather-station-show"

    public var title: String {
        switch self {
        case .category: "Flight Category"
        case .wind: "Surface Wind"
        case .temperature: "Temperature"
        case .spread: "Dewpoint Spread"
        case .visibility: "Visibility"
        case .ceiling: "Ceiling"
        case .sky: "Sky Coverage"
        }
    }
}

/// How radar bands are filled. A band's `dbz` is its floor; the pipeline cuts bands at these same floors.
public enum RadarStyle {
    /// Areas no radar reaches, below every echo floor. Outside the grid is shaded the same.
    public static let noCoverage = (color: "#808080", opacity: 70.0 / 255)
    public static let echoOpacity = 0.75
    /// NWS reflectivity colors, lowest floor first.
    public static let bands: [(dbz: Double, color: String)] = [
        (5, "#00ecec"), (10, "#01a0f6"), (15, "#0000f6"), (20, "#00ff00"), (25, "#00c800"), (30, "#009000"),
        (35, "#ffff00"), (40, "#e7c000"), (45, "#ff9000"), (50, "#ff0000"), (55, "#d60000"), (60, "#c00000"),
        (65, "#ff00ff"), (70, "#9955c9"),
    ]
}

public enum WeatherText {
    /// Goes beside the radar loop: the pictures shade areas no radar reaches.
    public static let radarLegend = "Gray shading: no radar coverage"

    /// The legends for the overlays on, radar first.
    public static func legends(_ on: [WeatherOverlay]) -> [String] {
        [(WeatherOverlay.radar, radarLegend), (.satellite, SatelliteStyle.legend), (.lightning, LightningStyle.legend)]
            .filter { on.contains($0.0) }.map(\.1)
    }

    /// "0035Z", or "130035Z" with the day of the month in front.
    public static func zulu(_ date: Date, withDay: Bool = false) -> String {
        let t = UTCTime(date)
        let clock = NavText.pad(t.hour, 2) + NavText.pad(t.minute, 2) + "Z"
        return withDay ? NavText.pad(t.day, 2) + clock : clock
    }

    /// "2026-10-13 0035Z", for times that can be weeks away.
    public static func dated(_ date: Date) -> String {
        let t = UTCTime(date)
        return "\(NavText.pad(t.year, 4))-\(NavText.pad(t.month, 2))-\(NavText.pad(t.day, 2)) " + zulu(date)
    }

    /// "12 min" or "1 h 05 min". A time slightly ahead of the clock reads as 0 min.
    public static func age(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(NavText.pad(minutes % 60, 2)) min"
    }

    /// The fixed label for a source that is not current or unknown. Nil while it is current.
    public static func notUpdated(_ name: String, status: SourceStatus, time: Date?, now: Date) -> String? {
        let since: Date?
        switch status {
        case .current: return nil
        case .notCurrent(let date): since = date
        case .unknown: since = time
        }
        guard let since else { return "\(name) not available" }
        // A day or more away, the day of the month goes in front, as in a METAR.
        // The same day number next month is always more than 27 days away, so from 27 the full date is used.
        let days = abs(now.timeIntervalSince(since)) / 86_400
        let when = days >= 27 ? dated(since) : zulu(since, withDay: days >= 1)
        if since > now.addingTimeInterval(WeatherIndex.clockAllowance) {
            return "\(name) dated \(when), ahead of this device's clock"
        }
        return "\(name) not updated since \(when)"
    }

    /// printf's %g for the small numbers a screen shows: six significant digits, no trailing zeros.
    public static func general(_ value: Double) -> String {
        guard value.isFinite, value != 0 else { return value == 0 ? "0" : String(describing: value) }
        var exponent = 0
        var scaled = abs(value)
        while scaled >= 10 { scaled /= 10; exponent += 1 }
        while scaled < 1 { scaled *= 10; exponent -= 1 }
        // ponytail: exponent form falls back to Swift's digits; no weather value is that large or small.
        guard (-4..<6).contains(exponent) else { return String(describing: value) }
        var text = NavText.fixed(value, 5 - exponent)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}
