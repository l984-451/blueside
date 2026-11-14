/// The map setup kept across launches. Each platform stores `text` under `key` and hands it back at launch.
/// Overlay switches are kept apart, under WeatherSwitches.saved.
public struct MapMemory: Equatable, Sendable {
    public static let key = "mapSetup"
    static let version = 1

    public struct Camera: Equatable, Sendable, Codable {
        public var latitude: Double
        public var longitude: Double
        public var zoom: Double

        public init(latitude: Double, longitude: Double, zoom: Double) {
            self.latitude = latitude
            self.longitude = longitude
            self.zoom = zoom
        }

        var isValid: Bool {
            (-90...90).contains(latitude) && (-180...180).contains(longitude) && (0...24).contains(zoom)
        }
    }

    /// The lower 48 from far out, where a first launch starts.
    public static let home = Camera(latitude: 39.5, longitude: -98.35, zoom: 4)

    public var base: BaseLayer
    public var night: Bool
    public var orientation: MapOrientation
    public var following: Bool
    public var camera: Camera
    /// Route text, parsed again against the nav data in hand at launch.
    public var route: String?
    /// Plates placed on the map, in the order placed.
    public var plates: [PlacedPlate]

    /// A plate by airport and file, found again in the plates packs at launch.
    public struct PlacedPlate: Hashable, Sendable, Codable {
        public var airport: String
        public var file: String
        public init(airport: String, file: String) { (self.airport, self.file) = (airport, file) }
    }

    public init(base: BaseLayer = .vfr, night: Bool = false, orientation: MapOrientation = .northUp,
                following: Bool = true, camera: Camera = home, route: String? = nil, plates: [PlacedPlate] = []) {
        self.base = base
        self.night = night
        self.orientation = orientation
        self.following = following
        self.camera = camera
        self.route = route
        self.plates = plates
    }

    /// The saved setup, or the first-launch one when there is none, it is unreadable, or another version wrote it.
    public init(text: String?) {
        self = text.flatMap { try? JSONDecoder().decode(MapMemory.self, from: Data($0.utf8)) } ?? MapMemory()
    }

    public var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The first map state: launch options win over what was saved. A fixed center follows only when asked;
    /// otherwise following comes back only if it was on when the app was left.
    public func launched(base: BaseLayer?, night: Bool?, orientation: MapOrientation?, center: Coordinate?,
                         zoom: Double?, follow: Bool) -> MapMemory {
        var out = self
        if let base { out.base = base }
        if let night { out.night = night }
        if let orientation { out.orientation = orientation }
        if let center {
            out.camera = Camera(latitude: center.latitude, longitude: center.longitude, zoom: zoom ?? Self.home.zoom)
            out.following = follow
        } else {
            if let zoom { out.camera.zoom = zoom }
            out.following = following || follow
        }
        return out
    }
}

/// Each field falls back on its own, so a base no longer offered or a bad camera keeps the rest.
extension MapMemory: Codable {
    enum CodingKeys: String, CodingKey { case version, base, night, orientation, following, camera, route, plates }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let version = try? c.decodeIfPresent(Int.self, forKey: .version), version != Self.version { return }
        base = (try? c.decode(String.self, forKey: .base)).flatMap(BaseLayer.init(rawValue:)) ?? base
        night = (try? c.decode(Bool.self, forKey: .night)) ?? night
        orientation = (try? c.decode(String.self, forKey: .orientation)).flatMap(MapOrientation.init(rawValue:)) ?? orientation
        following = (try? c.decode(Bool.self, forKey: .following)) ?? following
        camera = (try? c.decode(Camera.self, forKey: .camera)).flatMap { $0.isValid ? $0 : nil } ?? camera
        route = (try? c.decode(String.self, forKey: .route)).flatMap { $0.trimmed.isEmpty ? nil : $0 }
        plates = (try? c.decode([PlacedPlate].self, forKey: .plates)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .version)
        try c.encode(base.rawValue, forKey: .base)
        try c.encode(night, forKey: .night)
        try c.encode(orientation.rawValue, forKey: .orientation)
        try c.encode(following, forKey: .following)
        try c.encode(camera, forKey: .camera)
        try c.encodeIfPresent(route, forKey: .route)
        if !plates.isEmpty { try c.encode(plates, forKey: .plates) }
    }
}
