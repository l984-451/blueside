import Testing
@testable import FlightCore

private func airport(_ ident: String, _ lat: Double, _ lon: Double, elev: Double, variation: String?) -> Airport {
    Airport(id: 1, ident: ident, icao: "K" + ident, name: ident, city: "", state: "AL", type: "A", use: "PU",
            coordinate: Coordinate(latitude: lat, longitude: lon), elevationFt: elev, magneticVariation: variation,
            patternAltitude: nil, tower: "NON-ATCT", fuel: nil, artcc: nil, status: "O")
}

private func end(_ id: String, _ hdg: Int?, _ lat: Double?, _ lon: Double?, displaced: Int? = nil) -> RunwayEnd {
    RunwayEnd(id: id, trueHeading: hdg, rightTraffic: nil,
              coordinate: lat.flatMap { la in lon.map { Coordinate(latitude: la, longitude: $0) } },
              elevationFt: nil, displacedThresholdFt: displaced, vgsi: nil, approachLights: nil, toraFt: nil, ldaFt: nil)
}

private func runway(_ id: String, _ length: Int, _ width: Int, _ surface: String, _ ends: [RunwayEnd]) -> Runway {
    Runway(id: id, lengthFt: length, widthFt: width, surface: surface, condition: "GOOD", lights: "MED", ends: ends)
}

/// KEET, Shelby County AL, as the October 2026 NASR files it.
let keet = AirportDetail(
    airport: airport("EET", 33.17777777, -86.78322222, elev: 585.6, variation: "3W"),
    runways: [runway("16/34", 5000, 75, "ASPH", [end("16", 157, 33.18411386, -86.78637688),
                                                 end("34", 337, 33.17144422, -86.78004994)])],
    frequencies: [], remarks: [])

/// KBHM's two runways, as filed.
let bhm = AirportDetail(
    airport: airport("BHM", 33.56388888, -86.75230555, elev: 650, variation: "3W"),
    runways: [runway("06/24", 12007, 150, "ASPH", [end("06", 55, 33.55477952, -86.77156908),
                                                   end("24", 235, 33.57348041, -86.73909686)]),
              runway("18/36", 7099, 150, "ASPH", [end("18", 180, 33.57321347, -86.74719025),
                                                  end("36", 0, 33.55370516, -86.74720019)])],
    frequencies: [], remarks: [])

private func label(_ sketch: AirportSketch, _ text: String) -> AirportSketch.Label? {
    sketch.labels.first { $0.text == text }
}

private func near(_ a: Double, _ b: Double, _ within: Double) -> Bool { abs(a - b) <= within }

@Test func keetIsOneRunwayDrawnTrueNorthUpWithItsNumbersAndMagneticCourses() throws {
    let sketch = try #require(NavPages.airportSketch(keet))
    #expect(sketch.runways.count == 1 && sketch.runways[0].paved && !sketch.runways[0].closed)
    // 16 is the north end, so its number sits above 34's. Both follow the runway and read upright on the page.
    let sixteen = try #require(label(sketch, "16")), thirtyFour = try #require(label(sketch, "34"))
    #expect(sixteen.y < thirtyFour.y && sixteen.x < thirtyFour.x)
    #expect(near(sixteen.rotation, -23, 1) && near(thirtyFour.rotation, -23, 1))
    // Each course sits under its number as read.
    let course16 = try #require(label(sketch, "160°")), course34 = try #require(label(sketch, "340°"))
    #expect(course16.y > sixteen.y && course34.y > thirtyFour.y)
    #expect(sketch.labels.contains { $0.text == "KEET  Eet" && $0.bold })
    #expect(label(sketch, "160°") != nil && label(sketch, "340°") != nil)
    #expect(label(sketch, "5,000 × 75") != nil)
    #expect(sketch.labels.contains { $0.text.hasPrefix("16/34  5,000 × 75 ft · Asphalt · MIRL") })
    #expect(label(sketch, "Field elevation 586 ft") != nil)
}

@Test func theOutlineIsToScale() throws {
    let sketch = try #require(NavPages.airportSketch(keet))
    let o = sketch.runways[0].outline
    let length = ((o[1][0] - o[0][0]) * (o[1][0] - o[0][0]) + (o[1][1] - o[0][1]) * (o[1][1] - o[0][1])).squareRoot()
    let wide = ((o[3][0] - o[0][0]) * (o[3][0] - o[0][0]) + (o[3][1] - o[0][1]) * (o[3][1] - o[0][1])).squareRoot()
    #expect(near(length / wide, 5000.0 / 75, 1.5))
}

@Test func ownshipOnTheRunwayFallsOnItsDrawingAndOffTheFieldNowhere() throws {
    let sketch = try #require(NavPages.airportSketch(keet))
    let middle = try #require(sketch.geo.pagePoint(Coordinate(latitude: 33.17777904, longitude: -86.78321341)))
    let o = sketch.runways[0].outline
    let (cx, cy) = ((o[0][0] + o[2][0]) / 2 / sketch.width, (o[0][1] + o[2][1]) / 2 / sketch.height)
    #expect(near(middle[0], cx, 0.002) && near(middle[1], cy, 0.002))
    #expect(sketch.geo.pagePoint(Coordinate(latitude: 33.3, longitude: -86.78)) == nil)
}

@Test func everyRunwayOfAFieldIsDrawnAndTheTwoMeetAsFiled() throws {
    let sketch = try #require(NavPages.airportSketch(bhm))
    #expect(sketch.runways.map(\.id) == ["06/24", "18/36"])
    #expect(label(sketch, "06") != nil && label(sketch, "36") != nil)
    #expect(label(sketch, "058°") != nil && label(sketch, "003°") != nil)
    // 18/36 runs true north: its outline's x hardly changes from end to end.
    let north = sketch.runways[1].outline
    #expect(near(north[0][0], north[1][0], 1))
}

@Test func aClosedRunwayIsMarkedWithAnXAtEachEnd() throws {
    var detail = bhm
    detail.remarks = [Remark(tab: "RUNWAY", field: "RWY_ID", element: "18/36", seq: 1, text: "RWY CLSD.")]
    let sketch = try #require(NavPages.airportSketch(detail))
    #expect(sketch.runways[1].closed && !sketch.runways[0].closed)
    #expect(sketch.lines.filter { $0.width == 3 }.count == 4)
}

@Test func theOnlyRunwayWithNoSurveyedEndsIsCenteredOnTheFieldAlongItsNumber() throws {
    var detail = keet
    detail.runways[0].ends = [end("16", nil, nil, nil), end("34", nil, nil, nil)]
    let sketch = try #require(NavPages.airportSketch(detail))
    #expect(near(try #require(label(sketch, "16")).rotation, -23, 1))
    let middle = try #require(sketch.geo.pagePoint(detail.airport.coordinate))
    #expect(near(middle[0], 0.5, 0.002))
    // A second runway with no ends cannot be placed, so only the located one is drawn.
    var two = bhm
    two.runways[1].ends = []
    #expect(try #require(NavPages.airportSketch(two)).runways.map(\.id) == ["06/24"])
}

@Test func aFieldWithNothingToPlaceHasNoSketch() {
    var pads = keet
    pads.runways = [runway("H1", 60, 60, "CONC", [end("H1", nil, 33.1, -86.7)])]
    #expect(NavPages.airportSketch(pads) == nil)
}

/// KMSL: two runways crossing near 18's end.
let msl = AirportDetail(
    airport: airport("MSL", 34.74530555, -87.61022222, elev: 550.5, variation: "3W"),
    runways: [runway("12/30", 6694, 150, "ASPH", [end("12", 114, 34.74900758, -87.61701194),
                                                  end("30", 294, 34.74149733, -87.59667272)]),
              runway("18/36", 4000, 100, "ASPH", [end("18", 181, 34.75090825, -87.61572336),
                                                  end("36", 1, 34.73992072, -87.6160423)])],
    frequencies: [], remarks: [])

/// 08A: a paved runway and a turf one whose ends nearly meet, 36 displaced 983 ft.
let wetumpka = AirportDetail(
    airport: airport("08A", 32.52733333, -86.33102777, elev: 197.1, variation: "3W"),
    runways: [runway("09/27", 3013, 80, "ASPH", [end("09", 89, 32.5293818, -86.33310452),
                                                 end("27", 269, 32.52949688, -86.32332877)]),
              runway("18/36", 2876, 130, "TURF", [end("18", 181, 32.52907483, -86.33386694),
                                                  end("36", 1, 32.52117108, -86.33401997, displaced: 983)])],
    frequencies: [], remarks: [])

/// FST, Fort Stockton: five runways crossing, three of them turf.
let fst = AirportDetail(
    airport: airport("FST", 30.91525, -102.91277777, elev: 3011, variation: "9E"),
    runways: [runway("03/21", 4400, 60, "ASPH", [end("03", 37, 30.91367544, -102.91856397),
                                                 end("21", 217, 30.92339147, -102.91021233)]),
              runway("07/25", 4961, 150, "TURF", [end("07", 82, 30.91527916, -102.91624963),
                                                  end("25", 262, 30.91724147, -102.900597)]),
              runway("11/29", 3348, 100, "TURF", [end("11", 126, 30.91486269, -102.91632658),
                                                  end("29", 306, 30.909417, -102.90772058)]),
              runway("12/30", 7508, 100, "ASPH", [end("12", 127, 30.9201153, -102.92677738),
                                                  end("30", 307, 30.90783655, -102.90754005)]),
              runway("16/34", 3981, 150, "TURF", [end("16", 171, 30.92079238, -102.90983666),
                                                  end("34", 351, 30.9099703, -102.90794736)])],
    frequencies: [], remarks: [])

@Test(arguments: ["EET", "BHM", "MSL", "08A", "FST", "EET+", "BHM+"])
func noLabelOverlapsAnotherOrARunwayAndEveryEndIsNumbered(_ ident: String) throws {
    let detail = try #require(["EET": keet, "BHM": bhm, "MSL": msl, "08A": wetumpka, "FST": fst,
                               "EET+": keetMapped, "BHM+": bhmMapped][ident])
    let sketch = try #require(NavPages.airportSketch(detail))
    let boxes = sketch.labels.map(\.box)
    for i in boxes.indices {
        for j in boxes.indices where j > i {
            #expect(!NavPages.overlaps(boxes[i], boxes[j]), "\(sketch.labels[i].text) on \(sketch.labels[j].text)")
        }
        for runway in sketch.runways {
            #expect(!NavPages.overlaps(boxes[i], runway.outline), "\(sketch.labels[i].text) on \(runway.id)")
        }
        // Upright: never turned past level.
        #expect(abs(sketch.labels[i].rotation) <= 90)
    }
    for name in detail.runways.flatMap({ $0.id.split(separator: "/").map(String.init) }) {
        #expect(label(sketch, name) != nil, "\(name)")
    }
    // The Blueside stamp sits at the bottom right under the plan view, its mark clear of every label.
    let brand = try #require(label(sketch, "Blueside"))
    let mark = box(brand.x - 16, brand.y, 20, 20)
    #expect(brand.shade < 1 && brand.y > sketch.geo.plan[3] * sketch.height && brand.y + 10 < sketch.height)
    #expect(near(brand.box[1][0], sketch.width - 40, 1))
    for other in sketch.labels where other != brand {
        #expect(!NavPages.overlaps(mark, other.box), "mark on \(other.text)")
    }
    #expect(sketch.lines.filter { $0.shade < 1 }.allSatisfy { $0.points.allSatisfy { NavPages.overlaps(box($0[0], $0[1], 0.1, 0.1), mark) } })
}

@Test func pavedRunwaysCarryMarkingsAndTurfNone() throws {
    let sketch = try #require(NavPages.airportSketch(wetumpka))
    let paint = sketch.lines.filter(\.white)
    // 09/27 is 80 ft wide: six bars at each end and a dashed centerline.
    #expect(paint.filter { $0.dash != nil }.count == 1)
    // The turf runway has no bars or centerline, only its displaced 36: a bar across and two arrows.
    #expect(paint.filter { $0.dash == nil && $0.points.count == 2 }.count == 12 + 1 + 2)
    #expect(paint.filter { $0.points.count == 3 }.count == 2)
}

@Test func aDisplacedThresholdIsABarAcrossWithArrowsBehindIt() throws {
    var detail = keet
    detail.runways[0].ends[1].displacedThresholdFt = 800
    let sketch = try #require(NavPages.airportSketch(detail))
    // Arrows are three-point chevrons.
    #expect(sketch.lines.filter { $0.white && $0.points.count == 3 }.count == 2)
    #expect(try #require(NavPages.airportSketch(keet)).lines.filter { $0.shade == 1 }.allSatisfy { $0.points.count == 2 })
}

@Test func aNorthArrowAndScaleBarSitInACornerClearOfTheRunways() throws {
    let sketch = try #require(NavPages.airportSketch(keet))
    let scale = try #require(sketch.labels.first { $0.text.hasSuffix(" ft") && !$0.leading })
    #expect(["500 ft", "1,000 ft", "2,000 ft"].contains(scale.text))
    let north = try #require(label(sketch, "N"))
    for runway in sketch.runways {
        #expect(!NavPages.overlaps(north.box, runway.outline) && !NavPages.overlaps(scale.box, runway.outline))
    }
    // A faint field outline under it all.
    #expect(sketch.areas.contains { $0.shade < 0.1 && $0.outline.count > 8 })
}

private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [[Double]] {
    [[x - w / 2, y - h / 2], [x + w / 2, y - h / 2], [x + w / 2, y + h / 2], [x - w / 2, y + h / 2]]
}

/// KEET with a parallel taxiway west of the runway, a connector with a hold point, an apron, a hangar and an FBO,
/// in feet from the airport's point.
let keetMapped: AirportDetail = {
    var detail = keet
    detail.airport.fuel = "100LL,A"
    detail.surface = [
        SurfaceFeature(kind: .taxiway, name: "A", points: [[652, -2329], [-1206, 2097]]),
        SurfaceFeature(kind: .taxiway, name: "A3", points: [[-277, -116], [-20, -8]]),
        SurfaceFeature(kind: .hold, name: nil, points: [[-150, -63]]),
        SurfaceFeature(kind: .apron, name: nil, points: box(-553, -232, 300, 300)),
        SurfaceFeature(kind: .building, name: nil, points: box(-738, -310, 80, 60)),
        SurfaceFeature(kind: .fbo, name: "Shelby Aviation", points: [[-738, -310]]),
    ]
    return detail
}()

/// KBHM with a dozen FBOs crowded on one ramp and taxiways beside both runways.
let bhmMapped: AirportDetail = {
    var detail = bhm
    detail.surface = (0..<12).map {
        SurfaceFeature(kind: .fbo, name: "Hangar Services \($0)", points: [[2500, -1500 + Double($0) * 10]])
    } + [SurfaceFeature(kind: .taxiway, name: "F", points: [[-5600, -3900], [5500, 4000]]),
         SurfaceFeature(kind: .taxiway, name: "B", points: [[-1000, 3500], [-1000, -3500]]),
         SurfaceFeature(kind: .apron, name: nil, points: box(2500, -1500, 900, 600))]
    return detail
}()

@Test func mappedTaxiwaysApronsBuildingsAndFbosAreDrawnUnderTheRunwaysWithCredit() throws {
    let sketch = try #require(NavPages.airportSketch(keetMapped))
    // Two taxiways, a hold bar across A3, and the hangar's outline, all under the runway.
    #expect(sketch.under.filter { $0.shade == 0.35 }.count == 2)
    #expect(sketch.under.filter { $0.shade == 1 && $0.points.count == 2 }.count == 1)
    #expect(sketch.under.filter { $0.points.count == 5 }.count == 1)
    #expect(sketch.areas.contains { $0.shade == 0.12 } && sketch.areas.contains { $0.shade == 0.2 })
    #expect(label(sketch, "A") != nil && label(sketch, "Shelby Aviation") != nil)
    #expect(label(sketch, "Fuel 100LL, A") != nil)
    #expect(label(sketch, "© OpenStreetMap contributors") != nil)
}

@Test func crowdedFbosAreListedUnderTheDrawing() throws {
    let sketch = try #require(NavPages.airportSketch(bhmMapped))
    // Every name is in the rows under the drawing, at the left margin.
    let rows = sketch.labels.filter { $0.text.contains("Hangar Services") }
    #expect(rows.allSatisfy { $0.x == 40 && $0.leading })
    #expect(rows.first?.text.hasPrefix("FBO Hangar Services 0, ") == true)
    #expect(rows.map { $0.text.split(separator: ",").count }.reduce(0, +) == 12)
    #expect(label(sketch, "F") != nil && label(sketch, "B") != nil)
}

@Test func aFieldNobodyMappedIsDrawnAsBefore() throws {
    let sketch = try #require(NavPages.airportSketch(keet))
    #expect(sketch.under.isEmpty)
    #expect(!sketch.labels.contains { $0.text.contains("OpenStreetMap") || $0.text.hasPrefix("Fuel") })
}
