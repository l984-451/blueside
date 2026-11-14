/// The words the navigation screens show. Dates and numbers are formatted by hand, so no locale data is needed.
public enum NavText {
    public static let dashes = "---"

    /// A UTC date such as 01 Oct 2026.
    public static func day(_ date: Date) -> String {
        let t = UTCTime(date)
        return "\(pad(t.day, 2)) \(t.monthName) \(pad(t.year, 4))"
    }

    /// The data dates line, and a warning whenever the cycle is not the current one.
    public static func dataDates(_ metadata: NavMetadata, now: Date) -> (line: String, warning: String?) {
        let line = "FAA data effective \(day(metadata.effective)) to \(day(metadata.expires))"
        switch metadata.currency(at: now) {
        case .current: return (line, nil)
        case .expired: return (line, "Not current: expired \(day(metadata.expires))")
        case .notYetEffective: return (line, "Not current: not in effect until \(day(metadata.effective))")
        }
    }

    /// The fixed words shown over the map when the navigation data is missing, unreadable or out of cycle.
    public static func mapNotice(metadata: NavMetadata?, unreadable: Bool = false, hasTiles: Bool,
                                 overlayWanted: Bool, now: Date) -> String? {
        if unreadable { return "Navigation data could not be read" }
        guard let metadata else { return overlayWanted ? "Navigation data not downloaded" : nil }
        switch metadata.currency(at: now) {
        case .expired: return "Nav data expired \(day(metadata.expires))"
        case .notYetEffective: return "Nav data not in effect until \(day(metadata.effective))"
        case .current:
            guard overlayWanted else { return nil }
            return hasTiles ? nil : "Navigation overlay not downloaded"
        }
    }

    /// Why the navigation download cannot start, or that the list in hand is not fresh. Nil when all is well.
    public static func downloadNotice(_ failure: ListFailure?, hasList: Bool) -> String? {
        switch failure {
        case nil: return nil
        case _ where hasList: return "Navigation data list not updated"
        case .noConnection: return "No connection. Connect to the internet to download navigation data."
        case .unreadable: return "Update the app. This version cannot read the navigation data list."
        case .server: return "Navigation data server error. Try again later."
        }
    }

    /// A UTC time of day such as 08:00:00Z.
    public static func clock(_ date: Date) -> String {
        let t = UTCTime(date)
        return "\(pad(t.hour, 2)):\(pad(t.minute, 2)):\(pad(t.second, 2))Z"
    }

    /// A UTC day and time such as 15 Jan 08:00:00Z, for a fix that may be from another day.
    public static func stamp(_ date: Date) -> String {
        let t = UTCTime(date)
        return "\(pad(t.day, 2)) \(t.monthName) \(clock(date))"
    }

    public static func distance(_ nauticalMiles: Double) -> String {
        nauticalMiles.isFinite ? fixed(nauticalMiles, 1) + " NM" : dashes
    }

    /// A time to fly as hours and minutes, such as 1:05.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return dashes }
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes / 60):\(pad(minutes % 60, 2))"
    }

    /// A magnetic bearing as three digits, such as 011°M, with north written 360.
    /// Outside the years the magnetic model covers the true value is shown, marked T.
    public static func bearing(_ degreesTrue: Double, from point: Coordinate, altitudeFt: Double = 0,
                               date: Date) -> String {
        guard degreesTrue.isFinite else { return dashes }
        let magnetic = MagneticModel.covers(date)
        let value = magnetic
            ? RouteMath.magnetic(degreesTrue, at: point, altitudeFt: altitudeFt, date: date) : degreesTrue
        guard value.isFinite else { return dashes }
        let whole = ((Int(value.rounded()) % 360) + 360) % 360
        return pad(whole == 0 ? 360 : whole, 3) + (magnetic ? "°M" : "°T")
    }

    /// Distance and magnetic bearing from a live, exact fix. Dashes with no fix, a stale one or an approximate one.
    public static func directTo(from position: Position?, to destination: Coordinate, approximate: Bool = false,
                                now: Date) -> (distance: String, bearing: String) {
        guard let position, !approximate, !position.isStale(at: now) else { return (dashes, dashes) }
        return (distance(Geo.distanceNM(from: position.coordinate, to: destination)),
                bearing(Geo.initialBearing(from: position.coordinate, to: destination), from: position.coordinate,
                        altitudeFt: position.altitudeFtMSL ?? 0, date: now))
    }

    /// Degrees and minutes, such as 30°11.70′N 097°40.20′W.
    public static func degreesMinutes(_ coordinate: Coordinate) -> String {
        func part(_ value: Double, _ digits: Int) -> String {
            let minutes = (abs(value) * 60 * 100).rounded() / 100
            let degrees = Int(minutes / 60)
            let rest = fixed(minutes - Double(degrees) * 60, 2)
            return pad(degrees, digits) + "°" + String(repeating: "0", count: max(0, 5 - rest.count)) + rest + "′"
        }
        return part(coordinate.latitude, 2) + (coordinate.latitude < 0 ? "S " : "N ")
            + part(coordinate.longitude, 3) + (coordinate.longitude < 0 ? "W" : "E")
    }

    /// Distance, magnetic bearing from the first point, and time at a live groundspeed over 30 knots.
    public static func ruler(from a: Coordinate, to b: Coordinate, position: Position?, approximate: Bool = false,
                             now: Date) -> String {
        let miles = Geo.distanceNM(from: a, to: b)
        var parts = [distance(miles), bearing(Geo.initialBearing(from: a, to: b), from: a, date: now)]
        if let position, !approximate, !position.isStale(at: now), let speed = position.groundspeedKt, speed > 30 {
            parts.append(duration(miles / speed * 3600))
        }
        return parts.joined(separator: " · ")
    }

    /// Groundspeed, track and GPS altitude for the data strip, and why they may be missing.
    public struct Readout: Equatable, Sendable {
        public var groundspeed: String
        public var track: String
        public var altitude: String
        public var message: String?

        public init(groundspeed: String, track: String, altitude: String, message: String? = nil) {
            self.groundspeed = groundspeed
            self.track = track
            self.altitude = altitude
            self.message = message
        }
    }

    /// Dashes when there is no fix or it is stale. Says so in words when access is off or the fix is approximate.
    public static func readout(for position: Position?, accessOff: Bool = false, approximate: Bool = false,
                               now: Date) -> Readout {
        let message = accessOff ? "Location access is off" : approximate ? "Approximate location" : nil
        guard let position, !position.isStale(at: now) else {
            return Readout(groundspeed: dashes, track: dashes, altitude: dashes, message: message)
        }
        // Adding zero turns a negative zero into a plain one, so a small negative value reads 0.
        let whole = { (value: Double) in fixed(value.rounded() + 0, 0) }
        return Readout(
            groundspeed: position.groundspeedKt.map(whole) ?? dashes,
            track: position.trackTrue.map {
                bearing($0, from: position.coordinate, altitudeFt: position.altitudeFtMSL ?? 0, date: now)
            } ?? dashes,
            altitude: position.altitudeFtMSL.map(whole) ?? dashes,
            message: message)
    }

    /// Fuel in gallons to one decimal, such as 12.5 gal.
    public static func fuel(_ gallons: Double) -> String { fixed(gallons, 1) + " gal" }

    /// What is wrong with one token of a typed route, in plain words.
    public static func routeProblem(_ kind: RouteProblemKind, _ token: String) -> String {
        switch kind {
        case .unknownIdentifier: "\(token) is not an airport, navaid or fix"
        case .pointNotOnAirway: "\(token) is not on the airway next to it"
        case .airwayBroken: "\(token) has a break between the points on either side"
        case .malformedCoordinate: "\(token) is not a position Blueside can read"
        case .airwayWithoutPoint: "\(token) needs a waypoint before and after it"
        case .airwaysDoNotMeet: "\(token) does not meet the airway before it"
        case .airwaysMeetMoreThanOnce: "\(token) meets the airway before it more than once: type where to change"
        case .badRadialDistance: "\(token) has a radial or distance out of range"
        }
    }
}

// MARK: - Plain formatting

extension NavText {
    /// Fixed decimals as printf's %.Nf writes them: the exact binary value, ties to even.
    public static func fixed(_ value: Double, _ digits: Int) -> String {
        guard value.isFinite else { return value.isNaN ? "nan" : (value < 0 ? "-inf" : "inf") }
        let scale = (0..<digits).reduce(1.0) { value, _ in value * 10 }
        let magnitude = abs(value)
        let product = magnitude * scale
        // ponytail: past 2^63 the digits fall back to Swift's own; no screen shows such a number.
        guard product < 9e18 else { return String(describing: value) }
        var whole = product.rounded(.down)
        let fraction = product - whole
        // The product was rounded once; fma gives the exact remainder to settle a tie.
        let error = (-product).addingProduct(magnitude, scale)
        if fraction > 0.5 || (fraction == 0.5 && (error > 0 || (error == 0 && whole.truncatingRemainder(dividingBy: 2) == 1))) {
            whole += 1
        }
        var digitsText = String(UInt64(whole))
        if digits > 0 {
            if digitsText.count <= digits {
                digitsText = String(repeating: "0", count: digits + 1 - digitsText.count) + digitsText
            }
            digitsText.insert(".", at: digitsText.index(digitsText.endIndex, offsetBy: -digits))
        }
        return (value.sign == .minus ? "-" : "") + digitsText
    }

    /// A whole number with zeros in front up to width, such as 007.
    public static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(abs(value))
        return (value < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - text.count)) + text
    }

    /// A whole number with commas between thousands, such as 12,250.
    public static func grouped(_ value: Int) -> String {
        var text = String(abs(value))
        var at = text.count - 3
        while at > 0 {
            text.insert(",", at: text.index(text.startIndex, offsetBy: at))
            at -= 3
        }
        return (value < 0 ? "-" : "") + text
    }

    /// Each word with a capital first letter and the rest lower case, as Foundation's capitalized does.
    public static func capitalized(_ text: String) -> String {
        var out = ""
        var previous: Character?
        for character in text {
            let starts = previous.map { !$0.isLetter && $0 != "'" && $0 != "’" } ?? true
            out += character.isLetter ? (starts ? character.uppercased() : character.lowercased()) : String(character)
            previous = character
        }
        return out
    }
}

/// UTC calendar fields worked out from the seconds, with no calendar object.
struct UTCTime {
    var year, month, day, hour, minute, second: Int

    init(_ date: Date) {
        let total = Int(date.timeIntervalSince1970.rounded(.down))
        let days = total >= 0 ? total / 86400 : (total - 86399) / 86400
        let seconds = total - days * 86400
        (hour, minute, second) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        // Days to civil date in the proleptic Gregorian calendar (Hinnant).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shifted = (5 * dayOfYear + 2) / 153
        day = dayOfYear - (153 * shifted + 2) / 5 + 1
        month = shifted < 10 ? shifted + 3 : shifted - 9
        year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    }

    var monthName: String {
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][month - 1]
    }
}
