package com.gstudios.blueside

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.time.Instant
import java.time.ZoneId

// Route ops. The plan is the core's own JSON, kept whole and handed back with every call.

@Serializable data class Grab(val kind: String, val index: Int)

// op is direct, add, remove, move, directTarget, replace, typed, bend, bendTo or clear.
@Serializable
data class RouteEdit(
    val op: String,
    val place: Place? = null,
    val target: Int? = null,
    val to: Int? = null,
    val text: String? = null,
    val grab: Grab? = null,
    val drawnCount: Int? = null,
    val hits: List<Hit>? = null,
    val at: Coordinate? = null,
    val metersPerPoint: Double? = null,
)

@Serializable
data class RouteArgs(
    val plan: JsonElement? = null,
    val edit: RouteEdit? = null,
    val fix: Fix? = null,
    val approximate: Boolean = false,
    val now: Long,
    val speed: Double = 0.0,
    val burn: Double = 0.0,
    // The last result's plan key, sent back as it came.
    val planKey: JsonElement? = null,
)

@Serializable data class Waypoint(val kind: String, val ident: String, val name: String, val coordinate: Coordinate)

@Serializable
data class LegRow(
    val id: Int,
    val waypoint: Waypoint,
    val course: String,
    val distance: String,
    val time: String? = null,
    val isActive: Boolean,
)

@Serializable data class Leg(val row: LegRow, val closed: Boolean)

@Serializable data class Dot(val ident: String, val latitude: Double, val longitude: Double)

// points are the drawn waypoints a finger grabs; path and active are the lines to draw.
@Serializable
data class DrawnLine(
    val points: List<Coordinate>,
    val path: List<Coordinate>,
    val active: List<Coordinate>? = null,
    val dots: List<Dot>,
    val firstDot: Int,
)

@Serializable
data class EditorPoint(val title: String, val name: String? = null, val target: Int, val closed: Boolean, val leg: LegRow? = null)

@Serializable data class Editor(val header: String, val points: List<EditorPoint>, val totals: List<Line>)

@Serializable data class Suggestion(val ident: String, val detail: String, val place: Place)

@Serializable data class TypedView(val suggestions: List<Suggestion>, val problems: List<String>, val notes: List<String>)

@Serializable data class Offer(val target: Int, val places: List<NavItem>)

@Serializable data class Summary(val ident: String, val detail: String, val end: String? = null)

@Serializable
data class RouteResult(
    val plan: JsonElement? = null,
    val title: String? = null,
    val text: String,
    val rows: List<Leg>,
    val summary: Summary? = null,
    val line: DrawnLine? = null,
    val editor: Editor? = null,
    val typed: TypedView? = null,
    val offer: Offer? = null,
    val choose: List<NavItem>? = null,
    val flown: Boolean = false,
    // With plan, changes only when the planning page can differ, its inputs, aircraft and weather aside.
    val planKey: JsonElement? = null,
)

@Serializable data class ScreenPoint(val x: Double, val y: Double)

@Serializable data class GrabArgs(val points: List<ScreenPoint>, val firstDot: Int, val finger: ScreenPoint)

@Serializable data class GrabResult(val grab: Grab? = null, val anchors: List<Int>)

@Serializable data class SnapArgs(val hits: List<Hit>)

@Serializable data class SnapResult(val label: String? = null, val target: Place? = null)

@Serializable
data class RulerArgs(val from: Coordinate, val to: Coordinate, val fix: Fix? = null, val approximate: Boolean = false, val now: Long)

@Serializable data class TextResult(val text: String)

@Serializable data class TakeArgs(val text: String, val place: Place)

@Serializable
data class RouteLabels(
    val directTitle: String,
    val routeTitle: String,
    val expand: String,
    val collapse: String,
    val logColumns: List<String>,
    val logTime: Int,
    val planTitle: String,
    val edit: String,
    val done: String,
    val clear: String,
    val undo: String,
    val edited: String,
    val closed: String,
    val fuelBlock: String,
    val speedHint: String,
    val fieldPrompt: String,
    val useInstead: String,
    val keepPoint: String,
    val bendTitle: String,
    val speedTitle: String,
    val burnTitle: String,
    val aircraftNote: String,
    val speedKey: String,
    val burnKey: String,
    val offerSeconds: Double,
    val undoSeconds: Double,
    val planInputsKey: String,
    val planSection: String,
    val departureTitle: String,
    val rulesTitle: String,
    val rules: List<Rule>,
    val altitudeTitle: String,
    val alternateTitle: String,
    val alternatePrompt: String,
    val altitudesSection: String,
    val altitudesFooter: String,
    val sunSection: String,
    val notCovered: String,
    val briefTitle: String,
    val briefBuilding: String = "",
    val briefHazards: String = "",
    val briefProfile: String = "",
    val briefAirports: String = "",
    val briefPictures: String = "",
    val share: String,
    val shareNavlog: String = "",
    val savedTitle: String,
    val saveRoute: String,
    val savedSection: String,
    val recentSection: String,
    val routeName: String,
    val rename: String,
    val delete: String,
    val save: String,
    val cancel: String,
    val noSaved: String,
    val savedFile: String,
)

// Saved flights: file is routes.json's text, stored the plan inputs' text. One edit at most per call.
@Serializable
data class SavedArgs(
    val file: String? = null,
    val plan: JsonElement? = null,
    val stored: String? = null,
    val now: Long,
    val save: String? = null,
    val rename: String? = null,
    val name: String? = null,
    val remove: String? = null,
    val recent: Boolean? = null,
    val load: FlightLoad? = null,
    val aircraft: String? = null,
    val localOffset: LocalOffset? = null,
)
// Seconds from UTC now, and the instant of the next clock change with the seconds after it.
@Serializable data class LocalOffset(val seconds: Int, val nextChange: Long? = null, val secondsAfter: Int? = null)

// The zone's offset at now and across its next change; the core has no time zone data.
fun localOffset(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): LocalOffset {
    val next = zone.rules.nextTransition(now)
    return LocalOffset(zone.rules.getOffset(now).totalSeconds, next?.instant?.toEpochMilli(), next?.offsetAfter?.totalSeconds)
}
// A W&B load as numbers, as saved with a flight.
@Serializable data class FlightLoad(val weights: List<Double?> = emptyList(), val startFuel: Double? = null, val burned: Double? = null)
@Serializable data class SavedRow(val id: String, val name: String, val text: String, val detail: String)
// file is set when routes.json changed; problem when it could not be read, and then it is never written.
@Serializable
data class SavedView(
    val saved: List<SavedRow> = emptyList(),
    val recent: List<SavedRow> = emptyList(),
    val defaultName: String? = null,
    val file: String? = null,
    val problem: String? = null,
)
// aircraft is aircraft.json's text, so the flight's aircraft and load come back only while it is still there.
@Serializable data class LoadRouteArgs(val file: String? = null, val id: String, val stored: String? = null, val now: Long,
    val aircraft: String? = null)
// With problems, plan is null and the field shows text.
@Serializable
data class LoadedRoute(
    val text: String,
    val plan: JsonElement? = null,
    val problems: List<String>,
    val notes: List<String>,
    val inputs: PlanInputs,
    val load: FlightLoad? = null,
    val file: String? = null,
)

@Serializable data class Rule(val id: String, val name: String)

// The flight plan inputs: stored is the core's text kept on the device, alternate the typed ident. Inputs stay the core's JSON.
@Serializable
data class PlanInputArgs(
    val stored: String? = null,
    val now: Long,
    val departure: Long? = null,
    val rules: String? = null,
    val altitude: Int? = null,
    val alternate: String? = null,
    val aircraft: String? = null,
)
@Serializable data class PlanInputs(val inputs: JsonObject, val stored: String, val alternate: String)

// The plan and brief arguments. Speed, burn, taxi and fuel on board come from the aircraft in the core.
@Serializable
data class PlanArgs(
    val plan: JsonElement,
    val fix: Fix? = null,
    val approximate: Boolean = false,
    val now: Long,
    val inputs: JsonObject,
    val aircraft: JsonObject? = null,
    val startFuel: Double? = null,
    val weights: List<Double>? = null,
    val burned: Double? = null,
    val localOffset: Int? = null,
    // The inputs' text as kept, which gives the default departure as time goes on.
    val stored: String? = null,
    // The nav database and plates store, for the destination's approaches and the brief's runways and ground.
    val navDatabase: String? = null,
    val plates: String? = null,
    // For the brief's pictures: the pack stores, MapAssets folder and what __ASSETS__ becomes.
    val stores: List<String>? = null,
    val templates: String? = null,
    val assets: String? = null,
)
@Serializable data class EditorLeg(val target: Int, val time: String? = null, val wind: String, val note: String? = null)
@Serializable data class PlanAltitude(val ft: Int, val picked: Boolean, val line: Line)
@Serializable data class PlanAlternate(val text: String, val required: Boolean? = null)
@Serializable
data class PlanView(
    val legs: List<EditorLeg>,
    // The answer lines, then how the fuel required adds up.
    val summary: List<Line>,
    val fuelLines: List<Line>,
    val altitudes: List<PlanAltitude>,
    val alternate: PlanAlternate? = null,
    val sun: List<Line>,
    val burned: Double? = null,
    // The planning page's nav log, one row per editor point, then the totals.
    val log: List<List<String>> = emptyList(),
    val logTotals: List<String> = emptyList(),
    // Top of climb and top of descent rows ahead of each editor point's row, and the plan's notes on them.
    val logBefore: List<List<List<String>>> = emptyList(),
    // The log columns some row holds a value in.
    val logShown: List<Int> = emptyList(),
    val notes: List<String> = emptyList(),
    // When the page can next differ with no new data.
    val next: Long? = null,
)
// The printable nav log as the core lays it out; the app only draws it onto pages.
@Serializable data class NavlogBlock(val title: String, val lines: List<Line>)
@Serializable data class NavlogTable(val title: String, val columns: List<String>, val rows: List<List<String>>)
@Serializable
data class Navlog(
    val title: String, val fileName: String, val columns: List<String>, val rows: List<List<String>>,
    val totals: List<String>, val summary: NavlogBlock, val fuel: NavlogBlock, val weights: NavlogBlock? = null,
    val frequencies: NavlogTable, val boxesTitle: String, val boxes: List<String>,
)
@Serializable
data class BriefSection(
    val title: String,
    val lines: List<Line>,
    val empty: String? = null,
    val age: String? = null,
    val warning: String? = null,
    val adverse: Boolean = false,
)
@Serializable data class Brief(val title: String, val notice: String, val fileName: String, val sections: List<BriefSection>,
    val graphics: BriefGraphics)

// The brief's pictures as the core lays them out; the app only snapshots the styles and draws the shapes.
@Serializable data class BriefHazard(val text: String, val severe: Boolean)
@Serializable data class BriefBox(val minLatitude: Double, val minLongitude: Double, val maxLatitude: Double, val maxLongitude: Double)
@Serializable data class BriefPicture(val id: String, val title: String, val style: String)
@Serializable data class BriefMap(val bounds: BriefBox, val pictures: List<BriefPicture>)
@Serializable data class BriefTick(val value: Double, val text: String)
@Serializable data class BriefGround(val fromNM: Double, val toNM: Double, val ft: Int)
@Serializable data class BriefCloud(val nm: Double, val ft: Int? = null, val station: String, val text: String, val ceiling: Boolean, val color: String)
@Serializable
data class BriefBarb(val nm: Double, val ft: Int, val lineWidth: Double, val lines: List<List<Double>>,
    val triangles: List<List<Double>>, val ring: Double? = null)
@Serializable
data class BriefProfile(
    val lengthNM: Double, val topFt: Int, val cruiseFt: Int, val grid: List<BriefTick>, val waypoints: List<BriefTick>,
    val ground: List<BriefGround>, val freezing: List<List<List<Double>>>, val clouds: List<BriefCloud>,
    val winds: List<BriefBarb>, val caption: String,
)
@Serializable data class BriefSpan(val from: Double, val to: Double, val color: String)
@Serializable
data class BriefAirport(val title: String, val weather: AirportWeather, val spans: List<BriefSpan>, val mark: Double,
    val times: List<String>, val tafNote: String? = null)
@Serializable
data class BriefGraphics(val counts: String, val hazards: List<BriefHazard>, val map: BriefMap, val profile: BriefProfile,
    val airports: List<BriefAirport>)

fun route(args: RouteArgs, call: CoreCall): RouteResult = call.request("route", args)

fun grab(args: GrabArgs, call: CoreCall = Core::call): GrabResult = call.request("grab", args)

fun snap(args: SnapArgs, call: CoreCall = Core::call): SnapResult = call.request("snap", args)

fun ruler(args: RulerArgs, call: CoreCall = Core::call): String = call.request<RulerArgs, TextResult>("ruler", args).text

fun routeTake(args: TakeArgs, call: CoreCall = Core::call): String = call.request<TakeArgs, TextResult>("routeTake", args).text

fun routeLabels(call: CoreCall = Core::call): RouteLabels = decodeResult(call("routeLabels", ByteArray(0)))

// widths are by logColumns index, each with the gap after it, in dp, as is room.
@Serializable data class FitArgs(val shown: List<Int>, val widths: List<Double>, val room: Double)
@Serializable data class Columns(val columns: List<Int>? = null)

// The shown log columns that fit across, least needed dropped first; null when the page has no room for a table.
fun logFitted(args: FitArgs, call: CoreCall = Core::call): List<Int>? = call.request<FitArgs, Columns>("logFitted", args).columns

@Serializable data class FixArgs(val fix: Fix?, val approximate: Boolean = false, val now: Long)

// In flight by the core's rule, on this fix now.
fun airborne(args: FixArgs, call: CoreCall = Core::call): Boolean =
    call.request<FixArgs, Map<String, Boolean>>("airborne", args).getValue("airborne")

fun planInputs(args: PlanInputArgs, call: CoreCall): PlanInputs = call.request("planInputs", args)
fun savedRoutes(args: SavedArgs, call: CoreCall = Core::call): SavedView = call.request("savedRoutes", args)
fun loadRoute(args: LoadRouteArgs, call: CoreCall): LoadedRoute = call.request("loadRoute", args)
fun planView(args: PlanArgs, call: CoreCall): PlanView = call.request("planView", args)
fun flightBrief(args: PlanArgs, call: CoreCall): Brief = call.request("flightBrief", args)
fun navlog(args: PlanArgs, call: CoreCall): Navlog = call.request("navlog", args)
