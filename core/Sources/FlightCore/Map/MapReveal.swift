/// A rectangle on screen, in the platform's own map units (points on iOS, dp on Android).
public struct ScreenRect: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }
}

/// Where the map moves so the place an open panel shows sits in the part of the map the panel leaves open.
public enum MapReveal {
    public struct Camera: Equatable, Sendable, Codable {
        public var center: Coordinate
        public var zoom: Double
    }

    /// The camera that puts `place` in the middle of `open`, or nil when it already sits in the open part's
    /// middle 60 percent, or the open part is too small to use. `force` always moves, at the Show on Map zoom.
    /// `at` is where the place is drawn now; `size` is the whole map. Units must be MapLibre's (512 per tile).
    public static func camera(place: Coordinate, at: ScreenPoint, open: ScreenRect, size: ScreenPoint,
                              zoom: Double, bearing: Double, force: Bool = false) -> Camera? {
        guard open.width >= size.x * 0.25, open.height >= size.y * 0.2 else { return nil }
        let comfortable = at.x >= open.x + open.width * 0.2 && at.x <= open.x + open.width * 0.8
            && at.y >= open.y + open.height * 0.2 && at.y <= open.y + open.height * 0.8
        if comfortable && !force { return nil }
        let onScreen = at.x >= 0 && at.x <= size.x && at.y >= 0 && at.y <= size.y
        let newZoom = force || (!onScreen && zoom < 8) ? NavPages.showOnMapZoom : zoom
        // The screen center sits this far from the open part's center; turned by the bearing onto the ground.
        let (dx, dy) = (size.x / 2 - (open.x + open.width / 2), size.y / 2 - (open.y + open.height / 2))
        let turn = bearing * .pi / 180
        let world = 512 * pow(2, newZoom)
        let x = (place.longitude + 180) / 360 * world + dx * cos(turn) - dy * sin(turn)
        let sine = sin(place.latitude * .pi / 180)
        let y = (0.5 - log((1 + sine) / (1 - sine)) / (4 * .pi)) * world + dx * sin(turn) + dy * cos(turn)
        let latitude = (2 * atan(exp(.pi * (1 - 2 * y / world))) - .pi / 2) * 180 / .pi
        return Camera(center: Coordinate(latitude: latitude, longitude: x / world * 360 - 180), zoom: newZoom)
    }
}
