import Foundation
import Testing
@testable import FlightCore

/// A 172S from the template with a made-up airplane's record: empty 1663 lb at 39.3 in, front seats at 37.0,
/// baggage areas at 95 and 123, taxi fuel 1.4 gal.
private var skyhawk: AircraftProfile {
    var p = AircraftTemplates.c172s
    p.tail = "N12345"
    p.emptyWeightLb = 1663
    p.emptyArmIn = 39.3
    p.taxiFuelGal = 1.4
    p.stations[0].armIn = 37.0
    p.stations[2].armIn = 95
    p.stations[3].armIn = 123
    return p
}

@Test func skyhawkLoadInLimitsMatchesHandWorkedNumbers() throws {
    // Front 340, baggage 50, full 53 gal, 20 gal burned with taxi.
    let wb = try #require(WeightBalance(profile: skyhawk, stationWeightsLb: [340, 0, 50, 0], burnedGal: 20))
    // Zero fuel 1663 + 340 + 50 = 2053 lb; 65355.9 + 12580 + 4750 = 82685.9 lb-in.
    #expect(abs(wb.zeroFuel.weightLb - 2053) < 1e-9)
    #expect(abs(wb.zeroFuel.momentLbIn - 82685.9) < 1e-6)
    // Ramp adds 318 lb at 48.0: 2371 lb, 97949.9 lb-in.
    #expect(abs(wb.ramp.momentLbIn - 97949.9) < 1e-6)
    // Takeoff less 8.4 lb taxi: 2362.6 lb, 97546.7 lb-in, CG 41.288.
    #expect(abs(wb.takeoff.weightLb - 2362.6) < 1e-9)
    #expect(abs(wb.takeoff.cgIn - 97546.7 / 2362.6) < 1e-9)
    // Landing less 120 lb: 2251 lb, 92189.9 lb-in, CG 40.955; forward limit there is 38.01.
    let landing = try #require(wb.landing)
    #expect(abs(landing.weightLb - 2251) < 1e-9)
    #expect(abs(landing.momentLbIn - 92189.9) < 1e-6)
    #expect(wb.ok, "\(wb.problems)")
    #expect(wb.status == WeightBalance.withinLimits)
    #expect(wb.takeoffInLimits && wb.landingInLimits)
    #expect(wb.rows[2] == NavPages.Line(title: "Takeoff", value: "2,363 lb", detail: "CG 41.29 in · moment 97,547 lb-in"))
    #expect(wb.burnLine.first?.weightLb == wb.takeoff.weightLb)
    #expect(wb.burnLine.last?.weightLb == landing.weightLb)
    #expect(wb.notes.isEmpty)
}

@Test func skyhawkOverweightAndOverfullAreCalledOut() throws {
    let wb = try #require(WeightBalance(profile: skyhawk, stationWeightsLb: [400, 340, 100, 60], startFuelGal: 55,
                                        burnedGal: 10))
    #expect(!wb.ok)
    #expect(wb.status == WeightBalance.outOfLimits)
    #expect(wb.problems.contains("Baggage area 2: 60 lb is over its 50 lb limit."))
    #expect(wb.problems.contains("Fuel at start, 55.0 gal, is over the 53.0 gal usable."))
    #expect(wb.problems.contains { $0.hasPrefix("Ramp weight 2,893 lb is over the 2,558 lb max") })
    #expect(wb.problems.contains { $0.hasPrefix("Takeoff weight") })
    #expect(wb.problems.contains { $0.hasPrefix("Landing weight") })
    #expect(!wb.takeoffInLimits)
}

@Test func blankSeatArmAndMissingRecordAreSaid() throws {
    var p = AircraftTemplates.c172s
    p.tail = "N1"
    #expect(WeightBalance.missing(p) == ["empty weight", "empty arm"])
    #expect(WeightBalance(profile: p, stationWeightsLb: [170], burnedGal: 0) == nil)
    p.emptyWeightLb = 1663
    p.emptyArmIn = 39.3
    let wb = try #require(WeightBalance(profile: p, stationWeightsLb: [170], burnedGal: 0))
    #expect(wb.problems.contains("Front seats: fill in its arm."))
}

@Test func burnPathCatchesAConcaveForwardCornerBothEndsPass() throws {
    // Forward limit 36 at 1600 and 2400 but 40 at 2000. CG stays at 38.0 as 100 gal burns from 2300 to 1700 lb.
    let p = AircraftProfile(
        tail: "N2", usableFuelGal: 100, emptyWeightLb: 1700, emptyArmIn: 38, fuelArmIn: 38,
        envelope: [.init(armIn: 36, weightLb: 1600), .init(armIn: 40, weightLb: 2000), .init(armIn: 36, weightLb: 2400),
                   .init(armIn: 50, weightLb: 2400), .init(armIn: 50, weightLb: 1600)],
        maxRampLb: 2400, maxTakeoffLb: 2400)
    let wb = try #require(WeightBalance(profile: p, stationWeightsLb: [], burnedGal: 100))
    #expect(wb.takeoffInLimits && wb.landingInLimits)
    #expect(wb.problems == ["The CG leaves the envelope as fuel burns."])
    #expect(wb.burnLine.count == 101)
}

// An A36 with a made-up record: empty 2,500 lb at 83.0 in. Burning fuel moves its CG aft and out of the envelope.
@Test func withNoTripFuelTheBurnLineRunsToEmptyTanks() throws {
    var p = AircraftTemplates.named("Beechcraft A36 Bonanza")
    (p.tail, p.emptyWeightLb, p.emptyArmIn, p.taxiFuelGal) = ("N36", 2500, 83.0, 1.5)
    let load: [Double] = [200, 170, 100, 0, 70]
    #expect(AircraftPages.burnedDefault(p, tripFuelGal: nil, startFuelGal: 74) == 74)
    #expect(AircraftPages.burnedDefault(p, tripFuelGal: nil) == p.usableFuelGal)
    #expect(AircraftPages.burnedDefault(p, tripFuelGal: 20, startFuelGal: 74) == 21.5)
    let taxiOnly = try #require(WeightBalance(profile: p, stationWeightsLb: load, startFuelGal: 74, burnedGal: 1.5))
    #expect(taxiOnly.ok)
    let empty = try #require(WeightBalance(profile: p, stationWeightsLb: load, startFuelGal: 74,
                                           burnedGal: AircraftPages.burnedDefault(p, tripFuelGal: nil, startFuelGal: 74)))
    let emptyCG = try #require(empty.landing?.cgIn), taxiCG = try #require(taxiOnly.landing?.cgIn)
    #expect(!empty.ok && empty.status == WeightBalance.outOfLimits && emptyCG > taxiCG)
}

// Airborne the trip left says nothing of what was burned, so with none typed there is no landing condition.
@Test func airborneNoFuelBurnedIsAssumedAndTheLandingIsLeftOut() throws {
    var p = AircraftTemplates.named("Beechcraft A36 Bonanza")
    (p.tail, p.emptyWeightLb, p.emptyArmIn, p.taxiFuelGal) = ("N36", 2500, 83.0, 1.5)
    #expect(AircraftPages.burnedDefault(p, tripFuelGal: 20, startFuelGal: 74, airborne: true) == nil)
    #expect(AircraftPages.burnedDefault(p, tripFuelGal: nil, startFuelGal: 74, airborne: true) == nil)
    let wb = try #require(WeightBalance(profile: p, stationWeightsLb: [200, 170, 100, 0, 70], startFuelGal: 74,
                                        burnedGal: AircraftPages.burnedDefault(p, tripFuelGal: 20, startFuelGal: 74, airborne: true)))
    #expect(wb.landing == nil && wb.landingInLimits && wb.burnLine.isEmpty)
    #expect(wb.rows.map(\.title) == ["Zero fuel", "Ramp", "Takeoff"])
    #expect(!wb.problems.contains { $0.contains("Landing") || $0.contains("burned") })
    #expect(abs(wb.takeoff.weightLb - (wb.ramp.weightLb - 1.5 * p.fuelLbPerGal)) < 1e-9)
    // The takeoff is behind the pilot and the landing unknown, so no verdict; a named problem still says so.
    #expect(wb.ok && wb.status == nil)
    let heavy = try #require(WeightBalance(profile: p, stationWeightsLb: [200, 570, 100, 0, 70], startFuelGal: 74, burnedGal: nil))
    #expect(!heavy.ok && heavy.status == WeightBalance.outOfLimits && heavy.problems.contains { $0.hasPrefix("Takeoff weight") })
    // A typed burn brings the landing and the verdict back.
    let typed = try #require(WeightBalance(profile: p, stationWeightsLb: [200, 170, 100, 0, 70], startFuelGal: 74, burnedGal: 30))
    #expect(typed.landing != nil && typed.rows.count == 4 && !typed.burnLine.isEmpty && typed.status == WeightBalance.withinLimits)
    // The note under Fuel burned describes a default, so it goes when none is offered.
    #expect(AircraftPages.burnedFooter(airborne: false) == AircraftPages.burnedNote && AircraftPages.burnedFooter(airborne: true) == nil)
}

@Test func belowTheChartedEnvelopeIsAmberNotRed() throws {
    var p = skyhawk
    p.emptyWeightLb = 1500
    // Takeoff 1500 + 170 + 120 - 8.4 = 1781.6 lb, under the 1950 lb corner; CG about 40.
    let wb = try #require(WeightBalance(profile: p, stationWeightsLb: [170], startFuelGal: 20, burnedGal: 5))
    #expect(wb.ok, "\(wb.problems)")
    #expect(wb.notes == [WeightBalance.belowChart])
}

@Test func pointInPolygonCountsEdgesAsInside() {
    let square: [(x: Double, y: Double)] = [(0, 0), (10, 0), (10, 10), (0, 10)]
    #expect(Polygon.contains(5, 5, in: square))
    #expect(Polygon.contains(10, 5, in: square))
    #expect(Polygon.contains(0, 0, in: square))
    #expect(!Polygon.contains(10.001, 5, in: square))
    #expect(!Polygon.contains(-1, -1, in: square))
    #expect(!Polygon.contains(.nan, 5, in: square))
    // The 172S forward line from (35, 1950) to (41, 2550): 38.0 at 2250 lies on it.
    let ring = AircraftTemplates.c172s.envelope.map { (x: $0.armIn, y: $0.weightLb) }
    #expect(Polygon.contains(38.0, 2250, in: ring))
    #expect(!Polygon.contains(37.9, 2250, in: ring))
}

@Test func sr22TemplateMatchesTheMetricSheet() {
    // EASA.IM.A.007 Issue 19, Section B, in metres and kilograms.
    let metric: [(m: Double, kg: Double)] = [(3.500, 952), (3.533, 1225), (3.637, 1633), (3.762, 1633), (3.762, 952)]
    let envelope = AircraftTemplates.sr22.envelope
    #expect(envelope.count == metric.count)
    for (point, sheet) in zip(envelope, metric) {
        #expect(abs(point.armIn - sheet.m / 0.0254) < 0.05)
        #expect(abs(point.weightLb - sheet.kg / 0.45359237) < 2)
    }
}

@Test func templatesCarryNoAirplaneRecord() {
    for t in AircraftTemplates.all.map(\.profile) {
        #expect(t.emptyWeightLb == nil && t.emptyArmIn == nil)
    }
}

@Test func exportRoundTrips() throws {
    var p = skyhawk
    p.cruiseTASKt = 120
    p.burnGPH = 8.5
    let file = try p.exported()
    #expect(file.fileName == "N12345.json")
    let back = AircraftProfile.imported(file.data)
    #expect(back.problems.isEmpty)
    #expect(back.profile == p)
    let list = [p, AircraftTemplates.sr22]
    #expect(try AircraftProfile.decodeList(AircraftProfile.encodeList(list)) == list)
}

@Test func importRejectsBadFilesInPlainWords() throws {
    let good = String(decoding: try skyhawk.exported().data, as: UTF8.self)
    let newer = good.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2")
    #expect(newer != good)
    #expect(AircraftProfile.imported(Data(newer.utf8)).problems
        == ["This aircraft file is from a newer version of Blueside. Update the app to open it."])
    #expect(AircraftProfile.imported(Data("{\"format\":\"other\"}".utf8)).problems == ["This file is not a Blueside aircraft."])
    #expect(AircraftProfile.imported(Data("not json".utf8)).problems == ["This file is not a Blueside aircraft."])

    var twoPoint = skyhawk
    twoPoint.envelope.removeLast(2)
    let rejected = AircraftProfile.imported(try twoPoint.exported().data)
    #expect(rejected.profile == nil)
    #expect(rejected.problems == ["The envelope needs 3 or more points."])

    let nan = good.replacingOccurrences(of: "\"emptyWeightLb\" : 1663", with: "\"emptyWeightLb\" : NaN")
    #expect(nan != good)
    // JSON has no NaN, so the file does not parse at all.
    #expect(AircraftProfile.imported(Data(nan.utf8)).problems == ["This file is not a Blueside aircraft."])
    let missing = good.replacingOccurrences(of: "\"taxiFuelGal\"", with: "\"taxi\"")
    #expect(AircraftProfile.imported(Data(missing.utf8)).problems
        == ["This aircraft file could not be read. A value is missing or is not a number."])
    var bad = skyhawk
    bad.emptyArmIn = .nan
    bad.maxRampLb = 0
    #expect(bad.problems == ["Empty arm is not a number.", "Max ramp weight must be above 0."])
}

@Test func importConflictReplaceOrKeepBoth() {
    let mine = skyhawk
    var incoming = skyhawk
    incoming.id = UUID()
    incoming.cruiseTASKt = 115
    #expect(AircraftProfile.conflicts(incoming, in: [mine]))
    #expect(AircraftProfile.adding(incoming, to: [mine], replace: true) == [incoming])
    #expect(AircraftProfile.adding(incoming, to: [mine], replace: false).count == 2)
    // Keeping both of the same file twice gives the copy its own id.
    let both = AircraftProfile.adding(mine, to: [mine], replace: false)
    #expect(both.count == 2 && both[0].id != both[1].id)
}

@Test func oldSpeedAndBurnBecomeOneProfile() {
    #expect(AircraftProfile.migrated(trueAirspeedKt: 0, fuelBurnPerHour: 0) == nil)
    let p = AircraftProfile.migrated(trueAirspeedKt: 110, fuelBurnPerHour: 0)
    #expect(p?.tail == "My aircraft" && p?.cruiseTASKt == 110 && p?.burnGPH == nil)
}

@Test func pagesNameWhatIsMissingAndTheBurnDefault() {
    var p = AircraftTemplates.c172s
    #expect(AircraftPages.displayName(p) == "C172S")
    #expect(AircraftPages.needs(WeightBalance.missing(p)) == "Fill in the empty weight and empty arm to work out weight and balance.")
    p.tail = " N12345 "
    p.emptyWeightLb = 1663
    p.emptyArmIn = 39.3
    p.cruiseTASKt = 122
    p.burnGPH = nil
    p.taxiFuelGal = 1.4
    #expect(AircraftPages.needs(WeightBalance.missing(p)) == nil)
    #expect(AircraftPages.displayName(p) == "N12345")
    #expect(AircraftPages.summary(p) == "C172S · 122 kt")
    #expect(AircraftPages.burnedDefault(p, tripFuelGal: 10) == 11.4)
}

@Test func everyTemplateIsSane() throws {
    let all = AircraftTemplates.all
    #expect(all.count >= 60)
    #expect(Set(all.map(\.title)).count == all.count)
    for t in all {
        let p = t.profile
        let name = t.title
        #expect(p.problems == ["Tail number is empty."], "\(name)")
        #expect(p.source?.hasPrefix("FAA TCDS ") == true && p.source?.contains("Rev. ") == true, "\(name)")
        let top = try #require(p.maxTakeoffLb, "\(name)")
        #expect((800...7000).contains(top), "\(name)")
        if let landing = p.maxLandingLb { #expect(landing <= top, "\(name)") }
        let ramp = try #require(p.maxRampLb, "\(name)")
        #expect(ramp >= top && ramp - top <= 30, "\(name)")
        #expect(!WeightBalance.missing(p).contains("max ramp weight"), "\(name)")
        if let zeroFuel = p.maxZeroFuelLb { #expect(zeroFuel < top, "\(name)") }
        if let usable = p.usableFuelGal { #expect((12...200).contains(usable), "\(name)") }
        let speeds = [p.vfeKt, p.vaKt, p.vnoKt, p.vneKt].compactMap { $0 }
        #expect(speeds.allSatisfy { (50...260).contains($0) }, "\(name)")
        if let vno = p.vnoKt, let vne = p.vneKt { #expect(vno < vne, "\(name)") }
        // The J-3's sheet gives a CG range with no weights, so it carries no envelope.
        guard p.type != "J3C-65" else { #expect(p.envelope.isEmpty); continue }
        let env = p.envelope
        #expect(env.count >= 4, "\(name)")
        let arms = env.map(\.armIn), weights = env.map(\.weightLb)
        // The envelope tops out at max takeoff weight, and every arm sits in a plausible range.
        #expect(weights.max() == top, "\(name)")
        let stationArms = p.stations.compactMap(\.armIn) + [p.fuelArmIn].compactMap { $0 }
        for arm in arms + stationArms { #expect((-30...260).contains(arm), "\(name) arm \(arm)") }
        #expect(arms.max()! - arms.min()! < 25, "\(name)")
        // A simple polygon: nonzero area and no two edges crossing.
        let ring = env.map { (x: $0.armIn, y: $0.weightLb) }
        var area = 0.0
        for i in ring.indices { let a = ring[i], b = ring[(i + 1) % ring.count]; area += a.x * b.y - b.x * a.y }
        #expect(abs(area) > 1, "\(name)")
        func cross(_ o: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        for i in ring.indices {
            for j in ring.indices where j > i + 1 && !(i == 0 && j == ring.count - 1) {
                let (a, b, c, d) = (ring[i], ring[(i + 1) % ring.count], ring[j], ring[(j + 1) % ring.count])
                let crosses = cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0
                #expect(!crosses, "\(name) edges \(i) and \(j) cross")
            }
        }
        // Just under the top, midway across, is inside.
        let topArms = env.filter { $0.weightLb == top }.map(\.armIn)
        #expect(Polygon.contains((topArms.min()! + topArms.max()!) / 2, top - 1, in: ring), "\(name)")
    }
}

@Test func templatesSearchByMakeAndModel() {
    let titles = { (q: String) in AircraftTemplates.all.filter { $0.matches(q) }.map(\.title) }
    #expect(titles("").count == AircraftTemplates.all.count)
    #expect(titles("archer") == ["Piper PA-28-181 Archer II", "Piper PA-28-181 Archer III"])
    #expect(titles("pa28181").count == 2)
    #expect(titles("cessna 182t") == ["Cessna 182T Skylane", "Cessna T182T Turbo Skylane"])
    #expect(titles("diamond da40").count == 2)
    #expect(titles("zz").isEmpty)
}

@Test func theFlightUsesItsAircraftElseTheFirst() {
    let a = AircraftProfile(tail: "N1"), b = AircraftProfile(tail: "N2")
    #expect(AircraftPages.flightAircraft(b.id, in: [a, b])?.tail == "N2")
    #expect(AircraftPages.flightAircraft(nil, in: [a, b])?.tail == "N1")
    #expect(AircraftPages.flightAircraft(UUID(), in: [a, b])?.tail == "N1")
    #expect(AircraftPages.flightAircraft(b.id, in: []) == nil)
}
