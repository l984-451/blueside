@file:OptIn(ExperimentalMaterial3Api::class)

package com.gstudios.blueside.plates

import android.content.Context
import android.graphics.Bitmap
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ListAlt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.gstudios.blueside.AppModel
import com.gstudios.blueside.Core
import com.gstudios.blueside.CoreCall
import com.gstudios.blueside.PositionResult
import com.gstudios.blueside.aircraft.DialogBarIcons
import com.gstudios.blueside.map.Banner
import com.gstudios.blueside.request
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.io.File
import kotlin.math.roundToInt
import kotlin.math.sqrt

// The core picks, groups and names the charts; this file draws them.

@Serializable data class PlatesArgs(val store: String, val ident: String, val now: Long)

// The plan view's corners [lon, lat] (top left, top right, bottom right, bottom left), and the plan and
// airport sketch and not to scale inset boxes as [left, top, right, bottom] page fractions.
@Serializable data class PlateGeo(
    val corners: List<List<Double>>,
    val plan: List<Double>,
    val sketch: List<Double>? = null,
    val insets: List<List<Double>>? = null,
)

@Serializable data class PlateRef(val airport: String = "", val name: String, val file: String, val pack: String, val geo: PlateGeo? = null)

@Serializable data class PlateGroup(val title: String, val plates: List<PlateRef>)

@Serializable
data class PlatesResult(
    val diagram: PlateRef? = null,
    val groups: List<PlateGroup>,
    val count: Int,
    val diagramTitle: String,
    val proceduresTitle: String,
    val unavailable: String,
    val fullScreen: String,
    val showOnMap: String,
    val hideOnMap: String,
)

@Serializable data class ExtractArgs(val plate: PlateRef, val out: String)

@Serializable data class ExtractResult(val ok: Boolean)

fun plates(args: PlatesArgs, call: CoreCall = Core::call): PlatesResult = call.request("plates", args)

fun plateExtract(args: ExtractArgs, call: CoreCall = Core::call): Boolean = call.request<ExtractArgs, ExtractResult>("plateExtract", args).ok

@Serializable data class PlatePointArgs(val geo: PlateGeo, val latitude: Double, val longitude: Double)

@Serializable data class PlatePointResult(val point: List<Double>? = null)

// Where a position sits on the page as [x, y] fractions from top left; null off the plan view or in a box not to scale.
fun platePoint(args: PlatePointArgs, call: CoreCall = Core::call): List<Double>? =
    call.request<PlatePointArgs, PlatePointResult>("platePoint", args).point

private val plain @Composable get() = ListItemDefaults.colors(containerColor = Color.Transparent)

// The airport's charts from the plates store, read again when a pack arrives or leaves.
@Composable
fun rememberPlates(model: AppModel, ident: String): PlatesResult? =
    produceState<PlatesResult?>(null, ident, model.platesVersion) {
        value = withContext(Dispatchers.IO) {
            runCatching { plates(PlatesArgs(model.plates.root.path, ident, System.currentTimeMillis())) }.getOrNull()
        }
    }.value

// The Airport Diagram and Procedures rows. Nothing when no pack holds the airport.
fun LazyListScope.plateRows(result: PlatesResult?, openDiagram: (PlateRef) -> Unit, openProcedures: () -> Unit) {
    if (result == null) return
    result.diagram?.let { diagram ->
        item(key = "plates-diagram") {
            ListItem(
                leadingContent = { Icon(Icons.Outlined.Map, null) },
                colors = plain,
                modifier = Modifier.clickable { openDiagram(diagram) },
            ) { Text(result.diagramTitle) }
        }
    }
    if (result.count > 0) item(key = "plates-procedures") {
        ListItem(
            leadingContent = { Icon(Icons.AutoMirrored.Outlined.ListAlt, null) },
            trailingContent = { Text(result.count.toString()) },
            colors = plain,
            modifier = Modifier.clickable { openProcedures() },
        ) { Text(result.proceduresTitle) }
    }
}

// Procedures under the core's group headers: approaches, departures, arrivals, other.
fun LazyListScope.procedureRows(result: PlatesResult, open: (PlateRef) -> Unit) {
    for (group in result.groups) {
        item(key = "group-${group.title}") {
            Text(group.title, Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
                style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        }
        items(group.plates, key = { it.file + it.name }) { plate ->
            ListItem(colors = plain, modifier = Modifier.clickable { open(plate) }) { Text(plate.name) }
        }
    }
}

// The full-screen button for a chart page's top bar, and the full-screen view it opens with ownship on it.
// banner says the plates are out of date.
@Composable
fun FullScreenButton(plate: PlateRef, fullScreen: String, unavailable: String, model: AppModel, file: (() -> File?)? = null,
                     banner: String? = null) {
    val night = model.night
    var open by remember { mutableStateOf(false) }
    IconButton(onClick = { open = true }) { Icon(Icons.Filled.Fullscreen, fullScreen) }
    if (open) Dialog(onDismissRequest = { open = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        DialogBarIcons()
        Scaffold(
            modifier = Modifier.fillMaxSize(),
            topBar = {
                TopAppBar(
                    title = { Text(plate.name, maxLines = 1) },
                    navigationIcon = { IconButton(onClick = { open = false }) { Icon(Icons.Filled.Close, "Close") } },
                )
            },
        ) { padding ->
            // Only a moved or restyled marker recomposes the plate, not every new reading.
            val ownship by remember(model) { derivedStateOf { model.reading?.ownship } }
            Column(Modifier.padding(padding)) {
                banner?.let { Banner(it, Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
                PlateView(plate, night, unavailable, Modifier.fillMaxSize(), ownship, file)
            }
        }
    }
}

// Puts a georeferenced plate's plan view on the map, or takes it off.
@Composable
fun ShowOnMapButton(plate: PlateRef, words: PlatesResult, model: AppModel) {
    if (plate.geo == null) return
    val shown = plate in model.platesOnMap
    IconButton(onClick = { if (shown) model.platesOnMap.remove(plate) else model.platesOnMap.add(plate) }) {
        Icon(if (shown) Icons.Filled.Map else Icons.Outlined.Map, if (shown) words.hideOnMap else words.showOnMap)
    }
}

// The plan view cropped from the page, with the airport sketch and insets cleared since they are not to scale.
fun planBitmap(context: Context, plate: PlateRef, width: Int = 2048): Bitmap? {
    val geo = plate.geo?.takeIf { it.plan.size == 4 && it.plan[2] > it.plan[0] && it.plan[3] > it.plan[1] } ?: return null
    val pdf = extracted(context, plate)?.let(::open) ?: return null
    return runCatching {
        pdf.renderer.use { r ->
            r.openPage(0).use { page ->
                val pageW = (width / (geo.plan[2] - geo.plan[0])).toInt()
                val full = Bitmap.createBitmap(pageW, (pageW.toLong() * page.height / page.width).toInt(), Bitmap.Config.ARGB_8888)
                full.eraseColor(android.graphics.Color.WHITE)
                page.render(full, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                fun x(f: Double) = (f * full.width).toInt().coerceIn(0, full.width)
                fun y(f: Double) = (f * full.height).toInt().coerceIn(0, full.height)
                val plan = Bitmap.createBitmap(full, x(geo.plan[0]), y(geo.plan[1]),
                    x(geo.plan[2]) - x(geo.plan[0]), y(geo.plan[3]) - y(geo.plan[1])).copy(Bitmap.Config.ARGB_8888, true)
                val clear = android.graphics.Paint().apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR) }
                (listOfNotNull(geo.sketch) + geo.insets.orEmpty()).filter { it.size == 4 }.forEach { k ->
                    android.graphics.Canvas(plan).drawRect(
                        (x(k[0]) - x(geo.plan[0])).toFloat(), (y(k[1]) - y(geo.plan[1])).toFloat(),
                        (x(k[2]) - x(geo.plan[0])).toFloat(), (y(k[3]) - y(geo.plan[1])).toFloat(), clear,
                    )
                }
                plan
            }
        }
    }.getOrNull()
}

// Inverts the chart, then turns the hue back so colors keep their meaning, as iOS does.
private val nightMatrix = ColorMatrix(
    floatArrayOf(
        0.574f, -1.43f, -0.144f, 0f, 255f,
        -0.426f, -0.43f, -0.144f, 0f, 255f,
        -0.426f, -1.43f, 0.856f, 0f, 255f,
        0f, 0f, 0f, 1f, 0f,
    ),
)

// ponytail: about 16 million pixels for the pages on screen, about 64 MB; tile the page if deep zoom looks soft.
private const val PIXEL_BUDGET = 16_000_000f
private const val MAX_ZOOM = 8f
private const val DOUBLE_TAP_ZOOM = 2.5f

// A PdfRenderer is not safe across threads, so every call on one runs here, off the main thread, one at a time.
private val pdfThread = Dispatchers.IO.limitedParallelism(1)
private val pdfWork = CoroutineScope(pdfThread)

// An open document and its page sizes in points.
private class Pdf(val renderer: PdfRenderer, val sizes: List<Pair<Int, Int>>)

private fun extracted(context: Context, plate: PlateRef): File? {
    val out = File(context.cacheDir, "plates/${plate.pack.hashCode()}-${plate.file}")
    if (out.length() > 0) return out
    out.parentFile?.mkdirs()
    return if (runCatching { plateExtract(ExtractArgs(plate, out.path)) }.getOrDefault(false)) out else null
}

// The document with its page sizes, or null when it cannot be read; a document that fails partway is closed.
private fun open(file: File): Pdf? {
    val renderer = runCatching { PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)) }.getOrNull()
        ?: return null
    return runCatching {
        check(renderer.pageCount > 0)
        Pdf(renderer, (0 until renderer.pageCount).map { i ->
            renderer.openPage(i).use { check(it.width > 0 && it.height > 0); it.width to it.height }
        })
    }.onFailure { renderer.close() }.getOrNull()
}

// One page at the given width on white. Null once the document is closed.
private fun render(pdf: Pdf, page: Int, width: Int): ImageBitmap? = runCatching {
    val (w, h) = pdf.sizes[page]
    val bitmap = Bitmap.createBitmap(width, (width.toLong() * h / w).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
    bitmap.eraseColor(android.graphics.Color.WHITE)
    pdf.renderer.openPage(page).use { it.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY) }
    bitmap.asImageBitmap()
}.getOrNull()

// A chart or document opened on the whole first page, with pinch zoom and pan from there. Only the pages on screen
// are drawn, sharp again once a gesture settles, so a long POH opens as fast as a one-page chart.
@Composable
fun PlateView(plate: PlateRef, night: Boolean, unavailable: String, modifier: Modifier = Modifier,
              ownship: PositionResult.Ownship? = null, file: (() -> File?)? = null) {
    val context = LocalContext.current
    // Null while loading; a failed result shows "Chart unavailable".
    val loaded by produceState<Result<Pdf>?>(null, plate) {
        // Set on the PDF thread, so a view closed while it opens still closes the document.
        var pdf: Pdf? = null
        try {
            withContext(pdfThread) {
                pdf = runCatching { file?.invoke() ?: extracted(context, plate) }.getOrNull()?.let(::open)
            }
            value = pdf?.let { Result.success(it) } ?: Result.failure(IllegalStateException())
            awaitCancellation()
        } finally {
            // Closed on the PDF thread after any render there, so leaving never waits on one.
            pdf?.let { pdfWork.launch { it.renderer.close() } }
        }
    }
    val result = loaded ?: return Box(modifier)
    val pdf = result.getOrNull() ?: return Unavailable(unavailable, modifier)
    val sizes = pdf.sizes
    BoxWithConstraints(modifier.clipToBounds().background(if (night) Color.Black else Color.White).semantics { contentDescription = plate.name }) {
        val width = constraints.maxWidth.toFloat()
        val height = constraints.maxHeight.toFloat()
        // Each page's top at fit to width, then the bottom of the last.
        val tops = remember(sizes, width) { sizes.runningFold(0f) { y, (w, h) -> y + width * h / w } }
        val contentHeight = tops.last()
        val pageHeight = width * sizes[0].second / sizes[0].first
        // Scale 1 is fit to width; fit shows the whole first page, and zoom is over fit.
        val fit = minOf(1f, height / pageHeight)
        var zoom by remember(plate) { mutableFloatStateOf(1f) }
        var offset by remember(plate) { mutableStateOf(Offset.Zero) }
        val scale = fit * zoom
        // Content narrower than the view is centered, shorter is kept at the top; larger content covers the view.
        fun place(o: Offset, s: Float): Offset {
            fun span(v: Float, content: Float, view: Float, slack: Float) = if (content <= view) (view - content) * slack else v.coerceIn(view - content, 0f)
            return Offset(span(o.x, width * s, width, 0.5f), span(o.y, contentHeight * s, height, 0f))
        }
        val at = place(offset, scale)
        // Keeps the point under the fingers in place.
        fun zoomTo(next: Float, centroid: Offset, pan: Offset = Offset.Zero) {
            val from = fit * zoom
            offset = place(centroid - (centroid - place(offset, from)) * (fit * next / from) + pan, fit * next)
            zoom = next
        }
        // The pages on screen at an offset and scale.
        fun onScreen(o: Offset, s: Float) = sizes.indices.filter { i -> o.y + tops[i + 1] * s > 0 && o.y + tops[i] * s < height }
        // Rendered pages by index, only those on screen.
        var pages by remember(pdf) { mutableStateOf<Map<Int, ImageBitmap>>(emptyMap()) }
        LaunchedEffect(pdf, width, height, fit) {
            snapshotFlow { zoom.let { z -> onScreen(place(offset, fit * z), fit * z) to z } }.collectLatest { (shown, z) ->
                if (pages.isNotEmpty()) delay(250)
                // Each page as wide as it shows, all of them under the pixel budget.
                val full = width * fit * z
                val total = shown.sumOf { i -> (full * full * sizes[i].second / sizes[i].first).toDouble() }.toFloat()
                val w = (full * minOf(1f, sqrt(PIXEL_BUDGET / total))).toInt().coerceAtLeast(1)
                pages = pages.filterKeys { it in shown }
                for (i in shown) {
                    if (pages[i]?.width == w) continue
                    val page = withContext(pdfThread) { render(pdf, i, w) } ?: continue
                    pages = pages + (i to page)
                }
            }
        }
        val ink = if (night) ColorFilter.colorMatrix(nightMatrix) else null
        Canvas(
            Modifier
                .pointerInput(width, height, contentHeight) {
                    detectTapGestures(onDoubleTap = { tap ->
                        if (zoom > 1.01f) return@detectTapGestures zoomTo(1f, tap)
                        // Centers the tapped spot.
                        val spot = (tap - place(offset, fit * zoom)) / (fit * zoom)
                        offset = place(Offset(width / 2, height / 2) - spot * (fit * DOUBLE_TAP_ZOOM), fit * DOUBLE_TAP_ZOOM)
                        zoom = DOUBLE_TAP_ZOOM
                    })
                }
                .pointerInput(width, height, contentHeight) {
                    detectTransformGestures { centroid, pan, z, _ -> zoomTo((zoom * z).coerceIn(1f, MAX_ZOOM), centroid, pan) }
                }
                .fillMaxSize(),
        ) {
            for ((i, page) in pages) {
                drawImage(
                    page,
                    dstOffset = IntOffset(at.x.roundToInt(), (at.y + tops[i] * scale).roundToInt()),
                    dstSize = IntSize((width * scale).roundToInt(), ((tops[i + 1] - tops[i]) * scale).roundToInt()),
                    colorFilter = ink,
                )
            }
        }
        val geo = plate.geo
        val spot = remember(geo, ownship) {
            if (geo == null || ownship == null) null
            else runCatching { platePoint(PlatePointArgs(geo, ownship.latitude, ownship.longitude)) }.getOrNull()
        }
        if (ownship != null && spot != null && sizes.isNotEmpty()) {
            val ink = if ("stale" in ownship.image) Color(0xFF8E8E93) else Color(0xFF1A73E8)
            // Outside the zoomed layer, so it follows pan and zoom but keeps its size.
            Canvas(Modifier.fillMaxSize().semantics { contentDescription = "Ownship" }) {
                val mark = at + Offset(spot[0].toFloat() * width, spot[1].toFloat() * pageHeight) * scale
                val r = 14.dp.toPx()
                val arrow = Path().apply {
                    moveTo(mark.x, mark.y - r)
                    lineTo(mark.x + r * 0.7f, mark.y + r * 0.8f)
                    lineTo(mark.x, mark.y + r * 0.35f)
                    lineTo(mark.x - r * 0.7f, mark.y + r * 0.8f)
                    close()
                }
                rotate(ownship.track.toFloat(), mark) {
                    drawPath(arrow, ink)
                    drawPath(arrow, Color.White, style = Stroke(2.dp.toPx()))
                }
            }
        }
    }
}

@Composable
private fun Unavailable(text: String, modifier: Modifier) {
    Column(modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(Icons.Outlined.Description, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(text, style = MaterialTheme.typography.titleMedium)
    }
}
