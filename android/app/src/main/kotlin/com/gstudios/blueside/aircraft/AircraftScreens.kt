@file:OptIn(ExperimentalMaterial3Api::class)

package com.gstudios.blueside.aircraft

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.ui.platform.testTag
import com.gstudios.blueside.plates.PlateRef
import com.gstudios.blueside.plates.PlateView
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import com.gstudios.blueside.AppModel
import com.gstudios.blueside.Balance
import com.gstudios.blueside.Profile
import com.gstudios.blueside.WeightArgs
import com.gstudios.blueside.id
import com.gstudios.blueside.map.CautionAmber
import com.gstudios.blueside.number
import com.gstudios.blueside.text
import com.gstudios.blueside.weightBalance
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import java.util.UUID

private fun show(value: Double?): String = when {
    value == null -> ""
    value % 1.0 == 0.0 -> value.toLong().toString()
    else -> value.toString()
}

// Only text that reads as a number, or the start of one, gets into a number field.
private fun numeric(text: String) = text.isEmpty() || text == "." || text == "-" || text.toDoubleOrNull() != null

private fun Profile.list(key: String): List<JsonObject> = (this[key] as? JsonArray)?.map { it.jsonObject }.orEmpty()

// Settings, Aircraft: the list, add from a template or blank, and import.
@Composable
fun AircraftPane(model: AppModel) {
    val aircraft = model.aircraft
    val labels = aircraft.labels
    val context = LocalContext.current
    var editing by remember { mutableStateOf<Profile?>(null) }
    var adding by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf<String?>(null) }
    var problems by remember { mutableStateOf<List<String>>(emptyList()) }
    val open = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val text = uri?.let { context.contentResolver.openInputStream(it)?.use { s -> s.readBytes().decodeToString() } }
            ?: return@rememberLauncherForActivityResult
        val result = runCatching { aircraft.import(text) }.getOrElse { e -> problems = listOf(e.message.orEmpty()); return@rememberLauncherForActivityResult }
        if (result.conflict) importing = text else problems = result.problems
    }
    fun start(template: Profile) {
        adding = false
        editing = JsonObject(template + ("id" to JsonPrimitive(UUID.randomUUID().toString())))
    }

    LazyColumn {
        item {
            FlowRow(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box {
                    Button(onClick = { adding = true }) {
                        Icon(Icons.Filled.Add, null)
                        Text(labels.add, Modifier.padding(start = 8.dp))
                    }
                    DropdownMenu(expanded = adding, onDismissRequest = { adding = false }) {
                        DropdownMenuItem(text = { Text(labels.template) }, onClick = { adding = false; picking = true })
                        aircraft.list.blank?.let { b -> DropdownMenuItem(text = { Text(labels.blank) }, onClick = { start(b) }) }
                    }
                }
                OutlinedButton(onClick = { open.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) }) {
                    Text(labels.importFile)
                }
            }
        }
        if (aircraft.list.aircraft.isEmpty()) item { Note(labels.empty) }
        items(aircraft.list.aircraft, key = { it.id }) { p ->
            ListItem(
                supportingContent = p.text("type")?.let { { Text(it) } },
                modifier = Modifier.clickable { editing = p },
            ) { Text(p.text("tail").orEmpty(), fontWeight = FontWeight.SemiBold) }
        }
    }

    if (picking) TemplatePicker(aircraft, onClose = { picking = false }) { picking = false; start(it) }
    editing?.let { AircraftEditor(aircraft, it, model.night) { editing = null } }
    importing?.let { text ->
        AlertDialog(
            onDismissRequest = { importing = null },
            text = { Text(labels.conflict) },
            confirmButton = {
                TextButton(onClick = { importing = null; problems = aircraft.import(text, true).problems }) { Text(labels.replace) }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = { importing = null }) { Text(labels.cancel) }
                    TextButton(onClick = { importing = null; problems = aircraft.import(text, false).problems }) { Text(labels.keepBoth) }
                }
            },
        )
    }
    if (problems.isNotEmpty()) {
        AlertDialog(
            onDismissRequest = { problems = emptyList() },
            text = { Column { problems.forEach { Text(it) } } },
            confirmButton = { TextButton(onClick = { problems = emptyList() }) { Text(model.route.labels.done) } },
        )
    }
}

// The templates, searchable by make and model.
@Composable
private fun TemplatePicker(aircraft: AircraftModel, onClose: () -> Unit, pick: (Profile) -> Unit) {
    val labels = aircraft.labels
    var query by remember { mutableStateOf("") }
    val shown = aircraft.list.templates.filter { it.matches(query) }
    FullScreen(title = labels.template, close = Icons.Filled.Close, onClose = onClose) {
        item {
            OutlinedTextField(
                value = query, onValueChange = { query = it }, placeholder = { Text(labels.searchTemplates) },
                leadingIcon = { Icon(Icons.Filled.Search, null) }, singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("template-search"),
            )
        }
        items(shown, key = { it.title }) { t ->
            ListItem(
                supportingContent = t.profile.text("source")?.let { { Text(it) } },
                modifier = Modifier.clickable { pick(t.profile) },
            ) { Text(t.title) }
        }
    }
}

private class StationText(val source: JsonObject, name: String, arm: String, max: String) {
    var name by mutableStateOf(name)
    var arm by mutableStateOf(arm)
    var max by mutableStateOf(max)
}

private class PointText(arm: String, weight: String) {
    var arm by mutableStateOf(arm)
    var weight by mutableStateOf(weight)
}

// Edits one aircraft as a full-screen dialog. Save hands the profile to the core, which says what is wrong.
@Composable
private fun AircraftEditor(aircraft: AircraftModel, start: Profile, night: Boolean, onClose: () -> Unit) {
    val labels = aircraft.labels
    val fields = labels.sections.flatMap { it.fields }
    val saved = aircraft.list.aircraft.any { it.id == start.id }
    val texts = remember {
        mutableStateMapOf<String, String>().apply {
            fields.forEach { put(it.key, if (it.number) show(start.number(it.key)) else start.text(it.key).orEmpty()) }
        }
    }
    val stations = remember {
        start.list("stations").map { StationText(it, it.text("name").orEmpty(), show(it.number("armIn")), show(it.number("maxLb"))) }
            .toMutableStateList()
    }
    val points = remember {
        start.list("envelope").map { PointText(show(it.number("armIn")), show(it.number("weightLb"))) }.toMutableStateList()
    }
    var problems by remember { mutableStateOf<List<String>>(emptyList()) }
    var balance by remember { mutableStateOf(false) }

    fun number(text: String): JsonElement? = text.trim().toDoubleOrNull()?.let { JsonPrimitive(it) }
    fun built(): Profile {
        val out = start.toMutableMap()
        fields.forEach { f ->
            val t = texts[f.key].orEmpty().trim()
            val value = if (f.number) number(t) else t.takeIf { it.isNotEmpty() }?.let { JsonPrimitive(it) }
            when {
                value != null -> out[f.key] = value
                f.required -> out[f.key] = if (f.number) JsonPrimitive(0.0) else JsonPrimitive("")
                else -> out.remove(f.key)
            }
        }
        out["stations"] = JsonArray(stations.map { s ->
            val o = s.source.toMutableMap()
            o["name"] = JsonPrimitive(s.name.trim())
            listOf("armIn" to s.arm, "maxLb" to s.max).forEach { (k, t) -> number(t)?.let { o[k] = it } ?: o.remove(k) }
            JsonObject(o)
        })
        out["envelope"] = JsonArray(points.map { p ->
            JsonObject(mapOf("armIn" to (number(p.arm) ?: JsonPrimitive(0.0)), "weightLb" to (number(p.weight) ?: JsonPrimitive(0.0))))
        })
        return JsonObject(out)
    }
    fun save() {
        problems = runCatching { aircraft.save(built()) }.getOrElse { listOf(it.message.orEmpty()) }
        if (problems.isEmpty()) onClose()
    }
    // Back or close with edits asks first, as Material's full-screen dialogs do.
    val unedited = remember { built() }
    var asking by remember { mutableStateOf(false) }
    fun close() = if (built() != unedited) asking = true else onClose()

    FullScreen(
        title = start.text("tail")?.takeIf { it.isNotBlank() } ?: labels.add,
        close = Icons.Filled.Close,
        onClose = ::close,
        action = { TextButton(onClick = ::save) { Text(labels.save) } },
    ) {
        if (problems.isNotEmpty()) item {
            Column(Modifier.padding(16.dp)) { problems.forEach { Text(it, color = MaterialTheme.colorScheme.error) } }
        }
        start.text("source")?.let { source -> item { Note("${labels.fillInNote}\n$source") } }
        labels.sections.forEach { section ->
            item { Header(section.title) }
            items(section.fields, key = { it.key }) { f ->
                Field(texts[f.key].orEmpty(), f.title, f.unit, number = f.number) { texts[f.key] = it }
            }
        }
        item { Header(labels.stationsTitle) }
        itemsIndexed(stations) { i, s ->
            Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
                Row {
                    Field(s.name, labels.name, null, Modifier.weight(1f), padded = false, number = false) { s.name = it }
                    IconButton(onClick = { stations.removeAt(i) }) { Icon(Icons.Filled.Close, labels.delete) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Field(s.arm, labels.arm, labels.inches, Modifier.weight(1f), padded = false, hint = s.source.text("hint")) { s.arm = it }
                    Field(s.max, labels.limit, labels.lb, Modifier.weight(1f), padded = false) { s.max = it }
                }
            }
        }
        item {
            TextButton(onClick = { stations.add(StationText(JsonObject(emptyMap()), "", "", "")) }, Modifier.padding(horizontal = 8.dp)) {
                Text(labels.addStation)
            }
        }
        item { Header(labels.envelopeTitle) }
        item { Note(labels.envelopeNote) }
        itemsIndexed(points) { i, p ->
            Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Field(p.arm, labels.arm, labels.inches, Modifier.weight(1f), padded = false) { p.arm = it }
                Field(p.weight, labels.weight, labels.lb, Modifier.weight(1f), padded = false) { p.weight = it }
                IconButton(onClick = { points.removeAt(i) }) { Icon(Icons.Filled.Close, labels.delete) }
            }
        }
        item {
            TextButton(onClick = { points.add(PointText("", "")) }, Modifier.padding(horizontal = 8.dp)) { Text(labels.addPoint) }
        }
        if (saved) item { PohRow(aircraft, start.id, night) }
        if (saved) item {
            FlowRow(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledTonalButton(onClick = { balance = true }) { Text(labels.weightBalance) }
                OutlinedButton(onClick = { aircraft.share(start) }) { Text(labels.export) }
                TextButton(onClick = { aircraft.delete(start.id); onClose() }) {
                    Text(labels.delete, color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
    if (asking) {
        AlertDialog(
            onDismissRequest = { asking = false },
            text = { Text("Discard changes?") },
            confirmButton = { TextButton(onClick = { asking = false; onClose() }) { Text("Discard") } },
            dismissButton = { TextButton(onClick = { asking = false }) { Text("Keep editing") } },
        )
    }
    if (balance) aircraft.list.aircraft.firstOrNull { it.id == start.id }?.let {
        val load = remember(it.id) { if (it.id == aircraft.current?.id) aircraft.load else Load() }
        WeightBalanceScreen(aircraft, it, load) { balance = false }
    }
}

// The pilot's own POH: attach, open, replace or remove. Only for a saved aircraft.
@Composable
private fun PohRow(aircraft: AircraftModel, id: String, night: Boolean) {
    val labels = aircraft.labels
    val scope = rememberCoroutineScope()
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { scope.launch { aircraft.attachPOH(id, it) } }
    }
    var reading by remember { mutableStateOf(false) }
    val file = remember(aircraft.pohVersion) { aircraft.poh(id) }
    Column {
        Header(labels.poh)
        FlowRow(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (file != null) {
                FilledTonalButton(onClick = { reading = true }, Modifier.testTag("aircraft-poh")) { Text(labels.poh) }
                OutlinedButton(onClick = { pick.launch(arrayOf("application/pdf")) }) { Text(labels.replacePOH) }
                TextButton(onClick = { aircraft.removePOH(id) }) { Text(labels.removePOH, color = MaterialTheme.colorScheme.error) }
            } else {
                OutlinedButton(onClick = { pick.launch(arrayOf("application/pdf")) }, Modifier.testTag("aircraft-attach-poh")) {
                    Text(labels.attachPOH)
                }
            }
        }
        Note(labels.pohNote)
    }
    if (reading && file != null) {
        Dialog(onDismissRequest = { reading = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            DialogBarIcons()
            Scaffold(topBar = {
                TopAppBar(title = { Text(labels.poh) },
                    navigationIcon = { IconButton(onClick = { reading = false }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
            }) { padding ->
                PlateView(PlateRef(name = labels.poh, file = file.name, pack = "poh"), night, labels.poh,
                    Modifier.padding(padding).fillMaxSize(), file = { file })
            }
        }
    }
}

// One load against the aircraft's limits: station weights and fuel in, the core's four points, checks and envelope out.
// Fuel burned starts at the plan's taxi plus trip, or with no plan the core's default; in flight, as the screen opens,
// none is assumed, so there is no landing point until one is typed.
@Composable
fun WeightBalanceScreen(aircraft: AircraftModel, profile: Profile, load: Load, planBurned: Double? = null, onClose: () -> Unit) {
    val labels = aircraft.labels
    val stations = profile.list("stations")
    val weights = stations.indices.map { load.weights[it].orEmpty() }
    val airborne = remember { aircraft.airborne() }
    val result = remember(weights, load.startFuel, load.burned, planBurned) {
        runCatching {
            weightBalance(WeightArgs(profile, weights.map { it.toDoubleOrNull() ?: 0.0 }, load.startFuel.toDoubleOrNull(),
                load.burned?.let { it.toDoubleOrNull() ?: 0.0 } ?: planBurned, airborne))
        }.getOrNull()
    }
    val burned = load.burned ?: show(result?.burned)
    FullScreen(
        title = labels.weightBalance,
        subtitle = profile.text("tail"),
        close = Icons.AutoMirrored.Filled.ArrowBack,
        onClose = onClose,
    ) {
        item { Header(labels.loadTitle) }
        itemsIndexed(stations) { i, s ->
            Field(weights[i], s.text("name").orEmpty(), labels.lb, hint = s.number("maxLb")?.let { "${labels.limit} ${show(it)} ${labels.lb}" }) {
                load.weights[i] = it
            }
        }
        item { Header(labels.fuelTitle) }
        item { Field(load.startFuel, labels.startFuel, labels.gal, placeholder = show(profile.number("usableFuelGal"))) { load.startFuel = it } }
        item { Field(burned, labels.burnedFuel, labels.gal, hint = result?.burnedNote) { load.burned = it } }
        item { Header(labels.resultsTitle) }
        result?.missingNote?.let { item { Note(it) } }
        result?.balance?.let { b -> results(b, result.takeoffLabel, result.landingLabel, labels.lb, labels.inches) }
    }
}

private fun LazyListScope.results(b: Balance, takeoff: String, landing: String, lb: String, inches: String) {
    // No verdict without a landing point and nothing wrong; then only the problems and notes, if any.
    if (b.status != null || b.problems.isNotEmpty() || b.notes.isNotEmpty()) item {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            b.status?.let {
                Text(it, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold,
                    color = if (b.ok) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error)
            }
            b.problems.forEach { Text(it, color = MaterialTheme.colorScheme.error) }
            b.notes.forEach { Text(it, color = CautionAmber) }
        }
    }
    item { EnvelopeChart(b, takeoff, landing, lb, inches) }
    items(b.rows) { row ->
        ListItem(
            supportingContent = row.detail?.let { { Text(it, fontFamily = FontFamily.Monospace) } },
            trailingContent = { Text(row.value.orEmpty(), fontFamily = FontFamily.Monospace) },
        ) { Text(row.title) }
    }
}

// The envelope, the burn line from takeoff to landing, T filled and L hollow. An out-of-limits dot turns red.
// With no landing point there is no L and no burn line.
@Composable
private fun EnvelopeChart(b: Balance, takeoffLabel: String, landingLabel: String, lb: String, inches: String) {
    val colors = MaterialTheme.colorScheme
    val measurer = rememberTextMeasurer()
    val small = MaterialTheme.typography.labelSmall.copy(color = colors.onSurfaceVariant)
    val bold = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold)
    Canvas(
        Modifier.fillMaxWidth().aspectRatio(1.3f).padding(16.dp).semantics { b.status?.let { contentDescription = it } },
    ) {
        val points = listOfNotNull(b.takeoff, b.landing)
        val xs = (b.envelope + b.burnLine).map { it.armIn } + points.map { it.cgIn }
        val ys = (b.envelope + b.burnLine).map { it.weightLb } + points.map { it.weightLb }
        val padX = (xs.max() - xs.min()).coerceAtLeast(1.0) * 0.08
        val padY = (ys.max() - ys.min()).coerceAtLeast(1.0) * 0.08
        val x0 = xs.min() - padX
        val x1 = xs.max() + padX
        val y0 = ys.min() - padY
        val y1 = ys.max() + padY
        val left = 44.dp.toPx()
        val bottom = size.height - 20.dp.toPx()
        fun at(arm: Double, weight: Double) = Offset(
            left + ((arm - x0) / (x1 - x0)).toFloat() * (size.width - left),
            bottom - ((weight - y0) / (y1 - y0)).toFloat() * bottom,
        )
        drawRect(colors.outlineVariant, Offset(left, 0f), androidx.compose.ui.geometry.Size(size.width - left, bottom), style = Stroke(1.dp.toPx()))
        // Weight in pounds up the side, CG in inches along the bottom.
        drawText(measurer, show(Math.round(y1).toDouble()) + "\n" + lb, Offset(0f, 0f), small)
        drawText(measurer, show(Math.round(y0).toDouble()) + "\n" + lb, Offset(0f, bottom - 28.dp.toPx()), small)
        drawText(measurer, "%.1f %s".format(x0, inches), Offset(left, bottom + 4.dp.toPx()), small)
        val right = measurer.measure("%.1f %s".format(x1, inches), small)
        drawText(right, topLeft = Offset(size.width - right.size.width, bottom + 4.dp.toPx()))

        val ring = Path().apply {
            b.envelope.forEachIndexed { i, p -> at(p.armIn, p.weightLb).let { if (i == 0) moveTo(it.x, it.y) else lineTo(it.x, it.y) } }
            close()
        }
        drawPath(ring, colors.primary.copy(alpha = 0.12f))
        drawPath(ring, colors.primary, style = Stroke(2.dp.toPx()))
        val burn = Path().apply {
            b.burnLine.forEachIndexed { i, p -> at(p.armIn, p.weightLb).let { if (i == 0) moveTo(it.x, it.y) else lineTo(it.x, it.y) } }
        }
        if (b.burnLine.isNotEmpty()) drawPath(burn, colors.onSurface.copy(alpha = 0.6f), style = Stroke(2.dp.toPx()))

        val r = 6.dp.toPx()
        val t = at(b.takeoff.cgIn, b.takeoff.weightLb)
        val tColor = if (b.takeoffInLimits) colors.onSurface else colors.error
        drawCircle(tColor, r, t)
        drawText(measurer, takeoffLabel, t + Offset(r + 2.dp.toPx(), -r * 2.5f), bold.copy(color = tColor))
        b.landing?.let { landing ->
            val l = at(landing.cgIn, landing.weightLb)
            val lColor = if (b.landingInLimits) colors.onSurface else colors.error
            drawCircle(colors.surface, r - 2.dp.toPx(), l)
            drawCircle(lColor, r, l, style = Stroke(2.dp.toPx()))
            drawText(measurer, landingLabel, l + Offset(r + 2.dp.toPx(), 0f), bold.copy(color = lColor))
        }
    }
}

@Composable
internal fun FullScreen(
    title: String,
    close: androidx.compose.ui.graphics.vector.ImageVector,
    onClose: () -> Unit,
    subtitle: String? = null,
    action: @Composable () -> Unit = {},
    content: LazyListScope.() -> Unit,
) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        DialogBarIcons()
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        Column {
                            Text(title)
                            subtitle?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
                        }
                    },
                    navigationIcon = { IconButton(onClick = onClose) { Icon(close, if (close == Icons.Filled.Close) "Close" else "Back") } },
                    actions = { action() },
                )
            },
        ) { padding -> LazyColumn(Modifier.padding(padding).fillMaxSize().imePadding(), content = content) }
    }
}

@Composable
private fun Field(
    value: String,
    label: String,
    unit: String?,
    modifier: Modifier = Modifier.fillMaxWidth(),
    padded: Boolean = true,
    number: Boolean = true,
    hint: String? = null,
    placeholder: String? = null,
    onChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = { if (!number || numeric(it)) onChange(it) },
        label = { Text(label) },
        suffix = unit?.let { { Text(it) } },
        supportingText = hint?.let { { Text(it) } },
        placeholder = placeholder?.let { { Text(it) } },
        keyboardOptions = KeyboardOptions(keyboardType = if (number) KeyboardType.Decimal else KeyboardType.Text),
        singleLine = true,
        modifier = if (padded) modifier.padding(horizontal = 16.dp, vertical = 4.dp) else modifier,
    )
}

@Composable
private fun Header(text: String) {
    Text(text, Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 4.dp),
        style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun Note(text: String) {
    Text(text, Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
}

// Dialog windows own their system bars; match icon tone to the theme so they stay readable.
@Composable
internal fun DialogBarIcons() {
    val window = (LocalView.current.parent as? DialogWindowProvider)?.window ?: return
    val light = MaterialTheme.colorScheme.background.luminance() > 0.5f
    SideEffect {
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = light
            isAppearanceLightNavigationBars = light
        }
    }
}
