import Foundation
import Testing
@testable import FlightCore

// The small database both apps bundle for tests.
private let testDatabase = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ios/MapAssets/nav-test.sqlite").path

// 2027-01-15T08:00:00Z
private let fixTime = Date(timeIntervalSince1970: 1_800_000_000)

private func fix(_ latitude: Double, _ longitude: Double) -> Position {
    Position(latitude: latitude, longitude: longitude, courseDegrees: -1, speedMetersPerSecond: -1,
             altitudeMeters: nil, timestamp: fixTime)!
}

@Suite struct NavPagesTests {
    let database: NavDatabase

    init() throws { database = try NavDatabase(path: testDatabase) }

    @Test func airportPageRows() throws {
        let aus = try #require(try database.airport(identifier: "AUS"))
        let detail = try #require(try database.detail(airportID: aus.id))
        let page = NavPages.airportPage(detail, metadata: database.metadata, now: database.metadata.effective)
        #expect(page.title == "KAUS" && page.ident == "AUS")
        #expect(page.subtitle == NavText.capitalized(aus.name))
        #expect(page.glance.map { "\($0.title) \($0.value ?? "")" } == ["ATIS 124.4", "Tower 121.0", "Longest runway 18R/36L"])
        #expect(page.runways.title == "Runways" && page.runways.lines.first?.title == "18R/36L")
        #expect(page.frequencies.lines.first?.copy == "124.4")
        #expect(page.details.lines.contains { $0.title == "Coordinates" })
        #expect(page.footer.first?.hasPrefix("FAA data effective") == true)
        #expect(page.warning == nil)
    }

    @Test func nearestListFromALiveFix() {
        var list = NearestList()
        let here = fix(30.20, -97.66)
        #expect(list.shown(position: nil, now: fixTime).header == "No position")
        list.update(database, from: here, now: fixTime)
        let live = list.shown(position: here, now: fixTime.addingTimeInterval(1))
        #expect(live.header == "Nearest airports from 30°12.00′N 097°39.60′W at 08:00:00Z")
        #expect(live.rows.map(\.row.ident) == ["AUS", "EDC", "T82", "ANC"])
        #expect(live.rows.allSatisfy { $0.row.distance?.hasSuffix(" NM") == true })
        let stale = list.shown(position: here, now: fixTime.addingTimeInterval(6))
        #expect(stale.rows.allSatisfy { $0.row.distance == "---" && $0.row.turn == nil })
        // The same spot again, later, keeps the rows and takes the newer time.
        var held = here
        held.timestamp = fixTime.addingTimeInterval(10)
        list.airports.removeLast()
        list.update(database, from: held, now: held.timestamp)
        #expect(list.from == held && list.airports.count == 3)
    }

    @Test func tapPinAndPlaceCard() throws {
        let pin = NavPages.pin(at: Coordinate(latitude: 30.21, longitude: -97.68))
        #expect(pin.kind == .user && pin.ident == "30°12.60′N 097°40.80′W")
        let nearby = database.nearby(pin.coordinate)
        #expect(nearby.map(\.ident) == ["AUS", "TX05", "68TX"])
        let card = NavPages.placeCard(pin, navaid: nil, fix: nil)
        #expect(card.subtitle == "Dropped Pin" && !card.showOnMap)
        #expect(card.nearbyTitle == "Nearby")
        #expect(NavPages.row(nearby[0], from: pin.coordinate).distance == "1.1 NM")
        #expect(NavPages.row(nearby[0]).name == "Austin-Bergstrom Intl")
        #expect(NavPages.tap([]) == .nothing)
        #expect(NavPages.tap([nearby[0]]) == .airport("AUS"))
        #expect(NavPages.tap(nearby) == .here(nearby))

        let cwk = try #require(database.nearby(Coordinate(latitude: 30.37855, longitude: -97.52984722)).first)
        let navaid = database.navaid(for: cwk)
        let vor = NavPages.placeCard(cwk, navaid: navaid, fix: nil)
        #expect(vor.title == "CWK" && vor.lines.map(\.title) == ["Frequency", "Channel", "Coordinates"])
        #expect(vor.nearbyTitle == nil && vor.showOnMap)
    }

    // KAUS with one runway, 09/27 at true 090 and 270, and the given METAR observed 10 minutes before fixTime.
    private func weatherPage(direction: Int, speed: Int, gust: Int? = nil, temperature: Double = 15,
                             altimeter: Double = 29.92, elevation: Double = 542, age: TimeInterval = 600,
                             station: String = "KAUS", dewpoint: Double? = 9) throws -> NavPages.AirportPage {
        let aus = try #require(try database.airport(identifier: "AUS"))
        var detail = try #require(try database.detail(airportID: aus.id))
        detail.airport.elevationFt = elevation
        detail.remarks = []
        detail.runways = [Runway(id: "09/27", lengthFt: 6000, widthFt: nil, surface: nil, condition: nil, lights: nil,
                                 ends: [("09", 90), ("27", 270)].map {
            RunwayEnd(id: $0.0, trueHeading: $0.1, rightTraffic: nil, coordinate: nil, elevationFt: nil,
                      displacedThresholdFt: nil, vgsi: nil, approachLights: nil, toraFt: nil, ldaFt: nil)
        })]
        let metar = Metar(station: station, coordinate: aus.coordinate, category: .mvfr, ceilingFtAGL: 2500,
                          sky: [SkyLayer(cover: "BKN", baseFtAGL: 2500)], visibilityMiles: 10, visibilityOrMore: true,
                          windDirection: direction, windVariable: false, windSpeedKt: speed, windGustKt: gust,
                          temperatureC: temperature, dewpointC: dewpoint, altimeterInHg: altimeter,
                          observed: fixTime.addingTimeInterval(-age), raw: "")
        return NavPages.airportPage(detail, metadata: database.metadata, metar: metar, now: fixTime)
    }

    @Test func weatherBlockRowsAndRunwayWind() throws {
        let page = try weatherPage(direction: 270, speed: 15, gust: 25)
        let wx = page.weather
        #expect(wx.category?.value == "MVFR" && wx.color == "blue" && wx.note == "Observed 10 min ago")
        #expect(wx.lines.map { "\($0.title) \($0.value ?? "")" } == [
            "Wind 270° true at 15 kt, gusts 25", "Visibility 10+ SM", "Ceiling 2,500 ft",
            "Temperature / dewpoint 15°C / 9°C", "Altimeter 29.92 inHg", "Density altitude 836 ft",
        ])
        #expect(wx.runways == [
            NavPages.RunwayWindLine(end: "27", wind: "15 head · 0 cross", gust: "Gust 25 head · 0 cross", tag: "Best"),
            NavPages.RunwayWindLine(end: "09", wind: "15 tail · 0 cross", gust: "Gust 25 tail · 0 cross", tag: nil),
        ])
        #expect(page.glance.last.map { "\($0.title) \($0.value ?? "")" } == "Best runway 27")

        // 300° at 20 on runway 27: 30° off the nose, so 20 cos 30 = 17 head and 20 sin 30 = 10 from the right.
        let angled = try weatherPage(direction: 300, speed: 20).weather.runways
        #expect(angled.first == NavPages.RunwayWindLine(end: "27", wind: "17 head · 10 cross from right", gust: nil, tag: "Best"))
        #expect(angled.last?.wind == "17 tail · 10 cross from left")
    }

    @Test func densityAltitudeMatchesTheStandardAtmosphere() throws {
        // At 5,000 ft the standard atmosphere is 5.1 °C, so density altitude equals the field's pressure altitude.
        let standard = try weatherPage(direction: 270, speed: 10, temperature: 5.1, elevation: 5000, dewpoint: nil).weather.lines
        let value = try #require(standard.last?.value)
        let feet = try #require(Int(value.filter(\.isNumber)))
        #expect(standard.last?.title == "Density altitude" && abs(feet - 5000) <= 20)
    }

    @Test func anOldOrMissingMetarShowsNoWeather() throws {
        let old = try weatherPage(direction: 270, speed: 15, age: 2 * 3600 + 60)
        #expect(old.weather.note == NavPages.noCurrentMetar && old.weather.lines.isEmpty && old.weather.category == nil)
        #expect(old.glance.last?.title == "Longest runway")
        #expect(try weatherPage(direction: 270, speed: 15, station: "KEDC").weather.note == NavPages.noCurrentMetar)
    }

    @Test func addSpotTitle() {
        let waco = Coordinate(latitude: 31.6, longitude: -97.2)
        #expect(NavPages.addSpot(waco, route: nil, position: nil, now: fixTime) == (nil, "Add to Route"))
    }
}
