/// Weight and balance for one load: four points, every limit check in plain words, and what to draw.
public struct WeightBalance: Equatable, Sendable, Encodable {
    public struct Point: Equatable, Sendable, Encodable {
        public var weightLb: Double
        public var momentLbIn: Double
        public var cgIn: Double

        init(weightLb: Double, momentLbIn: Double) {
            self.weightLb = weightLb
            self.momentLbIn = momentLbIn
            cgIn = momentLbIn / weightLb
        }

        func adding(_ lb: Double, at arm: Double) -> Point {
            Point(weightLb: weightLb + lb, momentLbIn: momentLbIn + lb * arm)
        }
    }

    public var zeroFuel: Point
    public var ramp: Point
    public var takeoff: Point
    /// Nil without a fuel burned, so no landing condition is shown.
    public var landing: Point?
    /// Failed limits, red.
    public var problems: [String]
    /// Below the charted envelope, amber.
    public var notes: [String]
    public var takeoffInLimits: Bool
    /// True without a landing point.
    public var landingInLimits: Bool
    public var envelope: [AircraftProfile.EnvelopePoint]
    /// CG and weight every gallon from takeoff to landing.
    public var burnLine: [AircraftProfile.EnvelopePoint]
    public var rows: [NavPages.Line]
    /// Nil without a landing point while nothing is wrong: the takeoff is behind the pilot and the landing unknown.
    public var status: String?
    public var ok: Bool

    public static let withinLimits = "Within limits"
    public static let outOfLimits = "Out of limits"
    public static let takeoffLabel = "T"
    public static let landingLabel = "L"
    public static let belowChart = "Below the charted envelope"

    /// The fields a profile still needs before weight and balance can be worked out, in plain words.
    public static func missing(_ profile: AircraftProfile) -> [String] {
        var out: [String] = []
        if profile.emptyWeightLb == nil { out.append("empty weight") }
        if profile.emptyArmIn == nil { out.append("empty arm") }
        if profile.fuelArmIn == nil { out.append("fuel arm") }
        if profile.usableFuelGal == nil { out.append("usable fuel") }
        if profile.maxRampLb == nil { out.append("max ramp weight") }
        if profile.maxTakeoffLb == nil { out.append("max takeoff weight") }
        if profile.envelope.count < 3 { out.append("envelope") }
        return out
    }

    /// Nil when the profile is missing a field (see `missing`) or has a bad number.
    /// Station weights line up with the profile's stations; fuel burned includes taxi fuel. Nil fuel burned leaves out
    /// the landing point, its checks and the burn line.
    public init?(profile p: AircraftProfile, stationWeightsLb: [Double], startFuelGal: Double? = nil, burnedGal: Double?) {
        guard Self.missing(p).isEmpty, p.problems.isEmpty, let empty = p.emptyWeightLb, let emptyArm = p.emptyArmIn,
              let fuelArm = p.fuelArmIn, let usable = p.usableFuelGal, let maxRamp = p.maxRampLb,
              let maxTakeoff = p.maxTakeoffLb else { return nil }
        let start = startFuelGal ?? usable
        var problems: [String] = []
        let lb = { (value: Double) in NavText.grouped(Int(value.rounded())) + " lb" }
        let gal = { (value: Double) in NavText.fuel(value) }

        var zeroFuel = Point(weightLb: empty, momentLbIn: empty * emptyArm)
        for (i, station) in p.stations.enumerated() {
            let weight = i < stationWeightsLb.count ? stationWeightsLb[i] : 0
            guard weight != 0 else { continue }
            guard weight.isFinite, weight > 0 else { problems.append("\(station.name): weight must be above 0."); continue }
            guard let arm = station.armIn else { problems.append("\(station.name): fill in its arm."); continue }
            if let max = station.maxLb, weight > max {
                problems.append("\(station.name): \(lb(weight)) is over its \(lb(max)) limit.")
            }
            zeroFuel = zeroFuel.adding(weight, at: arm)
        }
        let perGal = p.fuelLbPerGal
        let burned = burnedGal.map { $0.isFinite ? max($0, 0) : 0 }
        let taxi = min(p.taxiFuelGal, burned ?? .infinity, max(start, 0))
        let fuelOK = start.isFinite && start >= 0
        if !fuelOK { problems.append("Fuel at start must be 0 or more.") }
        let startFuel = fuelOK ? start : 0
        if startFuel > usable { problems.append("Fuel at start, \(gal(startFuel)), is over the \(gal(usable)) usable.") }
        if let burned, burned > startFuel { problems.append("Fuel burned, \(gal(burned)), is more than the fuel at start.") }

        let ramp = zeroFuel.adding(startFuel * perGal, at: fuelArm)
        let takeoff = ramp.adding(-taxi * perGal, at: fuelArm)
        let landing = burned.map { ramp.adding(-min($0, startFuel) * perGal, at: fuelArm) }

        if ramp.weightLb > maxRamp { problems.append("Ramp weight \(lb(ramp.weightLb)) is over the \(lb(maxRamp)) max.") }
        if takeoff.weightLb > maxTakeoff {
            problems.append("Takeoff weight \(lb(takeoff.weightLb)) is over the \(lb(maxTakeoff)) max.")
        }
        if let max = p.maxLandingLb, let landing, landing.weightLb > max {
            problems.append("Landing weight \(lb(landing.weightLb)) is over the \(lb(max)) max.")
        }
        if let max = p.maxZeroFuelLb, zeroFuel.weightLb > max {
            problems.append("Zero fuel weight \(lb(zeroFuel.weightLb)) is over the \(lb(max)) max.")
        }

        let ring = p.envelope.map { (x: $0.armIn, y: $0.weightLb) }
        let floor = p.envelope.map(\.weightLb).min() ?? 0
        let roof = p.envelope.map(\.weightLb).max() ?? 0
        var below = false
        // Under the lowest charted weight the CG is tested against the bottom edge and flagged amber.
        func inside(_ point: Point) -> Bool {
            if point.weightLb < floor { below = true }
            // Over the top is already a weight problem; the CG is judged at the top edge.
            let weight = min(max(point.weightLb, floor), roof)
            return Polygon.contains(point.cgIn, weight, in: ring)
        }
        let takeoffIn = inside(takeoff)
        let landingIn = landing.map(inside) ?? true
        if !takeoffIn { problems.append("Takeoff CG \(Self.inches(takeoff.cgIn)) is outside the envelope.") }
        if let landing, !landingIn { problems.append("Landing CG \(Self.inches(landing.cgIn)) is outside the envelope.") }

        // CG moves along a curve as fuel burns, so a concave corner can catch a midpoint even when both ends pass.
        var line: [AircraftProfile.EnvelopePoint] = []
        var pathIn = true
        if let burned {
            let fromGal = startFuel - taxi
            let toGal = startFuel - min(burned, startFuel)
            let step = max(1, (fromGal - toGal) / 1000)
            var fuel = fromGal
            while true {
                let point = zeroFuel.adding(fuel * perGal, at: fuelArm)
                line.append(.init(armIn: point.cgIn, weightLb: point.weightLb))
                if !inside(point) { pathIn = false }
                if fuel <= toGal { break }
                fuel = max(fuel - step, toGal)
            }
        }
        if takeoffIn && landingIn && !pathIn { problems.append("The CG leaves the envelope as fuel burns.") }

        self.zeroFuel = zeroFuel
        self.ramp = ramp
        self.takeoff = takeoff
        self.landing = landing
        self.problems = problems
        notes = below ? [Self.belowChart] : []
        takeoffInLimits = takeoffIn && takeoff.weightLb <= maxTakeoff
        landingInLimits = landingIn && (landing?.weightLb ?? 0) <= (p.maxLandingLb ?? .infinity)
        envelope = p.envelope
        burnLine = line
        ok = problems.isEmpty
        status = !ok ? Self.outOfLimits : landing == nil ? nil : Self.withinLimits
        let points = [("Zero fuel", zeroFuel), ("Ramp", ramp), ("Takeoff", takeoff)] + (landing.map { [("Landing", $0)] } ?? [])
        rows = points.map { title, point in
            NavPages.Line(title: title, value: lb(point.weightLb),
                          detail: "CG \(Self.inches(point.cgIn)) · moment \(NavText.grouped(Int(point.momentLbIn.rounded()))) lb-in")
        }
    }

    static func inches(_ value: Double) -> String { NavText.fixed(value, 2) + " in" }
}
