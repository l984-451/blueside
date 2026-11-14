extension FISB {
    public enum ReportKind: Equatable, Sendable { case metar, taf }

    /// A METAR, SPECI or TAF text record split into its fields. The text is whitespace-normalised.
    public struct Record: Equatable, Sendable {
        public var kind: ReportKind
        public var station: String
        /// The day, hour and minute group, such as 260855Z.
        public var time: String
        /// The whole report as a line, with SPECI or AMD in place when the record says so.
        public var raw: String
    }

    /// Reads "<Type> <LocID> <Time>[SP|AM] <text>". Nil for a record that is not a METAR or TAF, or is a NIL.
    public static func record(_ text: String) -> Record? {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 4 else { return nil }
        let type = words[0].split(separator: ".").map(String.init)
        guard let first = type.first, ["METAR", "SPECI", "TAF"].contains(first) else { return nil }
        // A flag follows the time group: SP for a special report, AM for an amended forecast.
        var time = words[2]
        var special = false, amended = type.contains("AMD")
        for (flag, word) in [("SP", words[3]), ("AM", words[3])] where word == flag && words.count > 4 {
            words.remove(at: 3)
            (special, amended) = (special || flag == "SP", amended || flag == "AM")
        }
        for flag in ["SP", "AM"] where time.hasSuffix(flag) {
            time.removeLast(2)
            (special, amended) = (special || flag == "SP", amended || flag == "AM")
        }
        if words.last == "=" { words.removeLast() } else if words[words.count - 1].hasSuffix("=") { words[words.count - 1].removeLast() }
        guard time.count == 7, time.hasSuffix("Z"), time.dropLast().allSatisfy(\.isASCIIDigit), !words[3...].contains("NIL")
        else { return nil }
        let kind: ReportKind = first == "TAF" ? .taf : .metar
        let head = [kind == .metar && special ? "SPECI" : first] + (kind == .taf && amended ? ["AMD"] : [])
        return Record(kind: kind, station: words[1], time: time, raw: (head + [words[1], time] + words[3...]).joined(separator: " "))
    }

    /// The date with this day of the month, hour and minute that lies nearest the reference. Hour 24 is midnight after.
    static func date(day: Int, hour: Int, minute: Int = 0, near reference: Date) -> Date? {
        guard (1...31).contains(day), (0...24).contains(hour), (0...59).contains(minute) else { return nil }
        let midnight = (reference.timeIntervalSince1970 / 86400).rounded(.down) * 86400
        return (-16...16).compactMap { k -> Date? in
            let start = midnight + Double(k) * 86400
            guard UTCTime(Date(timeIntervalSince1970: start)).day == day else { return nil }
            return Date(timeIntervalSince1970: start + Double(hour * 3600 + minute * 60))
        }.min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
    }

    /// Day, hour and minute of a "ddhhmmZ" group.
    static func date(group: String, near reference: Date) -> Date? {
        let digits = group.dropLast().compactMap(\.wholeNumberValue)
        guard group.hasSuffix("Z"), digits.count == 6 else { return nil }
        return date(day: digits[0] * 10 + digits[1], hour: digits[2] * 10 + digits[3],
                    minute: digits[4] * 10 + digits[5], near: reference)
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// The report elements METARs and TAFs share, read one token at a time.
enum ReportToken {
    struct Wind {
        var direction: Int?
        var variable: Bool
        var speed: Int
        var gust: Int?
    }

    private static func number<S: StringProtocol>(_ text: S) -> Int? {
        !text.isEmpty && text.allSatisfy(\.isASCIIDigit) ? Int(text) : nil
    }

    /// dddss[Gss]KT or VRBssKT.
    static func wind(_ token: String) -> Wind? {
        guard token.hasSuffix("KT"), token.count >= 7 else { return nil }
        let body = token.dropLast(2)
        let variable = body.hasPrefix("VRB")
        let direction = variable ? nil : number(body.prefix(3))
        guard variable || direction != nil else { return nil }
        let parts = body.dropFirst(3).split(separator: "G", omittingEmptySubsequences: false)
        guard parts.count <= 2, let speed = number(parts[0]), parts.count == 1 || number(parts[1]) != nil else { return nil }
        return Wind(direction: direction, variable: variable, speed: speed, gust: parts.count == 2 ? number(parts[1]) : nil)
    }

    /// "dddVddd", the range a variable wind swings through.
    static func windRange(_ token: String) -> Bool {
        token.count == 7 && token.dropFirst(3).first == "V" && number(token.prefix(3)) != nil && number(token.suffix(3)) != nil
    }

    /// Statute miles from nnSM, n/nSM, Mn/nSM or Pn SM. A whole part in the token before a fraction is added by the caller.
    static func visibility(_ token: String) -> (miles: Double, orMore: Bool, fraction: Bool)? {
        guard token.hasSuffix("SM") else { return nil }
        var body = token.dropLast(2)
        let orMore = body.hasPrefix("P")
        if orMore || body.hasPrefix("M") { body = body.dropFirst() }
        let parts = body.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 1, let whole = number(parts[0]) { return (Double(whole), orMore, false) }
        if parts.count == 2, let top = number(parts[0]), let bottom = number(parts[1]), bottom > 0 {
            return (Double(top) / Double(bottom), orMore, true)
        }
        return nil
    }

    /// A sky layer, or vertical visibility as an obscured layer with the height as its base.
    static func sky(_ token: String) -> SkyLayer? {
        if ["SKC", "CLR", "NSC", "NCD"].contains(token) { return SkyLayer(cover: token, baseFtAGL: nil) }
        let cover = token.prefix(token.hasPrefix("VV") ? 2 : 3)
        let rest = token.dropFirst(cover.count)
        guard ["FEW", "SCT", "BKN", "OVC", "VV"].contains(String(cover)), let base = number(rest.prefix(3)) else { return nil }
        let type = String(rest.dropFirst(3))
        guard type.isEmpty || (cover != "VV" && ["CB", "TCU"].contains(type)) else { return nil }
        return SkyLayer(cover: cover == "VV" ? "OVX" : String(cover), baseFtAGL: base * 100, cloudType: type.isEmpty ? nil : type)
    }

    /// A present-weather group such as -SN, +TSRA or VCSH, as one entry for each phenomenon with its intensity and
    /// descriptor: -SHRASN gives -SHRA and -SHSN. Nil when the token is not weather.
    static func weather(_ token: String) -> [String]? {
        var rest = Substring(token)
        let intensity = rest.hasPrefix("-") || rest.hasPrefix("+") ? String(rest.removeFirst()) : ""
        guard !rest.isEmpty, rest.count % 2 == 0, rest.allSatisfy({ $0.isUppercase && $0.isASCII }) else { return nil }
        let descriptors: Set<String> = ["VC", "MI", "PR", "BC", "DR", "BL", "SH", "TS", "FZ"]
        let phenomena: Set<String> = ["DZ", "RA", "SN", "SG", "IC", "PL", "GR", "GS", "UP", "BR", "FG", "FU", "VA", "DU", "SA",
                                      "HZ", "PY", "PO", "SQ", "FC", "SS", "DS"]
        let codes = stride(from: 0, to: rest.count, by: 2).map { String(rest.dropFirst($0).prefix(2)) }
        guard codes.allSatisfy({ descriptors.contains($0) || phenomena.contains($0) }) else { return nil }
        let lead = codes.prefix { descriptors.contains($0) }
        let tail = codes.dropFirst(lead.count)
        return tail.isEmpty ? [token] : tail.map { intensity + lead.joined() + $0 }
    }
}

extension Metar {
    /// A METAR or SPECI line. Nil when its time or station cannot be read. `near` dates the day of the month.
    static func parse(_ raw: String, coordinate: Coordinate, near now: Date) -> Metar? {
        let tokens = raw.split(separator: " ").map(String.init)
        guard tokens.count >= 3, let observed = FISB.date(group: tokens[2], near: now) else { return nil }
        var metar = Metar(station: tokens[1], coordinate: coordinate, category: .unknown, ceilingFtAGL: nil,
                          visibilityMiles: nil, visibilityOrMore: false, windDirection: nil, windVariable: false,
                          windSpeedKt: nil, windGustKt: nil, temperatureC: nil, dewpointC: nil, altimeterInHg: nil,
                          observed: observed, raw: raw)
        var previous = ""
        var inRemarks = false
        for token in tokens.dropFirst(3) {
            defer { previous = token }
            if token == "RMK" { inRemarks = true; continue }
            if inRemarks {
                // The remarks give the temperatures to a tenth: T followed by sign and 3 digits, twice.
                if [5, 9].contains(token.count), token.hasPrefix("T"), token.dropFirst().allSatisfy(\.isASCIIDigit) {
                    func value(_ part: Substring) -> Double { Double(Int(part.dropFirst())!) / 10 * (part.first == "1" ? -1 : 1) }
                    metar.temperatureC = value(token.dropFirst().prefix(4))
                    if token.count == 9 { metar.dewpointC = value(token.dropFirst(5)) }
                }
                continue
            }
            if let wind = ReportToken.wind(token) {
                (metar.windDirection, metar.windVariable, metar.windSpeedKt, metar.windGustKt) = (wind.direction, wind.variable, wind.speed, wind.gust)
            } else if ReportToken.windRange(token) {
                continue
            } else if let seen = ReportToken.visibility(token) {
                let whole = seen.fraction ? Double(previous.count <= 2 ? previous : "") ?? 0 : 0
                metar.visibilityMiles = whole + seen.miles
                metar.visibilityOrMore = seen.orMore || whole + seen.miles >= 10
            } else if let layer = ReportToken.sky(token) {
                // A clear sky is no layer.
                if layer.baseFtAGL != nil, metar.sky.count < 4 { metar.sky.append(SkyLayer(cover: layer.cover, baseFtAGL: layer.baseFtAGL)) }
            } else if token.hasPrefix("A"), token.count == 5, let inches = Int(token.dropFirst()) {
                metar.altimeterInHg = Double(inches) / 100
            } else if let (temp, dew) = temperatures(token) {
                (metar.temperatureC, metar.dewpointC) = (temp, dew)
            }
        }
        metar.ceilingFtAGL = metar.sky.filter(\.isCeiling).compactMap(\.baseFtAGL).min()
        if let miles = metar.visibilityMiles {
            metar.category = FlightCategory.from(visibilityMiles: miles, ceilingFtAGL: metar.ceilingFtAGL)
        }
        return metar
    }

    /// "12/08", "M05/M08" or "12/", in degrees Celsius.
    private static func temperatures(_ token: String) -> (Double?, Double?)? {
        func value(_ text: Substring) -> Double?? {
            if text.isEmpty { return .some(nil) }
            let negative = text.hasPrefix("M")
            let digits = negative ? text.dropFirst() : text
            guard digits.count == 2, let n = Int(digits) else { return nil }
            return .some(Double(negative ? -n : n))
        }
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let temp = value(parts[0]), let dew = value(parts[1]) else { return nil }
        return (temp, dew)
    }
}
