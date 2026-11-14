/// Standard atmosphere altitudes by the National Weather Service formulas.
public enum Atmosphere {
    /// Feet: field elevation plus the height the altimeter setting stands for. Nil for values that are not real.
    public static func pressureAltitudeFt(fieldElevationFt: Double, altimeterInHg: Double) -> Double? {
        guard fieldElevationFt.isFinite, altimeterInHg.isFinite, altimeterInHg > 0 else { return nil }
        let altitude = fieldElevationFt + 145366.45 * (1 - pow(altimeterInHg / 29.92126, 0.190284))
        return altitude.isFinite ? altitude : nil
    }

    /// Feet. With a dewpoint the air's moisture counts through its virtual temperature, as the NWS calculator does;
    /// without one it is the dry-air figure, which reads low on a humid day.
    public static func densityAltitudeFt(pressureAltitudeFt: Double, temperatureC: Double, dewpointC: Double? = nil) -> Double? {
        let base = 1 - pressureAltitudeFt / 145366.45
        guard pressureAltitudeFt.isFinite, temperatureC.isFinite, base > 0 else { return nil }
        // Station pressure in inches of mercury: the pressure altitude formula turned around.
        let pressure = 29.92126 * pow(base, 1 / 0.190284)
        var kelvin = temperatureC + 273.15
        if let dewpointC, dewpointC.isFinite {
            let vaporMb = 6.11 * pow(10, 7.5 * dewpointC / (237.7 + dewpointC))
            kelvin /= 1 - vaporMb / (pressure * 33.8639) * (1 - 0.622)
        }
        let rankine = kelvin * 9 / 5
        guard rankine > 0 else { return nil }
        let altitude = 145366 * (1 - pow(17.326 * pressure / rankine, 0.235))
        return altitude.isFinite ? altitude : nil
    }
}
