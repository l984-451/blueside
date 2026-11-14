/// The words an airport page, place card and list row show.
extension NavText {
    /// The one code an airport goes by: its ICAO code, or the FAA code when it has none.
    public static func title(_ airport: Airport) -> String { airport.icao ?? airport.ident }

    /// The FAA code, only when it is not the ICAO code minus its first letter.
    public static func faaCode(_ airport: Airport) -> String? {
        airport.icao.map { $0.dropFirst() == airport.ident } == false ? airport.ident : nil
    }

    /// An elevation in whole feet, such as 542 ft.
    public static func elevation(_ feet: Double) -> String { grouped(Int(feet.rounded())) + " ft" }

    /// Austin, TX · 542 ft · Private, leaving out whatever is not published.
    public static func placeLine(_ airport: Airport) -> String {
        let place = [capitalized(airport.city), airport.state].filter { !$0.isEmpty }.joined(separator: ", ")
        let parts = [place.isEmpty ? nil : place, airport.elevationFt.map(elevation), kindLabel(airport).map(capitalized)]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// Closed, for any facility that is not operational.
    public static func closedLabel(_ airport: Airport) -> String? { airport.isOperational ? nil : "Closed" }

    /// PRIVATE for a field that is not public use, and the kind of any facility that is not an airport.
    public static func kindLabel(_ airport: Airport) -> String? {
        let kinds = ["H": "HELIPORT", "C": "SEAPLANE BASE", "U": "ULTRALIGHT", "G": "GLIDERPORT", "B": "BALLOONPORT"]
        let parts = [airport.use == "PU" ? nil : "PRIVATE", kinds[airport.type]].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// One row of an airport's details: a title and its value.
    public struct Fact: Equatable, Sendable {
        public var title: String
        public var value: String
    }

    /// The details section, leaving out whatever is not published.
    public static func facts(_ airport: Airport) -> [Fact] {
        let rows: [(String, String?)] = [
            ("FAA code", faaCode(airport)), ("Elevation", airport.elevationFt.map(elevation)),
            ("Magnetic variation", airport.magneticVariation), ("Coordinates", degreesMinutes(airport.coordinate)),
            ("Pattern altitude", airport.patternAltitude), ("Fuel", airport.fuel),
        ]
        return rows.compactMap { title, value in value.map { Fact(title: title, value: $0) } }
    }

    /// The first runway whose remarks close it outright, for the page header.
    public static func closedRunway(_ detail: AirportDetail) -> Runway? {
        detail.runways.first { runwayNote($0, in: detail.remarks) == "CLOSED" }
    }

    /// The bar subtitle of a navaid, fix or dropped pin.
    public static func placeSubtitle(_ place: WaypointMatch, navaidType: String?, fixState: String?) -> String {
        switch place.kind {
        case .user: "Dropped Pin"
        case .fix: ["Fix", fixState].compactMap { $0 }.joined(separator: " · ")
        default: [capitalized(place.name), navaidType].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// The second word of a navaid or fix list row.
    public static func placeRowName(_ place: WaypointMatch) -> String {
        place.kind == .fix ? "Fix" : place.name + " · Navaid"
    }

    /// Length, width, surface and lights, such as 12,250 × 150 ft · Concrete · HIRL.
    public static func runwayLine(_ runway: Runway) -> String {
        let size = [runway.lengthFt, runway.widthFt].compactMap { $0 }.map(grouped).joined(separator: " × ")
        let surfaces = ["ASPH": "Asphalt", "CONC": "Concrete", "TURF": "Turf", "GRVL": "Gravel", "DIRT": "Dirt",
                        "WATER": "Water", "DECK": "Deck", "MATS": "Mats", "SNOW": "Snow", "ICE": "Ice"]
        let lights = ["HIGH": "HIRL", "MED": "MIRL", "LOW": "LIRL", "PERI": "Perimeter lights",
                      "STRB": "Strobe lights", "NSTD": "Nonstandard lights", "FLOOD": "Floodlights"]
        let parts: [String?] = [size.isEmpty ? nil : size + " ft", runway.surface.map { surfaces[$0] ?? $0 },
                                runway.lights.flatMap { $0 == "NONE" ? nil : lights[$0] ?? $0 }]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// One item of an airport's at-a-glance row. copy is the frequency a tap copies.
    public struct Glance: Equatable, Sendable {
        public var label: String
        public var value: String
        public var copy: String?

        public init(label: String, value: String, copy: String? = nil) {
            self.label = label
            self.value = value
            self.copy = copy
        }
    }

    /// What a pilot wants first, chosen by the kind of airport: its weather frequency, the tower or the
    /// common traffic frequency, and the best runway for a current wind, else the longest open runway.
    public static func glance(_ detail: AirportDetail, best: RunwayChoice? = nil) -> [Glance] {
        let list = frequencies(detail.frequencies)
        let first = { (kinds: [FrequencyKind]) in kinds.lazy.compactMap { kind in list.first { $0.kind == kind } }.first }
        let traffic: [FrequencyKind] = list.contains { $0.kind == .tower } ? [.tower] : [.ctaf, .unicom]
        var items = [first([.atis, .weather]), first(traffic)].compactMap { $0 }
            .map { Glance(label: frequencyLabel($0), value: $0.frequency, copy: $0.frequency) }
        if let best {
            items.append(Glance(label: "Best runway", value: best.end.id))
        } else if let runway = runways(detail).first, runwayNote(runway, in: detail.remarks) != "CLOSED" {
            items.append(Glance(label: "Longest runway", value: runway.id))
        }
        return items
    }

    /// The at-a-glance items as one short line for a list row.
    public static func quickLine(_ detail: AirportDetail) -> String {
        let runway = runways(detail).first.flatMap { r in r.lengthFt.map { "\(r.id) \(grouped($0)) ft" } }
        return glance(detail).map { $0.copy == nil ? (runway ?? $0.value) : "\($0.label) \($0.value)" }
            .joined(separator: " · ")
    }

    /// Open runways longest first, then closed ones.
    public static func runways(_ detail: AirportDetail) -> [Runway] {
        let closed = { (runway: Runway) in runwayNote(runway, in: detail.remarks) == "CLOSED" }
        return detail.runways.enumerated().sorted { a, b in
            let key = { (r: Runway) in (closed(r) ? 1 : 0, -(r.lengthFt ?? 0)) }
            return key(a.element) != key(b.element) ? key(a.element) < key(b.element) : a.offset < b.offset
        }.map(\.element)
    }

    /// Frequencies in the order a pilot uses them, ATIS first and anything unnamed last.
    public static func frequencies(_ list: [Frequency]) -> [Frequency] {
        let order: [FrequencyKind] = [.atis, .weather, .clearance, .ground, .tower, .approach, .departure,
                                      .ctaf, .unicom, .emergency, .other]
        return list.enumerated().sorted {
            let a = order.firstIndex(of: $0.element.kind)!, b = order.firstIndex(of: $1.element.kind)!
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }

    /// The name a pilot calls a frequency by, such as Tower or AWOS-3.
    public static func frequencyLabel(_ frequency: Frequency) -> String {
        let names: [FrequencyKind: String] = [.atis: "ATIS", .clearance: "Clearance", .ground: "Ground",
                                              .tower: "Tower", .approach: "Approach", .departure: "Departure",
                                              .ctaf: "CTAF", .unicom: "UNICOM", .emergency: "Emergency"]
        let name = names[frequency.kind] ?? (frequency.kind == .weather
            ? String(frequency.use.split(separator: " ").last ?? "") : frequency.use)
        return [name, frequency.sector.map(capitalized)].compactMap { $0 }.joined(separator: " ")
    }

    /// A remark with the runway, end or item it is about in front, such as 07/25: CLSD INDEFLY.
    public static func remarkLine(_ remark: Remark) -> String {
        remark.element.flatMap { $0.isEmpty ? nil : "\($0): \(remark.text)" } ?? remark.text
    }

    /// The FAA remarks filed against one runway or either of its ends, in the FAA's own words.
    public static func runwayRemarks(_ runway: Runway, in remarks: [Remark]) -> [String] {
        let ids = Set([runway.id] + runway.ends.map(\.id))
        return remarks.filter { ($0.tab ?? "").hasPrefix("RUNWAY") && ids.contains($0.element ?? "") }
            .map(remarkLine)
    }

    private static func words(_ text: String) -> [String] {
        text.uppercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    // A sentence ends at a semicolon or at a full stop that is not a decimal point.
    private static func sentences(_ text: String) -> [String] {
        let characters = Array(text)
        var out = [""]
        for (index, character) in characters.enumerated() {
            let decimal = character == "." && index + 1 < characters.count && characters[index + 1].isNumber
            if character == ";" || (character == "." && !decimal) {
                out.append("")
            } else {
                out[out.count - 1].append(character)
            }
        }
        return out.map(\.trimmed).filter { !words($0).isEmpty }
    }

    // 07 and 7 name the same runway end.
    private static func unpadded(_ word: String) -> String {
        let cut = String(word.drop { $0 == "0" })
        return cut.isEmpty ? "0" : cut
    }

    /// CLOSED only when a sentence closes the whole runway outright. Any other closure sentence is quoted. Nil when none.
    public static func runwayClosure(id: String, remarks: [String]) -> String? {
        let closing: Set<String> = ["CLSD", "CLOSED"]
        // With one of these in front, something other than the runway is closing.
        let elsewhere: Set<String> = ["ATCT", "TWR", "TOWER", "ARPT", "AIRPORT", "FBO", "TWY", "WHEN", "IF"]
        let naming: Set<String> = ["RWY", "RY", "RUNWAY", "HELIPAD", "TEMP"]
        let outright: Set<String> = ["INDEFLY", "INDEF", "PERMLY", "UFN"]
        let own = Set(words(id).map(unpadded))
        var quoted: String?
        for remark in remarks {
            for sentence in sentences(remark) {
                let found = words(sentence)
                guard let at = found.firstIndex(where: closing.contains) else { continue }
                let before = found[..<at]
                if before.contains(where: elsewhere.contains) { continue }
                let whole = before.allSatisfy { naming.contains($0) || own.contains(unpadded($0)) }
                let next = at + 1 < found.count ? found[at + 1] : nil
                if whole, next.map(outright.contains) ?? true { return "CLOSED" }
                quoted = quoted ?? "CLOSURE REMARK: \(remark)"
            }
        }
        return quoted
    }

    /// The closure words for one runway: remarks filed against it, against one of its ends, or against the airport by name.
    public static func runwayNote(_ runway: Runway, in remarks: [Remark]) -> String? {
        let ends = Set(runway.ends.map(\.id))
        let name = words(runway.id).map(unpadded)
        var texts: [String] = []
        for remark in remarks {
            let tab = remark.tab ?? ""
            let element = remark.element ?? ""
            if tab.hasPrefix("RUNWAY"), element == runway.id {
                texts.append(remark.text)
            } else if tab.hasPrefix("RUNWAY"), ends.contains(element) {
                texts.append("END \(element) \(remark.text)")
            } else if tab == "AIRPORT" {
                // An airport remark counts only where a sentence begins with this runway's name.
                texts += sentences(remark.text).filter { sentence in
                    let found = words(sentence).map(unpadded)
                    return ["RWY", "RY"].contains(found.first ?? "") && Array(found.dropFirst().prefix(name.count)) == name
                }
            }
        }
        return runwayClosure(id: runway.id, remarks: texts)
    }

    /// True only when the frequency's own text says the service itself is out of service or decommissioned.
    public static func outOfService(use: String, frequency: String, remark: String?) -> Bool {
        let dead: Set<String> = ["OTS", "DCMSND"]
        let mine = words(use)
        if mine.contains(where: dead.contains) { return true }
        let service = Set(mine + words(frequency) + ["FREQ", "FREQUENCY", "CTAF", "UNICOM"])
        for (index, sentence) in sentences(remark ?? "").enumerated() {
            let text = sentence.uppercased().replacing("OUT OF SERVICE", with: "OTS")
                .replacing("OUT OF SVC", with: "OTS")
            let found = words(text)
            guard let at = found.firstIndex(where: dead.contains) else { continue }
            // A bare OTS speaks for the frequency only when it opens the remark; later it is about the item before it.
            let aboutThis = at == 0 ? index == 0 : found[..<at].allSatisfy(service.contains)
            if aboutThis { return true }
        }
        return false
    }
}
