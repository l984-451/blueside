import FlightCore
import Foundation

/// Replaces the pack store's contents with given files dated relative to now. Reached only by a launch option.
enum PackSeed {
    /// Effective and expiry dates for a named state. Nil for "empty" and for any unknown name.
    static func dates(_ name: String, now: Date) -> (effective: Date, expires: Date)? {
        let day: TimeInterval = 86_400
        switch name {
        case "expired": return (now.addingTimeInterval(-57 * day), now.addingTimeInterval(-day))
        case "upcoming": return (now.addingTimeInterval(7 * day), now.addingTimeInterval(63 * day))
        case "current": return (now.addingTimeInterval(-day), now.addingTimeInterval(55 * day))
        default: return nil
        }
    }

    static func apply(_ name: String, store: PackStore, files: [PackFile], now: Date = Date()) {
        let dates = Self.dates(name, now: now)
        // A mistyped name must not empty the store.
        guard dates != nil || name == "empty" else { return }
        for old in store.installedFiles() { store.remove(old.pack) }
        store.setRegions([])
        try? FileManager.default.removeItem(at: store.root.appendingPathComponent("manifest.json"))
        guard let dates else { return }
        for file in files {
            // The store moves the file it installs, so it is given a copy.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard (try? FileManager.default.copyItem(at: file.url, to: copy)) != nil,
                  let hash = try? Checksum.sha256(of: copy) else { continue }
            let id = PackID(cycle: "seed-\(name)", layer: file.pack.id.layer, region: "TX")
            let pending = PendingPack(id: id, url: file.url, sha256: hash, bytes: 0,
                                      effective: dates.effective, expires: dates.expires, attempt: 1)
            try? store.install(pending, from: copy)
        }
    }
}
