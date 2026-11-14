extension Taf {
    /// A TAF line, with new "ddhh/ddhh" periods or the older "ddhhhh" and "FMhhmm" forms. Nil when the issue time or
    /// the valid period cannot be read. As with the downloaded file, a TAF keeps all of its groups or none.
    static func parse(_ raw: String, near now: Date) -> Taf? {
        var tokens = raw.split(separator: " ").map(String.init)
        guard tokens.first == "TAF" else { return nil }
        tokens.removeFirst()
        if tokens.first == "AMD" || tokens.first == "COR" { tokens.removeFirst() }
        guard tokens.count >= 3, let issued = FISB.date(group: tokens[1], near: now),
              let (validFrom, validTo) = period(tokens[2], near: issued, after: nil) else { return nil }
        var taf = Taf(station: tokens[0], issued: issued, validFrom: validFrom, validTo: validTo, raw: raw)

        struct Draft {
            var group: TafGroup
            var weather: [String] = []
            var sky: [SkyLayer] = []
            var previous = ""
        }
        func draft(_ kind: TafGroup.Kind, _ from: Date, _ to: Date, probability: Int? = nil) -> Draft {
            Draft(group: TafGroup(kind: kind, from: from, to: to, becomingBy: kind == .becoming ? to : nil,
                                  probability: probability, windDirection: nil, windVariable: false, windSpeedKt: nil,
                                  windGustKt: nil, visibilityMiles: nil, visibilityOrMore: false, weather: nil, sky: nil,
                                  verticalVisibilityFt: nil, windShear: nil))
        }
        var drafts = [draft(.initial, validFrom, validTo)]
        var failed = false
        var i = 3
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            let current = drafts.lastIndex { $0.group.kind == .initial || $0.group.kind == .from } ?? 0
            if token.hasPrefix("FM"), let from = fromTime(token, after: drafts[current].group.from) {
                drafts[current].group.to = from
                drafts.append(draft(.from, from, validTo))
            } else if ["BECMG", "TEMPO"].contains(token) || token.hasPrefix("PROB"), token.count == 5 || token.count == 6 {
                var probability: Int?
                var kind: TafGroup.Kind = token == "BECMG" ? .becoming : .temporary
                if token.hasPrefix("PROB") {
                    probability = Int(token.dropFirst(4))
                    kind = .probability
                    if i < tokens.count, tokens[i] == "TEMPO" { i += 1 }
                }
                guard i < tokens.count, let (from, to) = period(tokens[i], near: validFrom, after: validFrom), from < to else {
                    failed = true
                    break
                }
                i += 1
                drafts.append(draft(kind, from, to, probability: probability))
            } else if token == "=" {
                break
            } else if token.hasPrefix("TX") || token.hasPrefix("TN") {
                continue
            } else if let wind = ReportToken.wind(token) {
                drafts[drafts.count - 1].group.windDirection = wind.direction
                drafts[drafts.count - 1].group.windVariable = wind.variable
                drafts[drafts.count - 1].group.windSpeedKt = wind.speed
                drafts[drafts.count - 1].group.windGustKt = wind.gust
            } else if let seen = ReportToken.visibility(token) {
                let whole = seen.fraction ? Double(drafts[drafts.count - 1].previous.count <= 2 ? drafts[drafts.count - 1].previous : "") ?? 0 : 0
                drafts[drafts.count - 1].group.visibilityMiles = whole + seen.miles
                drafts[drafts.count - 1].group.visibilityOrMore = seen.orMore
            } else if let layer = ReportToken.sky(token) {
                // Vertical visibility is its own field here, with the obscured sky as the layer.
                if layer.cover == "OVX" {
                    drafts[drafts.count - 1].group.verticalVisibilityFt = layer.baseFtAGL
                    drafts[drafts.count - 1].sky.append(SkyLayer(cover: "OVX", baseFtAGL: nil))
                } else {
                    drafts[drafts.count - 1].sky.append(layer)
                }
            } else if let weather = token == "NSW" ? [token] : ReportToken.weather(token) {
                // NSW ends the weather before it, as the downloaded TAFs read it.
                drafts[drafts.count - 1].weather += weather
            } else if token.hasPrefix("WS"), let shear = windShear(token) {
                drafts[drafts.count - 1].group.windShear = shear
            }
            drafts[drafts.count - 1].previous = token
        }
        guard !failed else { return taf }
        taf.groups = drafts.map { draft in
            var group = draft.group
            group.weather = draft.weather.isEmpty ? nil : draft.weather.joined(separator: " ")
            group.sky = draft.sky.isEmpty ? nil : draft.sky
            return group
        }.filter { $0.from < $0.to }
        taf.groups.sort { ($0.from, rank($0.kind)) < ($1.from, rank($1.kind)) }
        return taf
    }

    private static func rank(_ kind: TafGroup.Kind) -> Int {
        switch kind {
        case .initial: 0
        case .from: 1
        case .becoming: 2
        case .temporary, .probability: 3
        }
    }

    /// "ddhh/ddhh", or the older "ddhhhh" (day, hour, hour) and "hhhh". Times lie nearest the reference, or after `after`.
    private static func period(_ token: String, near reference: Date, after: Date?) -> (Date, Date)? {
        let digits = token.compactMap(\.wholeNumberValue)
        func number(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }
        guard token.allSatisfy({ $0.isASCIIDigit || $0 == "/" }) else { return nil }
        func resolve(day: Int?, hour: Int, from: Date? = nil) -> Date? {
            if let day { return FISB.date(day: day, hour: hour, near: reference) }
            // No day: the next such hour after the start.
            guard let start = from ?? after else { return nil }
            let midnight = (start.timeIntervalSince1970 / 86400).rounded(.down) * 86400
            let at = Date(timeIntervalSince1970: midnight + Double(hour * 3600))
            return at < start ? at.addingTimeInterval(86400) : at
        }
        var result: (Date?, Date?)
        if token.count == 9, digits.count == 8, token.dropFirst(4).first == "/" {
            result = (resolve(day: number(0..<2), hour: number(2..<4)), resolve(day: number(4..<6), hour: number(6..<8)))
        } else if token.count == 6, digits.count == 6 {
            let from = resolve(day: number(0..<2), hour: number(2..<4))
            result = (from, resolve(day: nil, hour: number(4..<6), from: from))
        } else if token.count == 4, digits.count == 4, let start = after {
            let from = resolve(day: nil, hour: number(0..<2), from: start)
            result = (from, resolve(day: nil, hour: number(2..<4), from: from))
        } else {
            return nil
        }
        guard let from = result.0, let to = result.1 else { return nil }
        return (from, to)
    }

    /// "FMddhhmm" or the older "FMhhmm", the first such time after `after`.
    private static func fromTime(_ token: String, after: Date) -> Date? {
        let digits = token.dropFirst(2).compactMap(\.wholeNumberValue)
        guard digits.count == token.count - 2, digits.count == 6 || digits.count == 4 else { return nil }
        let value = { (range: Range<Int>) in digits[range].reduce(0) { $0 * 10 + $1 } }
        if digits.count == 6 {
            return FISB.date(day: value(0..<2), hour: value(2..<4), minute: value(4..<6), near: after)
        }
        let midnight = (after.timeIntervalSince1970 / 86400).rounded(.down) * 86400
        let at = Date(timeIntervalSince1970: midnight + Double(value(0..<2) * 3600 + value(2..<4) * 60))
        return at <= after ? at.addingTimeInterval(86400) : at
    }

    /// "WShhh/dddssKT": the height in hundreds of feet, then the wind.
    private static func windShear(_ token: String) -> WindShear? {
        let parts = token.dropFirst(2).split(separator: "/")
        guard parts.count == 2, parts[0].count == 3, let height = Int(parts[0]), let wind = ReportToken.wind(String(parts[1])),
              let direction = wind.direction else { return nil }
        return WindShear(heightFtAGL: height * 100, directionTrue: direction, speedKt: wind.speed)
    }
}
