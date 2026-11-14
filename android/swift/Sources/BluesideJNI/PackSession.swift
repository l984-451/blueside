import FlightCore

/// One pack store and its downloads, as iOS DownloadsModel runs them. Kotlin moves the bytes (system download
/// service, hashing) and reports events; every decision and the index file stay here.
final class PackSession {
    struct Index: Codable {
        var packs: [InstalledPack] = []
        var regions: [String] = []
    }

    /// A pack being fetched. Kotlin keeps it with the transfer and hands it back with each event.
    struct Pending: Codable, Equatable {
        var id: PackID
        /// Path under the server base.
        var path: String
        var sha256: String
        var bytes: Int
        var effective: Date
        var expires: Date
        var attempt: Int
    }

    let root: URL
    private var layers: [String]?
    private var skipLayers: [String] = []
    private var always: Set<String> = []
    private var isNav = false
    private var category: DownloadCategory?
    private var manifest: Manifest?
    private var listFailure: ListFailure? = .noConnection
    private var transfers: [PackID: Transfer] = [:]
    // When a pack last failed its checksum or was refused. Kept in memory, so each launch allows one more try.
    private var held: [PackID: Date] = [:]
    private var message: String?

    init(root: String) {
        self.root = URL(fileURLWithPath: root)
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    // MARK: Files

    static func fileURL(root: URL, _ id: PackID) -> URL {
        root.appendingPathComponent("packs/\(id.cycle)/\(id.layer)/\(id.region).pmtiles")
    }

    static func index(root: URL) -> Index {
        FileManager.default.contents(atPath: root.appendingPathComponent("index.json").path)
            .flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
    }

    /// Installed packs whose file is present.
    static func installedFiles(root: String) -> [PackFile] {
        let url = URL(fileURLWithPath: root)
        return index(root: url).packs.compactMap { pack in
            let file = fileURL(root: url, pack.id)
            return FileManager.default.fileExists(atPath: file.path) ? PackFile(pack: pack, url: file) : nil
        }
    }

    private var installed: [PackFile] { Self.installedFiles(root: root.path) }
    private var chosen: Set<String> { Set(Self.index(root: root).regions).union(always) }

    private func update(_ edit: (inout Index) -> Void) {
        var index = Self.index(root: root)
        edit(&index)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
        }
    }

    private func remove(_ id: PackID) {
        try? FileManager.default.removeItem(at: Self.fileURL(root: root, id))
        update { $0.packs.removeAll { $0.id == id } }
    }

    private var cacheURL: URL { root.appendingPathComponent("manifest.json") }

    // MARK: Ops

    struct Configure: Decodable {
        var layers: [String]?
        var skipLayers: [String]?
        var always: [String]?
        var nav: Bool?
        /// The DownloadCategory id this store fills.
        var category: String?
    }

    func configure(_ a: Configure) {
        layers = a.layers
        skipLayers = a.skipLayers ?? []
        always = Set(a.always ?? [])
        isNav = a.nav ?? false
        category = DownloadCategory.all.first { $0.id == a.category }
        let cached = FileManager.default.contents(atPath: cacheURL.path).flatMap { try? Manifest.decode($0) }
        manifest = keep(cached)
    }

    private func keep(_ manifest: Manifest?) -> Manifest? {
        DownloadPolicy.keeping(manifest) { [layers, skipLayers] layer in
            (layers?.contains(layer) ?? true) && !skipLayers.contains(layer)
        }
    }

    struct ListFetched: Decodable {
        /// HTTP status, or -1 when there was no connection.
        var status: Int
        var body: String?
    }

    /// A fresh list, or the cached one and the reason when the network or the file is bad.
    func listFetched(_ a: ListFetched) {
        guard a.status != -1 else { return listFailure = .noConnection }
        guard a.status == 200, let body = a.body else { return listFailure = .server }
        let data = Data(body.utf8)
        do {
            manifest = keep(try Manifest.decode(data))
            try? data.write(to: cacheURL, options: .atomic)
            listFailure = nil
        } catch ManifestError.unsupportedVersion {
            listFailure = .unreadable
        } catch {
            // Anything else that is not a list, such as a sign-in page, is the server's fault.
            listFailure = .server
        }
    }

    struct Now: Decodable { var now: Date }

    struct Changed: Encodable {
        /// Seconds until the next cycle changeover. Nil when nothing changes.
        var delay: Double?
        var retry: Pending?
        /// True when a new pass should run, after a stop.
        var runPass = false
    }

    /// Clears failures that have rested and switches cycles.
    func refresh(_ a: Now) -> Changed {
        for id in DownloadPolicy.failuresToRetry(transfers: transfers, installed: installed.map(\.pack),
                                                 heldSince: held, now: a.now) {
            transfers[id] = nil
        }
        return switchCycles(now: a.now)
    }

    private func switchCycles(now: Date) -> Changed {
        for pack in DownloadPolicy.superseded(installed: installed.map(\.pack), now: now) { remove(pack.id) }
        return Changed(delay: DownloadPolicy.switchDelay(installed: installed.map(\.pack), now: now))
    }

    struct PassArgs: Decodable {
        /// Transfers the system holds now, including ones from before a relaunch.
        var active: [Pending]
        var freeBytes: Int64
        var now: Date
        var stopped: PackID?
    }

    struct PassResult: Encodable {
        var cancel: [String] = []
        var start: [Pending] = []
    }

    /// Starts whatever the core says is missing and stops transfers nobody wants.
    func pass(_ a: PassArgs) -> PassResult {
        var out = PassResult()
        var active = a.active
        // A stopped transfer with nothing running in its place is no longer downloading.
        if let stopped = a.stopped, case .downloading = transfers[stopped], !active.contains(where: { $0.id == stopped }) {
            transfers[stopped] = nil
        }
        let chosen = chosen
        let unwanted = DownloadPolicy.unwanted(active.map(\.id), chosen: chosen)
        out.cancel = unwanted.sorted()
        active.removeAll { unwanted.contains($0.id.region) }
        for pending in active where transfers[pending.id] == nil { transfers[pending.id] = .downloading(0) }
        guard let manifest else { return out }
        let all = ChartLibrary.packsToFetch(regions: chosen, manifest: manifest,
                                            installed: installed.map(\.pack), now: a.now)
        let wanted = DownloadPolicy.currentFirst(all, installed: installed.map(\.pack), now: a.now)
        let steps = DownloadPolicy.pass(wanted: wanted, transfers: transfers,
                                        committed: DownloadPolicy.total(active.map(\.bytes)), freeBytes: a.freeBytes)
        for step in steps {
            switch step {
            case .fail(let id, let text):
                transfers[id] = .failed(text)
                message = text
            case .start(let r):
                transfers[r.id] = .downloading(0)
                out.start.append(Pending(id: r.id, path: r.path, sha256: r.sha256, bytes: r.bytes,
                                         effective: r.effective, expires: r.expires, attempt: 1))
            }
        }
        return out
    }

    struct Event: Decodable {
        /// started, progress, downloaded, failed or stopped.
        var kind: String
        var pending: Pending
        var progress: Double?
        /// HTTP status or system error code, for failed.
        var code: Int?
        /// The finished file and its hash, for downloaded.
        var file: String?
        var sha256: String?
        var now: Date
    }

    func event(_ e: Event) -> Changed {
        let id = e.pending.id
        // A transfer for a region no longer wanted leaves nothing behind.
        guard chosen.contains(id.region) || id.region == ChartLibrary.overviewRegion else {
            transfers[id] = nil
            if let file = e.file { try? FileManager.default.removeItem(atPath: file) }
            return Changed()
        }
        switch e.kind {
        case "started": transfers[id] = .downloading(0)
        case "progress": transfers[id] = .downloading(e.progress ?? 0)
        case "failed": transfers[id] = .failed(DownloadPolicy.transferFailure(code: e.code ?? 0))
        case "stopped": return Changed(runPass: true)
        case "downloaded":
            guard let file = e.file else { break }
            return install(e.pending, file: file, sha256: e.sha256, now: e.now)
        default: break
        }
        return Changed()
    }

    /// Checks the hash, then renames the file into place. A wrong hash is fetched once more.
    private func install(_ pending: Pending, file: String, sha256: String?, now: Date) -> Changed {
        let fm = FileManager.default
        func fail(_ reason: String) -> Changed {
            try? fm.removeItem(atPath: file)
            transfers[pending.id] = .failed(reason)
            held[pending.id] = now
            return Changed()
        }
        guard sha256 == pending.sha256 else {
            if DownloadPolicy.retriesChecksum(attempt: pending.attempt) {
                try? fm.removeItem(atPath: file)
                var again = pending
                again.attempt += 1
                return Changed(retry: again)
            }
            return fail(DownloadPolicy.checksumFailure)
        }
        if pending.id.layer == DownloadPolicy.navDatabaseLayer, (try? NavDatabase(path: file)) == nil {
            return fail(DownloadPolicy.unreadableFailure)
        }
        let destination = Self.fileURL(root: root, pending.id)
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            // A rename inside one volume, so the map never sees part of a file.
            try fm.moveItem(atPath: file, toPath: destination.path)
        } catch {
            transfers[pending.id] = .failed("\(error)")
            return Changed()
        }
        update { index in
            index.packs.removeAll { $0.id == pending.id }
            index.packs.append(InstalledPack(id: pending.id, effective: pending.effective, expires: pending.expires,
                                             sha256: pending.sha256))
        }
        transfers[pending.id] = nil
        return switchCycles(now: now)
    }

    struct RowsArgs: Decodable {
        var now: Date
        /// True while the device has no network.
        var waiting: Bool?
    }

    struct Row: Encodable {
        var region: String
        var name: String
        var size: String
        /// notDownloaded, downloading, ready, expired or failed.
        var state: String
        var progress: Double?
        var text: String
        /// Kept by the Downloaded filter.
        var downloaded: Bool
    }

    struct Summary: Encodable {
        var title: String
        var footer: String
        var text: String
        var state: String
        var progress: Double?
    }

    struct RowsResult: Encodable {
        var rows: [Row]
        var notice: String?
        var message: String?
        /// The category row's words; nil when the store was given no category.
        var summary: Summary?
        var bytes: Int = 0
    }

    private static func kind(_ state: PackState) -> (String, Double?) {
        switch state {
        case .notDownloaded: ("notDownloaded", nil)
        case .downloading(let p): ("downloading", p)
        case .ready: ("ready", nil)
        case .expired: ("expired", nil)
        case .failed: ("failed", nil)
        }
    }

    /// Every region the list offers, and every region on disk whether or not the list names it.
    func rows(_ a: RowsArgs) -> RowsResult {
        let listed = (manifest?.currentCycle(at: a.now) ?? manifest?.nextCycle(at: a.now))?.packs ?? []
        let installed = installed
        let regions = Set(listed.map(\.region)).union(installed.map(\.pack.id.region)).union(always)
            .subtracting([ChartLibrary.overviewRegion]).sorted()
        var states: [PackState] = []
        var rowSizes: [Int] = []
        let rows = regions.map { region -> Row in
            let offered = listed.filter { $0.region == region }
            let onDisk = installed.filter { $0.pack.id.region == region }
            // A region the list no longer names is sized from its files.
            let sizes = offered.isEmpty
                ? onDisk.map { ((try? FileManager.default.attributesOfItem(atPath: $0.url.path))?[.size] as? Int) ?? 0 }
                : offered.map(\.bytes)
            var effective: Date?
            if case .notYetEffective(let date) = MapPlan.currency(layers: onDisk.map(\.pack.id.layer),
                                                                  installed: onDisk.map(\.pack), now: a.now) {
                effective = date
            }
            let layers = Set(offered.map(\.layer) + onDisk.map(\.pack.id.layer)).sorted()
            let layerSizes = layers.map { layer in offered.first { $0.layer == layer }?.bytes ?? 0 }
            let state = DownloadPolicy.combined(layers.map {
                DownloadPolicy.state(layer: $0, region: region, installed: installed.map(\.pack), transfers: transfers, now: a.now)
            }, sizes: layerSizes)
            let (kind, progress) = Self.kind(state)
            states.append(state)
            rowSizes.append(DownloadPolicy.total(sizes))
            return Row(region: region, name: DownloadPolicy.regionName(region),
                       size: DownloadPolicy.byteCount(Int64(DownloadPolicy.total(sizes))), state: kind, progress: progress,
                       text: DownloadPolicy.statusText(state, effective: effective, waiting: a.waiting ?? false),
                       downloaded: DownloadSummary.isDownloaded(state))
        }
        let notice = isNav ? NavText.downloadNotice(listFailure, hasList: manifest != nil)
                           : DownloadPolicy.listNotice(listFailure, hasList: manifest != nil)
        let summary = DownloadSummary(states: states, sizes: rowSizes, unit: category?.unit, waiting: a.waiting ?? false)
        let (kind, progress) = Self.kind(summary.state)
        return RowsResult(rows: rows, notice: notice, message: message,
                          summary: category.map { Summary(title: $0.title, footer: $0.footer, text: summary.text,
                                                           state: kind, progress: progress) },
                          bytes: summary.bytes)
    }

    struct RegionArgs: Decodable { var region: String }

    func choose(_ a: RegionArgs) {
        update { $0.regions = Set($0.regions).union([a.region]).sorted() }
    }

    /// Clears a region's failures so the next pass tries again.
    func retry(_ a: RegionArgs) {
        for (id, transfer) in transfers where id.region == a.region {
            if case .failed = transfer { transfers[id] = nil }
        }
        message = nil
    }

    /// Deletes a region's packs. Kotlin stops its transfers.
    func remove(_ a: RegionArgs) -> PassResult {
        update { $0.regions.removeAll { $0 == a.region } }
        for id in transfers.keys where id.region == a.region { transfers[id] = nil }
        for file in installed where file.pack.id.region == a.region { remove(file.pack.id) }
        return PassResult(cancel: [a.region])
    }

    struct SeedArgs: Decodable {
        struct File: Decodable { var layer: String; var path: String }
        var name: String
        var files: [File]
        var now: Date
    }

    /// Replaces the store's contents with the given files, dated relative to now. Reached only by a launch option.
    func seed(_ a: SeedArgs) {
        let day: TimeInterval = 86_400
        let dates: (Date, Date)? = switch a.name {
        case "expired": (a.now - 57 * day, a.now - day)
        case "upcoming": (a.now + 7 * day, a.now + 63 * day)
        case "current": (a.now - day, a.now + 55 * day)
        default: nil
        }
        // A mistyped name must not empty the store.
        guard dates != nil || a.name == "empty" else { return }
        for file in installed { remove(file.pack.id) }
        update { $0.regions = [] }
        try? FileManager.default.removeItem(at: cacheURL)
        manifest = nil
        guard let (effective, expires) = dates else { return }
        for file in a.files {
            // Nav files are looked up under their one national region; chart seeds stand in for Texas.
            let id = PackID(cycle: "seed-\(a.name)", layer: file.layer, region: isNav ? DownloadPolicy.navRegion : "TX")
            let destination = Self.fileURL(root: root, id)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            guard (try? FileManager.default.copyItem(atPath: file.path, toPath: destination.path)) != nil else { continue }
            update { $0.packs.append(InstalledPack(id: id, effective: effective, expires: expires)) }
        }
    }
}
