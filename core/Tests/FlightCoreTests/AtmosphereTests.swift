import Foundation
import Testing
@testable import FlightCore

@Test func pressureAltitudeMatchesThePublishedTable() throws {
    // Altimeter setting against the feet to add to field elevation, from the FAA handbook's conversion table.
    let table: [(Double, Double)] = [(28.0, 1824), (28.5, 1340), (29.0, 863), (29.5, 392), (29.7, 205), (29.92, 0),
                                     (30.0, -73), (30.5, -531), (31.0, -983)]
    for (setting, feet) in table {
        let found = try #require(Atmosphere.pressureAltitudeFt(fieldElevationFt: 0, altimeterInHg: setting))
        #expect(abs(found - feet) < 1.5, "\(setting)")
    }
    // Field elevation is added as it is.
    let high = try #require(Atmosphere.pressureAltitudeFt(fieldElevationFt: 5883, altimeterInHg: 29.80))
    #expect(abs(high - 5995.3) < 0.5)
    let low = try #require(Atmosphere.pressureAltitudeFt(fieldElevationFt: 542, altimeterInHg: 30.12))
    #expect(abs(low - 358.8) < 0.5)
}

@Test func densityAltitudeMatchesTheStandardAtmosphere() throws {
    // At the standard temperature for a pressure altitude, the two altitudes are the same.
    for altitude in [0.0, 2000, 5000, 8000, 12000] {
        let standard = 15 - 1.9812 * altitude / 1000
        let found = try #require(Atmosphere.densityAltitudeFt(pressureAltitudeFt: altitude, temperatureC: standard))
        #expect(abs(found - altitude) < 25, "\(altitude)")
    }
    // The published formula worked by hand.
    let worked: [(Double, Double, Double)] = [(0, 15, 16.7), (5000, 35, 8343.8), (0, -20, -4474.6)]
    for (altitude, temperature, feet) in worked {
        let found = try #require(Atmosphere.densityAltitudeFt(pressureAltitudeFt: altitude, temperatureC: temperature))
        #expect(abs(found - feet) < 1, "\(altitude) \(temperature)")
    }
    // Sea-level pressure at 44.37 C has the density the standard atmosphere table lists for 1000 m, 3281 ft.
    let hot = try #require(Atmosphere.densityAltitudeFt(pressureAltitudeFt: 0, temperatureC: 44.37))
    #expect(abs(hot - 3280.8) < 25)
}

@Test func altitudesAreAbsentForValuesThatAreNotReal() {
    #expect(Atmosphere.pressureAltitudeFt(fieldElevationFt: 500, altimeterInHg: 0) == nil)
    #expect(Atmosphere.pressureAltitudeFt(fieldElevationFt: 500, altimeterInHg: -29.92) == nil)
    #expect(Atmosphere.pressureAltitudeFt(fieldElevationFt: .nan, altimeterInHg: 29.92) == nil)
    #expect(Atmosphere.pressureAltitudeFt(fieldElevationFt: 500, altimeterInHg: .infinity) == nil)
    #expect(Atmosphere.densityAltitudeFt(pressureAltitudeFt: 500, temperatureC: -273.15) == nil)
    #expect(Atmosphere.densityAltitudeFt(pressureAltitudeFt: 500, temperatureC: .nan) == nil)
    #expect(Atmosphere.densityAltitudeFt(pressureAltitudeFt: .infinity, temperatureC: 15) == nil)
    #expect(Atmosphere.densityAltitudeFt(pressureAltitudeFt: 150_000, temperatureC: 15) == nil)
}

// Moist air is lighter: 30°C with a 25°C dewpoint at sea level reads a few hundred feet above the dry figure.
@Test func humidAirRaisesDensityAltitude() throws {
    let dry = try #require(Atmosphere.densityAltitudeFt(pressureAltitudeFt: 0, temperatureC: 30))
    let humid = try #require(Atmosphere.densityAltitudeFt(pressureAltitudeFt: 0, temperatureC: 30, dewpointC: 25))
    #expect(humid - dry > 250 && humid - dry < 600)
}
