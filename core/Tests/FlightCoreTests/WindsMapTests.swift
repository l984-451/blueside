import Foundation
import Testing
@testable import FlightCore

@Suite struct WindsMapTests {
    @Test func a270At65KnotsIsAPennantAFullBarbAndAHalfBarbTurnedWest() {
        let barb = WindBarb(directionDeg: 270, speedKt: 65)
        #expect(barb.bucket == 65 && barb.rotation == 270 && barb.image == "wind-barb-65")
        #expect(WindBarb.parts(barb.bucket) == (pennants: 1, full: 1, half: 1))
        let d = WindBarb.drawing(barb.bucket)
        // Staff plus one full and one half barb; the pennant is the one triangle.
        #expect(d.lines.count == 3 && d.triangles.count == 1 && d.ring == nil)
    }

    @Test func speedsRoundToTheNearestFiveAndLightAndVariableIsCalm() {
        #expect(WindBarb(directionDeg: 10, speedKt: 2).bucket == 0)
        #expect(WindBarb(directionDeg: 10, speedKt: 3).bucket == 5)
        #expect(WindBarb(directionDeg: 10, speedKt: 12).bucket == 10)
        #expect(WindBarb(directionDeg: nil, speedKt: 0) == WindBarb(directionDeg: 0, speedKt: 0))
        #expect(WindBarb(directionDeg: 250, speedKt: 240).bucket == WindBarb.maxKt)
        #expect(WindBarb.drawing(0).ring != nil)
        #expect(WindBarb.drawings.count == WindBarb.buckets.count)
    }

    @Test func theLevelIsTheChoiceElseTheCruiseRoundedElse6000() {
        #expect(WindsMap.level(chosen: nil, cruiseFt: nil) == 6000)
        #expect(WindsMap.level(chosen: nil, cruiseFt: 8500) == 9000)
        #expect(WindsMap.level(chosen: nil, cruiseFt: 45000) == 30000)
        #expect(WindsMap.level(chosen: 18000, cruiseFt: 8500) == 18000)
        #expect(WindsMap.level(chosen: 7000, cruiseFt: nil) == 6000)
    }

    @Test func theForecastInUseIsDrawnAndNamedInTheClock() throws {
        let winds = try WindsAloft.decode(try WeatherFixture.data("winds.json.gz"))
        let now = WeatherFixture.date("2026-10-15T04:00:00Z")
        #expect(WindsMap.label(winds, level: 9000, at: now) == "Winds 03Z-12Z, 9000 ft")
        #expect(WindsMap.label(winds, level: 9000, at: WeatherFixture.date("2026-10-14T19:00:00Z"))
            == "Winds aloft: no forecast for now")
        let object = try #require(try JSONSerialization.jsonObject(with: WeatherGeoJSON.winds(winds, level: 9000, now: now))
            as? [String: Any])
        let features = try #require(object["features"] as? [[String: Any]])
        #expect(features.count > 150)
        let first = try #require(features.first?["properties"] as? [String: Any])
        #expect((first["barb"] as? String)?.hasPrefix("wind-barb-") == true && first["rotate"] is Int)
        #expect(try JSONSerialization.jsonObject(with: WeatherGeoJSON.winds(winds, level: 9000, now: WeatherFixture.now))
            as? [String: Any] != nil)
    }
}
