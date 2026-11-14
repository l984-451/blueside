import FlightCore
import SwiftUI

/// Saved flights and recent routes in Application Support/routes.json. The core does every edit.
@MainActor @Observable final class SavedRouteStore {
    private(set) var routes = SavedRoutes()
    /// Set when the file could not be read; it is then never written over.
    private(set) var problem: String?
    @ObservationIgnored private let file: URL

    static var defaultFile: URL { URL.applicationSupportDirectory.appendingPathComponent(SavedRoutes.fileName) }

    init(file: URL = SavedRouteStore.defaultFile) {
        self.file = file
        do {
            routes = try SavedRoutes.decode(try? Data(contentsOf: file))
        } catch {
            problem = RoutePages.savedUnreadable
        }
    }

    func update(_ edit: (SavedRoutes) -> SavedRoutes) {
        guard problem == nil else { return }
        let new = edit(routes)
        guard new != routes else { return }
        routes = new
        // ponytail: a failed write keeps the list in memory only, like the aircraft list.
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? routes.encoded().write(to: file, options: .atomic)
    }
}

/// Tap loads a route; swipe or long press removes it, and a saved one can be renamed.
struct SavedRoutesList: View {
    let store: SavedRouteStore
    var onClose: () -> Void = {}
    let onLoad: (SavedRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renaming: SavedRoutes.Row?
    @State private var name = ""

    /// The device's offset now and after its next clock change, so each departure reads in the offset then.
    static func localOffset(_ zone: TimeZone = .current, now: Date = Date()) -> LocalOffset {
        let change = zone.nextDaylightSavingTimeTransition(after: now)
        return LocalOffset(seconds: zone.secondsFromGMT(for: now), nextChange: change,
                           secondsAfter: change.map { zone.secondsFromGMT(for: $0) })
    }

    var body: some View {
        let offset = Self.localOffset()
        List {
            if let problem = store.problem {
                Text(problem).foregroundStyle(PanelInk.danger)
            }
            Section(RoutePages.savedSection) {
                if store.routes.saved.isEmpty {
                    Text(RoutePages.noSaved).foregroundStyle(.secondary)
                }
                ForEach(store.routes.savedRows(now: .now, localOffset: offset)) { item($0, renamable: true) }
            }
            if !store.routes.recent.isEmpty {
                Section(RoutePages.recentSection) {
                    ForEach(store.routes.recentRows(localOffset: offset)) { item($0, renamable: false) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .panelList()
        .panelPage(RoutePages.savedTitle, onClose: onClose)
        .alert(RoutePages.rename, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(RoutePages.routeName, text: $name)
            Button(RoutePages.cancel, role: .cancel) {}
            Button(RoutePages.save) {
                if let id = renaming?.id { store.update { $0.renaming(id, to: name) } }
            }
        }
    }

    private func item(_ row: SavedRoutes.Row, renamable: Bool) -> some View {
        Button {
            guard let route = store.routes.route(row.id) else { return }
            onLoad(route)
            dismiss()
        } label: {
            VStack(alignment: .leading) {
                Text(row.name).font(.headline)
                Text(row.text).font(.subheadline.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                Text(row.detail).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
        .swipeActions {
            Button(RoutePages.delete, systemImage: "trash", role: .destructive) { store.update { $0.removing(row.id) } }
        }
        .contextMenu {
            if renamable {
                Button(RoutePages.rename, systemImage: "pencil") {
                    name = row.name
                    renaming = row
                }
            }
            Button(RoutePages.delete, systemImage: "trash", role: .destructive) { store.update { $0.removing(row.id) } }
        }
        .accessibilityIdentifier("saved-route-\(row.name)")
    }
}
