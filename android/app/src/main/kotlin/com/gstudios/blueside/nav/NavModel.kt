package com.gstudios.blueside.nav

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.gstudios.blueside.AirportPageResult
import com.gstudios.blueside.CardArgs
import com.gstudios.blueside.Core
import com.gstudios.blueside.CoreCall
import com.gstudios.blueside.Fix
import com.gstudios.blueside.NavItem
import com.gstudios.blueside.PageSection
import com.gstudios.blueside.NavMetadata
import com.gstudios.blueside.PageArgs
import com.gstudios.blueside.PickArgs
import com.gstudios.blueside.PickResult
import com.gstudios.blueside.Place
import com.gstudios.blueside.PlaceCardResult
import com.gstudios.blueside.PlaceHeader
import com.gstudios.blueside.SearchArgs
import com.gstudios.blueside.SearchPage
import com.gstudios.blueside.airportPage
import com.gstudios.blueside.handleCall
import com.gstudios.blueside.navLabels
import com.gstudios.blueside.navMetadata
import com.gstudios.blueside.navSearch
import com.gstudios.blueside.plates.PlateRef
import com.gstudios.blueside.plates.PlatesResult
import com.gstudios.blueside.pick
import com.gstudios.blueside.placeCard
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement

// One screen in the nav panel's stack.
sealed interface NavPage {
    data object Search : NavPage
    data class Airport(val ident: String) : NavPage
    data class Card(val place: Place) : NavPage
    // bend marks the places a let-go rubber band could snap to.
    data class Here(val items: List<NavItem>, val bend: Boolean = false) : NavPage
    data class Procedures(val plates: PlatesResult) : NavPage
    data class Chart(val plate: PlateRef, val words: PlatesResult) : NavPage
    data class Sketch(val ref: com.gstudios.blueside.plates.SketchRef) : NavPage
    data class Remarks(val section: PageSection) : NavPage
}

// The open nav database and what the nav panel shows from it. The core builds every row and word.
class NavModel(
    context: Context,
    private val fix: () -> Fix?,
    private val approximate: () -> Boolean,
    private val plan: () -> JsonElement?,
) {
    private val prefs = context.getSharedPreferences("blueside", Context.MODE_PRIVATE)
    private val lock = Mutex()
    private var handle = 0L
    private var call: CoreCall? = null

    val labels = navLabels()
    var open by mutableStateOf(false)
        private set
    // Set when a database file was named but could not be opened.
    var unreadable by mutableStateOf(false)
        private set
    var query by mutableStateOf("")
    val stack = mutableStateListOf<NavPage>(NavPage.Search)
    var search by mutableStateOf<SearchPage?>(null)
        private set
    var airport by mutableStateOf<AirportPageResult?>(null)
        private set
    var card by mutableStateOf<PlaceCardResult?>(null)
        private set
    // The open page's distance line on its own, so a new fix recomposes only the header.
    var header by mutableStateOf<Pair<Place, PlaceHeader>?>(null)
        private set
    // When the open page's words can next change with no new fix or report. Null for never.
    var next by mutableStateOf<Long?>(null)
        private set
    // The open airport's newest METAR from the weather folder; the core ignores another station's.
    var metar: JsonElement? = null
    // Identifiers in the order added, under the same key iOS uses.
    val favorites = mutableStateListOf<String>().apply {
        addAll(prefs.getString(FAVORITES, "").orEmpty().split(",").filter { it.isNotEmpty() })
    }

    val top: NavPage get() = stack.last()

    // Opens the database the style names, closing the last one. Called again on a cycle switch.
    suspend fun use(path: String?) = withContext(Dispatchers.IO) {
        lock.withLock {
            if (handle != 0L) Core.close(handle)
            handle = path?.let { Core.open("nav", it) } ?: 0L
            call = if (handle != 0L) handleCall(handle) else null
        }
        open = handle != 0L
        unreadable = path != null && handle == 0L
        refresh()
    }

    suspend fun metadata(): NavMetadata? = withCall { navMetadata(it) }

    // Runs a call on the open handle off the main thread. Null when nothing is open or the call fails.
    suspend fun <R> withCall(body: (CoreCall) -> R): R? = withContext(Dispatchers.IO) {
        lock.withLock { call?.let { runCatching { body(it) }.getOrNull() } }
    }

    // Reads again whatever page is on top, so distances follow the fix.
    suspend fun refresh() {
        val now = System.currentTimeMillis()
        when (val page = top) {
            NavPage.Search -> search = withCall { navSearch(SearchArgs(query, favorites.toList(), fix(), approximate(), now), it) }
                .also { next = it?.next }
            is NavPage.Airport -> withCall { airportPage(PageArgs(page.ident, plan(), fix(), approximate(), now, metar), it) }.let {
                if (it?.page != airport?.page || it?.place != airport?.place) airport = it
                header = it?.let { r -> r.place to r.header }
                next = it?.next
            }
            is NavPage.Card -> withCall { placeCard(CardArgs(page.place, plan(), fix(), approximate(), now), it) }.let {
                if (it?.card != card?.card || it?.nearby != card?.nearby) card = it
                header = it?.let { r -> page.place to r.header }
                next = null
            }
            else -> next = null
        }
    }

    suspend fun push(page: NavPage) {
        stack.add(page)
        refresh()
    }

    suspend fun pop() {
        if (stack.size > 1) stack.removeAt(stack.lastIndex)
        refresh()
    }

    // Starts the stack over at one page, with the search under an airport page.
    suspend fun reset(page: NavPage) {
        stack.clear()
        if (page is NavPage.Airport) stack.add(NavPage.Search)
        stack.add(page)
        refresh()
    }

    suspend fun pick(args: PickArgs): PickResult? = withCall { pick(args, it) }

    // Opens a list row: an airport's page, or any other place's card.
    suspend fun openPlace(place: Place) = push(if (place.kind == "airport") NavPage.Airport(place.ident) else NavPage.Card(place))

    fun toggleFavorite(ident: String) {
        if (!favorites.remove(ident)) favorites.add(ident)
        prefs.edit().putString(FAVORITES, favorites.joinToString(",")).apply()
    }

    companion object {
        const val FAVORITES = "favoriteAirports"
    }
}
