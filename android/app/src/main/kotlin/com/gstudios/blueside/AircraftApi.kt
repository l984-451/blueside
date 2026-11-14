package com.gstudios.blueside

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive

// Profiles stay the core's JSON objects, so Kotlin edits fields by key and never drops one it does not know.
typealias Profile = JsonObject

fun Profile.text(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
fun Profile.number(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull
val Profile.id: String get() = this["id"]!!.jsonPrimitive.content

@Serializable data class ListArgs(val file: String? = null, val speed: Double? = null, val burn: Double? = null)
@Serializable data class SaveArgs(val file: String? = null, val profile: Profile? = null, val delete: String? = null)
@Serializable data class ImportArgs(val file: String? = null, val text: String, val replace: Boolean? = null)
// burned null takes the core's default with no trip fuel known; airborne, none.
@Serializable data class WeightArgs(val profile: Profile, val weights: List<Double>, val startFuel: Double? = null, val burned: Double? = null,
                                    val airborne: Boolean? = null)

@Serializable
data class AircraftList(
    val aircraft: List<Profile> = emptyList(),
    val templates: List<Template> = emptyList(),
    val blank: Profile? = null,
    val file: String? = null,
    val problems: List<String> = emptyList(),
    val conflict: Boolean = false,
)

@Serializable data class Template(val title: String, val profile: Profile) {
    // Every word of the query is in the title or type, ignoring case, spaces and dashes; matches the core's rule.
    fun matches(query: String): Boolean {
        fun key(s: String) = s.lowercase().filter { it.isLetterOrDigit() }
        val text = key(title + (profile.text("type") ?: ""))
        return query.split(" ").map(::key).all { text.contains(it) }
    }
}

@Serializable data class ExportFile(val name: String, val text: String)

@Serializable data class EnvelopePoint(val armIn: Double, val weightLb: Double)
@Serializable data class BalancePoint(val weightLb: Double, val momentLbIn: Double, val cgIn: Double)

@Serializable
data class Balance(
    val takeoff: BalancePoint,
    // Absent in flight with no fuel burned typed, with burnLine empty.
    val landing: BalancePoint? = null,
    val problems: List<String>,
    val notes: List<String>,
    val takeoffInLimits: Boolean,
    val landingInLimits: Boolean,
    val envelope: List<EnvelopePoint>,
    val burnLine: List<EnvelopePoint>,
    val rows: List<Line>,
    // The verdict; absent when nothing is wrong and there is no landing point.
    val status: String? = null,
    val ok: Boolean,
)

@Serializable
data class WeightResult(
    val balance: Balance? = null,
    // The fuel burned the balance used.
    val burned: Double? = null,
    val missing: List<String> = emptyList(),
    val missingNote: String? = null,
    // The note under Fuel burned; absent in flight.
    val burnedNote: String? = null,
    val takeoffLabel: String,
    val landingLabel: String,
)

@Serializable data class AircraftField(val key: String, val title: String, val unit: String? = null, val number: Boolean = true,
    val required: Boolean = false)
@Serializable data class AircraftSection(val title: String, val fields: List<AircraftField>)

@Serializable
data class AircraftLabels(
    val title: String, val add: String, val blank: String, val importFile: String, val export: String,
    val delete: String, val save: String, val cancel: String, val empty: String,
    val conflict: String, val weightBalance: String, val stationsTitle: String, val station: String,
    val addStation: String, val envelopeTitle: String, val envelopeNote: String, val addPoint: String,
    val arm: String, val weight: String, val limit: String, val name: String, val fuelTitle: String,
    val startFuel: String, val burnedFuel: String, val loadTitle: String,
    val resultsTitle: String, val lb: String, val inches: String, val gal: String, val selectedKey: String,
    val sections: List<AircraftSection>, val fillInNote: String, val replace: String, val keepBoth: String,
    val belowChart: String, val template: String, val searchTemplates: String, val poh: String,
    val attachPOH: String, val replacePOH: String, val removePOH: String, val pohNote: String,
)

fun aircraftList(args: ListArgs, call: CoreCall = Core::call): AircraftList = call.request("aircraftList", args)
fun aircraftSave(args: SaveArgs, call: CoreCall = Core::call): AircraftList = call.request("aircraftSave", args)
fun aircraftImport(args: ImportArgs, call: CoreCall = Core::call): AircraftList = call.request("aircraftImport", args)
fun aircraftExport(profile: Profile, call: CoreCall = Core::call): ExportFile = call.request("aircraftExport", profile)
fun weightBalance(args: WeightArgs, call: CoreCall = Core::call): WeightResult = call.request("weightBalance", args)
fun aircraftLabels(call: CoreCall = Core::call): AircraftLabels = decodeResult(call("aircraftLabels", ByteArray(0)))
