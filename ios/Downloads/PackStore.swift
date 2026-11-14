import FlightCore
import Foundation

/// A pack being fetched. Small enough to travel in a download task's description across a relaunch.
struct PendingPack: Codable, Equatable, Sendable {
    var id: PackID
    var url: URL
    var sha256: String
    var bytes: Int
    var effective: Date
    var expires: Date
    var attempt: Int
}

extension PendingPack {
    init(_ request: PackRequest, url: URL) {
        self.init(id: request.id, url: url, sha256: request.sha256, bytes: request.bytes,
                  effective: request.effective, expires: request.expires, attempt: 1)
    }
}

/// Owns the pack files on disk and the record of what is installed.
final class PackStore: @unchecked Sendable {
    enum StoreError: Error, Equatable {
        case checksumMismatch
        /// The file is what the list promised, and this version of the app cannot open it.
        case rejected
        case notEnoughSpace(needed: Int64, free: Int64)
    }

    private struct Index: Codable {
        var packs: [InstalledPack] = []
        var regions: [String] = []
    }


    /// Library/Packs. The path has no space, which the map's file URLs depend on.
    static var standardRoot: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Packs", isDirectory: true)
    }

    /// Library/Street.
    static var streetRoot: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Street", isDirectory: true)
    }

    static var terrainRoot: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Terrain", isDirectory: true)
    }

    /// Library/NavData. Kept apart from the charts so neither list can delete the other's files.
    static var navRoot: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NavData", isDirectory: true)
    }

    let root: URL
    private let freeBytes: @Sendable () -> Int64
    private let lock = NSLock()
    // Says whether a verified file is one the app can open. Nil accepts every file.
    private let accepts: (@Sendable (PackID, URL) -> Bool)?

    init(root: URL, freeBytes: (@Sendable () -> Int64)? = nil, accepts: (@Sendable (PackID, URL) -> Bool)? = nil) {
        self.root = root
        self.accepts = accepts
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.freeBytes = freeBytes ?? {
            // The important-usage reading can come back empty or zero, so the plain one backs it up.
            let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                            .volumeAvailableCapacityKey])
            let important = values?.volumeAvailableCapacityForImportantUsage ?? 0
            return important > 0 ? important : Int64(values?.volumeAvailableCapacity ?? 0)
        }
    }

    func fileURL(for id: PackID) -> URL {
        root.appendingPathComponent("packs/\(id.cycle)/\(id.layer)/\(id.region).pmtiles")
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    // The record on disk. A missing or unreadable one is rebuilt from the pack files, so no file on disk is forgotten.
    // An unreadable one is moved aside first and never written over; a failed move throws.
    private func saved() throws -> Index {
        let present = FileManager.default.fileExists(atPath: indexURL.path)
        if present, let index = try? JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL)) { return index }
        if present {
            let aside = root.appendingPathComponent("index-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: indexURL, to: aside)
        }
        let index = rebuilt()
        if !index.packs.isEmpty { try? write(index) }
        return index
    }

    private func load() -> Index { (try? saved()) ?? rebuilt() }

    private func write(_ index: Index) throws {
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    private func update(_ edit: (inout Index) -> Void) throws {
        try lock.withLock {
            var index = try saved()
            edit(&index)
            try write(index)
        }
    }

    // Every pack file under packs/<cycle>/<layer>/, dated from the cached list where it names the cycle.
    // A cycle the list no longer names reads as expired. A file not of the listed size is fetched once more.
    private func rebuilt() -> Index {
        let folder = root.appendingPathComponent("packs")
        func names(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }
        var ids: [PackID] = []
        for cycle in names(folder) {
            for layer in names(folder.appendingPathComponent(cycle)) {
                for file in names(folder.appendingPathComponent(cycle).appendingPathComponent(layer))
                where file.hasSuffix(".pmtiles") {
                    ids.append(PackID(cycle: cycle, layer: layer, region: String(file.dropLast(".pmtiles".count))))
                }
            }
        }
        guard !ids.isEmpty else { return Index() }
        let list = (try? Data(contentsOf: root.appendingPathComponent("manifest.json"))).flatMap { try? Manifest.decode($0) }
        let packs = ids.map { id in
            let cycle = list?.cycles.first { $0.id == id.cycle }
            // Cycle-free packs are listed under every cycle, so any cycle names them.
            let named = ChartLibrary.cycleFreeLayers.contains(id.layer) ? list?.cycles ?? [] : [cycle].compactMap { $0 }
            let listed = named.lazy.flatMap(\.packs).first { $0.layer == id.layer && $0.region == id.region }
            // A file of the listed size is taken as the listed file, so it is not fetched again. Nothing is hashed.
            let size = (try? fileURL(for: id).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return InstalledPack(id: id, effective: cycle?.effective ?? .distantPast, expires: cycle?.expires ?? .distantPast,
                                 sha256: listed.flatMap { $0.bytes == size ? $0.sha256 : nil })
        }
        // A region with packs on disk was chosen; the overview is wanted without being chosen.
        return Index(packs: packs, regions: Set(ids.map(\.region)).subtracting([ChartLibrary.overviewRegion]).sorted())
    }

    /// Installed packs whose file is present. An entry without its file is left out.
    func installedFiles() -> [PackFile] {
        lock.withLock { load() }.packs.compactMap { pack in
            let url = fileURL(for: pack.id)
            return FileManager.default.fileExists(atPath: url.path) ? PackFile(pack: pack, url: url) : nil
        }
    }

    var regions: Set<String> { Set(lock.withLock { load() }.regions) }

    // A failed write keeps the choice for this session only.
    func setRegions(_ regions: Set<String>) {
        try? update { $0.regions = regions.sorted() }
    }

    /// Throws unless the pack fits with the margin left over.
    func checkSpace(for bytes: Int64) throws {
        if let short = DownloadPolicy.shortfall(needed: bytes, freeBytes: freeBytes()) {
            throw StoreError.notEnoughSpace(needed: short.needed, free: short.free)
        }
    }

    func freeSpace() -> Int64 { freeBytes() }

    /// Verifies the downloaded file, then renames it into place. A wrong hash deletes it.
    func install(_ pending: PendingPack, from file: URL) throws {
        guard try Checksum.sha256(of: file) == pending.sha256 else {
            try? FileManager.default.removeItem(at: file)
            throw StoreError.checksumMismatch
        }
        if let accepts, !accepts(pending.id, file) {
            try? FileManager.default.removeItem(at: file)
            throw StoreError.rejected
        }
        let destination = fileURL(for: pending.id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var staged = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try staged.setResourceValues(values)
        // A rename inside one volume, so the map never sees part of a file. A pack already there is swapped
        // out in the same step, so its file is never missing.
        let replacing = FileManager.default.fileExists(atPath: destination.path)
        if replacing {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        do {
            try update { index in
                index.packs.removeAll { $0.id == pending.id }
                index.packs.append(InstalledPack(id: pending.id, effective: pending.effective, expires: pending.expires,
                                                 sha256: pending.sha256))
            }
        } catch {
            // An unlisted new file would only take space. A replaced one stays listed under its old hash.
            if !replacing { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    // A failed write leaves an entry with no file, which reads as not installed.
    func remove(_ pack: InstalledPack) {
        try? FileManager.default.removeItem(at: fileURL(for: pack.id))
        try? update { $0.packs.removeAll { $0.id == pack.id } }
    }

    /// Removes installed packs the check now refuses, such as a file damaged on disk. True when any went.
    @discardableResult func removeRefused() -> Bool {
        guard let accepts else { return false }
        let refused = installedFiles().filter { !accepts($0.pack.id, $0.url) }
        for file in refused { remove(file.pack) }
        return !refused.isEmpty
    }
}
