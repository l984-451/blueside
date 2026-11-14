/// One entry in the top-level Downloads list. Each is backed by its own pack store on a platform.
public struct DownloadCategory: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var footer: String
    /// What one row is, counted in the summary. Nil when the category is a single row.
    public var unit: String?

    public init(id: String, title: String, footer: String, unit: String?) {
        self.id = id
        self.title = title
        self.footer = footer
        self.unit = unit
    }

    public static let nav = DownloadCategory(
        id: "nav", title: "Navigation Data",
        footer: "Airports, navaids and airspace for the whole US. Kept current automatically.", unit: nil)
    public static let charts = DownloadCategory(
        id: "charts", title: "Charts",
        footer: "VFR sectional, terminal area and flyway charts, and IFR low, high and area charts, one state at a time.",
        unit: "state")
    public static let procedures = DownloadCategory(
        id: "procedures", title: "Procedures",
        footer: "Airport diagrams and approach, departure and arrival charts.", unit: "state")
    public static let street = DownloadCategory(
        id: "street", title: "Street Map",
        footer: "Roads and places for the Street base map, one state at a time.", unit: "state")

    public static let terrain = DownloadCategory(
        id: "terrain", title: "Terrain Map",
        footer: "Elevation colors and shaded relief for the Terrain base map, one state at a time.", unit: "state")

    /// Top-level order. A new pack store adds its category here.
    public static let all: [DownloadCategory] = [nav, charts, procedures, street, terrain]
}

/// The trailing words and state of a category row, from the states of its region rows.
public struct DownloadSummary: Equatable, Sendable {
    public var text: String
    /// Combined state of the regions on disk or under way. notDownloaded when there are none.
    public var state: PackState
    /// Bytes of the regions on disk or under way.
    public var bytes: Int

    public init(states: [PackState], sizes: [Int], unit: String?, waiting: Bool = false) {
        let kept = zip(states, sizes).filter { Self.isDownloaded($0.0) }
        bytes = DownloadPolicy.total(kept.map(\.1))
        guard !kept.isEmpty else {
            state = .notDownloaded
            text = "Not downloaded"
            return
        }
        state = DownloadPolicy.combined(kept.map(\.0), sizes: kept.map(\.1))
        switch state {
        case .downloading: text = DownloadPolicy.statusText(state, waiting: waiting)
        case .failed: text = "Failed"
        case .expired: text = "Update available"
        case .ready, .notDownloaded:
            let count = unit.map { "\(kept.count) \($0)\(kept.count == 1 ? "" : "s"), " } ?? ""
            text = count + DownloadPolicy.byteCount(Int64(bytes))
        }
    }

    /// A region the Downloaded filter keeps: on disk, under way, needing an update, or failed after being chosen.
    public static func isDownloaded(_ state: PackState) -> Bool { state != .notDownloaded }

    /// Total bytes on disk or under way across categories, in words.
    public static func used(_ summaries: [DownloadSummary]) -> String {
        DownloadPolicy.byteCount(Int64(DownloadPolicy.total(summaries.map(\.bytes))))
    }
}
