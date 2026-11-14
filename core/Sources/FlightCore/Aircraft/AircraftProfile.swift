/// One airplane: what the route needs for time and fuel, and what weight and balance needs. US units only.
public struct AircraftProfile: Codable, Equatable, Sendable, Identifiable {
    /// A seat row or baggage area. A blank arm means the pilot has to fill it in from the POH.
    public struct Station: Codable, Equatable, Sendable {
        public var name: String
        public var armIn: Double?
        public var maxLb: Double?
        /// Shown under a blank or adjustable arm, such as the range the sheet gives.
        public var hint: String?

        public init(name: String, armIn: Double? = nil, maxLb: Double? = nil, hint: String? = nil) {
            self.name = name
            self.armIn = armIn
            self.maxLb = maxLb
            self.hint = hint
        }
    }

    public struct EnvelopePoint: Codable, Equatable, Sendable {
        public var armIn: Double
        public var weightLb: Double

        public init(armIn: Double, weightLb: Double) {
            self.armIn = armIn
            self.weightLb = weightLb
        }
    }

    public var id: UUID
    public var tail: String
    public var type: String?
    public var engine: String?
    public var cruiseTASKt: Double?
    public var burnGPH: Double?
    /// Typed from the POH; the plan counts climb and descent only when all six are given.
    public var climbRateFPM: Double?
    public var climbTASKt: Double?
    public var climbBurnGPH: Double?
    public var descentRateFPM: Double?
    public var descentTASKt: Double?
    public var descentBurnGPH: Double?
    public var usableFuelGal: Double?
    public var taxiFuelGal: Double
    public var fuelLbPerGal: Double
    public var emptyWeightLb: Double?
    public var emptyArmIn: Double?
    public var stations: [Station]
    public var fuelArmIn: Double?
    /// Closed polygon, normal category, in order around the edge.
    public var envelope: [EnvelopePoint]
    public var maxRampLb: Double?
    public var maxTakeoffLb: Double?
    public var maxLandingLb: Double?
    public var maxZeroFuelLb: Double?
    /// Airspeed limits in knots, as the type certificate gives them; its source says CAS or IAS.
    public var vneKt: Double?
    public var vnoKt: Double?
    public var vaKt: Double?
    public var vfeKt: Double?
    /// Where a template's limits come from.
    public var source: String?

    public init(id: UUID = UUID(), tail: String, type: String? = nil, engine: String? = nil, cruiseTASKt: Double? = nil, burnGPH: Double? = nil,
                usableFuelGal: Double? = nil, taxiFuelGal: Double = 0, fuelLbPerGal: Double = 6,
                emptyWeightLb: Double? = nil, emptyArmIn: Double? = nil, stations: [Station] = [],
                fuelArmIn: Double? = nil, envelope: [EnvelopePoint] = [], maxRampLb: Double? = nil,
                maxTakeoffLb: Double? = nil, maxLandingLb: Double? = nil, maxZeroFuelLb: Double? = nil,
                vneKt: Double? = nil, vnoKt: Double? = nil, vaKt: Double? = nil, vfeKt: Double? = nil,
                source: String? = nil, climbRateFPM: Double? = nil, climbTASKt: Double? = nil, climbBurnGPH: Double? = nil,
                descentRateFPM: Double? = nil, descentTASKt: Double? = nil, descentBurnGPH: Double? = nil) {
        self.id = id
        self.tail = tail
        self.type = type
        self.engine = engine
        self.cruiseTASKt = cruiseTASKt
        self.burnGPH = burnGPH
        self.usableFuelGal = usableFuelGal
        self.taxiFuelGal = taxiFuelGal
        self.fuelLbPerGal = fuelLbPerGal
        self.emptyWeightLb = emptyWeightLb
        self.emptyArmIn = emptyArmIn
        self.stations = stations
        self.fuelArmIn = fuelArmIn
        self.envelope = envelope
        self.maxRampLb = maxRampLb
        self.maxTakeoffLb = maxTakeoffLb
        self.maxLandingLb = maxLandingLb
        self.maxZeroFuelLb = maxZeroFuelLb
        (self.vneKt, self.vnoKt, self.vaKt, self.vfeKt) = (vneKt, vnoKt, vaKt, vfeKt)
        self.source = source
        (self.climbRateFPM, self.climbTASKt, self.climbBurnGPH) = (climbRateFPM, climbTASKt, climbBurnGPH)
        (self.descentRateFPM, self.descentTASKt, self.descentBurnGPH) = (descentRateFPM, descentTASKt, descentBurnGPH)
    }

    /// Climb and descent for the plan; nil unless all six numbers are typed.
    public var vertical: FlightPlan.Vertical? {
        guard let cr = climbRateFPM, let ct = climbTASKt, let cb = climbBurnGPH,
              let dr = descentRateFPM, let dt = descentTASKt, let db = descentBurnGPH else { return nil }
        return FlightPlan.Vertical(climb: .init(rateFPM: cr, tasKt: ct, burnGPH: cb),
                                   descent: .init(rateFPM: dr, tasKt: dt, burnGPH: db))
    }

    public static let fillInNote = "Fill in from your airplane's weight and balance record and POH."
    public static let migratedTail = "My aircraft"
    public static let replace = "Replace"
    public static let keepBoth = "Keep both"
    public static let format = "blueside-aircraft"
    public static let version = 1

    /// What is wrong with the profile, in plain words. Empty when it can be saved.
    public var problems: [String] {
        var out: [String] = []
        if tail.trimmed.isEmpty { out.append("Tail number is empty.") }
        let numbers: [(String, Double?)] = [
            ("Cruise speed", cruiseTASKt), ("Fuel burn", burnGPH), ("Usable fuel", usableFuelGal),
            ("Taxi fuel", taxiFuelGal), ("Fuel weight per gallon", fuelLbPerGal), ("Empty weight", emptyWeightLb),
            ("Empty arm", emptyArmIn), ("Fuel arm", fuelArmIn), ("Max ramp weight", maxRampLb),
            ("Max takeoff weight", maxTakeoffLb), ("Max landing weight", maxLandingLb),
            ("Max zero fuel weight", maxZeroFuelLb), ("Vne", vneKt), ("Vno", vnoKt), ("Va", vaKt), ("Vfe", vfeKt),
            ("Climb rate", climbRateFPM), ("Climb speed", climbTASKt), ("Climb fuel burn", climbBurnGPH),
            ("Descent rate", descentRateFPM), ("Descent speed", descentTASKt), ("Descent fuel burn", descentBurnGPH),
        ] + stations.flatMap { [("\($0.name) arm", $0.armIn), ("\($0.name) limit", $0.maxLb)] }
            + envelope.flatMap { [("Envelope arm", $0.armIn), ("Envelope weight", $0.weightLb)] }
        for (name, value) in numbers {
            guard let value else { continue }
            if !value.isFinite { out.append("\(name) is not a number.") }
        }
        let positive: [(String, Double?)] = [
            ("Fuel weight per gallon", fuelLbPerGal), ("Empty weight", emptyWeightLb), ("Max ramp weight", maxRampLb),
            ("Max takeoff weight", maxTakeoffLb), ("Max landing weight", maxLandingLb),
            ("Max zero fuel weight", maxZeroFuelLb), ("Vne", vneKt), ("Vno", vnoKt), ("Va", vaKt), ("Vfe", vfeKt),
        ] + stations.map { ("\($0.name) limit", $0.maxLb) } + envelope.map { ("Envelope weight", $0.weightLb) }
        for (name, value) in positive {
            if let value, value.isFinite, value <= 0 { out.append("\(name) must be above 0.") }
        }
        for (name, value) in [("Cruise speed", cruiseTASKt), ("Fuel burn", burnGPH), ("Usable fuel", usableFuelGal),
                              ("Taxi fuel", Optional(taxiFuelGal)), ("Climb rate", climbRateFPM),
                              ("Climb speed", climbTASKt), ("Climb fuel burn", climbBurnGPH), ("Descent rate", descentRateFPM),
                              ("Descent speed", descentTASKt), ("Descent fuel burn", descentBurnGPH)] {
            if let value, value.isFinite, value < 0 { out.append("\(name) cannot be below 0.") }
        }
        if !envelope.isEmpty && envelope.count < 3 { out.append("The envelope needs 3 or more points.") }
        return out
    }

    /// Builds one profile from the two numbers older versions kept, when either was set.
    public static func migrated(trueAirspeedKt: Double, fuelBurnPerHour: Double) -> AircraftProfile? {
        let speed = trueAirspeedKt.isFinite && trueAirspeedKt > 0 ? trueAirspeedKt : nil
        let burn = fuelBurnPerHour.isFinite && fuelBurnPerHour > 0 ? fuelBurnPerHour : nil
        guard speed != nil || burn != nil else { return nil }
        return AircraftProfile(tail: migratedTail, cruiseTASKt: speed, burnGPH: burn)
    }

    // MARK: Storage and transfer

    /// The on-device list, aircraft.json.
    public static func encodeList(_ list: [AircraftProfile]) throws -> Data { try encoder.encode(list) }

    public static func decodeList(_ data: Data) throws -> [AircraftProfile] {
        try JSONDecoder().decode([AircraftProfile].self, from: data)
    }

    private struct Wrapper: Codable {
        var format: String
        var version: Int
        var aircraft: AircraftProfile
    }

    /// One aircraft for sharing, as N12345.json.
    public func exported() throws -> (fileName: String, data: Data) {
        let name = tail.trimmed.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " }
        let data = try Self.encoder.encode(Wrapper(format: Self.format, version: Self.version, aircraft: self))
        return ((name.isEmpty ? "Aircraft" : name) + ".json", data)
    }

    /// Reads a shared file. Either the aircraft or plain-word problems, never both.
    public static func imported(_ data: Data) -> (profile: AircraftProfile?, problems: [String]) {
        struct Head: Decodable { var format: String?; var version: Int? }
        guard let head = try? JSONDecoder().decode(Head.self, from: data), head.format == format else {
            return (nil, ["This file is not a Blueside aircraft."])
        }
        guard head.version == version else {
            return (nil, ["This aircraft file is from a newer version of Blueside. Update the app to open it."])
        }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else {
            return (nil, ["This aircraft file could not be read. A value is missing or is not a number."])
        }
        let problems = wrapper.aircraft.problems
        return problems.isEmpty ? (wrapper.aircraft, []) : (nil, problems)
    }

    /// Whether an imported aircraft's tail is already in the list, so the app asks Replace or Keep both.
    public static func conflicts(_ profile: AircraftProfile, in list: [AircraftProfile]) -> Bool {
        list.contains { $0.tail.trimmed.uppercased() == profile.tail.trimmed.uppercased() }
    }

    /// Adds an imported aircraft. Replace swaps out any with the same tail; otherwise it joins under a new id.
    public static func adding(_ profile: AircraftProfile, to list: [AircraftProfile], replace: Bool) -> [AircraftProfile] {
        let tail = profile.tail.trimmed.uppercased()
        guard replace, let at = list.firstIndex(where: { $0.tail.trimmed.uppercased() == tail }) else {
            var copy = profile
            if list.contains(where: { $0.id == profile.id }) { copy.id = UUID() }
            return list + [copy]
        }
        var out = list.filter { $0.tail.trimmed.uppercased() != tail }
        out.insert(profile, at: min(at, out.count))
        return out
    }

    /// Saves an edit in place, or appends a new aircraft.
    public static func saving(_ profile: AircraftProfile, in list: [AircraftProfile]) -> [AircraftProfile] {
        guard let at = list.firstIndex(where: { $0.id == profile.id }) else { return list + [profile] }
        var out = list
        out[at] = profile
        return out
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }
}
