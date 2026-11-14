/// Download decisions and words, so a platform only moves bytes, keeps files and reports what happened.
public enum DownloadPolicy {
    /// Kept free beyond the pack itself, so a download never fills the disk to the last byte.
    public static let spaceMargin: Int64 = 100_000_000
    /// How long a pack that failed its checksum or was refused is left alone by a refresh.
    public static let failureHold: TimeInterval = 6 * 3600
    /// The reason reported when both attempts at a pack fail the checksum.
    public static let checksumFailure = "Checksum failed twice"
    /// The reason reported when a verified file is one this version of the app cannot open.
    public static let unreadableFailure = "File could not be read by this version"

    public static let navDatabaseLayer = "nav-db"
    public static let navTilesLayer = "nav-tiles"
    public static let navRegion = "US"

    public static func serverFailure(status: Int) -> String { "Server answered \(status)" }

    /// A transfer that ended without a file: the server's status, or the system's error code.
    public static func transferFailure(code: Int) -> String {
        (100..<600).contains(code) ? serverFailure(status: code) : "Download error \(code)"
    }

    /// What to say above the chart list when it is not fresh. Nil when it is.
    public static func listNotice(_ failure: ListFailure?, hasList: Bool) -> String? {
        let known = " Showing the last known list."
        switch failure {
        case nil: return nil
        case .noConnection:
            return hasList ? "No connection." + known : "No chart list yet. Connect to the internet once to fetch it."
        case .unreadable:
            return "Update the app. This version cannot read the chart list." + (hasList ? known : "")
        case .server:
            return "Chart server error." + (hasList ? known : " Try again later.")
        }
    }

    /// True when a file that failed its checksum on this attempt is fetched once more.
    public static func retriesChecksum(attempt: Int) -> Bool { attempt < 2 }

    /// A failure that a refresh leaves alone for the hold, because fetching again would likely fail the same way.
    public static func holds(_ reason: String) -> Bool { reason == checksumFailure || reason == unreadableFailure }

    /// The failures a refresh clears so they are tried again: those with no Retry button (the overview, or one
    /// hidden behind an installed pack), unless held since a checksum failure or refusal.
    public static func failuresToRetry(transfers: [PackID: Transfer], installed: [InstalledPack],
                                       heldSince: [PackID: Date], now: Date) -> [PackID] {
        let have = Set(installed.map { [$0.id.layer, $0.id.region] })
        return transfers.compactMap { id, transfer in
            guard case .failed = transfer,
                  id.region == ChartLibrary.overviewRegion || have.contains([id.layer, id.region]) else { return nil }
            let rested = heldSince[id].map { now.timeIntervalSince($0) >= failureHold } ?? true
            return rested ? id : nil
        }
    }

    /// Bytes short for a download once the margin is kept. Nil when it fits.
    public static func shortfall(needed: Int64, freeBytes: Int64) -> (needed: Int64, free: Int64)? {
        let free = freeBytes - spaceMargin
        return needed > free ? (needed, max(free, 0)) : nil
    }

    public enum Step: Equatable, Sendable {
        case start(PackRequest)
        case fail(PackID, String)
    }

    /// Holds back a next-cycle pack until the current cycle of that layer and region is installed,
    /// so a first install never shows data not yet in effect.
    /// A refetch of a pack already in effect on disk holds nothing back.
    public static func currentFirst(_ requests: [PackRequest], installed: [InstalledPack], now: Date) -> [PackRequest] {
        let inEffect = Set(installed.filter { $0.effective <= now && now < $0.expires }.map { [$0.id.layer, $0.id.region] })
        let current = Set(requests.filter { $0.effective <= now }.map { [$0.id.layer, $0.id.region] }).subtracting(inEffect)
        return requests.filter { $0.effective <= now || !current.contains([$0.id.layer, $0.id.region]) }
    }

    /// One pass over the packs wanted: start each one not already under way that fits on disk, beside the
    /// committed bytes of transfers running now, and fail the rest with the reason.
    public static func pass(wanted: [PackRequest], transfers: [PackID: Transfer], committed: Int,
                            freeBytes: Int64) -> [Step] {
        var committed = committed
        var steps: [Step] = []
        for request in wanted where transfers[request.id] == nil {
            let total = total([committed, request.bytes])
            if let short = shortfall(needed: Int64(total), freeBytes: freeBytes) {
                steps.append(.fail(request.id, "Not enough storage for \(request.id.region) \(request.id.layer): needs "
                                   + "\(byteCount(short.needed)), \(byteCount(short.free)) free"))
                continue
            }
            committed = total
            steps.append(.start(request))
        }
        return steps
    }

    /// Adds pack sizes and stops at the largest number, because sizes come from the network.
    public static func total(_ sizes: [Int]) -> Int {
        sizes.reduce(0) { sum, size in
            let (value, overflow) = sum.addingReportingOverflow(size)
            return overflow ? .max : value
        }
    }

    /// Regions with a live transfer that nobody wants any more. The overview is always wanted.
    public static func unwanted(_ active: [PackID], chosen: Set<String>) -> Set<String> {
        Set(active.map(\.region)).subtracting(chosen).subtracting([ChartLibrary.overviewRegion])
    }

    /// The list with only the packs of the wanted layers.
    public static func keeping(_ manifest: Manifest?, _ layers: (String) -> Bool) -> Manifest? {
        guard var manifest else { return nil }
        for index in manifest.cycles.indices { manifest.cycles[index].packs.removeAll { !layers($0.layer) } }
        return manifest
    }

    /// One layer's state for a row. A failed download outranks a stand-in pack, so the row offers Retry.
    public static func state(layer: String, region: String, installed: [InstalledPack],
                             transfers: [PackID: Transfer], now: Date) -> PackState {
        let state = ChartLibrary.state(layer: layer, region: region, installed: installed, transfers: transfers, now: now)
        guard state == .expired else { return state }
        let mine = transfers.filter { $0.key.layer == layer && $0.key.region == region }.sorted { $0.key.cycle < $1.key.cycle }
        for (_, transfer) in mine { if case .failed(let reason) = transfer { return .failed(reason) } }
        return state
    }

    /// One state for a region's packs: a failure first, then progress, then whatever is least complete.
    /// Progress is the share of bytes when every size is known, otherwise each pack counts the same.
    public static func combined(_ states: [PackState], sizes: [Int] = []) -> PackState {
        for state in states { if case .failed = state { return state } }
        if states.contains(where: { if case .downloading = $0 { true } else { false } }) {
            let weights = sizes.count == states.count && sizes.allSatisfy({ $0 > 0 })
                ? sizes.map(Double.init) : states.map { _ in 1.0 }
            let got = zip(states, weights).reduce(0.0) { sum, pair in
                switch pair.0 {
                case .ready: sum + pair.1
                case .downloading(let value): sum + value * pair.1
                default: sum
                }
            }
            return .downloading(got / weights.reduce(0, +))
        }
        if states.isEmpty || states.contains(.notDownloaded) { return .notDownloaded }
        return states.contains(.expired) ? .expired : .ready
    }

    /// The packs to delete at a changeover. Overlay tiles go with their database, not on their own dates:
    /// only once a current database of a later cycle is in use, so the database in use keeps its tiles.
    public static func superseded(installed: [InstalledPack], now: Date) -> [InstalledPack] {
        let inUse = ChartLibrary.packToShow(layer: navDatabaseLayer, region: navRegion, installed: installed, now: now)
        let current = inUse.flatMap { $0.effective <= now && now < $0.expires ? $0 : nil }
        return ChartLibrary.packsToDelete(installed: installed, now: now).filter { $0.id.layer != navTilesLayer }
            + installed.filter { pack in
                pack.id.layer == navTilesLayer && current.map { pack.effective < $0.effective } ?? false
            }
    }

    /// When an installed pack next takes effect or expires, so a timer can act at that moment.
    public static func nextChangeover(installed: [InstalledPack], now: Date) -> Date? {
        installed.filter { !ChartLibrary.cycleFreeLayers.contains($0.id.layer) }
            .flatMap { [$0.effective, $0.expires] }.filter { $0 > now }.min()
    }

    /// Seconds to wait before switching cycles: one past the next changeover. Nil when nothing changes.
    public static func switchDelay(installed: [InstalledPack], now: Date) -> TimeInterval? {
        nextChangeover(installed: installed, now: now).map { max($0.timeIntervalSince(now), 0) + 1 }
    }

    /// A row's state in words. `effective` is the date a pack not yet in effect starts, so it never reads expired.
    /// `waiting` is true while the device has no network, when a transfer makes no progress.
    public static func statusText(_ state: PackState, effective: Date? = nil, waiting: Bool = false) -> String {
        switch state {
        case .notDownloaded: "Not downloaded"
        case .downloading(let progress):
            waiting ? "Waiting for network" : "Downloading \(Int((progress * 100).rounded()))%"
        case .ready: "Ready"
        case .expired: effective.map { "Not yet in effect until \(NavText.day($0)) UTC" } ?? "Expired"
        case .failed(let reason): "Failed: \(reason)"
        }
    }

    /// The region's full name, or its code when the code is not a state.
    public static func regionName(_ region: String) -> String { stateNames[region] ?? region }

    public static let stateNames = [
        "AK": "Alaska", "AL": "Alabama", "AR": "Arkansas", "AZ": "Arizona", "CA": "California",
        "CO": "Colorado", "CT": "Connecticut", "DC": "District of Columbia", "DE": "Delaware", "FL": "Florida",
        "GA": "Georgia", "HI": "Hawaii", "IA": "Iowa", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "MA": "Massachusetts", "MD": "Maryland", "ME": "Maine", "MI": "Michigan",
        "MN": "Minnesota", "MO": "Missouri", "MS": "Mississippi", "MT": "Montana", "NC": "North Carolina",
        "ND": "North Dakota", "NE": "Nebraska", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico",
        "NV": "Nevada", "NY": "New York", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
        "PR": "Puerto Rico", "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee",
        "TX": "Texas", "UT": "Utah", "VA": "Virginia", "VI": "Virgin Islands", "VT": "Vermont", "WA": "Washington",
        "WI": "Wisconsin", "WV": "West Virginia", "WY": "Wyoming", "GU": "Guam", "AS": "American Samoa",
        "MP": "Northern Mariana Islands",
    ]

    /// A file size as the system's file style writes it in English: 999 bytes, 12 KB, 1.5 MB, 1.23 GB.
    public static func byteCount(_ bytes: Int64) -> String {
        if bytes == 0 { return "Zero KB" }
        let sign = bytes < 0 ? "-" : ""
        let value = bytes.magnitude
        if value < 1000 { return sign + "\(value) " + (value == 1 ? "byte" : "bytes") }
        let units = ["KB", "MB", "GB", "TB", "PB", "EB"]
        var unit = 0
        var scale: UInt64 = 1000
        while unit < units.count - 1, value / scale >= 1000 {
            unit += 1
            scale *= 1000
        }
        while true {
            let decimals = min(unit, 2)
            let factor = [1, 10, 100][decimals] as UInt64
            // Half up, worked in whole numbers so no rounding of a double creeps in.
            let (wide, overflow) = value.multipliedReportingOverflow(by: factor * 2)
            let scaled = overflow ? value / scale * factor : (wide + scale) / (scale * 2)
            if scaled >= 1000 * factor, unit < units.count - 1 {
                unit += 1
                scale *= 1000
                continue
            }
            var text = String(scaled / factor)
            var fraction = decimals > 0 ? NavText.pad(Int(scaled % factor), decimals) : ""
            while fraction.hasSuffix("0") { fraction.removeLast() }
            if !fraction.isEmpty { text += "." + fraction }
            return sign + text + " " + units[unit]
        }
    }
}
