import FlightCore
import Foundation
import Testing
@testable import Blueside

@Test func coreIsLinked() {
    let dfw = Coordinate(latitude: 32.8968, longitude: -97.0380)
    let iah = Coordinate(latitude: 29.9844, longitude: -95.3414)
    #expect(abs(Geo.distanceNM(from: dfw, to: iah) - 195) < 5)
}

// The name and bundle id are set once in project.yml, so only their presence is checked here.
@Test func appHasADisplayNameAndBundleID() {
    let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    #expect(name?.isEmpty == false)
    #expect(Bundle.main.bundleIdentifier?.isEmpty == false)
}

@Test func emptyMapStyleIsBundled() {
    #expect(Bundle.main.url(forResource: "empty", withExtension: "json", subdirectory: "MapAssets") != nil)
}
