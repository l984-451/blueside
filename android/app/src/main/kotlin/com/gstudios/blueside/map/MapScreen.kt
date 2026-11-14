@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class, ExperimentalLayoutApi::class)

package com.gstudios.blueside.map

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material.icons.filled.PortableWifiOff
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.DarkMode
import androidx.compose.material.icons.outlined.LocationSearching
import androidx.compose.material3.BottomSheetScaffold
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalFloatingToolbar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.rememberBottomSheetScaffoldState
import androidx.compose.material3.rememberBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.gstudios.blueside.AppModel
import com.gstudios.blueside.Panel
import com.gstudios.blueside.PositionResult
import com.gstudios.blueside.nav.NavPanel
import com.gstudios.blueside.panels.LayerPanel
import com.gstudios.blueside.route.RouteDrawer
import com.gstudios.blueside.route.RoutePanel
import com.gstudios.blueside.route.UndoBar

// Fixed caution amber: aviation meaning never follows the dynamic scheme.
val CautionAmber = Color(0xFFFFB300)

// The whole screen: the map, with the data strip, notices, toolbar and one panel over it.
@Composable
fun MapScreen(model: AppModel) {
    val view = LocalView.current
    // The screen stays awake while the map shows.
    DisposableEffect(view) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }
    // Back closes the open panel before it leaves the app.
    BackHandler(model.panel != null && !model.settingsOpen) { model.panelClosed() }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        // Wide windows get a fixed pane beside the toolbar; compact ones a standard, non-modal sheet.
        val wide = maxWidth >= 840.dp
        LaunchedEffect(wide) { model.wideWindow = wide }
        LaunchedEffect(model.panel) { if (model.panel != Panel.Route) model.routeWide = false }
        LaunchedEffect(model.planning) { if (!model.planning) model.wideNav = false }
        if (wide) {
            // The planning page leaves a third of the window for the map.
            val paneWidth = if (model.planning) maxWidth * 0.67f - 96.dp else 360.dp
            val sideWidth = minOf(360.dp, maxWidth * 0.33f - 24.dp)
            Box(Modifier.fillMaxSize()) {
                MapLayer(model)
                Row(Modifier.safeDrawingPadding().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Toolbar(model)
                    model.panel?.let { panel ->
                        DisposableEffect(Unit) { onDispose { model.paneRight = 0f } }
                        Surface(
                            Modifier.width(paneWidth).fillMaxHeight()
                                .onGloballyPositioned { model.paneRight = it.boundsInRoot().right },
                            shape = MaterialTheme.shapes.extraLarge,
                            tonalElevation = 3.dp,
                            shadowElevation = 6.dp,
                        ) { PanelBody(model, panel) }
                    }
                }
                if (model.wideNav) Surface(
                    Modifier.align(Alignment.CenterEnd).safeDrawingPadding().padding(12.dp)
                        .width(sideWidth).fillMaxHeight(0.7f),
                    shape = MaterialTheme.shapes.extraLarge,
                    tonalElevation = 3.dp,
                    shadowElevation = 6.dp,
                ) { Box(Modifier.nightDim(model.night)) { NavPanel(model) } }
            }
        } else {
            val sheet = rememberBottomSheetState(initialValue = SheetValue.Hidden)
            val state = rememberBottomSheetScaffoldState(sheet)
            LaunchedEffect(model.panel) { if (model.panel == null) sheet.hide() else sheet.partialExpand() }
            LaunchedEffect(sheet.currentValue) { if (sheet.currentValue == SheetValue.Hidden && model.panel != null) model.panelClosed() }
            // The keyboard lifts the sheet to full height, so a field and its results stay above it.
            val typing = WindowInsets.isImeVisible
            LaunchedEffect(typing) { if (typing && model.panel != null) sheet.expand() }
            // Read once the sheet settles, so a drag does not move the map frame by frame.
            LaunchedEffect(sheet) {
                snapshotFlow { sheet.currentValue to model.panel }.collect { (value, panel) ->
                    model.sheetTop = if (panel == null || value == SheetValue.Hidden) null else runCatching { sheet.requireOffset() }.getOrNull()
                }
            }
            // At most half the window, so a phone on its side keeps a map above the sheet.
            BottomSheetScaffold(
                scaffoldState = state,
                sheetPeekHeight = minOf(360.dp, maxHeight / 2),
                sheetContent = { model.panel?.let { Box(Modifier.imePadding()) { PanelBody(model, it) } } },
            ) {
                // The bottom notices ride above the sheet while it is up.
                val density = LocalDensity.current
                val sheetTop = runCatching { with(density) { sheet.requireOffset().toDp() } }.getOrNull()
                val above = if (sheetTop == null || model.panel == null) 0.dp else (maxHeight - sheetTop).coerceAtLeast(0.dp)
                Box(Modifier.fillMaxSize()) {
                    MapLayer(model, above)
                    Box(Modifier.safeDrawingPadding().padding(12.dp)) { Toolbar(model) }
                }
            }
        }
    }
}

// Night dims every ink on the chrome by one rule; the map itself keeps its own night paint.
fun Modifier.nightDim(night: Boolean) =
    if (night) graphicsLayer { alpha = 0.85f; compositingStrategy = CompositingStrategy.ModulateAlpha } else this

@Composable
private fun PanelBody(model: AppModel, panel: Panel) {
    Box(Modifier.nightDim(model.night)) {
        when (panel) {
            Panel.Layers -> LayerPanel(model)
            Panel.Nav -> NavPanel(model)
            Panel.Route -> RoutePanel(model)
        }
    }
}

// The map and everything drawn on it but the toolbar and panel.
@Composable
private fun MapLayer(model: AppModel, sheetHeight: Dp = 0.dp) {
    Box(Modifier.fillMaxSize()) {
        MapHost(model, Modifier.fillMaxSize())
        val style = model.style
        val dim = Modifier.nightDim(model.night)
        (style?.notice ?: model.coverage)?.let { Notice(it, Modifier.align(Alignment.Center).then(dim)) }
        Column(
            Modifier.align(Alignment.TopEnd).safeDrawingPadding().padding(12.dp).widthIn(max = 320.dp)
                .onGloballyPositioned { model.stripBottom = it.boundsInRoot().bottom }.then(dim),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            LiveStrip(model)
            // The planning page already lists the route.
            if (!model.planning) RouteDrawer(model, Modifier.fillMaxWidth())
            ReceiverBadge(model)
        }
        UndoBar(model, Modifier.align(Alignment.BottomCenter).safeDrawingPadding().then(dim))
        // Weather on top, data warnings nearest the corner, credit last.
        Column(
            Modifier.align(Alignment.BottomEnd).padding(bottom = sheetHeight).safeDrawingPadding().padding(12.dp)
                .widthIn(max = 320.dp).then(dim),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            WeatherNotices(model)
            model.notices.nav?.let { Banner(it) }
            model.notices.banner?.let { Banner(it) }
            style?.credit?.let { credit ->
                val uri = LocalUriHandler.current
                Text(
                    credit,
                    style = MaterialTheme.typography.labelSmall,
                    modifier = style.creditLink?.let { link -> Modifier.clickable { uri.openUri(link) } } ?: Modifier,
                )
            }
        }
        Box(Modifier.fillMaxSize().then(dim)) { OfferCard(model) }
    }
}


// Search, Tracking, Layers, Night and Settings, in one vertical toolbar at the leading edge.
@Composable
private fun Toolbar(model: AppModel) {
    VerticalFloatingToolbar(expanded = true, modifier = Modifier.nightDim(model.night)) {
        FilledIconToggleButton(checked = model.panel == Panel.Nav, onCheckedChange = { model.openSearch() }) {
            Icon(Icons.Filled.Search, contentDescription = model.nav.labels.searchTitle)
        }
        IconButton(onClick = model::tapTracking, modifier = Modifier.semantics { contentDescription = model.trackingLabel }) {
            Icon(
                when {
                    !model.following -> Icons.Outlined.LocationSearching
                    model.orientation == "northUp" -> Icons.Filled.MyLocation
                    else -> Icons.Filled.Navigation
                },
                contentDescription = null,
            )
        }
        FilledIconToggleButton(
            checked = model.panel == Panel.Layers,
            onCheckedChange = { model.panel = if (it) Panel.Layers else null },
        ) { Icon(Icons.Filled.Layers, contentDescription = "Layers") }
        FilledIconToggleButton(checked = model.night, onCheckedChange = { model.night = it }) {
            Icon(if (model.night) Icons.Filled.DarkMode else Icons.Outlined.DarkMode, contentDescription = "Night")
        }
        IconButton(onClick = { model.panel = null; model.settingsOpen = true }) {
            Icon(Icons.Filled.Settings, contentDescription = "Settings")
        }
    }
}

// Reads the fix's reading in its own scope, so a fix recomposes the strip and not the map screen.
// derivedStateOf drops fixes that move the aircraft but leave the strip's words unchanged.
@Composable
private fun LiveStrip(model: AppModel) {
    val strip by remember(model) { derivedStateOf { model.reading?.strip } }
    strip?.let { DataStrip(it) }
}

// A small antenna once an ADS-B receiver has been heard, crossed out while it is lost. Reads only those two flags.
@Composable
private fun ReceiverBadge(model: AppModel) {
    val state by remember(model) { derivedStateOf { model.traffic?.batch?.status?.let { it.heard to it.connected } } }
    val (heard, connected) = state ?: return
    if (!heard) return
    Surface(shape = CircleShape, color = MaterialTheme.colorScheme.surfaceContainer, shadowElevation = 2.dp) {
        Icon(
            if (connected) Icons.Filled.SettingsInputAntenna else Icons.Filled.PortableWifiOff,
            contentDescription = if (connected) "ADS-B receiver connected" else "ADS-B receiver lost",
            tint = if (connected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.error,
            modifier = Modifier.padding(6.dp).size(18.dp),
        )
    }
}

// Groundspeed, track and GPS altitude on a solid dark surface, the same on both platforms.
@Composable
private fun DataStrip(strip: PositionResult.Strip) {
    MaterialTheme(colorScheme = darkColorScheme()) {
        Surface(shape = MaterialTheme.shapes.large, color = Color(0xFF1C1B1F), contentColor = Color.White) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Field("GS", strip.groundspeed)
                    Field("TRK", strip.track)
                    Field("ALT", strip.altitude)
                }
                strip.message?.let {
                    Text(it, color = CautionAmber, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

// Every column is sized by the widest altitude, so the values never move the layout.
@Composable
private fun Field(title: String, value: String) {
    Column(Modifier.semantics(mergeDescendants = true) {}, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold)
        Box(contentAlignment = Alignment.Center) {
            Text("00,000 ft", Modifier.alpha(0f).clearAndSetSemantics {}, style = MaterialTheme.typography.titleMedium,
                fontFamily = FontFamily.Monospace)
            Text(value, style = MaterialTheme.typography.titleMedium, fontFamily = FontFamily.Monospace, maxLines = 1)
        }
    }
}

// The amber pill for charts or data out of date.
@Composable
fun Banner(text: String, modifier: Modifier = Modifier) {
    Surface(modifier, shape = MaterialTheme.shapes.extraLarge, color = CautionAmber, contentColor = Color.Black) {
        Text(text, Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.labelLarge)
    }
}

// Each switched-on source that is not current says so, and a small clock gives the time of what is drawn.
@Composable
private fun WeatherNotices(model: AppModel) {
    val notices = model.weather.notices
    notices.labels.forEach { Banner(it.text) }
    notices.clock?.let { clock ->
        val loop = model.weather.loop
        Surface(shape = MaterialTheme.shapes.large, tonalElevation = 3.dp, shadowElevation = 3.dp) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (notices.radar) {
                    IconButton(onClick = { model.weather.toggleLoop(model.scope) }) {
                        if (loop == null) Icon(Icons.Filled.PlayArrow, "Play radar loop") else Icon(Icons.Filled.Stop, "Stop radar loop")
                    }
                }
                Column(Modifier.padding(end = 12.dp, top = 6.dp, bottom = 6.dp, start = if (notices.radar) 0.dp else 12.dp),
                       horizontalAlignment = Alignment.End) {
                    Text(loop?.text ?: clock, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold,
                         fontFamily = FontFamily.Monospace)
                    notices.legend?.let { Text(it, style = MaterialTheme.typography.labelSmall) }
                    notices.winds?.let { Text(it, style = MaterialTheme.typography.labelSmall) }
                }
            }
        }
    }
}

@Composable
private fun Notice(text: String, modifier: Modifier) {
    Surface(modifier, shape = MaterialTheme.shapes.large, tonalElevation = 3.dp, shadowElevation = 3.dp) {
        Text(text, Modifier.padding(horizontal = 16.dp, vertical = 10.dp), style = MaterialTheme.typography.bodyLarge)
    }
}

