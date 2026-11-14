package com.gstudios.blueside.aircraft

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.FileProvider
import com.gstudios.blueside.AircraftList
import com.gstudios.blueside.FlightLoad
import com.gstudios.blueside.LoadedRoute
import com.gstudios.blueside.ImportArgs
import com.gstudios.blueside.ListArgs
import com.gstudios.blueside.Profile
import com.gstudios.blueside.SaveArgs
import com.gstudios.blueside.aircraftExport
import com.gstudios.blueside.aircraftImport
import com.gstudios.blueside.aircraftLabels
import com.gstudios.blueside.aircraftList
import com.gstudios.blueside.aircraftSave
import com.gstudios.blueside.id
import com.gstudios.blueside.number
import com.gstudios.blueside.text
import com.gstudios.blueside.route.RouteModel
import com.gstudios.blueside.route.writeWhole
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

// A W&B load as typed: station weights by index, fuel at start, and fuel burned (null takes the plan's).
class Load {
    val weights = mutableStateMapOf<Int, String>()
    var startFuel by mutableStateOf("")
    var burned by mutableStateOf<String?>(null)
}

// The aircraft list in filesDir/aircraft.json. The core reads, checks and writes the text.
// airborne is the core's in-flight rule on the fix now, which W&B reads as it opens.
class AircraftModel(private val context: Context, private val route: RouteModel, val airborne: () -> Boolean) {
    private val prefs = context.getSharedPreferences("blueside", Context.MODE_PRIVATE)
    private val file = File(context.filesDir, "aircraft.json")
    val labels = aircraftLabels()
    var list by mutableStateOf(AircraftList())
        private set
    // The load for the flight's aircraft, so the plan and brief see it. Cleared on a change of aircraft.
    var load by mutableStateOf(Load())
        private set
    private var followed: String? = null

    init {
        // The two numbers older versions kept become one profile, once.
        val old = listOf(route.labels.speedKey, route.labels.burnKey).map { prefs.getString(it, null)?.toDoubleOrNull() }
        apply(aircraftList(ListArgs(read(), old[0], old[1])))
        if (old.any { it != null } && file.exists()) prefs.edit().remove(route.labels.speedKey).remove(route.labels.burnKey).apply()
    }

    private fun read(): String? = file.takeIf { it.exists() }?.readText()

    private fun apply(result: AircraftList): AircraftList {
        result.file?.let { file.writeWhole(it) }
        list = result
        return result
    }

    // The flight's aircraft, else the first, so a deleted one falls back.
    val current: Profile?
        get() = list.aircraft.firstOrNull { it.id == route.inputs?.inputs?.text("aircraftID") } ?: list.aircraft.firstOrNull()

    // Route numbers follow the flight's aircraft; its load stays only while it does.
    fun follow(profile: Profile?) {
        if (profile?.id != followed) load = Load()
        followed = profile?.id
        route.setAircraft(profile?.number("cruiseTASKt") ?: 0.0, profile?.number("burnGPH") ?: 0.0)
    }

    fun fileText(): String? = read()

    // The load as numbers, to save with a flight.
    fun flightLoad() = FlightLoad(
        weights = List((load.weights.keys.maxOrNull() ?: -1) + 1) { load.weights[it]?.toDoubleOrNull() },
        startFuel = load.startFuel.toDoubleOrNull(), burned = load.burned?.toDoubleOrNull())

    // A loaded flight's load, kept when its aircraft becomes current.
    fun restore(loaded: LoadedRoute) {
        val saved = loaded.load ?: return
        val id = loaded.inputs.inputs.text("aircraftID") ?: return
        load = Load().apply {
            saved.weights.forEachIndexed { i, w -> w?.let { weights[i] = number(it) } }
            startFuel = saved.startFuel?.let(::number).orEmpty()
            burned = saved.burned?.let(::number)
        }
        followed = id
    }

    private fun number(v: Double) = if (v % 1.0 == 0.0) v.toLong().toString() else v.toString()

    // The one aircraft older versions used for every route, once, to move into the flight.
    fun takeOldChoice(): String? = prefs.getString(labels.selectedKey, null)?.also {
        prefs.edit().remove(labels.selectedKey).apply()
    }

    // Returns the core's problems; empty means saved.
    fun save(profile: Profile): List<String> = apply(aircraftSave(SaveArgs(read(), profile = profile))).problems

    fun delete(id: String) {
        apply(aircraftSave(SaveArgs(read(), delete = id)))
        removePOH(id)
    }

    // The pilot's own POH, copied into the app as POH/<id>.pdf. Bumped on change so the editor redraws.
    var pohVersion by mutableStateOf(0)
        private set

    fun poh(id: String): File? = File(context.filesDir, "POH/$id.pdf").takeIf { it.length() > 0 }

    // Copies the picked PDF in off the main thread, replacing any earlier one only once the copy is whole.
    // False when it could not be read.
    suspend fun attachPOH(id: String, uri: android.net.Uri): Boolean {
        val out = File(context.filesDir, "POH/$id.pdf")
        val copied = withContext(Dispatchers.IO) {
            out.parentFile?.mkdirs()
            val temp = File("${out.path}.tmp")
            runCatching {
                context.contentResolver.openInputStream(uri)!!.use { input -> temp.outputStream().use { input.copyTo(it) } }
                check(temp.renameTo(out))
            }.isSuccess.also { if (!it) temp.delete() }
        }
        pohVersion++
        return copied
    }

    fun removePOH(id: String) {
        File(context.filesDir, "POH/$id.pdf").delete()
        pohVersion++
    }

    // With a tail already here and `replace` null, the result has conflict set and nothing changes.
    fun import(text: String, replace: Boolean? = null): AircraftList = apply(aircraftImport(ImportArgs(read(), text, replace)))

    // Writes the core's file to the cache and offers the share sheet.
    fun share(profile: Profile) {
        val out = aircraftExport(profile)
        val folder = File(context.cacheDir, "aircraft").apply { mkdirs() }
        val shared = File(folder, out.name).apply { writeText(out.text) }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", shared)
        val send = Intent(Intent.ACTION_SEND).setType("application/json").putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(send, out.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
