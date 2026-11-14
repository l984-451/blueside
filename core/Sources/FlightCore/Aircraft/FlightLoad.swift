/// A W&B load as typed: station weights by index, fuel at start, and fuel burned (nil takes the plan's).
public struct FlightLoad: Codable, Equatable, Sendable {
    public var weights: [Double?]
    public var startFuel: Double?
    public var burned: Double?

    public init(weights: [Double?] = [], startFuel: Double? = nil, burned: Double? = nil) {
        self.weights = weights
        self.startFuel = startFuel
        self.burned = burned
    }
}
