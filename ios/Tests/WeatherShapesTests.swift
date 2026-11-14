import FlightCore
import Foundation
import MapLibre
import Testing
@testable import Blueside

@Suite struct WeatherShapesTests {
    // The station GeoJSON is parsed where it is built, away from the main thread.
    @Test func stationShapesAreParsedOffTheMainThread() async throws {
        var data = WeatherData()
        try data.take(.metars, json: try WeatherFixture.json("metars.json.gz"))
        let shapes = await Task.detached { [data] in
            WeatherLayers.shapes([.stations], data: data, show: .category, windsLevel: 0, now: WeatherFixture.now)
        }.value
        #expect(Array(shapes.parsed.keys) == [.stations])
        #expect((shapes.parsed[.stations] as? MLNShapeCollectionFeature)?.shapes.count == 2547)
    }

    @Test func aCancelledBuildStopsBeforeTheNextOverlay() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await WeatherLayers.build([.stations, .pireps], data: WeatherData(), show: .category, windsLevel: 0,
                                             now: WeatherFixture.now)
        }
        #expect(await task.value.parsed.isEmpty)
    }
}
