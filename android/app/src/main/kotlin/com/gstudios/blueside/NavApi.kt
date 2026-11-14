package com.gstudios.blueside

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

// Nav ops on an open "nav" handle. Every word shown comes from these results.

@Serializable
data class Place(val kind: String, val ident: String, val icao: String? = null, val name: String, val latitude: Double, val longitude: Double)

@Serializable
data class NavRow(
    val kind: String,
    val ident: String,
    val title: String,
    val name: String? = null,
    val closed: String? = null,
    val kindLabel: String? = null,
    val quick: String? = null,
    val distance: String? = null,
    val bearing: String? = null,
    val turn: Double? = null,
    val coordinate: Coordinate,
)

@Serializable data class NavItem(val row: NavRow, val place: Place)

// removable marks the favorites, whose rows offer Remove.
@Serializable
data class ListSection(val title: String? = null, val items: List<NavItem>, val empty: String? = null, val removable: Boolean = false)

@Serializable
data class NavLabels(
    val searchTitle: String,
    val searchPrompt: String,
    val direct: String,
    val add: String,
    val showOnMap: String,
    val remove: String,
    val download: String,
    val addFavorite: String,
    val removeFavorite: String,
    val copyHint: String,
    val notDownloaded: String,
    val unreadable: String,
    val here: String,
    val pickLayers: List<String>,
    val pickBox: Double,
    val showOnMapZoom: Double,
)

@Serializable
data class SearchArgs(val text: String, val favorites: List<String>, val fix: Fix? = null, val approximate: Boolean = false, val now: Long)

@Serializable data class SearchPage(val warning: String? = null, val problem: String? = null, val sections: List<ListSection>, val next: Long? = null)

@Serializable
data class PageArgs(
    val ident: String,
    val plan: JsonElement? = null,
    val fix: Fix? = null,
    val approximate: Boolean = false,
    val now: Long,
    // The airport's newest METAR as the weather station op returns it.
    val metar: JsonElement? = null,
)

@Serializable
data class Line(
    val title: String,
    val value: String? = null,
    val detail: String? = null,
    val tag: String? = null,
    val alert: String? = null,
    val copy: String? = null,
)

@Serializable data class PageSection(val title: String, val lines: List<Line>, val empty: String? = null)

@Serializable
data class AirportPage(
    val ident: String,
    val title: String,
    val subtitle: String,
    val closed: String? = null,
    val warning: String? = null,
    val place: String,
    val glance: List<Line>,
    val weather: AirportWeather,
    val runways: PageSection,
    val frequencies: PageSection,
    val remarks: PageSection,
    val details: PageSection,
    val footer: List<String>,
)

@Serializable data class RunwayWindLine(val end: String, val wind: String, val gust: String? = null, val tag: String? = null)

// The airport's current METAR as rows; category is null when there is none and note says so.
@Serializable
data class AirportWeather(
    val title: String,
    val category: Line? = null,
    val color: String? = null,
    val lines: List<Line>,
    val runways: List<RunwayWindLine>,
    val note: String,
    val raw: String? = null,
)

@Serializable
data class PlaceHeader(val distance: String, val bearing: String, val addTitle: String? = null)

@Serializable
data class AirportPageResult(
    val page: AirportPage,
    val header: PlaceHeader,
    val place: Place,
    val next: Long? = null,
    // Shown where the plates hold no FAA diagram.
    val sketch: com.gstudios.blueside.plates.SketchRef? = null,
)

@Serializable
data class CardArgs(val place: Place, val plan: JsonElement? = null, val fix: Fix? = null, val approximate: Boolean = false, val now: Long)

@Serializable
data class PlaceCard(
    val title: String,
    val subtitle: String,
    val lines: List<Line>,
    val nearbyTitle: String? = null,
    val nearbyEmpty: String? = null,
    val showOnMap: Boolean,
)

@Serializable data class PlaceCardResult(val card: PlaceCard, val header: PlaceHeader, val nearby: List<NavItem>)

@Serializable data class Hit(val place: Place, val distance: Double)

@Serializable data class StationHit(val station: String, val latitude: Double, val longitude: Double, val distance: Double)

@Serializable data class PickArgs(val hits: List<Hit>? = null, val stations: List<StationHit>? = null, val pin: Coordinate? = null)

// open is nothing, airport, place or here.
@Serializable
data class PickResult(val open: String, val ident: String? = null, val place: Place? = null, val here: List<NavItem>)

fun navLabels(call: CoreCall = Core::call): NavLabels = decodeResult(call("navLabels", ByteArray(0)))

fun navSearch(args: SearchArgs, call: CoreCall): SearchPage = call.request("search", args)

fun airportPage(args: PageArgs, call: CoreCall): AirportPageResult = call.request("airportPage", args)

fun placeCard(args: CardArgs, call: CoreCall): PlaceCardResult = call.request("placeCard", args)

fun pick(args: PickArgs, call: CoreCall): PickResult = call.request("pick", args)
