/// The fixed words of the aircraft list, editor and weight and balance screens. Both apps only lay these out.
public enum AircraftPages {
    /// One number or text field. `key` is the `AircraftProfile` JSON key it edits.
    public struct Field: Encodable, Equatable, Sendable {
        public var key: String
        public var title: String
        public var unit: String?
        public var number = true
        /// Blank sends 0 (or empty text) because the profile always carries it.
        public var required = false
    }

    public struct Section: Encodable, Equatable, Sendable {
        public var title: String
        public var fields: [Field]
    }

    public static let title = "Aircraft"
    public static let add = "Add Aircraft"
    public static let blank = "Blank"
    public static let importFile = "Import"
    public static let export = "Export"
    public static let delete = "Delete"
    public static let save = "Save"
    public static let cancel = "Cancel"
    public static let empty = "No aircraft yet. Add one from a template, start blank, or import a file."
    public static let conflict = "An aircraft with this tail number is already here."
    public static let weightBalance = "Weight and Balance"
    public static let stationsTitle = "Stations"
    public static let station = "Station"
    public static let addStation = "Add Station"
    public static let envelopeTitle = "CG Envelope"
    public static let envelopeNote = "Corners in order around the edge, normal category."
    public static let addPoint = "Add Point"
    public static let arm = "Arm"
    public static let weight = "Weight"
    public static let limit = "Limit"
    public static let name = "Name"
    public static let fuelTitle = "Fuel"
    public static let startFuel = "Fuel at start"
    public static let burnedFuel = "Fuel burned"
    public static let burnedNote = "Taxi plus trip fuel. With no trip fuel, all the fuel at start."
    /// The note under Fuel burned; none airborne, where no burn is assumed.
    public static func burnedFooter(airborne: Bool) -> String? { airborne ? nil : burnedNote }
    public static let loadTitle = "Load"
    public static let resultsTitle = "Results"
    public static let lb = "lb"
    public static let inches = "in"
    public static let gal = "gal"
    public static let template = "Template"
    public static let searchTemplates = "Search make or model"
    public static let poh = "POH"
    public static let attachPOH = "Attach POH"
    public static let replacePOH = "Replace POH"
    public static let removePOH = "Remove POH"
    public static let find = "Find"
    public static let pohNote = "Your own copy, kept on this device. Exported aircraft leave it out."
    /// Older versions kept one aircraft for all routes under this key; read once to move it into the flight.
    public static let selectedKey = "selectedAircraft"

    /// The aircraft a flight uses: its own, else the first, so a deleted one falls back.
    public static func flightAircraft(_ id: UUID?, in list: [AircraftProfile]) -> AircraftProfile? {
        list.first { $0.id == id } ?? list.first
    }

    public static let sections: [Section] = [
        Section(title: "Aircraft", fields: [
            Field(key: "tail", title: "Tail number", number: false, required: true),
            Field(key: "type", title: "Type", number: false),
            Field(key: "engine", title: "Engine", number: false),
        ]),
        Section(title: "Performance", fields: [
            Field(key: "cruiseTASKt", title: RoutePages.speedTitle, unit: "kt"),
            Field(key: "burnGPH", title: RoutePages.burnTitle, unit: "gal/h"),
        ]),
        Section(title: "Climb and Descent", fields: [
            Field(key: "climbRateFPM", title: "Climb rate", unit: "ft/min"),
            Field(key: "climbTASKt", title: "Climb speed", unit: "kt"),
            Field(key: "climbBurnGPH", title: "Climb fuel burn", unit: "gal/h"),
            Field(key: "descentRateFPM", title: "Descent rate", unit: "ft/min"),
            Field(key: "descentTASKt", title: "Descent speed", unit: "kt"),
            Field(key: "descentBurnGPH", title: "Descent fuel burn", unit: "gal/h"),
        ]),
        Section(title: "Fuel", fields: [
            Field(key: "usableFuelGal", title: "Usable fuel", unit: gal),
            Field(key: "taxiFuelGal", title: "Taxi fuel", unit: gal, required: true),
            Field(key: "fuelLbPerGal", title: "Fuel weight", unit: "lb/gal", required: true),
            Field(key: "fuelArmIn", title: "Fuel arm", unit: inches),
        ]),
        Section(title: "Empty Weight", fields: [
            Field(key: "emptyWeightLb", title: "Empty weight", unit: lb),
            Field(key: "emptyArmIn", title: "Empty arm", unit: inches),
        ]),
        Section(title: "Limits", fields: [
            Field(key: "maxRampLb", title: "Max ramp weight", unit: lb),
            Field(key: "maxTakeoffLb", title: "Max takeoff weight", unit: lb),
            Field(key: "maxLandingLb", title: "Max landing weight", unit: lb),
            Field(key: "maxZeroFuelLb", title: "Max zero fuel weight", unit: lb),
        ]),
        Section(title: "Speeds", fields: [
            Field(key: "vneKt", title: "Vne", unit: "kt"),
            Field(key: "vnoKt", title: "Vno", unit: "kt"),
            Field(key: "vaKt", title: "Va", unit: "kt"),
            Field(key: "vfeKt", title: "Vfe", unit: "kt"),
        ]),
    ]

    /// What a profile still needs before weight and balance can be worked out, as one sentence.
    public static func needs(_ missing: [String]) -> String? {
        guard !missing.isEmpty else { return nil }
        let list = missing.count == 1 ? missing[0]
            : missing.dropLast().joined(separator: ", ") + " and " + missing[missing.count - 1]
        return "Fill in the \(list) to work out weight and balance."
    }

    // MARK: iOS extras

    public static let newTitle = "New Aircraft"
    public static let tailPrompt = "N12345"
    public static let importFailed = "Could not import"
    public static let performanceNote = RoutePages.aircraftNote
    public static let noAircraft = "Add an aircraft in Settings, Aircraft, for weight and balance."
    public static let chartArm = "CG, in"
    public static let chartWeight = "Weight, lb"

    /// What lists and pickers call the aircraft: its tail, else its type.
    public static func displayName(_ p: AircraftProfile) -> String {
        let tail = p.tail.trimmed
        return tail.isEmpty ? (p.type ?? newTitle) : tail
    }

    /// The line under the name: type, cruise speed and burn as far as known.
    public static func summary(_ p: AircraftProfile) -> String {
        var parts: [String] = []
        if let type = p.type, !type.isEmpty { parts.append(type) }
        if let kt = p.cruiseTASKt { parts.append("\(Int(kt.rounded())) kt") }
        if let gph = p.burnGPH { parts.append(NavText.fixed(gph, 1) + " gal/h") }
        return parts.joined(separator: " · ")
    }

    /// Fuel burned when the pilot types none: taxi fuel plus the route's trip fuel. With no trip fuel known, all the
    /// fuel at start (else the usable fuel), so the burn line is checked down to empty tanks. Airborne, none: the trip
    /// left says nothing of what was burned before.
    public static func burnedDefault(_ p: AircraftProfile, tripFuelGal: Double?, startFuelGal: Double? = nil,
                                     airborne: Bool = false) -> Double? {
        airborne ? nil : tripFuelGal.map { p.taxiFuelGal + $0 } ?? startFuelGal ?? p.usableFuelGal ?? p.taxiFuelGal
    }
}
