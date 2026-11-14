import FlightCore
import Testing
@testable import Blueside

@Test func readsOneStringPerValue() {
    let options = LaunchOptions(arguments: [
        "/path/to/app", "-center", "32.9,-97.04", "-zoom", "9.5", "-basePack", "test", "-night", "1",
    ])
    #expect(options.coordinate("center") == Coordinate(latitude: 32.9, longitude: -97.04))
    #expect(options.double("zoom") == 9.5)
    #expect(options.string("basePack") == "test")
    #expect(options.flag("night"))
}

@Test func noArgumentsGivesNothing() {
    let options = LaunchOptions(arguments: [])
    #expect(options.string("basePack") == nil)
    #expect(options.double("zoom") == nil)
    #expect(options.coordinate("center") == nil)
    #expect(!options.flag("night"))
}

@Test func negativeNumberIsAValueNotAKey() {
    let options = LaunchOptions(arguments: ["-bearing", "-97.04", "-zoom", "8"])
    #expect(options.double("bearing") == -97.04)
    #expect(options.double("zoom") == 8)
}

@Test func keyWithoutValueDoesNotSwallowTheNextKey() {
    let options = LaunchOptions(arguments: ["-night", "-center", "32.9,-97.04", "-zoom"])
    #expect(!options.flag("night"))
    #expect(options.coordinate("center") == Coordinate(latitude: 32.9, longitude: -97.04))
    #expect(options.double("zoom") == nil)
}

@Test func laterDuplicateWins() {
    #expect(LaunchOptions(arguments: ["-zoom", "8", "-zoom", "11"]).double("zoom") == 11)
}

@Test func badNumbersReadAsNil() {
    for value in ["fast", "", "nan", "inf", "9,5"] {
        #expect(LaunchOptions(arguments: ["-zoom", value]).double("zoom") == nil, "zoom \(value)")
    }
}

@Test func badCoordinatesReadAsNil() {
    for value in ["abc", "32.9", "32.9,", "32.9,-97.04,5", "91,0", "0,181", "nan,0", "32.9 -97.04"] {
        #expect(LaunchOptions(arguments: ["-center", value]).coordinate("center") == nil, "center \(value)")
    }
}

@Test func flagAcceptsCommonSpellings() {
    for value in ["1", "true", "YES"] {
        #expect(LaunchOptions(arguments: ["-night", value]).flag("night"), "night \(value)")
    }
    for value in ["0", "false", "no", "2"] {
        #expect(!LaunchOptions(arguments: ["-night", value]).flag("night"), "night \(value)")
    }
}
