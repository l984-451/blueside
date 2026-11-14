package com.gstudios.blueside.route

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.gstudios.blueside.Fix
import com.gstudios.blueside.Grab
import com.gstudios.blueside.LoadRouteArgs
import com.gstudios.blueside.LoadedRoute
import com.gstudios.blueside.Offer
import com.gstudios.blueside.PlanInputArgs
import com.gstudios.blueside.PlanInputs
import com.gstudios.blueside.Place
import com.gstudios.blueside.RouteArgs
import com.gstudios.blueside.RouteEdit
import com.gstudios.blueside.RouteResult
import com.gstudios.blueside.SavedArgs
import com.gstudios.blueside.SavedView
import com.gstudios.blueside.TypedView
import com.gstudios.blueside.nav.NavModel
import com.gstudios.blueside.loadRoute
import com.gstudios.blueside.localOffset
import com.gstudios.blueside.planInputs
import com.gstudios.blueside.route
import com.gstudios.blueside.routeLabels
import com.gstudios.blueside.savedRoutes
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import java.io.File

// Written whole and then moved over, so a failed write never leaves half a file.
fun File.writeWhole(text: String) {
    val temp = File("$path.tmp")
    temp.writeText(text)
    temp.renameTo(this)
}

// A dropped point's Use instead? offer, with where on the map view (px) it was dropped.
data class Shown(val offer: Offer, val x: Float, val y: Float)

// The bend waiting for one of several equally near places.
data class PendingBend(val grab: Grab, val drawnCount: Int)

// The active route as the core's JSON, and what the drawer, editor and map draw from it. The core decides every edit.
class RouteModel(context: Context, private val nav: NavModel, private val fix: () -> Fix?, private val approximate: () -> Boolean) {
    val labels = routeLabels()
    private val prefs = context.getSharedPreferences("blueside", Context.MODE_PRIVATE)

    var plan: JsonElement? = null
        private set
    var view by mutableStateOf<RouteResult?>(null)
        private set
    var typed by mutableStateOf<TypedView?>(null)
    // The route before the last map edit, kept while Undo shows.
    var undo by mutableStateOf<JsonElement?>(null)
    var offer by mutableStateOf<Shown?>(null)
    var pending: PendingBend? = null
    var drawerOpen by mutableStateOf(true)

    // From the flight's aircraft; AircraftModel sets them.
    var speed by mutableDoubleStateOf(0.0)
        private set
    var burn by mutableDoubleStateOf(0.0)
        private set

    fun setAircraft(speed: Double, burn: Double) {
        this.speed = speed
        this.burn = burn
    }

    // Applies an edit, or with none steps the active leg and reads the rows again. Returns the result.
    suspend fun edit(edit: RouteEdit? = null, undoable: Boolean = false): RouteResult? {
        val before = plan
        val result = nav.withCall {
            route(RouteArgs(before, edit, fix(), approximate(), System.currentTimeMillis(), speed, burn, view?.planKey), it)
        } ?: return null
        // A tick that raced an edit must not undo it.
        if (edit == null && plan != before) return null
        // A fix changes the route only by sequencing a leg; what else it notes in the plan is no edit.
        val changed = if (edit == null) result.flown else result.plan != before
        if (undoable && changed) undo = before
        if (result.plan == null || changed) offer = null
        plan = result.plan
        view = result
        if (edit?.op == "typed") typed = result.typed
        if (edit != null) loaded = null
        if (result.flown) savedEdit(SavedArgs(now = 0, recent = true))
        if (changed) drawerOpen = true
        return result
    }

    // The flight plan inputs, kept on the device as the core's text. Null until the nav database opens.
    var inputs by mutableStateOf<PlanInputs?>(null)
        private set

    // One at a time, so a slower call never writes over a newer one.
    private val inputsLock = Mutex()

    suspend fun setInputs(change: PlanInputArgs = PlanInputArgs(now = 0)) = inputsLock.withLock {
        val args = change.copy(stored = prefs.getString(labels.planInputsKey, null), now = System.currentTimeMillis())
        val result = nav.withCall { planInputs(args, it) } ?: return@withLock
        prefs.edit().putString(labels.planInputsKey, result.stored).apply()
        inputs = result
    }

    // Saved and recent routes in filesDir/routes.json. The core reads, edits and writes the text.
    private val savedFile = File(context.filesDir, labels.savedFile)
    var saved by mutableStateOf(SavedView())
        private set
    // The last route loaded from the list, with what the parser and the new cycle say about it.
    var loaded by mutableStateOf<LoadedRoute?>(null)
        private set

    private fun readSaved(): String? = savedFile.takeIf { it.exists() }?.readText()

    private fun writeSaved(text: String) = savedFile.writeWhole(text)

    // One edit at most (save, rename, remove or recent) on the current plan and inputs, then the list again.
    suspend fun savedEdit(args: SavedArgs = SavedArgs(now = 0)) {
        val result = withContext(Dispatchers.IO) {
            val sent = args.copy(file = readSaved(), plan = plan, stored = prefs.getString(labels.planInputsKey, null),
                now = System.currentTimeMillis(), localOffset = localOffset())
            runCatching { savedRoutes(sent) }.getOrNull()?.also { r -> r.file?.let(::writeSaved) }
        } ?: return
        saved = result
    }

    // Parses the route again against the nav cycle in use. With problems the active route stays.
    // restore takes the flight's load before its aircraft becomes current.
    suspend fun load(id: String, aircraft: String?, restore: (LoadedRoute) -> Unit) {
        val args = LoadRouteArgs(withContext(Dispatchers.IO) { readSaved() }, id, prefs.getString(labels.planInputsKey, null),
            System.currentTimeMillis(), aircraft)
        val result = nav.withCall { loadRoute(args, it) } ?: return
        withContext(Dispatchers.IO) { result.file?.let(::writeSaved) }
        restore(result)
        prefs.edit().putString(labels.planInputsKey, result.inputs.stored).apply()
        inputs = result.inputs
        result.plan?.let {
            plan = it
            edit()
        }
        loaded = result
        savedEdit()
    }

    suspend fun direct(place: Place) = edit(RouteEdit("direct", place = place))

    suspend fun add(place: Place) = edit(RouteEdit("add", place = place))

    suspend fun undoEdit() {
        plan = undo
        undo = null
        edit()
    }
}
