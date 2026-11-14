import FlightCore
import Foundation
import Observation

/// One line of the download list: a region, the total size of its packs, and their combined state.
struct RegionRow: Identifiable, Equatable, Sendable {
    var id: String
    var bytes: Int
    var state: PackState
    /// When the pack on disk takes effect, set only while its cycle has not started.
    var effective: Date?
}

/// State behind the downloads sheet. Starts whatever the core says is missing.
@MainActor @Observable final class DownloadsModel {
    private(set) var installed: [PackFile]
    private(set) var transfers: [PackID: Transfer] = [:]
    private(set) var manifest: Manifest?
    /// Why the list is the last known one. Reads as no connection until the first fetch answers.
    private(set) var listFailure: ListFailure? = .noConnection
    var manifestIsFresh: Bool { listFailure == nil }
    private(set) var message: String?
    private(set) var chosen: Set<String>
    /// The detail page's Downloaded filter, kept for the session. All by default.
    var downloadedOnly = false
    // Counts the times the clock was consulted. Pack states read it, so an open list follows the clock.
    private var clockChecks = 0

    @ObservationIgnored private let store: PackStore
    // Regions wanted without being chosen. Never saved, so they cannot leak into another store.
    @ObservationIgnored private let always: Set<String>
    @ObservationIgnored private let client: ManifestClient?
    // Which layers of the list this model offers.
    @ObservationIgnored private let layers: @Sendable (String) -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var downloader: PackDownloader!
    @ObservationIgnored private var changeover: Task<Void, Never>?
    @ObservationIgnored private var starting: Task<Void, Never>?
    // When a pack last failed its checksum or was refused. Refresh leaves such a failure alone for six hours.
    // Kept in memory only, so each launch allows one more try.
    @ObservationIgnored private var checksumFailed: [PackID: Date] = [:]

    /// `prepare` is launch work on the store, run off the main thread; it returns true when it removed a pack.
    init(store: PackStore, client: ManifestClient?,
         configuration: URLSessionConfiguration = PackDownloader.backgroundConfiguration(),
         now: @escaping @Sendable () -> Date = { Date() }, always: Set<String> = [],
         layers: @escaping @Sendable (String) -> Bool = { _ in true },
         prepare: (@Sendable (PackStore) -> Bool)? = nil) {
        self.store = store
        self.client = client
        self.now = now
        self.always = always
        self.layers = layers
        // The record is read here, so a transfer reporting in at once is weighed against the regions chosen.
        installed = store.installedFiles()
        chosen = store.regions.union(always)
        downloader = PackDownloader(store: store, configuration: configuration) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // The last known list and the launch work are read off the main thread. A list fetched meanwhile wins.
        Task { [weak self, layers] in
            let (removed, cached) = await Task.detached(priority: .userInitiated) {
                (prepare?(store) ?? false, DownloadPolicy.keeping(client?.cached(), layers))
            }.value
            guard let self else { return }
            if manifest == nil { manifest = cached }
            if removed { installed = store.installedFiles() }
        }
    }

    static func standard(options: LaunchOptions) -> DownloadsModel {
        let store = PackStore(root: PackStore.standardRoot)
        let client = ManifestClient.baseURL(options: options).map {
            ManifestClient(base: $0, cache: store.root.appendingPathComponent("manifest.json"),
                           list: options.string("chartList") ?? "manifest.json")
        }
        let own = [MapStyleSpec.streetLayer, MapStyleSpec.terrainLayer]
        return DownloadsModel(store: store, client: client, layers: { !own.contains($0) }) { store in
            // Street packs moved to their own store; any left from before are dropped.
            let old = store.installedFiles().filter { $0.pack.id.layer == MapStyleSpec.streetLayer }
            for file in old { store.remove(file.pack) }
            return !old.isEmpty
        }
    }

    /// Street or terrain packs: one layer of the chart list, chosen state by state, kept in a store of its own.
    static func baseMap(_ layer: String, root: URL, options: LaunchOptions) -> DownloadsModel {
        let store = PackStore(root: root)
        let quiet = options.flag("offline") || options.string("basePack") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let client = quiet ? nil : ManifestClient.baseURL(options: options).map {
            ManifestClient(base: $0, cache: store.root.appendingPathComponent("manifest.json"),
                           list: options.string("chartList") ?? "manifest.json")
        }
        return DownloadsModel(store: store, client: client,
                              configuration: PackDownloader.backgroundConfiguration(identifier: layer),
                              layers: { $0 == layer })
    }

    /// The navigation data list and files. A launch with bundled packs, no network, or a unit test run has no client.
    static func nav(options: LaunchOptions) -> DownloadsModel {
        let store = PackStore(root: PackStore.navRoot, accepts: NavFiles.readable)
        let quiet = options.flag("offline") || options.string("basePack") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let client = quiet ? nil : ManifestClient.baseURL(options: options).map {
            ManifestClient(base: $0, cache: store.root.appendingPathComponent("manifest.json"),
                           list: options.string("navList") ?? "nav/manifest.json")
        }
        return DownloadsModel(store: store, client: client,
                              configuration: PackDownloader.backgroundConfiguration(identifier: "nav"),
                              always: [NavFiles.region], prepare: { $0.removeRefused() })
    }

    /// Fetches the list, switches cycles if it is time, and starts what is missing.
    func refresh() async {
        // A failure with no Retry button (overview, or hidden behind an installed pack) is tried again here.
        for id in DownloadPolicy.failuresToRetry(transfers: transfers, installed: installed.map(\.pack),
                                                 heldSince: checksumFailed, now: now()) {
            transfers[id] = nil
        }
        if let client {
            let result = await client.fetch()
            manifest = DownloadPolicy.keeping(result.manifest, layers) ?? manifest
            listFailure = result.failure
        }
        switchCycles()
        await startMissing()
    }

    func choose(_ region: String) async {
        chosen.insert(region)
        store.setRegions(chosen)
        await startMissing()
    }

    /// Clears a region's failures and tries again.
    func retry(_ region: String) async {
        for (id, transfer) in transfers where id.region == region {
            if case .failed = transfer { transfers[id] = nil }
        }
        message = nil
        await startMissing()
    }

    /// Deletes a region's packs and stops its transfers.
    func remove(_ region: String) async {
        chosen.remove(region)
        store.setRegions(chosen)
        await downloader.cancel(region: region)
        for id in transfers.keys where id.region == region { transfers[id] = nil }
        // Read from the store, so a pack installed during the wait is caught too.
        for file in store.installedFiles() where file.pack.id.region == region { store.remove(file.pack) }
        installed = store.installedFiles()
    }

    func activeCount() async -> Int { await downloader.active().count }

    /// Every region the list offers, and every region on disk whether or not the list names it.
    var rows: [RegionRow] {
        _ = clockChecks
        let regions = Set(listed.map(\.region)).union(installed.map(\.pack.id.region)).union(always)
            .subtracting([ChartLibrary.overviewRegion]).sorted()
        return regions.map { region in
            let offered = listed.filter { $0.region == region }
            let onDisk = installed.filter { $0.pack.id.region == region }
            // A region the list no longer names is sized from its files.
            let sizes = offered.isEmpty
                ? onDisk.map { (try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
                : offered.map(\.bytes)
            var effective: Date?
            if case .notYetEffective(let date) = MapPlan.currency(
                layers: onDisk.map(\.pack.id.layer), installed: onDisk.map(\.pack), now: now()) {
                effective = date
            }
            return RegionRow(id: region, bytes: DownloadPolicy.total(sizes), state: state(of: region), effective: effective)
        }
    }

    func state(of region: String) -> PackState {
        _ = clockChecks
        // Layers the list offers, plus any on disk that it no longer names.
        let layers = Set(listed.filter { $0.region == region }.map(\.layer)
            + installed.map(\.pack.id).filter { $0.region == region }.map(\.layer)).sorted()
        let sizes = layers.map { layer in listed.first { $0.region == region && $0.layer == layer }?.bytes ?? 0 }
        return DownloadPolicy.combined(layers.map {
            DownloadPolicy.state(layer: $0, region: region, installed: installed.map(\.pack), transfers: transfers, now: now())
        }, sizes: sizes)
    }

    // Packs of the cycle the list is showing: the current one, or the next when none has started.
    private var listed: [Manifest.Pack] {
        (manifest?.currentCycle(at: now()) ?? manifest?.nextCycle(at: now()))?.packs ?? []
    }

    // One pass at a time, so no pass acts on a list of live transfers that another pass has since added to.
    private func startMissing(stopped: PackID? = nil) async {
        let earlier = starting
        let pass = Task {
            await earlier?.value
            await startPass(stopped: stopped)
        }
        starting = pass
        await pass.value
    }

    private func startPass(stopped: PackID?) async {
        guard let manifest, let client else { return }
        var active = await downloader.active()
        // A stopped transfer with nothing running in its place is no longer downloading.
        if let stopped, case .downloading = transfers[stopped], !active.contains(where: { $0.id == stopped }) {
            transfers[stopped] = nil
        }
        // A transfer the system kept for a region no longer wanted is stopped, not shown as running.
        let unwanted = DownloadPolicy.unwanted(active.map(\.id), chosen: chosen)
        for region in unwanted { await downloader.cancel(region: region) }
        active.removeAll { unwanted.contains($0.id.region) }
        for pending in active where transfers[pending.id] == nil { transfers[pending.id] = .downloading(0) }
        let wanted = DownloadPolicy.currentFirst(ChartLibrary.packsToFetch(regions: chosen, manifest: manifest,
                                               installed: installed.map(\.pack), now: now()), installed: installed.map(\.pack), now: now())
        // Checked before any request is made, so a full disk never holds part of a pack.
        let steps = DownloadPolicy.pass(wanted: wanted, transfers: transfers,
                                        committed: DownloadPolicy.total(active.map(\.bytes)), freeBytes: store.freeSpace())
        for step in steps {
            switch step {
            case .fail(let id, let text):
                transfers[id] = .failed(text)
                message = text
            case .start(let request):
                transfers[request.id] = .downloading(0)
                downloader.start(PendingPack(request, url: client.url(for: request.path)))
            }
        }
    }
    func handle(_ event: PackDownloader.Event) {
        // A transfer for a region no longer wanted leaves nothing behind.
        let id = event.id
        guard chosen.contains(id.region) || id.region == ChartLibrary.overviewRegion else {
            transfers[id] = nil
            if case .installed = event {
                for file in store.installedFiles() where file.pack.id == id { store.remove(file.pack) }
                installed = store.installedFiles()
            }
            return
        }
        switch event {
        case .started(let id):
            transfers[id] = .downloading(0)
        case .progress(let id, let value):
            transfers[id] = .downloading(value)
        case .installed(let id):
            transfers[id] = nil
            switchCycles()
            // A next-cycle pack held back for this one can start now.
            Task { await startMissing() }
        case .failed(let id, let reason):
            transfers[id] = .failed(reason)
            if DownloadPolicy.holds(reason) {
                checksumFailed[id] = now()
            }
        case .stopped(let id):
            // The stop can arrive after the region was asked for again, so it is weighed against live transfers.
            Task { await startMissing(stopped: id) }
        }
    }

    private func switchCycles() {
        installed = CycleSwitcher.deleteSuperseded(store: store, now: now())
        clockChecks &+= 1
        changeover?.cancel()
        // Wakes one second after a pack takes effect or expires, then switches cycles and reads the states again.
        guard let wait = DownloadPolicy.switchDelay(installed: installed.map(\.pack), now: now()) else { return }
        changeover = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { await self?.refresh() }
        }
    }
}
