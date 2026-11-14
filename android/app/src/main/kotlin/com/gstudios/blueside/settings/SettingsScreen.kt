@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3AdaptiveApi::class, ExperimentalFoundationApi::class)

package com.gstudios.blueside.settings

import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material3.RadioButton
import androidx.compose.foundation.selection.selectable
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.Terrain
import androidx.compose.material.icons.filled.Update
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.TextButton
import androidx.compose.ui.Alignment
import com.gstudios.blueside.byteCount
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffold
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.gstudios.blueside.AppModel
import com.gstudios.blueside.R
import androidx.compose.ui.res.painterResource
import com.gstudios.blueside.Row
import com.gstudios.blueside.downloads.PackStore
import com.gstudios.blueside.map.CautionAmber
import com.gstudios.blueside.aircraft.AircraftPane
import kotlinx.coroutines.launch

// Full-screen settings: a list of pages, shown beside it on a wide window.
@Composable
fun SettingsScreen(model: AppModel) {
    val navigator = rememberListDetailPaneScaffoldNavigator<String>()
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) {
        if (model.options.string("show") == "downloads") {
            navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, "Downloads")
            // A launch can open one category by store name, such as --es downloads Packs.
            model.options.string("downloads")?.let { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, "Downloads/$it") }
        }
    }
    BackHandler {
        if (navigator.canNavigateBack()) scope.launch { navigator.navigateBack() } else model.settingsOpen = false
    }
    // The same pages as iOS, with the same symbols.
    val pages = listOf(
        "Downloads" to Icons.Filled.Download, "Aircraft" to Icons.Filled.Flight, "Devices" to Icons.Filled.SettingsInputAntenna,
        "About" to Icons.Outlined.Info, "Legal" to Icons.Outlined.Description,
    )
    ListDetailPaneScaffold(
        directive = navigator.scaffoldDirective,
        value = navigator.scaffoldValue,
        listPane = {
            AnimatedPane {
                Page("Settings", onBack = { model.settingsOpen = false }) {
                    LazyColumn {
                        items(pages) { (page, icon) ->
                            ListItem(
                                leadingContent = { Icon(icon, null) },
                                modifier = Modifier.combinedClickable {
                                    scope.launch { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, page) }
                                },
                            ) { Text(page) }
                        }
                    }
                }
            }
        },
        detailPane = {
            AnimatedPane {
                val page = navigator.currentDestination?.contentKey ?: "Downloads"
                val category = model.stores.find { "Downloads/${it.name}" == page }
                Page(category?.rows?.summary?.title ?: page, onBack = { scope.launch { navigator.navigateBack() } }) {
                    when (page) {
                        "About" -> Column {
                            val context = LocalContext.current
                            val version = remember { context.packageManager.getPackageInfo(context.packageName, 0).versionName }
                            ListItem(
                                leadingContent = {
                                    Icon(painterResource(R.drawable.ic_mark), null, Modifier.size(40.dp),
                                        tint = MaterialTheme.colorScheme.primary)
                                },
                                supportingContent = { Text("Version $version") },
                            ) { Text("Blueside", style = MaterialTheme.typography.headlineSmall) }
                            Note("Blueside is free for noncommercial use under the PolyForm Noncommercial License 1.0.0.")
                        }
                        "Legal" -> Column {
                            Note("Charts and navigation data: FAA, public domain. Not for use as the sole means of navigation.")
                            Note("Street map: © OpenStreetMap contributors, ODbL.")
                            Note("Airport taxiways, aprons, buildings and FBOs: © OpenStreetMap contributors, ODbL.")
                            Note("Aerial imagery: USGS The National Map: Orthoimagery, public domain.")
                            Note("Terrain: elevation from Mapzen Terrain Tiles (USGS 3DEP, NASA SRTM, NOAA ETOPO1).")
                            Note("Map rendering: MapLibre Native, BSD 2-Clause license.")
                            Note("Fonts: Noto Sans, SIL Open Font License. Map style and icons: Protomaps, BSD 3-Clause license.")
                        }
                        "Aircraft" -> AircraftPane(model)
                        "Devices" -> DevicesPane(model)
                        else -> if (category != null) CategoryPane(category) else DownloadsPane(model) {
                            scope.launch { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, "Downloads/$it") }
                        }
                    }
                }
            }
        },
    )
}

@Composable
private fun Note(text: String) = Text(text, Modifier.padding(horizontal = 16.dp, vertical = 8.dp))

@Composable
private fun Page(title: String, onBack: () -> Unit, content: @Composable () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            )
        },
    ) { padding -> Box(Modifier.padding(padding).fillMaxSize()) { content() } }
}

// The ADS-B receiver's state and where the aircraft symbol takes its position from.
@Composable
private fun DevicesPane(model: AppModel) {
    val status = model.traffic?.batch?.status
    val connected = status?.connected == true
    LazyColumn {
        item { ListItem(trailingContent = { Text(status?.name ?: if (connected) "Connected" else "Not connected") }) { Text("ADS-B Receiver") } }
        item {
            val word = if (model.traffic?.socketOpen != true) model.trafficCatalog.notListening else if (connected) "Connected" else "Not connected"
            ListItem(trailingContent = { Text(word) }) { Text("Status") }
        }
        item { ListItem(trailingContent = { Text(if (status?.gpsValid == true) "Valid" else "No fix") }) { Text("GPS") } }
        item { ListItem(trailingContent = { Text(status?.lastMessage ?: "Never") }) { Text("Last message") } }
        item { Note("Join the receiver's Wi-Fi network. Blueside listens for GDL 90 on UDP port ${model.trafficCatalog.port}.") }
        item { Text("Position source", Modifier.padding(16.dp, 16.dp, 16.dp, 4.dp), MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.titleSmall) }
        items(model.trafficCatalog.sources, key = { it.id }) { source ->
            ListItem(
                leadingContent = { RadioButton(selected = model.ownshipSource == source.id, onClick = null) },
                modifier = Modifier.selectable(model.ownshipSource == source.id, role = Role.RadioButton) {
                    model.chooseOwnshipSource(source.id)
                },
            ) { Text(source.title) }
        }
        item { Note("Automatic uses the receiver's GPS while it has a fix, and this device's otherwise.") }
    }
}

// Downloads like Android Settings: a row per category with the core's summary, opening that category's regions.
@Composable
fun DownloadsPane(model: AppModel, onOpen: (String) -> Unit) {
    // The app's scope: a failed store call is logged, and the work goes on if the page closes.
    val scope = model.scope
    val stores = model.stores.filter { it.rows.summary != null }
    var confirm by remember { mutableStateOf(false) }
    LazyColumn {
        item(key = "used") {
            ListItem(trailingContent = { Text(byteCount(stores.sumOf { it.rows.bytes }), style = MaterialTheme.typography.bodyLarge) }) { Text("Used") }
        }
        model.charts.rows.notice?.let { item(key = "notice") { Note(it) } }
        items(stores, key = { it.name }) { store ->
            val summary = store.rows.summary ?: return@items
            ListItem(
                leadingContent = { Icon(categoryIcon(store.name), null) },
                supportingContent = { Text(summary.text, color = stateColor(summary.state)) },
                trailingContent = {
                    if (summary.state == "downloading") {
                        CircularProgressIndicator(progress = { (summary.progress ?: 0.0).toFloat() }, Modifier.size(24.dp))
                    }
                },
                modifier = Modifier.clickable { onOpen(store.name) },
            ) { Text(summary.title) }
        }
        if (stores.any { it.rows.summary?.state in listOf("failed", "expired") }) {
            item(key = "update") {
                ListItem(modifier = Modifier.clickable {
                    scope.launch {
                        stores.forEach { store ->
                            store.rows.rows.filter { it.state == "failed" }.forEach { store.retry(it.region) }
                            store.refresh()
                        }
                    }
                }) { Text("Update All", color = MaterialTheme.colorScheme.primary) }
            }
        }
        item(key = "delete") {
            ListItem(modifier = Modifier.clickable { confirm = true }) {
                Text("Delete All", color = MaterialTheme.colorScheme.error)
            }
        }
        item(key = "delete-note") { Note("Delete All removes every chart, procedure, street map and terrain map. Navigation data stays.") }
    }
    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("Delete all downloads?") },
            text = { Text("Charts, procedures, street and terrain maps are removed from this device.") },
            confirmButton = {
                TextButton(onClick = {
                    confirm = false
                    scope.launch {
                        stores.filter { it !== model.navData }.forEach { store ->
                            store.rows.rows.filter { it.state != "notDownloaded" }.forEach { store.remove(it.region) }
                        }
                    }
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } },
        )
    }
}

private fun categoryIcon(store: String) = when (store) {
    "NavData" -> Icons.Filled.Navigation
    "Plates" -> Icons.Filled.Description
    "Street" -> Icons.Filled.DirectionsCar
    "Terrain" -> Icons.Filled.Terrain
    else -> Icons.Filled.Map
}

@Composable
private fun stateColor(state: String) = when (state) {
    "failed" -> MaterialTheme.colorScheme.error
    "expired" -> CautionAmber
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

// One category's regions, with the list's notice or message above and the category's footer below.
@Composable
fun CategoryPane(store: PackStore) {
    val rows = store.rows
    val shown = rows.rows.filter { !store.downloadedOnly || it.downloaded }
    LazyColumn {
        if (store.name != "NavData") {
            item(key = "filter") {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                    listOf("All" to false, "Downloaded" to true).forEachIndexed { index, (label, only) ->
                        SegmentedButton(
                            selected = store.downloadedOnly == only,
                            onClick = { store.downloadedOnly = only },
                            shape = SegmentedButtonDefaults.itemShape(index, 2),
                        ) { Text(label) }
                    }
                }
            }
        }
        (rows.notice ?: rows.message)?.let { item(key = "notice") { Note(it) } }
        items(shown, key = { it.region }) { row -> PackRow(row, store) }
        if (shown.isEmpty() && store.downloadedOnly) {
            item(key = "empty") {
                Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Nothing downloaded yet", style = MaterialTheme.typography.titleMedium)
                    TextButton(onClick = { store.downloadedOnly = false }) { Text("Show All") }
                }
            }
        }
        rows.summary?.footer?.let {
            item(key = "footer") {
                Text(it, Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun PackRow(row: Row, store: PackStore) {
    val scope = store.scope
    var menu by remember { mutableStateOf(false) }
    val removable = row.state == "ready" || row.state == "expired" || row.state == "downloading"
    Box {
        ListItem(
            supportingContent = { Text("${row.size} · ${row.text}", color = stateColor(row.state)) },
            trailingContent = {
                // One 48 dp slot for every state, so the control never moves when a download starts or ends.
                Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                    when (row.state) {
                        "notDownloaded" -> IconButton(onClick = { scope.launch { store.choose(row.region) } }) {
                            Icon(Icons.Filled.Download, "Download ${row.name}")
                        }
                        "downloading" -> CircularProgressIndicator(progress = { (row.progress ?: 0.0).toFloat() }, Modifier.size(24.dp))
                        "failed" -> IconButton(onClick = { scope.launch { store.retry(row.region) } }) {
                            Icon(Icons.Filled.Refresh, "Retry ${row.name}")
                        }
                        "expired" -> IconButton(onClick = { scope.launch { store.retry(row.region) } }) {
                            Icon(Icons.Filled.Update, "Update ${row.name}")
                        }
                        else -> Icon(Icons.Filled.CheckCircle, "Downloaded", tint = MaterialTheme.colorScheme.primary)
                    }
                }
            },
            modifier = Modifier.combinedClickable(onLongClick = { if (removable) menu = true }) {},
        ) { Text(row.name) }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Remove") }, onClick = {
                menu = false
                scope.launch { store.remove(row.region) }
            })
        }
    }
}
