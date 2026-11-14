/// Point in polygon on flat (x, y) points, such as arm and weight or a local grid in nautical miles.
public enum Polygon {
    /// Ray casting. A point on an edge or corner counts as inside. The ring may be open or closed.
    public static func contains(_ x: Double, _ y: Double, in ring: [(x: Double, y: Double)]) -> Bool {
        guard ring.count >= 3, x.isFinite, y.isFinite else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let (a, b) = (ring[i], ring[j])
            if onSegment(x, y, a, b) { return true }
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func onSegment(_ x: Double, _ y: Double, _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Bool {
        let cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
        let scale = max(abs(b.x - a.x), abs(b.y - a.y), 1)
        return abs(cross) <= 1e-9 * scale * scale
            && x >= min(a.x, b.x) - 1e-9 && x <= max(a.x, b.x) + 1e-9
            && y >= min(a.y, b.y) - 1e-9 && y <= max(a.y, b.y) + 1e-9
    }
}
