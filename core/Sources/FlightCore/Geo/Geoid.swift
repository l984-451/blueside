/// Mean sea level as the EGM96 geoid places it against the WGS-84 ellipsoid, over the US and its territories.
public enum Geoid {
    struct Grid {
        let south, west, step: Double
        let columns: Int
        /// Whole meters, row by row northward from the south-west corner.
        let heights: [Int8]
    }

    /// Meters the geoid lies above the ellipsoid, negative across the contiguous US. Height above the ellipsoid
    /// minus this is height above MSL. Nil outside the areas in `grids`.
    public static func height(latitude: Double, longitude: Double) -> Double? {
        for g in grids {
            let rows = g.heights.count / g.columns
            let y = (latitude - g.south) / g.step
            var east = (longitude - g.west).truncatingRemainder(dividingBy: 360)
            if east < 0 { east += 360 }
            let x = east / g.step
            guard y >= 0, y <= Double(rows - 1), x <= Double(g.columns - 1) else { continue }
            let i = min(Int(y), rows - 2), j = min(Int(x), g.columns - 2)
            let fy = y - Double(i), fx = x - Double(j)
            func h(_ r: Int, _ c: Int) -> Double { Double(g.heights[r * g.columns + c]) }
            return (h(i, j) * (1 - fx) + h(i, j + 1) * fx) * (1 - fy) + (h(i + 1, j) * (1 - fx) + h(i + 1, j + 1) * fx) * fy
        }
        return nil
    }
}
