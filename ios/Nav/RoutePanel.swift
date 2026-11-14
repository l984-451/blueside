import FlightCore
import SwiftUI

/// The route's answer first, then its text with suggestions, the plan inputs and the waypoints or nav log.
struct RoutePanel: View {
    /// Pages pushed from the panel, as values so the map's kept path survives a turn.
    enum Page: Hashable { case saved, weightBalance(tripFuelGal: Double?) }

    let model: NavModel
    /// The panel's pushed pages, kept by the map.
    @Binding var path: NavigationPath
    var onClose: () -> Void = {}
    var onShowOnMap: (Coordinate) -> Void = { _ in }
    /// Set where the panel can grow into the planning page; true while it has.
    var wide: Binding<Bool>?

    @AppStorage(RoutePages.planInputsKey) private var storedInputs = Data()
    @Environment(WeatherStore.self) private var weather: WeatherStore?
    @Environment(LocationProvider.self) private var location: LocationProvider?
    @Environment(Plates.self) private var plates: Plates?
    @Environment(\.fixedNow) private var fixedNow
    @State private var text = ""
    @State private var alternateText = ""
    @State private var typed: RoutePages.Typed?
    @State private var naming = false
    @State private var routeName = ""
    /// The fix the plan was last worked out from, replaced only when the page could change.
    @State private var kept: (key: RoutePages.PlanKey, fix: Fix)?
    @State private var picked: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The planning page's visible size, and its parts, each as tall as its content, all measured.
    @State private var pageSize = CGSize.zero
    @State private var answersHeight: CGFloat?
    @State private var inputsHeight: CGFloat?
    @State private var detailsHeight: CGFloat?
    @State private var logHeight: CGFloat?
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var editing: Bool

    var body: some View {
        // Wakes when the default departure rolls on or a winds window ends.
        Clock(next: { RoutePages.planChange(stored: storedInputs, winds: weather?.data.winds, after: $0) }) { now in content(now) }
        .panelPage(RoutePages.routeTitle, onClose: onClose)
        .toolbar {
            if let wide {
                ToolbarItem(placement: .topBarLeading) {
                    Button(wide.wrappedValue ? RoutePages.collapse : RoutePages.expand,
                           systemImage: wide.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        withAnimation(.snappy(duration: 0.3)) { wide.wrappedValue.toggle() }
                    }
                    .accessibilityIdentifier("route-expand")
                }
            }
            // Trailing sits left of the close button.
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .alert(RoutePages.saveRoute, isPresented: $naming) {
            TextField(RoutePages.routeName, text: $routeName)
            Button(RoutePages.cancel, role: .cancel) {}
            Button(RoutePages.save) {
                guard let plan = model.route else { return }
                var inputs = RoutePages.planInputs(stored: storedInputs, now: fixedNow ?? Date())
                // The aircraft flown, even a fallback, so its load comes back with the flight.
                inputs.aircraftID = model.aircraft.aircraft(for: inputs.aircraftID)?.id
                let load = inputs.aircraftID.flatMap { model.aircraft.loads[$0] }
                model.savedRoutes.update { $0.saving(plan, inputs: inputs, name: routeName, load: load) }
            }
        }
        .onChange(of: model.route, initial: true) { _, plan in
            if !editing { text = plan?.text ?? "" }
            // A picked log row belongs to the route it was picked in.
            picked = nil
        }
        .onChange(of: text) { _, typed in if editing { apply(typed) } }
        .onChange(of: editing) { _, now in
            // Leaving the field shows the route as it stands, so a rejected edit does not linger.
            if !now { text = model.route?.text ?? ""; typed = nil }
        }
        // Only the brief's own close clears it, so the sheet going away on a turn leaves it open for the card.
        .fullScreenCover(isPresented: Binding(get: { model.brief != nil }, set: { _ in })) {
            if let job = model.brief {
                BriefPage(job: job, cached: model.briefDone, onBuilt: { model.briefDone = $0 }) { model.brief = nil }
            }
        }
    }

    private var menu: some View {
        Menu {
            Button(RoutePages.savedTitle, systemImage: "bookmark") { path.append(Page.saved) }
            if let plan = model.route {
                Button(RoutePages.saveRoute, systemImage: "square.and.arrow.down") {
                    routeName = SavedRoutes.defaultName(plan)
                    naming = true
                }
                Divider()
                Button(RoutePages.clear, systemImage: "trash", role: .destructive) { model.route = nil }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityIdentifier("route-menu")
    }

    /// What one draw shows: the plan inputs, the aircraft and, with a route, its plan from the kept fix.
    private struct Shown {
        var inputs: FlightPlanInputs
        var aircraft: AircraftProfile?
        var speed = 0.0
        var burn = 0.0
        var editor: RoutePages.Editor?
        var page: RoutePages.PlanPage?
        /// Time and fuel need the aircraft's cruise speed and burn.
        var needsAircraft: Bool { speed <= 0 || burn <= 0 }
    }

    private func shown(_ fix: Fix, now: Date) -> Shown {
        let inputs = RoutePages.planInputs(stored: storedInputs, now: now)
        let aircraft = model.aircraft.aircraft(for: inputs.aircraftID)
        var out = Shown(inputs: inputs, aircraft: aircraft, speed: aircraft?.cruiseTASKt ?? 0, burn: aircraft?.burnGPH ?? 0)
        guard let plan = model.route else { return out }
        // From the kept fix too, so the active leg's live time is there to keep its column; its row follows the fix.
        out.editor = RoutePages.editor(plan, position: fix.position, approximate: fix.approximate, now: fix.now,
                                       trueAirspeedKt: out.speed, fuelBurnPerHour: out.burn)
        out.page = RoutePages.planPage(plan, position: fix.position, approximate: fix.approximate, now: fix.now,
                                       inputs: inputs, trueAirspeedKt: out.speed, burnGPH: out.burn,
                                       taxiFuelGal: aircraft?.taxiFuelGal ?? 0,
                                       fuelOnBoardGal: aircraft.flatMap { model.aircraft.loads[$0.id]?.startFuel },
                                       winds: weather?.data.winds, tafs: weather?.data.tafs ?? [],
                                       destinationHasApproach: hasApproach(plan, inputs), vertical: aircraft?.vertical)
        return out
    }

    // IFR advice only. Unknown until the plates index is read, and outside the states whose plates are installed.
    private func hasApproach(_ plan: RoutePlan, _ inputs: FlightPlanInputs) -> Bool? {
        guard inputs.rules == .ifr, let last = plan.route.waypoints.last, last.kind == .airport,
              let airport = model.airport(last.ident),
              let plates, let charts = plates.charts(for: airport) else { return nil }
        return RoutePages.hasApproach(charts, regionInstalled: plates.downloads.installed.contains { $0.pack.id.region == airport.state })
    }

    // The navlog from the fix of this moment, as Brief is.
    private func navlogNow(_ plan: RoutePlan) -> NavlogPDF? {
        let fix = currentFix()
        let s = shown(fix, now: fix.now)
        guard let page = s.page else { return nil }
        let balance = s.aircraft.flatMap { WeightBalancePage.balance($0, model.aircraft.loads[$0.id] ?? .init(),
                                                                     tripFuelGal: page.plan.fuel?.trip, airborne: page.plan.airborne) }
        return NavlogPDF(route: plan, page: page, position: fix.position, approximate: fix.approximate, now: fix.now,
                         aircraft: s.aircraft, balance: balance,
                         localOffset: TimeZone.current.secondsFromGMT(for: s.inputs.departure), database: model.database)
    }

    /// The fix as it stands, for the first draw and for a tap.
    private func currentFix() -> Fix {
        Fix(position: location?.position, approximate: location?.isApproximate ?? false,
            accessOff: location?.accessOff ?? false, now: fixedNow ?? Date())
    }

    // Keeps a new fix only when the plan key changes, so the page is not worked out again on every fix.
    // Each deadline restarts this and keeps the fix of that moment.
    private func follow() async {
        guard let location else { return }
        var first = true
        for await (route, fix) in Observations({ [model, fixedNow] in
            _ = location.isStale
            return (model.route, Fix(position: location.position, approximate: location.isApproximate,
                                     accessOff: location.accessOff, now: fixedNow ?? Date()))
        }) {
            let key = RoutePages.planKey(route, position: fix.position, approximate: fix.approximate, now: fix.now,
                                         after: kept?.key)
            if first || key != kept?.key { kept = (key, fix) }
            first = false
        }
    }

    private var isWide: Bool { wide?.wrappedValue == true }

    // Results beside the route and plan inputs where the page is wide enough for both at ordinary type sizes.
    private var sideBySide: Bool { pageSize.width >= 600 && !typeSize.isAccessibilitySize }

    private func content(_ now: Date) -> some View {
        let s = shown(kept?.fix ?? currentFix(), now: now)
        // A compact width, as a phone on its side, shows a table's first column only, so it keeps the list. So does a
        // page the core finds too narrow for the log's main columns, as at the largest text sizes.
        let table = isWide && sizeClass == .regular ? s.editor.flatMap { logTable($0, s) } : nil
        return Group {
            if let plan = model.route, let table {
                // The planning page: results and inputs over the nav log, then fuel, altitudes and sun. One page that
                // scrolls as a whole, each part as tall as its content. The same lists in either layout, so a turn
                // moves them and never builds new ones mid-rotation.
                let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                ScrollView {
                    VStack(spacing: 0) {
                        layout {
                            list { if let page = s.page { results(plan, page, s) } }.accessibilityIdentifier("route-list")
                                .fitted($answersHeight, until: pageSize.height)
                            // Beside, the wider share, so the departure date and time fit beside their label.
                            list { questions(s, now) }.accessibilityIdentifier("route-inputs")
                                .fitted($inputsHeight, until: pageSize.height)
                                .frame(width: sideBySide ? pageSize.width * 0.55 : nil)
                        }
                        Divider()
                        log(plan, table, s)
                        list { details(s, now) }.accessibilityIdentifier("route-details")
                            .fitted($detailsHeight, until: pageSize.height)
                    }
                    .listSectionSpacing(.compact)
                }
            } else {
                list {
                    if let plan = model.route, let page = s.page { results(plan, page, s) }
                    questions(s, now)
                    if let plan = model.route, let editor = s.editor { waypoints(plan, editor, s) }
                    details(s, now)
                }
                .accessibilityIdentifier("route-list")
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { pageSize = $0 }
        .navigationDestination(for: Page.self) { shown in
            switch shown {
            case .saved: SavedRoutesList(store: model.savedRoutes, onClose: onClose) { load($0, now) }
            case .weightBalance(let trip):
                if let aircraft = s.aircraft {
                    WeightBalancePage(store: model.aircraft, profile: aircraft, tripFuelGal: trip)
                }
            }
        }
        .task(id: RoutePages.planChange(stored: storedInputs, winds: weather?.data.winds, after: now)) { await follow() }
    }

    private func list<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        List { content() }
            .listStyle(.insetGrouped)
            .panelList()
    }

    // What the pilot types and sets: the route, then the plan inputs.
    @ViewBuilder private func questions(_ s: Shown, _ now: Date) -> some View {
        Section {
            TextField("Route", text: $text, prompt: Text(RoutePages.fieldPrompt))
                .font(.body.monospaced())
                .focused($editing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .submitLabel(.done)
                .accessibilityIdentifier("route-field")
            ForEach(Array((typed?.suggestions ?? []).enumerated()), id: \.offset) { _, match in
                Button { take(match) } label: {
                    PlaceLabel(ident: RoutePages.ident(match), name: RoutePages.suggestionDetail(match))
                }
                .accessibilityIdentifier("route-suggestion-\(RoutePages.ident(match))")
            }
            ForEach(Array((typed?.problems ?? []).enumerated()), id: \.offset) { index, problem in
                StateWord(.danger, problem, systemImage: "xmark.octagon.fill")
                    .accessibilityIdentifier("route-problem-\(index)")
            }
            ForEach(typed?.notes ?? [], id: \.self) { Text($0).note() }
        } footer: {
            // Opening the data at launch is not the same as having none.
            if model.database == nil, !model.isOpeningFirst { Text(NavModel.notDownloaded) }
        }
        planInputs(s.inputs, now)
    }

    // Fuel, weight and balance, altitudes and sun: how the results add up.
    @ViewBuilder private func details(_ s: Shown, _ now: Date) -> some View {
        if let page = s.page, !page.fuelLines.isEmpty {
            Section(RoutePages.fuelBlock) {
                ForEach(page.fuelLines, id: \.title) { line in
                    PlanLine(line: line).accessibilityIdentifier("route-total-\(line.title.lowercased())")
                }
            }
            .monospacedDigit()
        }
        if let aircraft = s.aircraft {
            Section {
                NavigationLink(value: Page.weightBalance(tripFuelGal: s.page?.plan.fuel?.trip)) {
                    LabeledContent(AircraftPages.weightBalance, value: AircraftPages.displayName(aircraft))
                }
                .accessibilityIdentifier("route-weight-balance")
            }
        }
        if let plan = s.page?.plan {
            // Without the aircraft's numbers the altitudes have nothing to compare.
            if plan.altitudes.contains(where: { $0.time != nil }) { altitudes(plan, now) }
            sun(plan)
        }
    }

    // What the pilot asks first: how far, how long, how much fuel and whether it is enough.
    private func results(_ plan: RoutePlan, _ page: RoutePages.PlanPage, _ s: Shown) -> some View {
        Section {
            ForEach(page.summary, id: \.title) { line in
                PlanLine(line: line).accessibilityIdentifier("route-total-\(line.title.lowercased())")
            }
            // In place of the time and fuel lines it explains.
            if s.needsAircraft { Text(RoutePages.speedHint).note().accessibilityIdentifier("route-speed-hint") }
            if let alternate = page.plan.alternate {
                Text(alternate.text).font(.subheadline)
                    .foregroundStyle(alternate.required == true ? PanelInk.warning : .primary)
                    .accessibilityIdentifier("plan-alternate-advice")
            }
            Button(RoutePages.briefTitle, systemImage: "doc.text.magnifyingglass") { openBrief(plan) }
                .accessibilityIdentifier("route-brief")
            ShareLink(item: NavlogNow { navlogNow(plan) }, preview: SharePreview(RoutePages.navlogTitle)) {
                Label(RoutePages.shareNavlog, systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("route-share-navlog")
        }
        .monospacedDigit()
    }

    // Parsed again against the cycle in use; with problems the active route stays and the field shows why.
    private func load(_ saved: SavedRoute, _ now: Date) {
        guard let database = model.database else { return }
        let loaded = SavedRoutes.load(saved, inputs: RoutePages.planInputs(stored: storedInputs, now: now),
                                      database: database, now: now, aircraft: model.aircraft.list)
        if let id = loaded.inputs.aircraftID, let load = loaded.load { model.aircraft.loads[id] = load }
        storedInputs = RoutePages.storing(loaded.inputs)
        alternateText = loaded.inputs.alternate?.ident ?? ""
        if let plan = loaded.plan {
            model.route = plan
            model.savedRoutes.update { $0.noting(plan, inputs: loaded.inputs) }
        }
        text = loaded.text
        typed = loaded.typed
    }

    // Each binding reads and writes the stored inputs, so the core decides the defaults.
    private func input<T>(_ key: WritableKeyPath<FlightPlanInputs, T>, _ now: Date) -> Binding<T> {
        Binding(get: { RoutePages.planInputs(stored: storedInputs, now: now)[keyPath: key] },
                set: { value in
                    var inputs = RoutePages.planInputs(stored: storedInputs, now: now)
                    inputs[keyPath: key] = value
                    storedInputs = RoutePages.storing(inputs)
                })
    }

    private func planInputs(_ inputs: FlightPlanInputs, _ now: Date) -> some View {
        Section(RoutePages.planSection) {
            if !model.aircraft.list.isEmpty {
                Picker(AircraftPages.title, selection: Binding(get: { model.aircraft.aircraft(for: inputs.aircraftID)?.id },
                                                               set: { input(\.aircraftID, now).wrappedValue = $0 })) {
                    ForEach(model.aircraft.list) { Text(AircraftPages.displayName($0)).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("plan-aircraft")
            }
            DatePicker(RoutePages.departureTitle, selection: input(\.departure, now), in: now...)
                .accessibilityIdentifier("plan-departure")
            Picker(RoutePages.rulesTitle, selection: input(\.rules, now)) {
                ForEach([FlightPlanInputs.Rules.vfr, .ifr], id: \.self) { Text(RoutePages.rulesName($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("plan-rules")
            LabeledContent(RoutePages.altitudeTitle) {
                HStack {
                    TextField(RoutePages.altitudeTitle, value: input(\.cruiseAltitudeFt, now), format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("plan-altitude")
                    Text("ft").foregroundStyle(.secondary)
                }
            }
            LabeledContent(RoutePages.alternateTitle) {
                TextField(RoutePages.alternateTitle, text: $alternateText, prompt: Text(RoutePages.alternatePrompt))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .submitLabel(.done)
                    .onSubmit {
                        let found = model.database.flatMap { RoutePages.alternate(alternateText, database: $0) }
                        input(\.alternate, now).wrappedValue = found
                        alternateText = found?.ident ?? ""
                    }
                    .accessibilityIdentifier("plan-alternate")
            }
            .onAppear { alternateText = inputs.alternate?.ident ?? "" }
        }
    }

    private func waypoints(_ plan: RoutePlan, _ editor: RoutePages.Editor, _ s: Shown) -> some View {
        Section {
            ForEach(Array(editor.points.enumerated()), id: \.offset) { index, point in
                let planned = s.page?.legs[point.target]
                HStack {
                    VStack(alignment: .leading) {
                        PlaceLabel(ident: point.title, name: point.name, closed: model.isClosed(point.waypoint))
                        if let planned {
                            if planned.wind != NavText.dashes {
                                Text(planned.wind).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if let note = planned.note { Text(note).font(.footnote).foregroundStyle(PanelInk.warning) }
                        }
                    }
                    Spacer()
                    if let leg = point.leg {
                        if point.target == plan.activeLeg {
                            FixReader { fix in
                                let live = plan.rows(position: fix.position, approximate: fix.approximate, now: fix.now,
                                                     trueAirspeedKt: s.speed > 0 ? s.speed : nil)[safe: point.target] ?? leg
                                RangeColumn(distance: live.distance, bearing: live.course, time: planned?.time ?? live.time)
                                    .equatable()
                            }
                        } else {
                            RangeColumn(distance: leg.distance, bearing: leg.course, time: planned?.time ?? leg.time)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("route-point-\(index)")
                .placeRowActions(direct: plan.isDirect ? nil : { model.route = plan.direct(toTarget: point.target) },
                                 showOnMap: { onShowOnMap(point.waypoint.coordinate) },
                                 remove: { model.route = plan.removing(target: point.target) })
            }
            .onMove { from, to in
                let first = editor.points.first?.target ?? 0
                model.route = plan.moving(from: from.first.map { $0 + first }, to: to + first)
            }
        } header: {
            Text(editor.header)
        } footer: {
            notes(s.page)
        }
    }

    @ViewBuilder private func notes(_ page: RoutePages.PlanPage?) -> some View {
        if let notes = page?.plan.notes, !notes.isEmpty {
            VStack(alignment: .leading) { ForEach(notes, id: \.self) { Text($0) } }
                .accessibilityIdentifier("plan-notes")
        }
    }

    /// One nav log row: a top of climb or descent ahead of a point, a point, or the totals.
    /// Named by the point it belongs to, so a picked row stays the same row while the route does.
    fileprivate struct LogRow: Identifiable {
        enum Kind { case marker, point(index: Int, RoutePages.Point), total }
        var id: String
        var cells: [String]
        var kind: Kind
    }

    private func logRows(_ editor: RoutePages.Editor, _ page: RoutePages.PlanPage?) -> [LogRow] {
        var rows: [LogRow] = []
        for (index, point) in editor.points.enumerated() {
            for (n, cells) in RoutePages.logInserts(point, page: page).enumerated() {
                rows.append(LogRow(id: "\(point.target)-\(n)", cells: cells, kind: .marker))
            }
            rows.append(LogRow(id: "\(point.target)", cells: RoutePages.logCells(point, page: page), kind: .point(index: index, point)))
        }
        if let page { rows.append(LogRow(id: "total", cells: RoutePages.logTotals(page), kind: .total)) }
        return rows
    }

    /// The table's own margins and the space between its columns, measured on the iPad's planning page.
    private static let tableMargins: CGFloat = 56, columnGap: CGFloat = 12

    /// Column widths as last measured, with the cells and text size they were measured for.
    private final class MeasuredWidths {
        var cells: [[String]]?
        var size: DynamicTypeSize?
        var widths: [CGFloat] = []
    }
    @State private var measured = MeasuredWidths()

    /// Each column's widest header or cell, set semibold with digits of one width so no row is wider. Measured again
    /// only when the cells or the text size change.
    private func logWidths(_ rows: [LogRow]) -> [CGFloat] {
        let cells = rows.map(\.cells)
        if measured.cells == cells, measured.size == typeSize { return measured.widths }
        let size = UIFont.preferredFont(forTextStyle: .body, compatibleWith: .init(preferredContentSizeCategory: .init(typeSize)))
        let font = UIFont.monospacedDigitSystemFont(ofSize: size.pointSize, weight: .semibold)
        let widths = RoutePages.logColumns.indices.map { i in
            ([RoutePages.logColumns[i]] + cells.map { $0[safe: i] ?? "" })
                .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        }
        (measured.cells, measured.size, measured.widths) = (cells, typeSize, widths)
        return widths
    }

    /// The log's rows and the columns that fit the page, leaving out those no row has a value in, then the least
    /// needed until every cell fits. Nil where the core finds no room for the main columns. Unmeasured, all of them.
    private func logTable(_ editor: RoutePages.Editor, _ s: Shown) -> (rows: [LogRow], columns: [Int], widths: [CGFloat])? {
        let rows = logRows(editor, s.page)
        let shown = RoutePages.logShown(rows.map(\.cells))
        let widths = logWidths(rows)
        guard pageSize.width > 0 else { return (rows, shown, widths) }
        return RoutePages.logFitted(shown, widths: widths.map { Double($0 + Self.columnGap) },
                                    room: Double(pageSize.width - Self.tableMargins)).map { (rows, $0, widths) }
    }

    // The nav log as a table. A long press on a point gives its actions.
    private func log(_ plan: RoutePlan, _ table: (rows: [LogRow], columns: [Int], widths: [CGFloat]), _ s: Shown) -> some View {
        let (rows, columns, widths) = table
        return VStack(alignment: .leading, spacing: 0) {
            // Rows can be picked, which the long-press actions need.
            Table(rows, selection: $picked) {
                TableColumnForEach(columns, id: \.self) { column in
                    TableColumn(RoutePages.logColumns[column]) { row in logCell(row, column, plan, s) }
                        .width(min: widths[column])
                }
            }
            .contextMenu(forSelectionType: LogRow.ID.self) { ids in
                if let id = ids.first, case .point(_, let point)? = rows.first(where: { $0.id == id })?.kind {
                    if !plan.isDirect {
                        Button(NavPages.Action.direct, systemImage: "arrow.up.right") { model.route = plan.direct(toTarget: point.target) }
                    }
                    Button(NavPages.Action.showOnMap, systemImage: "map") { onShowOnMap(point.waypoint.coordinate) }
                    Button(NavPages.Action.remove, systemImage: "trash", role: .destructive) {
                        model.route = plan.removing(target: point.target)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            // Headers are names, not buttons.
            .tint(.secondary)
            .fitted($logHeight, until: pageSize.height)
            .accessibilityIdentifier("route-log")
            notes(s.page).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, chromeInset / 2)
        }
    }

    @ViewBuilder private func logCell(_ row: LogRow, _ column: Int, _ plan: RoutePlan, _ s: Shown) -> some View {
        let text = row.cells[safe: column] ?? ""
        Group {
            // Airborne, the active leg keeps its live time, in its own leaf.
            if column == RoutePages.logTime, case .point(_, let point) = row.kind, point.target == plan.activeLeg,
               s.page?.legs[point.target].map({ $0.time == nil }) == true {
                FixReader { fix in
                    Text(plan.rows(position: fix.position, approximate: fix.approximate, now: fix.now,
                                   trueAirspeedKt: s.speed > 0 ? s.speed : nil)[safe: point.target]?.time ?? text)
                }
            } else if column == 0, case .point(let index, _) = row.kind {
                Text(text).accessibilityIdentifier("route-point-\(index)")
            } else {
                Text(text)
            }
        }
        .lineLimit(1)
        .monospacedDigit()
        .fontWeight(row.isTotal ? .semibold : nil)
        .foregroundStyle(row.isMarker ? .secondary : .primary)
        .frame(maxWidth: .infinity, alignment: column == 0 ? .leading : .trailing)
    }

    // Tapping an altitude flies it.
    private func altitudes(_ plan: FlightPlan, _ now: Date) -> some View {
        Section {
            ForEach(Array(zip(plan.altitudes, plan.altitudeLines)), id: \.0.ft) { altitude, line in
                Button { input(\.cruiseAltitudeFt, now).wrappedValue = altitude.ft } label: {
                    PlanLine(line: line)
                }
                .tint(.primary)
                .accessibilityAddTraits(altitude.picked ? .isSelected : [])
                .accessibilityIdentifier("plan-altitude-\(altitude.ft)")
            }
        } header: {
            Text(RoutePages.altitudesSection)
        } footer: {
            Text(RoutePages.altitudesFooter)
        }
        .monospacedDigit()
    }

    private func sun(_ plan: FlightPlan) -> some View {
        Section {
            ForEach(plan.sunLines, id: \.title) { PlanLine(line: $0) }
        } header: {
            Text(RoutePages.sunSection)
        } footer: {
            Text(RoutePages.notCovered)
        }
        .monospacedDigit()
    }

    // Built at the tap from the fix and weather held then, with the flight's aircraft and its W&B load.
    private func openBrief(_ plan: RoutePlan) {
        let fix = currentFix()
        let s = shown(fix, now: fix.now)
        guard let page = s.page, let route = plan.route(from: fix.position, approximate: fix.approximate, now: fix.now) else { return }
        let balance = s.aircraft.flatMap { WeightBalancePage.balance($0, model.aircraft.loads[$0.id] ?? .init(),
                                                                     tripFuelGal: page.plan.fuel?.trip, airborne: page.plan.airborne) }
        model.brief = BriefJob(route: route, inputs: s.inputs, plan: page.plan, aircraft: s.aircraft, balance: balance,
                               weather: weather?.data ?? WeatherData(), now: fix.now,
                               localOffset: TimeZone.current.secondsFromGMT(for: s.inputs.departure),
                               database: model.database, packs: model.mapPacks())
    }

    // Parses as typed; the core says whether the route changes.
    private func apply(_ text: String) {
        guard let database = model.database else { return }
        let result = RoutePages.typed(text, plan: model.route, database: database, now: Date())
        typed = result
        if result.replaces { model.route = result.plan }
    }

    private func take(_ match: WaypointMatch) {
        text = RoutePages.take(match, into: text)
        editing = true
    }
}

/// The navlog worked out when it is shared, from the fix of that moment.
private struct NavlogNow: Transferable {
    let make: @MainActor @Sendable () -> NavlogPDF?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { item in
            guard let navlog = await item.make() else { throw CocoaError(.fileNoSuchFile) }
            return SentTransferredFile(try navlog.write())
        }
    }
}

private extension View {
    /// A list or table that scrolls with the page, as tall as its content. Measured from the content size alone, so
    /// the frame it sets cannot feed back; a change under a point is not taken. Until measured, `start` tall.
    func fitted(_ height: Binding<CGFloat?>, until start: CGFloat) -> some View {
        scrollDisabled(true)
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { _, new in
                if new > 0, abs(new - (height.wrappedValue ?? 0)) >= 1 { height.wrappedValue = new }
            }
            .frame(height: height.wrappedValue ?? max(start, 1))
    }
}

private extension RoutePanel.LogRow {
    var isTotal: Bool { if case .total = kind { true } else { false } }
    var isMarker: Bool { if case .marker = kind { true } else { false } }
}

/// One core line: title with its detail under, value at the end, and a red tag when the core gives one.
struct PlanLine: View {
    let line: NavPages.Line

    var body: some View {
        LabeledContent {
            HStack {
                if let tag = line.tag { Text(tag).font(.subheadline.weight(.semibold)).foregroundStyle(PanelInk.danger) }
                if let value = line.value { Text(value) }
            }
        } label: {
            Text(line.title)
            if let detail = line.detail { Text(detail) }
        }
        .accessibilityElement(children: .combine)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
