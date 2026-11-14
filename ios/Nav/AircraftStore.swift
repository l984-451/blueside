import FlightCore
import Foundation
import Observation

/// The aircraft list in Application Support/aircraft.json. The core does every check.
@MainActor @Observable final class AircraftStore {
    private(set) var list: [AircraftProfile] = []
    /// Station weights and fuel typed on the weight and balance page, by aircraft, kept beside aircraft.json.
    var loads: [UUID: Load] = [:] {
        didSet { try? JSONEncoder().encode(loads).write(to: loadsFile, options: .atomic) }
    }
    /// Aircraft with the pilot's own POH attached, as POH/<id>.pdf beside aircraft.json.
    private(set) var pohs: Set<UUID> = []
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let defaults: UserDefaults

    typealias Load = FlightLoad

    enum Import: Equatable { case added, conflict(AircraftProfile), problems([String]) }

    static var defaultFile: URL {
        URL.applicationSupportDirectory.appendingPathComponent("aircraft.json")
    }

    init(file: URL = AircraftStore.defaultFile, defaults: UserDefaults = .standard) {
        self.file = file
        self.defaults = defaults
        if let data = try? Data(contentsOf: file), let saved = try? AircraftProfile.decodeList(data) { list = saved }
        if let data = try? Data(contentsOf: loadsFile), let saved = try? JSONDecoder().decode([UUID: Load].self, from: data) {
            loads = saved
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pohFolder.path)) ?? []
        pohs = Set(names.compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) })
        migrate()
        if let old = defaults.string(forKey: AircraftPages.selectedKey) {
            if flightAircraftID == nil, let id = UUID(uuidString: old) { setFlightAircraft(id) }
            defaults.removeObject(forKey: AircraftPages.selectedKey)
        }
    }

    /// The aircraft a flight with this id flies.
    func aircraft(for id: UUID?) -> AircraftProfile? { AircraftPages.flightAircraft(id, in: list) }

    /// Saves when the core finds nothing wrong; otherwise returns what is wrong.
    func save(_ profile: AircraftProfile) -> [String] {
        let problems = profile.problems
        guard problems.isEmpty else { return problems }
        let isNew = !list.contains { $0.id == profile.id }
        write(AircraftProfile.saving(profile, in: list))
        // A newly added aircraft is the one the pilot means to fly.
        if isNew { setFlightAircraft(profile.id) }
        return []
    }

    func delete(_ id: UUID) {
        write(list.filter { $0.id != id })
        loads[id] = nil
        removePOH(id)
    }

    private var pohFolder: URL { file.deletingLastPathComponent().appendingPathComponent("POH") }

    // Named after the list file, so each list keeps its own loads. Written through a temporary file and a rename.
    private var loadsFile: URL {
        file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-loads.json")
    }

    func poh(_ id: UUID) -> URL? { pohs.contains(id) ? pohFolder.appendingPathComponent(id.uuidString + ".pdf") : nil }

    /// Copies the picked PDF in, replacing any earlier one. False when it could not be read.
    func attachPOH(_ source: URL, to id: UUID) async -> Bool {
        let folder = pohFolder
        let copied = await Task.detached {
            let opened = source.startAccessingSecurityScopedResource()
            defer { if opened { source.stopAccessingSecurityScopedResource() } }
            let out = folder.appendingPathComponent(id.uuidString + ".pdf")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: out)
            return (try? FileManager.default.copyItem(at: source, to: out)) != nil
        }.value
        if copied { pohs.insert(id) }
        return copied
    }

    func removePOH(_ id: UUID) {
        try? FileManager.default.removeItem(at: pohFolder.appendingPathComponent(id.uuidString + ".pdf"))
        pohs.remove(id)
    }

    /// Reads a shared file. With a tail already in the list, `replace` nil asks first.
    func importFile(_ data: Data, replace: Bool? = nil) -> Import {
        let read = AircraftProfile.imported(data)
        guard let profile = read.profile else { return .problems(read.problems) }
        if replace == nil && AircraftProfile.conflicts(profile, in: list) { return .conflict(profile) }
        write(AircraftProfile.adding(profile, to: list, replace: replace ?? false))
        return .added
    }

    func add(_ profile: AircraftProfile, replace: Bool) {
        write(AircraftProfile.adding(profile, to: list, replace: replace))
    }

    private var flightAircraftID: UUID? {
        RoutePages.planInputs(stored: defaults.data(forKey: RoutePages.planInputsKey), now: .now).aircraftID
    }

    // Writes the stored flight inputs the route panel reads.
    private func setFlightAircraft(_ id: UUID) {
        var inputs = RoutePages.planInputs(stored: defaults.data(forKey: RoutePages.planInputsKey), now: .now)
        inputs.aircraftID = id
        defaults.set(RoutePages.storing(inputs), forKey: RoutePages.planInputsKey)
    }

    // The two numbers older versions kept become one profile, once.
    private func migrate() {
        let old = (RoutePages.speedKey, RoutePages.burnKey)
        guard defaults.object(forKey: old.0) != nil || defaults.object(forKey: old.1) != nil else { return }
        if list.isEmpty, let profile = AircraftProfile.migrated(trueAirspeedKt: defaults.double(forKey: old.0),
                                                                 fuelBurnPerHour: defaults.double(forKey: old.1)) {
            write([profile])
        }
        defaults.removeObject(forKey: old.0)
        defaults.removeObject(forKey: old.1)
    }

    private func write(_ new: [AircraftProfile]) {
        list = new
        // ponytail: a failed write keeps the list in memory only; surface it if disks ever fill up.
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? AircraftProfile.encodeList(new).write(to: file, options: .atomic)
    }
}
