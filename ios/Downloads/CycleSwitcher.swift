import FlightCore
import Foundation

/// Cycle changeover on disk. Which pack is shown and which are deleted is the core's decision,
/// except that navigation tiles are deleted with their database.
enum CycleSwitcher {
    /// Deletes packs a current one has replaced and returns what is left.
    static func deleteSuperseded(store: PackStore, now: Date) -> [PackFile] {
        let installed = store.installedFiles().map(\.pack)
        for pack in DownloadPolicy.superseded(installed: installed, now: now) { store.remove(pack) }
        return store.installedFiles()
    }
}
