/// Weather a receiver uplinks over GDL 90, kept per station and block and merged with the downloaded weather.
public struct FISBWeather: Sendable {
    /// The position of a station by its identifier, from the navigation data. A METAR needs one to be drawn.
    public typealias Locate = @Sendable (String) -> Coordinate?

    public private(set) var metars: [String: Metar] = [:]
    public private(set) var tafs: [String: Taf] = [:]
    private var blocks: [Int: RadarBlock] = [:]
    /// When the newest METAR or TAF record arrived.
    public private(set) var metarsAt: Date?
    public private(set) var tafsAt: Date?
    private let locate: Locate

    public init(locate: @escaping Locate) {
        self.locate = locate
    }

    /// Takes every message in one datagram, the same datagram the traffic store reads.
    public mutating func receive(datagram: some Sequence<UInt8>, at now: Date) {
        for message in GDL90.messages(in: datagram) {
            if let decoded = GDL90.decode(message) { receive(decoded, at: now) }
        }
    }

    public mutating func receive(_ message: GDL90.Message, at now: Date) {
        if case .uplink(let uplink) = message { receive(uplink, at: now) }
    }

    public mutating func receive(_ uplink: FISB.Uplink, at now: Date) {
        for apdu in uplink.apdus {
            switch apdu.productID {
            case FISB.textProduct:
                for text in FISB.records(apdu.payload) { take(text, at: now) }
            case FISB.regionalRadar, FISB.conusRadar:
                for block in FISB.radarBlocks(apdu, near: now) where Self.isCurrent(block, at: now) {
                    if blocks[block.key].map({ $0.time <= block.time }) ?? true { blocks[block.key] = block }
                }
            default: break
            }
        }
        prune(now: now)
    }

    private mutating func take(_ text: String, at now: Date) {
        guard let record = FISB.record(text) else { return }
        switch record.kind {
        case .metar:
            guard let at = locate(record.station), let metar = Metar.parse(record.raw, coordinate: at, near: now),
                  WeatherGeoJSON.isFresh(metar.age(at: now)) else { return }
            metarsAt = now
            if metars[metar.station].map({ $0.observed <= metar.observed }) ?? true { metars[metar.station] = metar }
        case .taf:
            guard let taf = Taf.parse(record.raw, near: now), now < taf.validTo else { return }
            tafsAt = now
            if tafs[taf.station].map({ $0.issued <= taf.issued }) ?? true { tafs[taf.station] = taf }
        }
    }

    private static func isCurrent(_ block: RadarBlock, at now: Date) -> Bool {
        let age = block.age(at: now)
        return age <= WeatherSource.radar.currentFor && age >= -WeatherIndex.clockAllowance
    }

    /// Drops what the downloaded weather would no longer show: METARs past their life, TAFs past their period,
    /// radar blocks older than a radar picture counts as current.
    public mutating func prune(now: Date) {
        metars = metars.filter { WeatherGeoJSON.isFresh($0.value.age(at: now)) }
        tafs = tafs.filter { now < $0.value.validTo }
        blocks = blocks.filter { Self.isCurrent($0.value, at: now) }
    }

    /// The radar blocks to draw, the coarsest first so finer ones lie on top.
    public func radarBlocks(at now: Date) -> [RadarBlock] {
        blocks.values.filter { Self.isCurrent($0, at: now) }
            .sorted { ($0.scale, $0.blockNumber, $0.productID) > ($1.scale, $1.blockNumber, $1.productID) }
    }

    /// The downloaded weather with these reports in it: a station with no report there gets this one, and one
    /// with an older report has it replaced. A tie keeps the download. When any arrived, the source counts as
    /// checked at the time of the newest.
    public func merged(into weather: WeatherData, at now: Date) -> WeatherData {
        var out = weather
        for metar in metars.values where WeatherGeoJSON.isFresh(metar.age(at: now)) {
            let held = weather.metars.filter { $0.station == metar.station }.map(\.observed).max()
            guard held.map({ metar.observed > $0 }) ?? true else { continue }
            out.metars.removeAll { $0.station == metar.station }
            out.metars.append(metar)
        }
        for taf in tafs.values where now < taf.validTo {
            let held = weather.tafs.filter { $0.station == taf.station }.map(\.issued).max()
            guard held.map({ taf.issued > $0 }) ?? true else { continue }
            out.tafs.removeAll { $0.station == taf.station }
            out.tafs.append(taf)
        }
        if let metarsAt, !metars.isEmpty { out.checkedAt[.metars] = max(metarsAt, weather.checkedAt[.metars] ?? metarsAt) }
        if let tafsAt, !tafs.isEmpty { out.checkedAt[.tafs] = max(tafsAt, weather.checkedAt[.tafs] ?? tafsAt) }
        return out
    }

    /// The next time what is held changes with no new message.
    public func nextChange(after now: Date) -> Date? {
        NextChange.earliest(after: now,
            metars.values.map { $0.observed.addingTimeInterval(WeatherGeoJSON.reportLife + NextChange.past) }
            + tafs.values.map { $0.validTo.addingTimeInterval(NextChange.past) }
            + blocks.values.map { $0.time.addingTimeInterval(WeatherSource.radar.currentFor + NextChange.past) })
    }
}
