import FlightCore
import Foundation

/// Launch arguments read as `-key value` pairs. Each value is one string, such as `-center 32.9,-97.04`.
struct LaunchOptions: Equatable, Sendable {
    private var values: [String: String] = [:]

    init(arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let hasValue = index + 1 < arguments.count && !Self.isKey(arguments[index + 1])
            if Self.isKey(arguments[index]), hasValue {
                values[String(arguments[index].dropFirst())] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
    }

    /// The options this process was started with.
    static var current: LaunchOptions { LaunchOptions(arguments: ProcessInfo.processInfo.arguments) }

    // A key is a dash and then a letter, so "-97.04" is always a value.
    private static func isKey(_ argument: String) -> Bool {
        argument.first == "-" && argument.dropFirst().first?.isLetter == true
    }

    func string(_ key: String) -> String? { values[key] }

    func double(_ key: String) -> Double? {
        values[key].flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil }
    }

    func flag(_ key: String) -> Bool {
        ["1", "true", "yes"].contains(values[key]?.lowercased() ?? "")
    }

    /// Reads "latitude,longitude". Nil when a part is missing, not a number, or out of range.
    func coordinate(_ key: String) -> Coordinate? {
        let parts = (values[key] ?? "").split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        guard parts.count == 2, let latitude = parts[0], let longitude = parts[1],
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }
}
