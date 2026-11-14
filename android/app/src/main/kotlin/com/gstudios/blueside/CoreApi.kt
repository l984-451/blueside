package com.gstudios.blueside

import kotlinx.serialization.Serializable

// Typed shapes of the bridge ops in android/swift/Sources/BluesideJNI. Dates are epoch milliseconds.

@Serializable data class FileRef(val identifier: String, val path: String)

@Serializable
data class StyleArgs(
    val base: String,
    val night: Boolean,
    val now: Long,
    val stores: List<String>,
    val navStore: String?,
    val templates: String,
    val assets: String,
    val view: ViewBox?,
    val online: Boolean = true,
)

// What the map shows, in degrees.
@Serializable
data class ViewBox(val minLatitude: Double, val minLongitude: Double, val maxLatitude: Double, val maxLongitude: Double)

@Serializable
data class StyleResult(
    val style: String,
    val rasters: List<FileRef>,
    val notice: String? = null,
    val credit: String? = null,
    val creditLink: String? = null,
    val navDatabase: String? = null,
    val navTiles: String? = null,
    val overlay: Boolean,
    val rasterPaint: List<Double> = listOf(0.0, 1.0, 0.0),
)

@Serializable
data class NavState(
    val cycle: String?,
    val effective: Long?,
    val expires: Long?,
    val unreadable: Boolean,
    val hasTiles: Boolean,
)

// plates is the plates pack store folder.
@Serializable
data class NoticeArgs(val base: String, val stores: List<String>, val now: Long, val nav: NavState?, val overlayWanted: Boolean,
                      val plates: String? = null)

@Serializable data class Notices(val banner: String? = null, val nav: String? = null, val plates: String? = null, val next: Long? = null)

@Serializable data class GapArgs(val rasters: List<FileRef>, val latitude: Double, val longitude: Double, val zoom: Double)

@Serializable data class Gap(val text: String? = null)

// aerialProbe is the aerial imagery's top tile, asked for to learn whether the service answers.
@Serializable
data class Catalog(val bases: List<Base>, val title: String, val overlays: List<Group>, val traffic: Group, val memoryKey: String,
                   val menu: Menu, val aerialProbe: String) {
    @Serializable data class Base(val id: String, val title: String)

    @Serializable data class Group(val id: String, val title: String, val startsOn: Boolean, val layers: List<String>)

    // The picker's order and grouping. A row is a switch id or a station dot readout.
    @Serializable data class Menu(val bases: List<List<String>>, val aeronautical: Section, val overlays: List<Section>,
                                  val onMap: String = "", val removeAll: String = "") {
        @Serializable data class Section(val title: String? = null, val rows: List<Row>)
        @Serializable data class Row(val id: String? = null, val station: String? = null)
    }
}

// altitude is meters above MSL; ellipsoidAltitude, sent only without it, meters above the WGS-84 ellipsoid.
// accuracy is the horizontal error in meters, from which the core tells an approximate fix.
@Serializable
data class Fix(
    val latitude: Double,
    val longitude: Double,
    val course: Double,
    val speed: Double,
    val altitude: Double?,
    val ellipsoidAltitude: Double? = null,
    val time: Long,
    val accuracy: Double? = null,
)

@Serializable
data class PositionArgs(
    val fix: Fix?,
    val now: Long,
    val approximate: Boolean = false,
    val accessOff: Boolean = false,
    val following: Boolean,
    val orientation: String,
    val heading: Double,
    val zoom: Double,
    val zoomedToFirstFix: Boolean,
)

@Serializable
data class PositionResult(val strip: Strip, val ownship: Ownship? = null, val camera: Camera? = null, val staleAt: Long? = null) {
    @Serializable
    data class Strip(val groundspeed: String, val track: String, val altitude: String, val message: String? = null)

    @Serializable data class Ownship(val latitude: Double, val longitude: Double, val track: Double, val image: String)

    @Serializable
    data class Camera(val latitude: Double? = null, val longitude: Double? = null, val heading: Double, val zoom: Double? = null)
}

@Serializable data class TrackingArgs(val following: Boolean, val orientation: String, val tap: Boolean = true)

@Serializable data class TrackingResult(val following: Boolean, val orientation: String, val label: String)

// A place, where it is drawn, the part of the map no panel covers and the whole map, all in dp.
@Serializable data class ScreenRect(val x: Double, val y: Double, val width: Double, val height: Double)

@Serializable
data class RevealArgs(val place: Coordinate, val x: Double, val y: Double, val open: ScreenRect, val width: Double,
                      val height: Double, val zoom: Double, val bearing: Double, val force: Boolean = false)

@Serializable data class RevealCamera(val center: Coordinate, val zoom: Double)

// No camera leaves the map alone.
@Serializable data class RevealResult(val camera: RevealCamera? = null)

// The saved map setup's text, and the launch options that win over it.
@Serializable
data class LaunchArgs(
    val saved: String?,
    val base: String?,
    val night: Boolean?,
    val orientation: String?,
    val center: Coordinate?,
    val zoom: Double?,
    val follow: Boolean,
)

@Serializable data class MapCamera(val latitude: Double, val longitude: Double, val zoom: Double)

@Serializable
data class LaunchResult(
    val base: String,
    val night: Boolean,
    val orientation: String,
    val following: Boolean,
    val label: String,
    val camera: MapCamera,
    val route: String? = null,
    val plates: List<PlacedPlate> = emptyList(),
)

// A plate placed on the map, found again by airport and file.
@Serializable data class PlacedPlate(val airport: String, val file: String)

// The map setup as it stands; the core turns it into the text kept under Catalog.memoryKey.
@Serializable
data class MapMemory(
    val base: String,
    val night: Boolean,
    val orientation: String,
    val following: Boolean,
    val camera: MapCamera?,
    val route: String?,
    val plates: List<PlacedPlate> = emptyList(),
)

@Serializable data class MemoryText(val text: String)

fun mapStyle(args: StyleArgs, call: CoreCall = Core::call): StyleResult = call.request("mapStyle", args)

@Serializable data class StreetArgs(val stores: List<String>, val now: Long, val view: ViewBox?)

@Serializable data class StreetKey(val key: String)

// The street packs a view shows, as one key; empty with none.
fun streetKey(args: StreetArgs, call: CoreCall = Core::call): String = call.request<StreetArgs, StreetKey>("streetKey", args).key

fun notices(args: NoticeArgs, call: CoreCall = Core::call): Notices = call.request("notices", args)

fun layerCatalog(call: CoreCall = Core::call): Catalog = decodeResult(call("layerCatalog", ByteArray(0)))

fun position(args: PositionArgs, call: CoreCall = Core::call): PositionResult = call.request("position", args)

fun tracking(args: TrackingArgs, call: CoreCall = Core::call): TrackingResult = call.request("tracking", args)

fun reveal(args: RevealArgs, call: CoreCall = Core::call): RevealResult = call.request("reveal", args)

fun launch(args: LaunchArgs, call: CoreCall = Core::call): LaunchResult = call.request("launch", args)

fun mapMemory(args: MapMemory, call: CoreCall = Core::call): String = call.request<MapMemory, MemoryText>("mapMemory", args).text

// A call bound to an open handle.
fun handleCall(handle: Long): CoreCall = { op, args -> Core.callHandle(handle, op, args) }

// Pack sessions: one per store, opened with Core.open("packs", root).

@Serializable data class PackID(val cycle: String, val layer: String, val region: String)

@Serializable
data class Pending(
    val id: PackID,
    val path: String,
    val sha256: String,
    val bytes: Long,
    val effective: Long,
    val expires: Long,
    val attempt: Int,
)

@Serializable
data class Configure(val layers: List<String>? = null, val skipLayers: List<String>? = null, val always: List<String>? = null, val nav: Boolean? = null, val category: String? = null)

@Serializable data class ListFetched(val status: Int, val body: String?)

@Serializable data class Now(val now: Long)

@Serializable data class Changed(val delay: Double? = null, val retry: Pending? = null, val runPass: Boolean = false)

@Serializable data class PassArgs(val active: List<Pending>, val freeBytes: Long, val now: Long, val stopped: PackID?)

@Serializable data class PassResult(val cancel: List<String>, val start: List<Pending>)

@Serializable
data class TransferEvent(
    val kind: String,
    val pending: Pending,
    val progress: Double? = null,
    val code: Int? = null,
    val file: String? = null,
    val sha256: String? = null,
    val now: Long,
)

@Serializable data class RowsArgs(val now: Long, val waiting: Boolean)

@Serializable
data class Row(val region: String, val name: String, val size: String, val state: String, val progress: Double? = null, val text: String, val downloaded: Boolean = false)

// The category row's words, from the core.
@Serializable
data class DownloadSummary(val title: String, val footer: String, val text: String, val state: String, val progress: Double? = null)

@Serializable
data class Rows(val rows: List<Row>, val notice: String? = null, val message: String? = null, val summary: DownloadSummary? = null, val bytes: Long = 0)

@Serializable data class RegionArgs(val region: String)

@Serializable data class SeedFile(val layer: String, val path: String)

@Serializable data class SeedArgs(val name: String, val files: List<SeedFile>, val now: Long)
