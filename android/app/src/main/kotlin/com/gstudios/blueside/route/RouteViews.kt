@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)

package com.gstudios.blueside.route

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CloseFullscreen
import androidx.compose.material.icons.filled.OpenInFull
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material.icons.filled.Route
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.produceState
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import com.gstudios.blueside.AppModel
import com.gstudios.blueside.EditorLeg
import com.gstudios.blueside.EditorPoint
import com.gstudios.blueside.FitArgs
import com.gstudios.blueside.Leg
import com.gstudios.blueside.Line
import com.gstudios.blueside.LegRow
import com.gstudios.blueside.Place
import com.gstudios.blueside.PlanInputArgs
import com.gstudios.blueside.PlanView
import com.gstudios.blueside.RouteEdit
import com.gstudios.blueside.RouteResult
import com.gstudios.blueside.TakeArgs
import com.gstudios.blueside.TypedView
import com.gstudios.blueside.aircraft.WeightBalanceScreen
import com.gstudios.blueside.map.CautionAmber
import com.gstudios.blueside.number
import com.gstudios.blueside.text
import com.gstudios.blueside.id
import com.gstudios.blueside.logFitted
import com.gstudios.blueside.routeTake
import kotlinx.coroutines.withTimeoutOrNull
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.rememberTextMeasurer
import kotlin.math.ceil
import kotlin.math.roundToInt

// Fixed aviation colors that ignore the dynamic scheme.
private val RouteMagenta = Color(0xFFD11FB6)
private val DangerRed = Color(0xFFD32F2F)
private val plain @Composable get() = ListItemDefaults.colors(containerColor = Color.Transparent)

// Rows shown before the drawer scrolls.
private const val VISIBLE_ROWS = 4

// What a log row's list item takes beside its cells: 16 padding each side, the 24 handle and the 48 remove button.
private val LOG_CHROME = 136.dp
// Between log columns.
private val LOG_GAP = 8.dp

// The route's legs in a card under the data strip; tucked away it shows one summary line.
@Composable
fun RouteDrawer(model: AppModel, modifier: Modifier = Modifier) {
    val route = model.route
    val labels = route.labels
    val view = route.view?.takeIf { it.plan != null }
    if (view == null) {
        FilledTonalButton(onClick = model::openRoute) { Text(labels.planTitle) }
        return
    }
    val direct = view.title == labels.directTitle
    Card(modifier, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
        Row(Modifier.padding(start = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(if (direct) Icons.Filled.NorthEast else Icons.Filled.Route, null, tint = RouteMagenta)
            Text(view.title.orEmpty(), Modifier.padding(start = 8.dp), color = RouteMagenta, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = model::openRoute) { Text(labels.edit) }
            IconButton(onClick = { route.drawerOpen = !route.drawerOpen }) {
                Icon(if (route.drawerOpen) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    if (route.drawerOpen) "Hide ${view.title}" else "Show ${view.title}")
            }
        }
        if (!route.drawerOpen) {
            view.summary?.let { s ->
                Row(Modifier.padding(start = 12.dp, end = 12.dp, bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(s.ident, fontWeight = FontWeight.SemiBold)
                    Text(s.detail, fontFamily = FontFamily.Monospace)
                    s.end?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
            return@Card
        }
        val list = rememberLazyListState()
        val active = view.rows.indexOfFirst { it.row.isActive }
        LaunchedEffect(active) { if (active >= 0) list.animateScrollToItem(active) }
        LazyColumn(Modifier.heightIn(max = (VISIBLE_ROWS * 60).dp), state = list) {
            items(view.rows, key = { it.row.id }) { DrawerRow(model, it, direct) }
        }
    }
}

@Composable
private fun DrawerRow(model: AppModel, leg: Leg, direct: Boolean) {
    val row = leg.row
    val labels = model.nav.labels
    var menu by remember { mutableStateOf(false) }
    Box {
        ListItem(
            leadingContent = {
                Icon(Icons.AutoMirrored.Filled.ArrowRight, null, tint = if (row.isActive) RouteMagenta else Color.Transparent)
            },
            supportingContent = { Text(row.waypoint.name, maxLines = 1) },
            trailingContent = { Range(row) },
            colors = ListItemDefaults.colors(containerColor = if (row.isActive) RouteMagenta.copy(alpha = 0.12f) else Color.Transparent),
            modifier = Modifier.combinedClickable(onLongClick = { menu = true }) { menu = true },
        ) { Ident(row.waypoint.ident, leg.closed, model.route.labels.closed) }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (!direct) DropdownMenuItem(text = { Text(labels.direct) }, onClick = {
                menu = false
                model.routeEdit(RouteEdit("directTarget", target = row.id))
            })
            DropdownMenuItem(text = { Text(labels.showOnMap) }, onClick = {
                menu = false
                val w = row.waypoint
                model.showOnMap(Place(w.kind, w.ident, null, w.name, w.coordinate.latitude, w.coordinate.longitude))
            })
            DropdownMenuItem(text = { Text(labels.remove) }, onClick = {
                menu = false
                model.routeEdit(RouteEdit("remove", target = row.id))
            })
        }
    }
}

@Composable
private fun Ident(ident: String, closed: Boolean, closedWord: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(ident, fontWeight = FontWeight.SemiBold)
        if (closed) Text(closedWord, color = DangerRed, style = MaterialTheme.typography.labelMedium)
    }
}

// Distance over course and time, in fixed-width digits.
@Composable
private fun Range(row: LegRow) {
    Column(horizontalAlignment = Alignment.End) {
        Text(row.distance, fontFamily = FontFamily.Monospace)
        Text(listOfNotNull(row.course, row.time).joinToString("  "), fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.bodySmall)
    }
}

// The route's answer first, then its text with suggestions, the plan inputs, its waypoints to reorder or remove, and
// how the answer adds up.
@Composable
fun RoutePanel(model: AppModel) {
    val route = model.route
    val labels = route.labels
    // Without what moves with each fix, so a fix redraws only the active leg's leaf.
    val view by remember { derivedStateOf { route.view?.takeIf { it.plan != null }?.still() } }
    var focused by remember { mutableStateOf(false) }
    var text by remember { mutableStateOf(TextFieldValue(view?.text.orEmpty())) }
    // Away from the field it shows the route as it stands, so a rejected edit does not linger.
    // A route loaded from the list shows its text with what the parser said, until the next edit.
    LaunchedEffect(view?.text, focused, route.loaded) {
        if (!focused) {
            val loaded = route.loaded
            text = TextFieldValue(loaded?.text ?: view?.text.orEmpty())
            route.typed = loaded?.let { TypedView(emptyList(), it.problems, it.notes) }
        }
    }
    fun type(value: TextFieldValue) {
        val changed = value.text != text.text
        text = value
        if (changed) model.routeEdit(RouteEdit("typed", text = value.text))
    }
    // Read again on open, so a departure already past rolls on.
    LaunchedEffect(model.nav.open) { route.setInputs() }
    val load = model.aircraft.load
    // Read again when the route, its plan key, inputs, aircraft, load, weather or plates change, and at the core's deadline,
    // where the inputs take a rolled-on departure first, in the app's scope so a restart here cannot cut it short.
    val plan by produceState<PlanView?>(null, view?.plan, view?.planKey, route.inputs, model.aircraft.current, load.startFuel,
        load.weights.toMap(), load.burned, model.weather.passes, model.platesVersion) {
        while (true) {
            value = model.planArgs()?.let { model.weather.planView(it) }
            model.sleepUntil(value?.next ?: break)
            model.planEdit(PlanInputArgs(now = 0))
        }
    }
    Column(Modifier.verticalScroll(rememberScrollState())) {
        TopAppBar(
            title = { Text(labels.routeTitle) },
            actions = {
                if (model.wideWindow) IconButton(onClick = { model.routeWide = !model.routeWide }) {
                    if (model.routeWide) Icon(Icons.Filled.CloseFullscreen, labels.collapse) else Icon(Icons.Filled.OpenInFull, labels.expand)
                }
                IconButton(onClick = model::routeClosed) { Icon(Icons.Filled.Close, "Close") }
            },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
            // The sheet or pane already clears the system bars.
            windowInsets = WindowInsets(0),
        )
        if (view != null) Results(model, plan)
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = text,
                onValueChange = ::type,
                modifier = Modifier.fillMaxWidth().onFocusChanged { focused = it.isFocused },
                textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
                placeholder = { Text(labels.fieldPrompt, fontFamily = FontFamily.Monospace) },
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false),
                singleLine = true,
            )
            if (!model.nav.open) Text(model.nav.labels.notDownloaded, color = MaterialTheme.colorScheme.onSurfaceVariant)
            SavedRoutesChips(model, hasRoute = view != null)
            val typed = route.typed
            if (typed != null) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    typed.suggestions.forEach { s ->
                        SuggestionChip(
                            onClick = {
                                val next = runCatching { routeTake(TakeArgs(text.text, s.place)) }.getOrNull() ?: return@SuggestionChip
                                type(TextFieldValue(next, TextRange(next.length)))
                            },
                            label = { Text(s.ident, fontWeight = FontWeight.SemiBold) },
                        )
                    }
                }
                typed.problems.forEach { Text(it, color = DangerRed, fontWeight = FontWeight.SemiBold) }
                typed.notes.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
            }
        }
        val editor = view?.editor ?: return@Column
        PlanFields(model)
        Header(editor.header)
        BoxWithConstraints {
            // Every row of the log, header first, measured as drawn. The core keeps the columns some row fills that fit
            // the room beside the row's handle and button, least needed dropped first; with none the route is a list.
            val rows = plan?.takeIf { model.planning && it.log.size == editor.points.size && it.logBefore.size == editor.points.size }
                ?.let { listOf(labels.logColumns) + it.log + it.logBefore.flatten() + listOf(it.logTotals) }
            val widths = logWidths(rows)
            // What a row takes beside its cells, measured on the header once it shows; a guess until then.
            var chrome by remember { mutableStateOf(LOG_CHROME) }
            val density = LocalDensity.current
            val page = maxWidth
            val shown = remember(rows, widths, page, chrome) {
                val room = (page - chrome + LOG_GAP).value.toDouble()
                plan?.logShown?.takeIf { rows != null }
                    ?.let { runCatching { logFitted(FitArgs(it, widths.map { w -> w + LOG_GAP.value }, room)) }.getOrNull() }
            }
            val log = shown?.let { s -> plan?.log?.map { row -> s.map { row[it] } } }
            val before = shown?.let { s -> plan?.logBefore?.map { inserts -> inserts.map { row -> s.map { row[it] } } } }
            val weights = shown?.map { widths[it].toFloat() }.orEmpty()
            Column {
                shown?.let { s ->
                    LogItem(s.map { labels.logColumns[it] }, weights, MaterialTheme.colorScheme.onSurfaceVariant) { px ->
                        chrome = page - with(density) { px.toDp() }
                    }
                }
                Points(model, editor.points, plan?.legs.orEmpty().associateBy { it.target }, log, before,
                    shown?.indexOf(labels.logTime) ?: -1, weights)
                shown?.let { s -> plan?.logTotals?.let { t -> LogItem(s.map { t[it] }, weights, bold = true) } }
            }
        }
        // Why there are no top of climb and top of descent rows, or what capped them.
        plan?.notes?.forEach { Note(it) }
        HorizontalDivider(Modifier.padding(horizontal = 16.dp))
        Details(model, plan)
        TextButton(onClick = { model.routeEdit(RouteEdit("clear")) }, Modifier.padding(horizontal = 8.dp)) {
            Text(labels.clear, color = MaterialTheme.colorScheme.error)
        }
    }
}

// The route as the panel draws it, without what moves with each fix: the drawer's rows and line, the calm totals and
// the active leg's figures, which their own leaves read.
internal fun RouteResult.still() = copy(rows = emptyList(), summary = null, line = null, typed = null, offer = null,
    choose = null, flown = false, editor = editor?.let { e ->
        e.copy(totals = emptyList(), points = e.points.map { p ->
            p.leg?.takeIf { it.isActive }?.let { p.copy(leg = it.copy(course = "", distance = "", time = null)) } ?: p
        })
    })

// What the pilot asks first: how far, how long, how much fuel and whether it is enough.
@Composable
private fun Results(model: AppModel, plan: PlanView?) {
    val route = model.route
    val labels = route.labels
    if (plan != null) plan.summary.forEach { PlanLine(it) } else CalmTotals(route)
    // In place of the time and fuel lines it explains.
    if (route.speed <= 0 || route.burn <= 0) Note(labels.speedHint)
    plan?.alternate?.let {
        Text(it.text, Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            color = if (it.required == true) CautionAmber else MaterialTheme.colorScheme.onSurface)
    }
    FlowRow(Modifier.padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        BriefButton(model)
        NavlogButton(model)
    }
}

// The editor's calm totals until the plan is worked out; from the aircraft they follow each fix.
@Composable
private fun CalmTotals(route: RouteModel) {
    route.view?.editor?.totals?.forEach { PlanLine(it) }
}

// How the answer adds up: the fuel, weight and balance, the altitudes and the sun.
@Composable
private fun Details(model: AppModel, plan: PlanView?) {
    val labels = model.route.labels
    val fuel = plan?.fuelLines.orEmpty()
    if (fuel.isNotEmpty()) {
        Header(labels.fuelBlock)
        fuel.forEach { PlanLine(it) }
    }
    WeightBalanceButton(model, plan?.burned, Modifier.padding(horizontal = 8.dp))
    plan ?: return
    // None when every line would be dashes.
    if (plan.altitudes.isNotEmpty()) {
        Header(labels.altitudesSection)
        plan.altitudes.forEach { a ->
            PlanLine(a.line, selected = a.picked) { model.planEdit(PlanInputArgs(now = 0, altitude = a.ft)) }
        }
        Note(labels.altitudesFooter)
    }
    Header(labels.sunSection)
    plan.sun.forEach { PlanLine(it) }
    Note(labels.notCovered)
}

// The active leg's distance, course and time, read on each fix in this leaf alone.
@Composable
private fun LiveRange(route: RouteModel, target: Int, planned: String?) {
    val leg = route.view?.editor?.points?.firstOrNull { it.target == target }?.leg ?: return
    Range(leg.copy(time = planned ?: leg.time))
}

// The active leg's log row, its time read on each fix in this leaf alone.
@Composable
private fun LiveLogRow(route: RouteModel, target: Int, cells: List<String>, timeAt: Int, weights: List<Float>) {
    val time = route.view?.editor?.points?.firstOrNull { it.target == target }?.leg?.time
    LogRow(if (time == null || timeAt < 0) cells else cells.toMutableList().apply { set(timeAt, time) }, weights)
}

// The waypoints; a long press lifts a row to drag it to a new place.
@Composable
private fun Points(model: AppModel, points: List<EditorPoint>, legs: Map<Int, EditorLeg>, log: List<List<String>>? = null,
                   before: List<List<List<String>>>? = null, timeAt: Int = -1, weights: List<Float> = emptyList()) {
    var dragging by remember { mutableStateOf<Int?>(null) }
    var offset by remember { mutableFloatStateOf(0f) }
    var rowHeight by remember { mutableFloatStateOf(1f) }
    val haptics = LocalHapticFeedback.current
    val first = points.firstOrNull()?.target ?: 0
    Column {
        points.forEachIndexed { index, point ->
            val moving = dragging == index
            val planned = legs[point.target]
            // Top of climb and top of descent: rows of the log that are not waypoints, so they do not drag.
            before?.getOrNull(index)?.forEach {
                LogItem(it, weights, MaterialTheme.colorScheme.onSurfaceVariant, italic = true)
            }
            ListItem(
                leadingContent = { Icon(Icons.Filled.DragHandle, null) },
                // The nav log's columns already say what these would.
                supportingContent = if (log != null) planned?.note?.let { n -> { Text(n, color = CautionAmber, style = MaterialTheme.typography.bodySmall) } } else { {
                    Column {
                        point.name?.let { Text(it, maxLines = 1) }
                        planned?.let { Text(it.wind, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
                        planned?.note?.let { Text(it, color = CautionAmber, style = MaterialTheme.typography.bodySmall) }
                    }
                } },
                trailingContent = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (log == null) point.leg?.let {
                            if (it.isActive) LiveRange(model.route, point.target, planned?.time)
                            else Range(it.copy(time = planned?.time ?: it.time))
                        }
                        IconButton(onClick = { model.routeEdit(RouteEdit("remove", target = point.target)) }) {
                            Icon(Icons.Filled.Close, model.nav.labels.remove)
                        }
                    }
                },
                colors = ListItemDefaults.colors(containerColor = if (moving) MaterialTheme.colorScheme.surfaceContainerHighest else Color.Transparent),
                modifier = Modifier
                    .onSizeChanged { rowHeight = it.height.toFloat() }
                    .zIndex(if (moving) 1f else 0f)
                    .graphicsLayer {
                        translationY = if (moving) offset else 0f
                        shadowElevation = if (moving) 8.dp.toPx() else 0f
                    }
                    .pointerInput(points, index) {
                        detectDragGesturesAfterLongPress(
                            onDragStart = {
                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                dragging = index
                                offset = 0f
                            },
                            onDrag = { change, amount ->
                                change.consume()
                                offset += amount.y
                            },
                            onDragEnd = {
                                val to = (index + (offset / rowHeight).roundToInt()).coerceIn(0, points.lastIndex)
                                dragging = null
                                offset = 0f
                                // The core takes a list move: the destination counted before the row leaves.
                                if (to != index) model.routeEdit(RouteEdit("move", target = index + first, to = (if (to > index) to + 1 else to) + first))
                            },
                            onDragCancel = {
                                dragging = null
                                offset = 0f
                            },
                        )
                    },
            ) {
                val cells = log?.getOrNull(index)
                when {
                    cells == null -> Ident(point.title, point.closed, model.route.labels.closed)
                    // Airborne, the active leg keeps its live time.
                    point.leg?.isActive == true && planned?.time == null -> LiveLogRow(model.route, point.target, cells, timeAt, weights)
                    else -> LogRow(cells, weights)
                }
            }
        }
    }
}

// A log row that is no waypoint. It holds the waypoint rows' handle and remove button, unseen, so its cells take the same
// room and each value sits under its header. onWidth gets the cells' width in px.
@Composable
private fun LogItem(cells: List<String>, weights: List<Float>, color: Color = Color.Unspecified, bold: Boolean = false,
                    italic: Boolean = false, onWidth: ((Int) -> Unit)? = null) {
    ListItem(
        leadingContent = { Icon(Icons.Filled.DragHandle, null, Modifier.alpha(0f)) },
        trailingContent = {
            IconButton(onClick = {}, Modifier.alpha(0f).clearAndSetSemantics {}, enabled = false) { Icon(Icons.Filled.Close, null) }
        },
        colors = plain,
    ) {
        LogRow(cells, weights, color, bold, italic, onWidth?.let { Modifier.onSizeChanged { size -> it(size.width) } } ?: Modifier)
    }
}

// One nav log row: the planning page's columns, each as wide as its widest text and sharing what is left in step,
// numbers in monospace.
@Composable
private fun LogRow(cells: List<String>, weights: List<Float>, color: Color = Color.Unspecified, bold: Boolean = false,
                   italic: Boolean = false, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(LOG_GAP)) {
        cells.forEachIndexed { i, cell ->
            Text(cell, Modifier.weight(weights.getOrElse(i) { 1f }.coerceAtLeast(1f)), color = color, maxLines = 1,
                fontFamily = if (i == 0) null else FontFamily.Monospace,
                fontWeight = if (bold) FontWeight.SemiBold else null, fontStyle = if (italic) FontStyle.Italic else null, textAlign = if (i == 0) TextAlign.Start else TextAlign.End,
                style = MaterialTheme.typography.bodyMedium)
        }
    }
}

// Each log column's widest header or cell in dp, set as LogRow sets it but semibold, so the totals are no wider.
@Composable
private fun logWidths(rows: List<List<String>>?): List<Double> {
    // Room for every cell, so a cell measured before costs nothing; in steps of 256, so an edit seldom drops the cache.
    val measurer = rememberTextMeasurer(cacheSize = ((rows?.sumOf { it.size } ?: 0) / 256 + 1) * 256)
    val density = LocalDensity.current
    val style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold)
    return remember(rows, style, density) {
        val count = rows?.maxOfOrNull { it.size } ?: return@remember emptyList()
        List(count) { i ->
            val set = if (i == 0) style else style.copy(fontFamily = FontFamily.Monospace)
            val px = rows.maxOf { row -> row.getOrNull(i)?.let { measurer.measure(it, set, softWrap = false, maxLines = 1).size.width } ?: 0 }
            ceil(with(density) { px.toDp() }.value).toDouble()
        }
    }
}

@Composable
private fun Header(text: String) {
    Text(text, Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
        style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun Note(text: String) {
    Text(text, Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
}

// Undo after a map edit, the native way: a snackbar that stays for the core's ten seconds.
@Composable
fun UndoBar(model: AppModel, modifier: Modifier = Modifier) {
    val host = remember { SnackbarHostState() }
    val route = model.route
    val undo = route.undo
    LaunchedEffect(undo) {
        if (undo == null) return@LaunchedEffect
        val result = withTimeoutOrNull((route.labels.undoSeconds * 1000).toLong()) {
            host.showSnackbar(route.labels.edited, route.labels.undo, duration = SnackbarDuration.Indefinite)
        }
        if (result == SnackbarResult.ActionPerformed) model.undoRoute() else if (route.undo == undo) route.undo = null
    }
    SnackbarHost(host, modifier)
}

// Opens weight and balance for the flight's aircraft, fuel burned from the plan.
@Composable
private fun WeightBalanceButton(model: AppModel, planBurned: Double?, modifier: Modifier = Modifier) {
    val profile = model.aircraft.current ?: return
    var open by remember { mutableStateOf(false) }
    FilledTonalButton(onClick = { open = true }, modifier) { Text(model.aircraft.labels.weightBalance) }
    if (open) WeightBalanceScreen(model.aircraft, profile, model.aircraft.load, planBurned) { open = false }
}

// Builds the nav log in the core and draws its PDF off the main thread, then offers it to share.
@Composable
private fun NavlogButton(model: AppModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var making by remember { mutableStateOf(false) }
    // One at a time; a failed write shares nothing rather than crashing.
    FilledTonalButton(enabled = !making, onClick = {
        making = true
        scope.launch {
            try {
                val args = model.briefArgs() ?: return@launch
                val file = withContext(Dispatchers.IO) {
                    runCatching { model.weather.navlog(args)?.let { writeNavlog(context, it) } }.getOrNull()
                } ?: return@launch
                shareNavlog(context, file, model.route.labels.shareNavlog)
            } finally {
                making = false
            }
        }
    }, modifier = Modifier.testTag("route-share-navlog")) { Text(model.route.labels.shareNavlog) }
}

@Composable
private fun BriefButton(model: AppModel) {
    var open by remember { mutableStateOf(false) }
    FilledTonalButton(onClick = { open = true }) { Text(model.route.labels.briefTitle) }
    if (open) BriefScreen(model) { open = false }
}

// One core line: title with its detail under, value at the end, and a red tag when the core gives one.
@Composable
internal fun PlanLine(line: Line, selected: Boolean = false, onClick: (() -> Unit)? = null) {
    ListItem(
        supportingContent = (line.detail ?: line.alert)?.let { { Text(it, color = if (line.alert != null) DangerRed else Color.Unspecified) } },
        trailingContent = line.value?.let { { Text(it, fontFamily = FontFamily.Monospace) } },
        colors = ListItemDefaults.colors(containerColor = if (selected) MaterialTheme.colorScheme.surfaceContainerHighest else Color.Transparent),
        modifier = onClick?.let { Modifier.clickable(onClick = it) } ?: Modifier,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(line.title, Modifier.weight(1f, fill = false), fontWeight = if (selected) FontWeight.SemiBold else null)
            line.tag?.let { Text(it, color = DangerRed, style = MaterialTheme.typography.labelLarge) }
        }
    }
}

// Aircraft, departure, rules, cruise altitude and alternate. The core keeps them and decides the defaults.
@Composable
private fun PlanFields(model: AppModel) {
    val route = model.route
    val labels = route.labels
    val current = route.inputs ?: return
    val inputs = current.inputs
    fun edit(change: PlanInputArgs) = model.planEdit(change)
    Header(labels.planSection)
    val craft = model.aircraft
    if (craft.list.aircraft.isNotEmpty()) Box {
        var choosing by remember { mutableStateOf(false) }
        PlanLine(Line(craft.labels.title, craft.current?.text("tail"))) { choosing = true }
        DropdownMenu(expanded = choosing, onDismissRequest = { choosing = false }) {
            craft.list.aircraft.forEach { p ->
                DropdownMenuItem(text = { Text(p.text("tail").orEmpty()) }, onClick = {
                    choosing = false
                    edit(PlanInputArgs(now = 0, aircraft = p.id))
                })
            }
        }
    }
    val departure = inputs.number("departure")?.toLong() ?: 0L
    var picking by remember { mutableStateOf(false) }
    PlanLine(Line(labels.departureTitle, DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
        .withZone(ZoneId.systemDefault()).format(Instant.ofEpochMilli(departure)))) { picking = true }
    if (picking) DeparturePicker(departure) { picked ->
        picking = false
        picked?.let { edit(PlanInputArgs(now = 0, departure = it)) }
    }
    ListItem(
        trailingContent = {
            SingleChoiceSegmentedButtonRow {
                labels.rules.forEachIndexed { i, rule ->
                    SegmentedButton(
                        selected = inputs.text("rules") == rule.id,
                        onClick = { edit(PlanInputArgs(now = 0, rules = rule.id)) },
                        shape = SegmentedButtonDefaults.itemShape(i, labels.rules.size),
                    ) { Text(rule.name) }
                }
            }
        },
        colors = plain,
    ) { Text(labels.rulesTitle) }
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        var altitude by remember(inputs) { mutableStateOf(inputs.number("cruiseAltitudeFt")?.toInt()?.toString().orEmpty()) }
        OutlinedTextField(
            value = altitude,
            onValueChange = { typed ->
                if (typed.length <= 5 && typed.all(Char::isDigit)) {
                    altitude = typed
                    typed.toIntOrNull()?.let { edit(PlanInputArgs(now = 0, altitude = it)) }
                }
            },
            label = { Text(labels.altitudeTitle) },
            suffix = { Text("ft") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        var alternate by remember(current.alternate) { mutableStateOf(current.alternate) }
        OutlinedTextField(
            value = alternate,
            onValueChange = { alternate = it },
            label = { Text(labels.alternateTitle) },
            placeholder = { Text(labels.alternatePrompt) },
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false,
                imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { edit(PlanInputArgs(now = 0, alternate = alternate)) }),
            singleLine = true,
            modifier = Modifier.fillMaxWidth().onFocusChanged {
                if (!it.isFocused && alternate != current.alternate) edit(PlanInputArgs(now = 0, alternate = alternate))
            },
        )
    }
}

// Date, then time, in the device's zone. Null when cancelled.
@Composable
private fun DeparturePicker(departure: Long, onDone: (Long?) -> Unit) {
    val zone = ZoneId.systemDefault()
    val start = Instant.ofEpochMilli(departure).atZone(zone)
    val date = rememberDatePickerState(start.toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
    val time = rememberTimePickerState(start.hour, start.minute)
    var timeStep by remember { mutableStateOf(false) }
    val ok = stringResource(android.R.string.ok)
    val cancel = @Composable { TextButton(onClick = { onDone(null) }) { Text(stringResource(android.R.string.cancel)) } }
    if (!timeStep) {
        DatePickerDialog(onDismissRequest = { onDone(null) }, confirmButton = { TextButton(onClick = { timeStep = true }) { Text(ok) } },
            dismissButton = cancel) { DatePicker(date) }
    } else {
        AlertDialog(
            onDismissRequest = { onDone(null) },
            confirmButton = {
                TextButton(onClick = {
                    val day = date.selectedDateMillis?.let { Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate() } ?: LocalDate.now(zone)
                    onDone(day.atTime(LocalTime.of(time.hour, time.minute)).atZone(zone).toInstant().toEpochMilli())
                }) { Text(ok) }
            },
            dismissButton = cancel,
            text = { TimePicker(time) },
        )
    }
}
