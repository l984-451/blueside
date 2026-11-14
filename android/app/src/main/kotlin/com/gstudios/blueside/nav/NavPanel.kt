@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class, ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)

package com.gstudios.blueside.nav

import android.content.ClipData
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material.icons.outlined.Map
import androidx.compose.ui.platform.LocalContext
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MediumFlexibleTopAppBar
import androidx.compose.material3.SearchBar
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberSearchBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.gstudios.blueside.AirportWeather
import com.gstudios.blueside.AppModel
import com.gstudios.blueside.Line
import com.gstudios.blueside.NavItem
import com.gstudios.blueside.PageSection
import com.gstudios.blueside.Place
import com.gstudios.blueside.PlaceHeader
import com.gstudios.blueside.map.Banner
import com.gstudios.blueside.map.CautionAmber
import com.gstudios.blueside.plates.FullScreenButton
import com.gstudios.blueside.plates.PlateView
import com.gstudios.blueside.plates.ShowOnMapButton
import com.gstudios.blueside.plates.plateRows
import com.gstudios.blueside.plates.procedureRows
import com.gstudios.blueside.plates.rememberPlates
import com.gstudios.blueside.plates.sketchPdf
import com.gstudios.blueside.WxStation
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

// Fixed aviation colors that ignore the dynamic scheme.
private val DangerRed = Color(0xFFD32F2F)
private val RouteMagenta = Color(0xFFD11FB6)
private val plain @Composable get() = ListItemDefaults.colors(containerColor = Color.Transparent)

// The nav panel: search, airport page, place card and the Here list, one stack deep at a time.
@Composable
fun NavPanel(model: AppModel) {
    val nav = model.nav
    BackHandler(nav.stack.size > 1 && !model.settingsOpen) { model.navigate { pop() } }
    when (val page = nav.top) {
        NavPage.Search -> SearchPane(model)
        is NavPage.Airport -> AirportPane(model)
        is NavPage.Card -> CardPane(model)
        is NavPage.Here -> Column {
            Bar(model, if (page.bend) model.route.labels.bendTitle else nav.labels.here, null)
            LazyColumn {
                items(page.items) { item ->
                    PlaceRow(model, item, onTap = if (page.bend) { { model.pickBend(item.place) } } else null)
                }
            }
        }
        is NavPage.Procedures -> Column {
            Bar(model, page.plates.proceduresTitle, null)
            model.notices.plates?.let { Banner(it, Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
            LazyColumn { procedureRows(page.plates) { model.navigate { push(NavPage.Chart(it, page.plates)) } } }
        }
        is NavPage.Chart -> Column {
            val banner = model.notices.plates
            Bar(model, page.plate.name, null) {
                ShowOnMapButton(page.plate, page.words, model)
                FullScreenButton(page.plate, page.words.fullScreen, page.words.unavailable, model, banner = banner)
            }
            banner?.let { Banner(it, Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
            PlateView(page.plate, model.night, page.words.unavailable, Modifier.fillMaxSize())
        }
        is NavPage.Sketch -> Column {
            val context = LocalContext.current
            val file = remember(page.ref) { { sketchPdf(context, page.ref.sketch) } }
            Bar(model, page.ref.title, null) {
                IconButton(onClick = { model.showPlate(page.ref.plate) }) { Icon(Icons.Outlined.Map, page.ref.showOnMap) }
                FullScreenButton(page.ref.plate, page.ref.fullScreen, page.ref.unavailable, model, file)
            }
            PlateView(page.ref.plate, model.night, page.ref.unavailable, Modifier.fillMaxSize(), file = file)
        }
        is NavPage.Remarks -> Column {
            Bar(model, page.section.title, null)
            LazyColumn {
                items(page.section.lines) {
                    Text(it.title, Modifier.padding(horizontal = 16.dp, vertical = 6.dp), style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

// Back when there is a page under this one; close always last on the right, where every panel keeps it.
@Composable
private fun Bar(model: AppModel, title: String, subtitle: String?, actions: @Composable () -> Unit = {}) {
    MediumFlexibleTopAppBar(
        title = { Text(title) },
        subtitle = subtitle?.let { { Text(it) } },
        navigationIcon = {
            if (model.nav.stack.size > 1) {
                IconButton(onClick = { model.navigate { pop() } }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            }
        },
        actions = {
            actions()
            IconButton(onClick = model::panelClosed) { Icon(Icons.Filled.Close, "Close") }
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
        // The sheet or pane already clears the system bars.
        windowInsets = WindowInsets(0),
    )
}

@Composable
private fun SearchPane(model: AppModel) {
    val nav = model.nav
    val labels = nav.labels
    if (!nav.open) return NoData(model)
    val text = rememberTextFieldState(nav.query)
    LaunchedEffect(text) {
        snapshotFlow { text.text.toString() }.drop(1).collect {
            nav.query = it
            nav.refresh()
        }
    }
    val bar = rememberSearchBarState()
    val page = nav.search
    LazyColumn(Modifier.fillMaxWidth()) {
        item {
            Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                SearchBar(
                    state = bar,
                    inputField = {
                        SearchBarDefaults.InputField(
                            textFieldState = text,
                            searchBarState = bar,
                            onSearch = {},
                            placeholder = { Text(labels.searchPrompt) },
                            leadingIcon = { Icon(Icons.Filled.Search, null) },
                        )
                    },
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = model::panelClosed) { Icon(Icons.Filled.Close, "Close") }
            }
        }
        page?.warning?.let { item { Caution(it) } }
        page?.problem?.let { item { Danger(it, Modifier.padding(horizontal = 16.dp)) } }
        for (section in page?.sections.orEmpty()) {
            section.title?.let { item { Header(it) } }
            if (section.items.isEmpty()) section.empty?.let { item { Note(it) } }
            items(section.items, key = { "${section.title}-${it.place.kind}-${it.place.ident}" }) {
                PlaceRow(model, it, section.removable)
            }
        }
    }
}

// No database on the device: what the download is doing and a button to start it.
@Composable
private fun NoData(model: AppModel) {
    val labels = model.nav.labels
    val rows = model.navData.rows
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Bar(model, labels.searchTitle, null)
        Danger(if (model.nav.unreadable) labels.unreadable else labels.notDownloaded)
        rows.rows.firstOrNull()?.let { row ->
            Text(row.text)
            Button(onClick = { model.downloadNav(row.region) }, Modifier.fillMaxWidth()) { Text(labels.download) }
        }
        rows.notice?.let { Note(it) }
    }
}

// One row of any list. A tap opens the place; a long press offers its actions.
@Composable
private fun PlaceRow(model: AppModel, item: NavItem, removable: Boolean = false, onTap: (() -> Unit)? = null) {
    val row = item.row
    var menu by remember { mutableStateOf(false) }
    val labels = model.nav.labels
    Box {
        ListItem(
            supportingContent = {
                Column {
                    row.name?.let { Text(it, maxLines = 1) }
                    row.quick?.let { Text(it, style = MaterialTheme.typography.bodySmall, maxLines = 1) }
                }
            },
            trailingContent = row.distance?.let { distance ->
                {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Column(horizontalAlignment = Alignment.End) {
                            Text(distance, fontFamily = FontFamily.Monospace)
                            row.bearing?.let { Text(it, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace) }
                        }
                        row.turn?.let { Icon(Icons.Filled.Navigation, null, Modifier.rotate(it.toFloat())) }
                    }
                }
            },
            colors = plain,
            modifier = Modifier.combinedClickable(onLongClick = { menu = true }) { onTap?.invoke() ?: model.navigate { openPlace(item.place) } },
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(row.title, fontWeight = FontWeight.SemiBold)
                row.closed?.let { Text(it, color = DangerRed, style = MaterialTheme.typography.labelMedium) }
                row.kindLabel?.let { Text(it, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold) }
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (!model.wideNav) DropdownMenuItem(text = { Text(labels.direct) }, onClick = { menu = false; model.directTo(item.place) })
            DropdownMenuItem(text = { Text(labels.add) }, onClick = { menu = false; model.addToRoute(item.place) })
            DropdownMenuItem(text = { Text(labels.showOnMap) }, onClick = { menu = false; model.showOnMap(item.place) })
            if (removable) DropdownMenuItem(text = { Text(labels.remove) }, onClick = { menu = false; model.nav.toggleFavorite(row.ident); model.navigate { refresh() } })
        }
    }
}

@Composable
private fun AirportPane(model: AppModel) {
    val nav = model.nav
    val result = nav.airport ?: return
    val page = result.page
    val starred = page.ident in nav.favorites
    val copy = rememberCopy()
    val plates = rememberPlates(model, page.ident)
    // The newest METAR goes back through the page for its rows; the raw TAF is shown as it is.
    val weather by produceState(WxStation(), page.ident, model.weather.passes) {
        value = model.weather.station(page.ident, result.place.icao)
        nav.metar = value.metar
        nav.refresh()
    }
    Column {
        Bar(model, page.title, page.subtitle) {
            IconToggleButton(checked = starred, onCheckedChange = { nav.toggleFavorite(page.ident) }) {
                Icon(
                    if (starred) Icons.Filled.Star else Icons.Outlined.StarOutline,
                    if (starred) nav.labels.removeFavorite else nav.labels.addFavorite,
                )
            }
        }
        LazyColumn {
            item {
                Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    page.closed?.let { Danger(it) }
                    page.warning?.let { Caution(it) }
                    Text(page.place, style = MaterialTheme.typography.bodyMedium)
                    Header(model, result.header, result.place, showOnMap = true)
                }
            }
            if (page.glance.isNotEmpty()) item {
                Row(Modifier.fillMaxWidth().padding(16.dp)) {
                    page.glance.forEach { g ->
                        Column(
                            Modifier.weight(1f).combinedClickable(onClick = { g.copy?.let(copy) }),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Text(g.title, style = MaterialTheme.typography.labelSmall)
                            Text(g.value.orEmpty(), style = MaterialTheme.typography.titleMedium, fontFamily = FontFamily.Monospace, maxLines = 1)
                        }
                    }
                }
            }
            weatherRows(page.weather, weather.lines)
            plateRows(plates,{ d -> model.navigate { push(NavPage.Chart(d, plates!!)) } }) {
                model.navigate { push(NavPage.Procedures(plates!!)) }
            }
            result.sketch?.takeIf { plates?.diagram == null }?.let { ref ->
                item(key = "plates-sketch") {
                    ListItem(
                        leadingContent = { Icon(Icons.Outlined.Map, null) },
                        colors = plain,
                        modifier = Modifier.clickable { model.navigate { push(NavPage.Sketch(ref)) } },
                    ) { Text(ref.title) }
                }
            }
            section(page.runways) { LineRow(it) }
            section(page.frequencies) { LineRow(it, copy, nav.labels.copyHint) }
            if (page.remarks.lines.isNotEmpty()) item {
                ListItem(
                    trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null) },
                    colors = plain,
                    modifier = Modifier.clickable { model.navigate { push(NavPage.Remarks(page.remarks)) } },
                ) { Text(page.remarks.title) }
            }
            section(page.details) { LineRow(it) }
            items(page.footer) { Note(it) }
        }
    }
}

@Composable
private fun CardPane(model: AppModel) {
    val result = model.nav.card ?: return
    val card = result.card
    val place = (model.nav.top as? NavPage.Card)?.place ?: return
    Column {
        Bar(model, card.title, card.subtitle)
        LazyColumn {
            item { Column(Modifier.padding(horizontal = 16.dp)) { Header(model, result.header, place, card.showOnMap) } }
            items(card.lines) { LineRow(it) }
            card.nearbyTitle?.let { title ->
                item { Header(title) }
                if (result.nearby.isEmpty()) card.nearbyEmpty?.let { item { Note(it) } }
                items(result.nearby) { PlaceRow(model, it) }
            }
        }
    }
}

// Distance and bearing from the aircraft, then the action row. It wraps on a narrow phone rather than squeeze.
// It reads the live header itself, so a new fix recomposes this and not the page around it.
@Composable
private fun Header(model: AppModel, page: PlaceHeader, place: Place, showOnMap: Boolean) {
    val labels = model.nav.labels
    val header = model.nav.header?.takeIf { it.first == place }?.second ?: page
    Text("${header.distance} · ${header.bearing}", fontFamily = FontFamily.Monospace)
    FlowRow(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Beside the planning page Direct To would replace the route being planned.
        if (!model.wideNav) Button(
            onClick = { model.directTo(place) },
            colors = ButtonDefaults.buttonColors(containerColor = RouteMagenta, contentColor = Color.White),
        ) {
            Icon(Icons.Filled.NorthEast, null)
            Text(labels.direct, Modifier.padding(start = 6.dp), maxLines = 1)
        }
        header.addTitle?.let { add ->
            FilledTonalButton(onClick = { model.addToRoute(place) }) {
                Icon(Icons.Filled.Add, null)
                Text(add, Modifier.padding(start = 6.dp), maxLines = 1)
            }
        }
        if (showOnMap) {
            OutlinedButton(onClick = { model.showOnMap(place) }) {
                Icon(Icons.Filled.Map, null)
                Text(labels.showOnMap, Modifier.padding(start = 6.dp), maxLines = 1)
            }
        }
    }
}

private fun LazyListScope.section(section: PageSection, line: @Composable (Line) -> Unit) {
    item { Header(section.title) }
    if (section.lines.isEmpty()) section.empty?.let { item { Note(it) } }
    items(section.lines) { line(it) }
    item { HorizontalDivider(Modifier.padding(horizontal = 16.dp)) }
}

// Flight category colors, as the station dots on the map draw them.
internal val categoryColors = mapOf(
    "green" to Color(0xFF1A8F3C), "blue" to Color(0xFF1F5FD0), "red" to DangerRed, "magenta" to Color(0xFFB0189E),
)

// The current METAR as rows, runway ends by headwind, then the raw reports; or the core's note when none is current.
private fun LazyListScope.weatherRows(wx: AirportWeather, tafs: List<String>) {
    item { Header(wx.title) }
    val category = wx.category
    if (category == null) item { Note(wx.note) } else {
        item {
            ListItem(
                trailingContent = {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Filled.Circle, null, Modifier.size(12.dp), tint = categoryColors[wx.color] ?: Color.Gray)
                        Text(category.value.orEmpty(), fontWeight = FontWeight.SemiBold)
                    }
                },
                colors = plain,
            ) { Text(category.title) }
        }
        items(wx.lines) { LineRow(it) }
        items(wx.runways) { r ->
            ListItem(
                trailingContent = {
                    Column(horizontalAlignment = Alignment.End) {
                        Text(r.wind, fontFamily = FontFamily.Monospace)
                        r.gust?.let { Text(it, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace) }
                    }
                },
                colors = plain,
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(r.end, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
                    r.tag?.let { Text(it, color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.SemiBold) }
                }
            }
        }
        item { Note(wx.note) }
    }
    items(listOfNotNull(wx.raw) + tafs) {
        Text(it, Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace)
    }
    item { HorizontalDivider(Modifier.padding(horizontal = 16.dp)) }
}

// One page line; a line with something to copy copies it on tap.
@Composable
private fun LineRow(line: Line, copy: ((String) -> Unit)? = null, hint: String? = null) {
    ListItem(
        supportingContent = if (line.detail == null && line.alert == null) null else {
            {
                Column {
                    line.alert?.let { Text(it, color = DangerRed) }
                    line.detail?.let { Text(it) }
                }
            }
        },
        trailingContent = line.value?.let { { Text(it, fontFamily = FontFamily.Monospace) } },
        colors = plain,
        modifier = if (copy != null && line.copy != null) {
            Modifier.combinedClickable(onClick = { copy(line.copy) }).semantics { hint?.let { contentDescription = "${line.title} ${line.value}, $it" } }
        } else Modifier,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(line.title)
            line.tag?.let { Text(it, color = DangerRed, fontWeight = FontWeight.SemiBold) }
        }
    }
}

// Copies to the clipboard with a confirming tap of haptics.
@Composable
private fun rememberCopy(): (String) -> Unit {
    val clipboard = LocalClipboard.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    return { text ->
        haptics.performHapticFeedback(HapticFeedbackType.Confirm)
        scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText(text, text))) }
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

@Composable
private fun Danger(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier, color = DangerRed, fontWeight = FontWeight.SemiBold)
}

@Composable
private fun Caution(text: String) {
    Text(text, Modifier.padding(horizontal = 16.dp), color = CautionAmber, fontWeight = FontWeight.SemiBold)
}
