import FlightCore

/// Plates ops: an airport's diagram and grouped procedures, and one chart's PDF written to a file.
extension Bridge {
    struct PlatesArgs: Decodable {
        /// The plates pack store folder.
        var store: String
        var ident: String
        var now: Date
    }

    struct PlateRef: Codable, Equatable {
        var airport = ""
        var name: String
        var file: String
        var pack: String
        var geo: PlateGeo?
    }

    struct PlateGroup: Encodable { var title: String; var plates: [PlateRef] }

    struct PlatesResult: Encodable {
        var diagram: PlateRef?
        var groups: [PlateGroup]
        var count: Int
        var diagramTitle = "Airport Diagram"
        var proceduresTitle = "Procedures"
        var unavailable = "Chart unavailable"
        var fullScreen = "Full Screen"
        var showOnMap = "Show on Map"
        var hideOnMap = "Hide on Map"
    }

    struct ExtractArgs: Decodable { var plate: PlateRef; var out: String }

    struct PlatePointArgs: Decodable { var geo: PlateGeo; var latitude: Double; var longitude: Double }

    /// Where ownship sits on the page as [x, y] fractions from top left; nil off the plan view or in a box not to scale.
    static func platePoint(_ a: PlatePointArgs) -> [String: [Double]] {
        a.geo.pagePoint(Coordinate(latitude: a.latitude, longitude: a.longitude)).map { ["point": $0] } ?? [:]
    }

    // The last indexes read, so each airport page does not reread every pack.
    nonisolated(unsafe) private static var loaded: (packs: [URL], byAirport: [String: [Plate]]) = ([], [:])
    private static let loadedLock = Lock()

    static func charts(_ a: PlatesArgs) -> [Plate] {
        let packs = PlateLibrary.packs(installed: PackSession.installedFiles(root: a.store), now: a.now)
        loadedLock.lock()
        defer { loadedLock.unlock() }
        if packs != loaded.packs { loaded = (packs, PlateLibrary.byAirport(packs)) }
        return loaded.byAirport[a.ident] ?? []
    }

    private struct ApproachKey: Equatable {
        var ident: String, navDatabase: String, installed: [PackFile], shown: [URL]
    }

    // The last airport's answer; the nav database is opened again only when the airport, the plates or the nav data change.
    nonisolated(unsafe) private static var approach: (key: ApproachKey, answer: Bool?)?
    private static let approachLock = Lock()

    /// Whether an airport has an instrument approach, from the plates on the device as the core decides it.
    static func hasApproach(_ ident: String, navDatabase: String, plates: String, now: Date) -> Bool? {
        let installed = PackSession.installedFiles(root: plates)
        let key = ApproachKey(ident: ident, navDatabase: navDatabase, installed: installed,
                              shown: PlateLibrary.packs(installed: installed, now: now))
        approachLock.lock()
        defer { approachLock.unlock() }
        if let kept = approach, kept.key == key { return kept.answer }
        let answer = (try? NavDatabase(path: navDatabase).airport(identifier: ident)).flatMap { airport in
            RoutePages.hasApproach(charts(PlatesArgs(store: plates, ident: airport.ident, now: now)),
                                   regionInstalled: installed.contains { $0.pack.id.region == airport.state })
        }
        approach = (key, answer)
        return answer
    }

    static func plates(_ a: PlatesArgs) -> PlatesResult {
        let charts = charts(a)
        let ref = { (p: Plate) in PlateRef(airport: p.airport, name: p.name, file: p.file, pack: p.pack?.path ?? "", geo: p.geo) }
        let procedures = charts.filter { !$0.isDiagram }
        let groups = Plate.Group.allCases.compactMap { group -> PlateGroup? in
            let members = procedures.filter { $0.group == group }
            return members.isEmpty ? nil : PlateGroup(title: group.rawValue, plates: members.map(ref))
        }
        return PlatesResult(diagram: charts.first(where: \.isDiagram).map(ref), groups: groups, count: procedures.count)
    }

    static func plateExtract(_ a: ExtractArgs) -> [String: Bool] {
        let plate = Plate(airport: "", icao: "", name: a.plate.name, code: "", file: a.plate.file, pages: 0,
                          pack: URL(fileURLWithPath: a.plate.pack))
        return ["ok": PlateLibrary.extract(plate, to: URL(fileURLWithPath: a.out))]
    }
}

/// A pthread mutex; NSLock would pull Foundation, and with it ICU, into the Android build.
final class Lock: @unchecked Sendable {
    private let m = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    init() { pthread_mutex_init(m, nil) }
    deinit { pthread_mutex_destroy(m); m.deallocate() }
    func lock() { pthread_mutex_lock(m) }
    func unlock() { pthread_mutex_unlock(m) }
}
