public struct PackID: Hashable, Sendable, Codable {
    public var cycle: String
    public var layer: String
    public var region: String

    public init(cycle: String, layer: String, region: String) {
        self.cycle = cycle
        self.layer = layer
        self.region = region
    }
}

/// A pack on disk. It carries its own dates because its cycle may have left the manifest.
public struct InstalledPack: Hashable, Sendable, Codable {
    public var id: PackID
    public var effective: Date
    public var expires: Date
    /// The file's hash at install. Nil in indexes written before it was kept, which refetches once.
    public var sha256: String?

    public init(id: PackID, effective: Date, expires: Date, sha256: String? = nil) {
        self.id = id
        self.effective = effective
        self.expires = expires
        self.sha256 = sha256
    }
}

/// Why the chart list on hand is not a fresh one.
public enum ListFailure: Equatable, Sendable {
    case noConnection
    /// The list is in a format this version of the app does not know.
    case unreadable
    case server
}

public enum Transfer: Equatable, Sendable {
    case downloading(Double)
    case failed(String)
}

public enum PackState: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case ready
    case expired
    case failed(String)
}

public struct PackRequest: Equatable, Sendable {
    public var id: PackID
    public var path: String
    public var bytes: Int
    public var sha256: String
    public var effective: Date
    public var expires: Date
}

public enum ChartLibrary {
    public static let overviewRegion = "overview"
    /// Layers whose data does not follow the chart cycle. A pack of one never expires and is kept while its hash is listed.
    public static let cycleFreeLayers: Set<String> = ["street", "terrain"]

    /// The newest installed pack whose cycle is in effect. If none is, the earliest
    /// one on disk, so a wrong clock or a missing cycle never blanks the map.
    public static func packToShow(layer: String, region: String,
                                  installed: [InstalledPack], now: Date) -> InstalledPack? {
        let mine = installed.filter { $0.id.layer == layer && $0.id.region == region }
        return mine.filter { $0.effective <= now }.max { $0.effective < $1.effective }
            ?? mine.min { $0.effective < $1.effective }
    }

    private static func isCurrent(_ pack: InstalledPack, now: Date) -> Bool {
        cycleFreeLayers.contains(pack.id.layer) || pack.effective <= now && now < pack.expires
    }

    public static func state(layer: String, region: String, installed: [InstalledPack],
                             transfers: [PackID: Transfer], now: Date) -> PackState {
        let shown = packToShow(layer: layer, region: region, installed: installed, now: now)
        if let shown, isCurrent(shown, now: now) { return .ready }

        // Sorted so the result does not depend on dictionary order.
        let mine = transfers
            .filter { $0.key.layer == layer && $0.key.region == region }
            .sorted { $0.key.cycle < $1.key.cycle }
        for (_, transfer) in mine {
            if case .downloading(let progress) = transfer { return .downloading(progress) }
        }
        if shown != nil { return .expired }
        for (_, transfer) in mine {
            if case .failed(let reason) = transfer { return .failed(reason) }
        }
        return .notDownloaded
    }

    /// Packs replaced by a newer one that is current. Future-cycle packs are kept, and
    /// nothing is deleted unless a current pack remains, which limits wrong-clock damage.
    public static func packsToDelete(installed: [InstalledPack], now: Date) -> [InstalledPack] {
        installed.filter { pack in
            guard pack.effective <= now,
                  let shown = packToShow(layer: pack.id.layer, region: pack.id.region, installed: installed, now: now)
            else { return false }
            return shown != pack && isCurrent(shown, now: now)
        }
    }

    /// Missing or republished packs for the current and next cycle, for the chosen regions plus the overview.
    /// A cycle-free pack is fetched once, and not at all while any cycle's copy on disk has the listed hash.
    public static func packsToFetch(regions: Set<String>, manifest: Manifest,
                                    installed: [InstalledPack], now: Date) -> [PackRequest] {
        let have = Dictionary(installed.map { ($0.id, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        var free = Set(installed.filter { cycleFreeLayers.contains($0.id.layer) }.compactMap { pack in
            pack.sha256.map { [pack.id.layer, pack.id.region, $0] }
        })
        let cycles = [manifest.currentCycle(at: now), manifest.nextCycle(at: now)].compactMap { $0 }
        return cycles.flatMap { cycle in
            cycle.packs.compactMap { pack -> PackRequest? in
                guard regions.contains(pack.region) || pack.region == overviewRegion else { return nil }
                let id = PackID(cycle: cycle.id, layer: pack.layer, region: pack.region)
                if cycleFreeLayers.contains(pack.layer), !free.insert([pack.layer, pack.region, pack.sha256]).inserted {
                    return nil
                }
                if let sha = have[id], sha == pack.sha256 { return nil }
                return PackRequest(id: id, path: pack.path, bytes: pack.bytes, sha256: pack.sha256,
                                   effective: cycle.effective, expires: cycle.expires)
            }
        }
    }
}
