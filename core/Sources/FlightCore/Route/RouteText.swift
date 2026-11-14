/// Reads and writes positions typed into a route.
enum RouteText {
    /// Six decimals of a degree, so a position written as text reads back to the same value.
    static func rounded(_ c: Coordinate) -> Coordinate {
        Coordinate(latitude: (c.latitude * 1e6).rounded() / 1e6, longitude: (c.longitude * 1e6).rounded() / 1e6)
    }

    private static func isDigit(_ character: Character) -> Bool { character >= "0" && character <= "9" }

    private static func isDigits(_ text: Substring) -> Bool { !text.isEmpty && text.allSatisfy(isDigit) }

    private static func checked(_ latitude: Double, _ longitude: Double) -> Coordinate? {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return rounded(Coordinate(latitude: latitude, longitude: longitude))
    }

    /// Degrees, minutes and optional seconds run together, such as 3015 or 0974500.
    private static func degrees(_ digits: Substring, degreeDigits: Int) -> Double? {
        guard let whole = Int(digits.prefix(degreeDigits)),
              let minutes = Int(digits.dropFirst(degreeDigits).prefix(2)) else { return nil }
        let rest = digits.dropFirst(degreeDigits + 2)
        let seconds = rest.isEmpty ? 0 : (Int(rest) ?? 60)
        guard minutes < 60, seconds < 60 else { return nil }
        return Double(whole) + Double(minutes) / 60 + Double(seconds) / 3600
    }

    /// 3015N09745W, 301530N0974500W, either with a slash after the N or S, or 30.25/-97.75.
    /// Nil when the text is not a real position.
    static func coordinate(_ token: String) -> Coordinate? {
        var text = token.uppercased()
        // 3015N/09745W: a slash straight after the latitude's letter is dropped, leaving the run-together form.
        if let slash = text.firstIndex(of: "/"), slash > text.startIndex,
           let before = text[..<slash].last, before == "N" || before == "S" {
            text.remove(at: slash)
        }
        if text.contains("/") {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            for part in parts {
                guard !part.isEmpty, part.allSatisfy({ isDigit($0) || $0 == "." || $0 == "-" || $0 == "+" }) else { return nil }
            }
            guard let latitude = Double(parts[0]), let longitude = Double(parts[1]) else { return nil }
            return checked(latitude, longitude)
        }
        guard let split = text.firstIndex(where: { $0 == "N" || $0 == "S" }),
              let last = text.last, last == "E" || last == "W" else { return nil }
        let latitudeDigits = text[text.startIndex..<split]
        let longitudeDigits = text[text.index(after: split)...].dropLast()
        guard isDigits(latitudeDigits), isDigits(longitudeDigits) else { return nil }
        let short = latitudeDigits.count == 4 && longitudeDigits.count == 5
        let long = latitudeDigits.count == 6 && longitudeDigits.count == 7
        guard short || long,
              let latitude = degrees(latitudeDigits, degreeDigits: 2),
              let longitude = degrees(longitudeDigits, degreeDigits: 3) else { return nil }
        return checked(text[split] == "S" ? -latitude : latitude, last == "W" ? -longitude : longitude)
    }

    /// True for text that was meant as a position, so a bad one is reported as a bad position.
    static func looksLikeCoordinate(_ token: String) -> Bool {
        if token.contains("/") { return true }
        let head = token.prefix(4)
        return head.count == 4 && isDigits(head) && token.uppercased().contains(where: { $0 == "N" || $0 == "S" })
    }

    /// CLL090020: three to five letters or digits starting with a letter, three digits of magnetic radial,
    /// three digits of nautical miles. The numbers are not range checked here.
    static func fixRadialDistance(_ token: String) -> (ident: String, radial: Int, distanceNM: Int)? {
        let text = token.uppercased()
        guard (9...11).contains(text.count), let first = text.first, first >= "A", first <= "Z" else { return nil }
        let ident = text.dropLast(6)
        let numbers = text.suffix(6)
        guard isDigits(numbers), ident.allSatisfy({ isDigit($0) || ($0 >= "A" && $0 <= "Z") }),
              let radial = Int(numbers.prefix(3)), let distance = Int(numbers.suffix(3)) else { return nil }
        return (String(ident), radial, distance)
    }

    /// Degrees east from text such as 6E or 12W: whole degrees, as published. Nil for any other form.
    static func variationDegrees(_ text: String) -> Double? {
        guard let side = text.last, side == "E" || side == "W", isDigits(text.dropLast()),
              let degrees = Int(text.dropLast()), degrees <= 180 else { return nil }
        return side == "E" ? Double(degrees) : -Double(degrees)
    }

    private static func padded(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    /// The degrees and minutes form, such as 3015N09745W, to the nearest minute.
    static func name(for c: Coordinate) -> String {
        func part(_ value: Double, _ width: Int, _ positive: String, _ negative: String) -> String {
            guard value.isFinite else { return "" }
            let minutes = Int((min(abs(value), 180) * 60).rounded())
            return padded(minutes / 60, width) + padded(minutes % 60, 2) + (value < 0 ? negative : positive)
        }
        return part(c.latitude, 2, "N", "S") + part(c.longitude, 3, "E", "W")
    }

    /// Decimal degrees with six places, such as 30.251235/-97.753400.
    static func decimal(_ c: Coordinate) -> String {
        func part(_ value: Double) -> String {
            guard value.isFinite else { return "0" }
            let millionths = Int((min(abs(value), 180) * 1e6).rounded())
            return (value < 0 ? "-" : "") + String(millionths / 1_000_000) + "." + padded(millionths % 1_000_000, 6)
        }
        return part(c.latitude) + "/" + part(c.longitude)
    }
}
