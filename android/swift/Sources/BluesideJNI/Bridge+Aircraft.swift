import FlightCore

/// Aircraft and weight and balance. Kotlin reads and writes aircraft.json as text; the core does the rest.
extension Bridge {
    /// `file` is aircraft.json's text, nil when there is none yet. Old speed and burn migrate into it once.
    struct ListArgs: Decodable { var file: String?; var speed: Double?; var burn: Double? }

    struct AircraftList: Encodable {
        var aircraft: [AircraftProfile]
        var templates: [AircraftTemplate]
        var blank = AircraftProfile(tail: "")
        /// The text to write back to aircraft.json, set when it changed.
        var file: String?
        var problems: [String] = []
        var conflict = false
        var fillInNote = AircraftProfile.fillInNote
        var replace = AircraftProfile.replace
        var keepBoth = AircraftProfile.keepBoth
    }

    /// Saves `profile`, or deletes `delete`.
    struct SaveArgs: Decodable { var file: String?; var profile: AircraftProfile?; var delete: UUID? }

    /// `text` is the opened file. With a tail already in the list, `replace` nil asks first.
    struct ImportArgs: Decodable { var file: String?; var text: String; var replace: Bool? }

    /// `burned` nil takes the default with no trip fuel known; `airborne`, the core's rule on the fix as W&B opens, takes none.
    struct WeightArgs: Decodable {
        var profile: AircraftProfile
        var weights: [Double]
        var startFuel: Double?
        var burned: Double?
        var airborne: Bool?
    }

    struct WeightResult: Encodable {
        var balance: WeightBalance?
        /// The fuel burned the balance used; nil airborne with none typed.
        var burned: Double?
        var missing: [String]
        var missingNote: String?
        /// The note under Fuel burned; nil airborne.
        var burnedNote: String?
        var takeoffLabel = WeightBalance.takeoffLabel
        var landingLabel = WeightBalance.landingLabel
    }

    /// The fixed words of the aircraft screens.
    struct AircraftLabels: Encodable {
        var title = AircraftPages.title, add = AircraftPages.add, blank = AircraftPages.blank
        var importFile = AircraftPages.importFile, export = AircraftPages.export, delete = AircraftPages.delete
        var save = AircraftPages.save, cancel = AircraftPages.cancel
        var empty = AircraftPages.empty, conflict = AircraftPages.conflict, weightBalance = AircraftPages.weightBalance
        var stationsTitle = AircraftPages.stationsTitle, station = AircraftPages.station, addStation = AircraftPages.addStation
        var envelopeTitle = AircraftPages.envelopeTitle, envelopeNote = AircraftPages.envelopeNote
        var addPoint = AircraftPages.addPoint, arm = AircraftPages.arm, weight = AircraftPages.weight
        var limit = AircraftPages.limit, name = AircraftPages.name, fuelTitle = AircraftPages.fuelTitle
        var startFuel = AircraftPages.startFuel, burnedFuel = AircraftPages.burnedFuel
        var loadTitle = AircraftPages.loadTitle, resultsTitle = AircraftPages.resultsTitle
        var lb = AircraftPages.lb, inches = AircraftPages.inches, gal = AircraftPages.gal
        var selectedKey = AircraftPages.selectedKey, sections = AircraftPages.sections
        var fillInNote = AircraftProfile.fillInNote, replace = AircraftProfile.replace, keepBoth = AircraftProfile.keepBoth
        var belowChart = WeightBalance.belowChart
        var template = AircraftPages.template, searchTemplates = AircraftPages.searchTemplates, poh = AircraftPages.poh
        var attachPOH = AircraftPages.attachPOH, replacePOH = AircraftPages.replacePOH, removePOH = AircraftPages.removePOH
        var pohNote = AircraftPages.pohNote
    }

    static func list(_ file: String?) throws -> [AircraftProfile] {
        guard let file, !file.isEmpty else { return [] }
        return try AircraftProfile.decodeList(Data(file.utf8))
    }

    static func listed(_ list: [AircraftProfile], changed: Bool) throws -> AircraftList {
        AircraftList(aircraft: list, templates: AircraftTemplates.all,
                     file: changed ? String(decoding: try AircraftProfile.encodeList(list), as: UTF8.self) : nil)
    }

    static func aircraftCall(_ op: String, _ args: Data) throws -> (any Encodable)? {
        func arg<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(type, from: args) }
        switch op {
        case "aircraftList":
            let a = try arg(ListArgs.self)
            var aircraft = try list(a.file)
            let migrated = aircraft.isEmpty
                ? AircraftProfile.migrated(trueAirspeedKt: a.speed ?? 0, fuelBurnPerHour: a.burn ?? 0) : nil
            if let migrated { aircraft = [migrated] }
            return try listed(aircraft, changed: migrated != nil)
        case "aircraftSave":
            let a = try arg(SaveArgs.self)
            var aircraft = try list(a.file)
            if let id = a.delete { aircraft.removeAll { $0.id == id } }
            if let profile = a.profile {
                let problems = profile.problems
                guard problems.isEmpty else {
                    var out = try listed(aircraft, changed: false)
                    out.problems = problems
                    return out
                }
                aircraft = AircraftProfile.saving(profile, in: aircraft)
            }
            return try listed(aircraft, changed: true)
        case "aircraftImport":
            let a = try arg(ImportArgs.self)
            let aircraft = try list(a.file)
            let read = AircraftProfile.imported(Data(a.text.utf8))
            guard let profile = read.profile else {
                var out = try listed(aircraft, changed: false)
                out.problems = read.problems
                return out
            }
            if a.replace == nil && AircraftProfile.conflicts(profile, in: aircraft) {
                var out = try listed(aircraft, changed: false)
                out.conflict = true
                return out
            }
            return try listed(AircraftProfile.adding(profile, to: aircraft, replace: a.replace ?? false), changed: true)
        case "aircraftExport":
            let file = try decoder.decode(AircraftProfile.self, from: args).exported()
            return ["name": file.fileName, "text": String(decoding: file.data, as: UTF8.self)]
        case "weightBalance":
            let a = try arg(WeightArgs.self)
            let burned = a.burned ?? AircraftPages.burnedDefault(a.profile, tripFuelGal: nil, startFuelGal: a.startFuel,
                                                                 airborne: a.airborne ?? false)
            return WeightResult(
                balance: WeightBalance(profile: a.profile, stationWeightsLb: a.weights, startFuelGal: a.startFuel,
                                       burnedGal: burned),
                burned: burned,
                missing: WeightBalance.missing(a.profile), missingNote: AircraftPages.needs(WeightBalance.missing(a.profile)),
                burnedNote: AircraftPages.burnedFooter(airborne: a.airborne ?? false))
        case "aircraftLabels": return AircraftLabels()
        default: return nil
        }
    }
}
