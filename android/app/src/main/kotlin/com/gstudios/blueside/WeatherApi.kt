package com.gstudios.blueside

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

// Weather ops: "weatherCatalog", and a "weather" handle opened on the weather folder.

@Serializable
data class WeatherCatalog(
    val title: String,
    val toggles: List<Catalog.Group>,
    val tfrs: Catalog.Group,
    val saved: List<String>,
    val stationsID: String,
    val showTitle: String,
    val showKey: String,
    val shows: List<Choice>,
    val tfrsID: String,
    val tfrListTitle: String,
    val tfrCountSuffix: String,
    val refreshSeconds: Double,
    val passLimitSeconds: Double,
    val indexPath: String,
    val frameID: String,
    val shadingID: String,
    val satelliteID: String,
    val satelliteAnchor: String,
    val satelliteOpacity: Double,
    val noCoverageColor: String,
    val noCoverageOpacity: Double,
    val echoOpacity: Double,
    val bands: List<Band>,
    val stationLayer: String,
    val windsID: String,
    val windsLevelTitle: String,
    val windsLevelKey: String,
    val windsLevels: List<Level>,
    val barbs: List<Barb>,
) {
    @Serializable data class Choice(val id: String, val title: String)

    @Serializable data class Band(val dbz: Double, val color: String)

    @Serializable data class Level(val ft: Int, val title: String)

    // A wind barb icon in a size-point square, staff up from the center: lines and triangles as flat point lists.
    @Serializable
    data class Barb(
        val name: String,
        val size: Double,
        val lineWidth: Double,
        val lines: List<List<Double>>,
        val triangles: List<List<Double>>,
        val ring: Double? = null,
    )
}

// A reply: the status and the body saved to a file, or why no answer came (offline, timeout, tls, other).
@Serializable
data class WxReply(val status: Int? = null, val file: String? = null, val etag: String? = null, val failed: String? = null)

@Serializable data class WxIndexArgs(val reply: WxReply, val now: Long)

@Serializable data class WxFetch(val source: String, val path: String, val etag: String? = null)

@Serializable data class WxPlan(val jobs: List<WxFetch>, val frames: List<WxFetch>)

@Serializable data class WxSourceArgs(val source: String, val reply: WxReply)

@Serializable data class WxFrameArgs(val path: String, val reply: WxReply)

@Serializable data class WxKept(val kept: Boolean)

@Serializable data class WxNow(val now: Long)

// A loop picture to download, with the progress words to show meanwhile. Null fetch: nothing to loop.
@Serializable data class WxLoopFetch(val path: String, val loading: String)

@Serializable data class WxLoopStart(val fetch: List<WxLoopFetch>? = null)

@Serializable data class WxLoopFrame(val file: String, val clock: String, val seconds: Double)

@Serializable data class WxLoopPlay(val frames: List<WxLoopFrame>)

@Serializable
data class WxShowArgs(
    val now: Long,
    val on: List<String>,
    val show: String? = null,
    val windsLevel: Int? = null,
    val cruiseFt: Int? = null,
)

@Serializable
data class WxNotices(
    val labels: List<Label> = emptyList(),
    val clock: String? = null,
    val legend: String? = null,
    val radar: Boolean = false,
    val winds: String? = null,
    val next: Long? = null,
) {
    @Serializable data class Label(val id: String, val text: String)
}

// note says when the notice's shape could not be read.
@Serializable data class WxTfr(val title: String, val detail: String? = null, val levels: String? = null, val note: String? = null)

@Serializable
data class WxLayers(
    val sources: Map<String, String>,
    val visible: Map<String, Boolean>,
    val radar: String? = null,
    val satellite: String? = null,
    val tfrsWithoutArea: List<WxTfr>,
    val windsLevel: Int,
)

@Serializable data class WxStationArgs(val ident: String, val icao: String? = null)

// The newest raw TAF, and the newest METAR the nav airportPage op turns into rows.
@Serializable data class WxStation(val lines: List<String> = emptyList(), val metar: JsonElement? = null)

fun weatherCatalog(call: CoreCall = Core::call): WeatherCatalog = decodeResult(call("weatherCatalog", ByteArray(0)))
