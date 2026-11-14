import FlightCore

/// Route ops: the plan crosses as its Codable JSON, and every edit, line, row and total comes from the core.
extension Bridge {
    /// A grabbed leg or dot of the drawn route. kind is leg or point.
    struct Grab: Codable, Equatable {
        var kind: String
        var index: Int

        init(_ grab: RouteGrab) {
            switch grab {
            case .leg(let i): (kind, index) = ("leg", i)
            case .point(let i): (kind, index) = ("point", i)
            }
        }

        var grab: RouteGrab { kind == "leg" ? .leg(index) : .point(index) }
    }

    /// op is direct, add, remove, move, directTarget, replace, typed, bend, bendTo or clear.
    struct RouteEdit: Decodable {
        var op: String
        var place: Place?
        var target: Int?
        var to: Int?
        var text: String?
        var grab: Grab?
        var drawnCount: Int?
        var hits: [Hit]?
        var at: Coordinate?
        var metersPerPoint: Double?
    }

    struct RouteArgs: Decodable {
        var plan: RoutePlan?
        var edit: RouteEdit?
        var fix: Fix?
        var approximate: Bool?
        var now: Date
        var speed: Double?
        var burn: Double?
        /// The last call's plan key, so a kept start stays put. Kotlin holds it and compares it without reading.
        var planKey: RoutePages.PlanKey?
    }

    struct Leg: Encodable {
        var row: RoutePlan.LegRow
        var closed: Bool
    }

    struct Dot: Encodable { var ident: String; var latitude: Double; var longitude: Double }

    /// The drawn route: its waypoints (for grabbing), the bent line, the active leg's line and the labeled dots.
    struct DrawnLine: Encodable {
        var points: [Coordinate]
        var path: [Coordinate]
        var active: [Coordinate]?
        var dots: [Dot]
        var firstDot: Int
    }

    struct EditorPoint: Encodable {
        var title: String
        var name: String?
        var target: Int
        var closed: Bool
        var leg: RoutePlan.LegRow?
    }

    struct Editor: Encodable {
        var header: String
        var points: [EditorPoint]
        var totals: [NavPages.Line]
    }

    struct Suggestion: Encodable { var ident: String; var detail: String; var place: Place }

    struct TypedView: Encodable {
        var suggestions: [Suggestion]
        var problems: [String]
        var notes: [String]
    }

    struct Offer: Encodable { var target: Int; var places: [Item] }

    struct RouteResult: Encodable {
        var plan: RoutePlan?
        var title: String?
        var text: String
        var rows: [Leg]
        var summary: RoutePages.Summary?
        var line: DrawnLine?
        var editor: Editor?
        var typed: TypedView?
        var offer: Offer?
        var choose: [Item]?
        /// True when this call sequenced a leg, so the route goes in Recent.
        var flown = false
        /// With `plan`, changes only when the plan page can differ, its inputs, aircraft and weather aside.
        /// Its route is `plan`, so it crosses without it.
        var planKey: RoutePages.PlanKey?
    }

    /// Applies one edit, steps the active leg from the fix, and lays the route out for the drawer, editor and map.
    static func route(_ nav: NavSession, _ a: RouteArgs) -> RouteResult {
        let db = nav.database
        let position = position(a.fix)
        let approximate = Bridge.approximate(a.approximate, a.fix)
        let cycle = db.metadata.cycle
        var plan = a.plan
        var typed: TypedView?
        var offer: Offer?
        var choose: [Item]?
        if let edit = a.edit {
            let point = edit.place.map { RouteWaypoint(match: $0.match) }
            switch edit.op {
            case "direct": if let point { plan = .direct(to: point, navCycle: cycle) }
            case "add":
                if let point {
                    plan = .adding(point, to: plan, position: position, approximate: approximate, now: a.now, navCycle: cycle)
                }
            case "remove": if let target = edit.target { plan = plan?.removing(target: target) }
            case "move": if let target = edit.target, let to = edit.to { plan = plan?.moving(from: target, to: to) }
            case "directTarget": if let target = edit.target { plan = plan?.direct(toTarget: target) }
            case "replace":
                if let target = edit.target, let point { plan = plan?.replacing(target: target, with: point) ?? plan }
            case "typed":
                let result = RoutePages.typed(edit.text ?? "", plan: plan, database: db, now: a.now)
                if result.replaces { plan = result.plan }
                typed = TypedView(
                    suggestions: result.suggestions.map {
                        Suggestion(ident: RoutePages.ident($0), detail: RoutePages.suggestionDetail($0), place: Place($0))
                    },
                    problems: result.problems, notes: result.notes)
            case "bend":
                guard let current = plan, let grab = edit.grab?.grab, let count = edit.drawnCount, let at = edit.at else { break }
                let snap = MapPick.snap((edit.hits ?? []).map { ($0.place.match, $0.distance) })
                switch RoutePages.bend(current, grab, drawnCount: count, snap: snap, at: at) {
                case .edit(let edited, let target)?:
                    plan = edited
                    if let target, let scale = edit.metersPerPoint {
                        let places = db.useInstead(near: at, metersPerPoint: scale)
                        if !places.isEmpty {
                            offer = Offer(target: target, places: places.map { item($0, NavPages.row($0), nav) })
                        }
                    }
                case .choose(let places)?: choose = places.map { item($0, NavPages.row($0), nav) }
                case nil: break
                }
            case "bendTo":
                if let grab = edit.grab?.grab, let count = edit.drawnCount, let point {
                    plan = plan?.bending(grab, drawnCount: count, to: point) ?? plan
                }
            case "clear": plan = nil
            case "restore": plan = plan ?? RoutePages.restored(edit.text, database: db, now: a.now)
            default: break
            }
        }
        let unflown = plan
        plan?.advance(position: position, approximate: approximate, now: a.now)
        guard let plan else { return RouteResult(text: "", rows: [], typed: typed) }

        let rows = plan.rows(position: position, approximate: approximate, now: a.now,
                             trueAirspeedKt: (a.speed ?? 0) > 0 ? a.speed : nil)
        let line = RoutePages.drawn(plan, position: position, approximate: approximate, now: a.now).map { drawn in
            let points = drawn.route.waypoints.map(\.coordinate)
            return DrawnLine(
                points: points, path: drawn.route.linePoints(),
                active: drawn.active.map { RoutePages.path(from: points[$0], to: points[$0 + 1]) },
                dots: drawn.dots.map { Dot(ident: $0.ident, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
                firstDot: drawn.firstDot)
        }
        let editor = RoutePages.editor(plan, position: position, approximate: approximate, now: a.now,
                                       trueAirspeedKt: a.speed ?? 0, fuelBurnPerHour: a.burn ?? 0)
        var key = RoutePages.planKey(plan, position: position, approximate: approximate, now: a.now, after: a.planKey)
        key.route = nil
        return RouteResult(
            plan: plan, title: RoutePages.title(plan), text: plan.text,
            rows: rows.map { Leg(row: $0, closed: db.isClosed($0.waypoint)) },
            summary: RoutePages.summary(rows), line: line,
            editor: Editor(header: editor.header,
                           points: editor.points.map {
                               EditorPoint(title: $0.title, name: $0.name, target: $0.target,
                                           closed: db.isClosed($0.waypoint), leg: $0.leg)
                           },
                           totals: editor.totals),
            typed: typed, offer: offer, choose: choose, flown: !plan.sameLeg(as: unflown), planKey: key)
    }

    struct Point: Codable { var x: Double; var y: Double }
    struct GrabArgs: Decodable { var points: [Point]; var firstDot: Int; var finger: Point }
    struct GrabResult: Encodable { var grab: Grab?; var anchors: [Int] }

    /// What a held finger grabs on the drawn route, in dp, and the ends its band stays fixed to.
    static func grab(_ a: GrabArgs) -> GrabResult {
        let found = MapPick.grab(a.points.map { ScreenPoint(x: $0.x, y: $0.y) }, firstDot: a.firstDot,
                                 at: ScreenPoint(x: a.finger.x, y: a.finger.y))
        return GrabResult(grab: found.map(Grab.init), anchors: found.map { MapPick.anchors($0, count: a.points.count) } ?? [])
    }

    struct SnapArgs: Decodable { var hits: [Hit] }
    struct SnapResult: Encodable { var label: String?; var target: Place? }

    /// What the band would snap to under the finger, said over it.
    static func snap(_ a: SnapArgs) -> SnapResult {
        let snap = MapPick.snap(a.hits.map { ($0.place.match, $0.distance) })
        if case .one(let place) = snap { return SnapResult(label: snap.label, target: Place(place)) }
        return SnapResult(label: snap.label)
    }

    struct RulerArgs: Decodable {
        var from: Coordinate
        var to: Coordinate
        var fix: Fix?
        var approximate: Bool?
        var now: Date
    }

    static func ruler(_ a: RulerArgs) -> [String: String] {
        ["text": NavText.ruler(from: a.from, to: a.to, position: position(a.fix),
                               approximate: Bridge.approximate(a.approximate, a.fix), now: a.now)]
    }

    struct TakeArgs: Decodable { var text: String; var place: Place }

    /// A plan view's `logShown`, each column's width by `logColumns` index with the gap after it, and the room across.
    struct FitArgs: Decodable { var shown: [Int]; var widths: [Double]; var room: Double }
    /// Nil when the page has no room for a table.
    struct Fitted: Encodable { var columns: [Int]? }

    struct FixArgs: Decodable { var fix: Fix?; var approximate: Bool?; var now: Date }

    /// The fixed words of the route screens.
    struct RouteLabels: Encodable {
        var directTitle = RoutePages.directTitle
        var routeTitle = RoutePages.routeTitle
        var expand = RoutePages.expand, collapse = RoutePages.collapse, logColumns = RoutePages.logColumns,
            logTime = RoutePages.logTime
        var planTitle = RoutePages.planTitle
        var edit = RoutePages.edit
        var done = RoutePages.done
        var clear = RoutePages.clear
        var undo = RoutePages.undo
        var edited = RoutePages.edited
        var closed = NavPages.closed
        var fuelBlock = RoutePages.fuelBlock
        var speedHint = RoutePages.speedHint
        var fieldPrompt = RoutePages.fieldPrompt
        var useInstead = RoutePages.useInstead
        var keepPoint = RoutePages.keepPoint
        var bendTitle = NavPages.bendTitle
        var speedTitle = RoutePages.speedTitle
        var burnTitle = RoutePages.burnTitle
        var aircraftNote = RoutePages.aircraftNote
        var speedKey = RoutePages.speedKey
        var burnKey = RoutePages.burnKey
        var offerSeconds = RoutePages.offerSeconds
        var undoSeconds = RoutePages.undoSeconds
        var planInputsKey = RoutePages.planInputsKey
        var planSection = RoutePages.planSection
        var departureTitle = RoutePages.departureTitle
        var rulesTitle = RoutePages.rulesTitle
        var rules = [FlightPlanInputs.Rules.vfr, .ifr].map { Rule(id: $0.rawValue, name: RoutePages.rulesName($0)) }
        var altitudeTitle = RoutePages.altitudeTitle
        var alternateTitle = RoutePages.alternateTitle
        var alternatePrompt = RoutePages.alternatePrompt
        var altitudesSection = RoutePages.altitudesSection
        var altitudesFooter = RoutePages.altitudesFooter
        var sunSection = RoutePages.sunSection
        var notCovered = RoutePages.notCovered
        var briefTitle = RoutePages.briefTitle
        var briefBuilding = BriefGraphics.building, briefHazards = BriefGraphics.hazardsTitle
        var briefProfile = BriefGraphics.profileTitle, briefAirports = BriefGraphics.airportsTitle
        var briefPictures = BriefGraphics.picturesTitle
        var share = RoutePages.share, shareNavlog = RoutePages.shareNavlog
        var savedTitle = RoutePages.savedTitle, saveRoute = RoutePages.saveRoute
        var savedSection = RoutePages.savedSection, recentSection = RoutePages.recentSection
        var routeName = RoutePages.routeName, rename = RoutePages.rename, delete = RoutePages.delete
        var save = RoutePages.save, cancel = RoutePages.cancel, noSaved = RoutePages.noSaved
        var savedFile = SavedRoutes.fileName
    }

    struct Rule: Encodable { var id: String; var name: String }

    /// Speed, burn, taxi and fuel on board not given come from `aircraft`; on board is the W&B start fuel,
    /// else full usable.
    struct FlightPlanArgs: Decodable {
        var plan: RoutePlan
        var fix: Fix?
        var approximate: Bool?
        var now: Date
        var inputs: FlightPlanInputs
        /// The inputs' text as kept, which gives the default departure as time goes on.
        var stored: String?
        var speed: Double?
        var burn: Double?
        var taxi: Double?
        var onBoard: Double?
        var aircraft: AircraftProfile?
        var startFuel: Double?
        /// The nav database, for the brief's runways and ground and the destination's state, and the plates store folder.
        var navDatabase: String?
        var plates: String?

        var speedKt: Double { speed ?? aircraft?.cruiseTASKt ?? 0 }
        var burnGPH: Double { burn ?? aircraft?.burnGPH ?? 0 }
        var taxiGal: Double { taxi ?? aircraft?.taxiFuelGal ?? 0 }
        var vertical: FlightPlan.Vertical? { aircraft?.vertical }
        var onBoardGal: Double? { onBoard ?? startFuel ?? aircraft?.usableFuelGal }

        /// From the plates on the device, for IFR alternate advice only; nil where it cannot be told.
        var hasApproach: Bool? {
            guard inputs.rules == .ifr, let last = plan.route.waypoints.last, last.kind == .airport, let navDatabase,
                  let plates else { return nil }
            return Bridge.hasApproach(last.ident, navDatabase: navDatabase, plates: plates, now: now)
        }
    }

    /// The route as flown and its plan; nil when nothing is drawn.
    static func planned(_ a: FlightPlanArgs, winds: WindsAloft?, tafs: [Taf]) -> (Route, FlightPlan)? {
        let fix = position(a.fix), approximate = Bridge.approximate(a.approximate, a.fix)
        guard let route = a.plan.route(from: fix, approximate: approximate, now: a.now) else { return nil }
        return (route, FlightPlan.make(route: route, inputs: a.inputs, trueAirspeedKt: a.speedKt, burnGPH: a.burnGPH,
                                       taxiFuelGal: a.taxiGal, fuelOnBoardGal: a.onBoardGal, winds: winds, tafs: tafs,
                                       destinationHasApproach: a.hasApproach, vertical: a.vertical,
                                       inFlight: RoutePages.inFlight(a.plan, fix, approximate: approximate, now: a.now),
                                       airborne: RoutePages.airborne(fix, approximate: approximate, now: a.now), now: a.now))
    }

    struct EditorLeg: Encodable { var target: Int; var time: String?; var wind: String; var note: String? }
    struct PlanAltitude: Encodable { var ft: Int; var picked: Bool; var line: NavPages.Line }
    struct PlanAlternate: Encodable { var text: String; var required: Bool? }

    /// The route panel's plan: editor rows' legs by target, answer and fuel lines, altitude table, alternate advice and sun.
    struct PlanView: Encodable {
        var legs: [EditorLeg]
        /// The answer lines, then how the fuel required adds up; a line with no number is left out.
        var summary: [NavPages.Line]
        var fuelLines: [NavPages.Line]
        /// Empty when no altitude has a time, since its lines would show only dashes.
        var altitudes: [PlanAltitude]
        var alternate: PlanAlternate?
        var sun: [NavPages.Line]
        /// The W&B fuel burned when none is typed, as `AircraftPages.burnedDefault` gives it; nil with no aircraft.
        var burned: Double?
        /// The planning page's nav log: one row per editor point in its order, then the totals.
        var log: [[String]]
        var logTotals: [String]
        /// Top of climb and top of descent rows ahead of each editor point's row, and the plan's notes on them.
        var logBefore: [[[String]]]
        /// The log columns some row holds a value in, which `logFitted` fits to the page.
        var logShown: [Int]
        var notes: [String]
        /// When the page can next differ with no new data: the departure rolling on or a winds window ending.
        var next: Date
    }

    static func planView(_ a: FlightPlanArgs, winds: WindsAloft?, tafs: [Taf]) -> PlanView? {
        let approximate = Bridge.approximate(a.approximate, a.fix)
        guard let page = RoutePages.planPage(a.plan, position: position(a.fix), approximate: approximate,
                                             now: a.now, inputs: a.inputs, trueAirspeedKt: a.speedKt, burnGPH: a.burnGPH,
                                             taxiFuelGal: a.taxiGal, fuelOnBoardGal: a.onBoardGal, winds: winds, tafs: tafs,
                                             destinationHasApproach: a.hasApproach, vertical: a.vertical)
        else { return nil }
        let p = page.plan
        let editor = RoutePages.editor(a.plan, position: position(a.fix), approximate: approximate, now: a.now,
                                       trueAirspeedKt: a.speedKt, fuelBurnPerHour: a.burnGPH)
        let log = editor.points.map { RoutePages.logCells($0, page: page) }
        let before = editor.points.map { RoutePages.logInserts($0, page: page) }
        let totals = RoutePages.logTotals(page)
        return PlanView(
            legs: page.legs.sorted { $0.key < $1.key }.map { EditorLeg(target: $0.key, time: $0.value.time, wind: $0.value.wind, note: $0.value.note) },
            summary: page.summary, fuelLines: page.fuelLines,
            altitudes: p.altitudes.contains { $0.time != nil }
                ? zip(p.altitudes, p.altitudeLines).map { PlanAltitude(ft: $0.ft, picked: $0.picked, line: $1) } : [],
            alternate: p.alternate.map { PlanAlternate(text: $0.text, required: $0.required) },
            sun: p.sunLines,
            burned: a.aircraft.flatMap { AircraftPages.burnedDefault($0, tripFuelGal: p.fuel?.trip, startFuelGal: a.startFuel,
                                                                    airborne: p.airborne) },
            log: log, logTotals: totals, logBefore: before, logShown: RoutePages.logShown(log + before.flatMap { $0 } + [totals]),
            notes: p.notes,
            next: RoutePages.planChange(stored: a.stored.map { Data($0.utf8) }, winds: winds, after: a.now))
    }

    static func routeCall(_ op: String, _ args: Data) throws -> (any Encodable)? {
        func arg<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(type, from: args) }
        switch op {
        case "grab": return grab(try arg(GrabArgs.self))
        case "snap": return snap(try arg(SnapArgs.self))
        case "ruler": return ruler(try arg(RulerArgs.self))
        case "routeTake":
            let a = try arg(TakeArgs.self)
            return ["text": RoutePages.take(a.place.match, into: a.text)]
        case "routeLabels": return RouteLabels()
        case "logFitted":
            let a = try arg(FitArgs.self)
            return Fitted(columns: RoutePages.logFitted(a.shown, widths: a.widths, room: a.room))
        // In flight by the core's rule, on this fix now.
        case "airborne":
            let a = try arg(FixArgs.self)
            return ["airborne": RoutePages.airborne(position(a.fix), approximate: Bridge.approximate(a.approximate, a.fix), now: a.now)]
        case "savedRoutes": return try savedRoutes(arg(SavedArgs.self))
        default: return nil
        }
    }
}
