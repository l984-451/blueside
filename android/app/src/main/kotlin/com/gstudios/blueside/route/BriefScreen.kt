@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)

package com.gstudios.blueside.route

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Color as PdfColor
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.text.StaticLayout
import android.text.TextPaint
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import com.gstudios.blueside.AppModel
import com.gstudios.blueside.Brief
import com.gstudios.blueside.BriefAirport
import com.gstudios.blueside.R
import com.gstudios.blueside.RouteLabels
import com.gstudios.blueside.aircraft.DialogBarIcons
import com.gstudios.blueside.map.CautionAmber
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// Hazard sections, tinted orange.
private val HazardOrange = Color(0xFFEF6C00)

// A finished brief, its pictures, and what it was built from.
class BriefKept(val key: Any, val brief: Brief, val images: Map<String, Bitmap>)

// The preflight brief as one scrolling page: the core's graphics, then its sections, with a PDF to share.
// It builds in the background and fills in; closing it cancels the work, and a finished brief is kept for reopening.
@Composable
fun BriefScreen(model: AppModel, onClose: () -> Unit) {
    val labels = model.route.labels
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var sharing by remember { mutableStateOf(false) }
    var brief by remember { mutableStateOf<Brief?>(null) }
    val images = remember { mutableStateMapOf<String, Bitmap>() }
    var finished by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        val args = model.briefArgs() ?: return@LaunchedEffect
        // The plan key carries what the fix and the clock change in the plan, such as an airborne departure.
        val key = listOf(args.copy(now = 0, fix = null), model.weather.passes, model.route.view?.planKey)
        model.briefKept?.takeIf { it.key == key }?.let { kept ->
            brief = kept.brief
            images.putAll(kept.images)
            finished = true
            return@LaunchedEffect
        }
        val made = model.weather.brief(args) ?: return@LaunchedEffect
        brief = made
        for (picture in made.graphics.map.pictures) {
            snapshot(context, picture, made.graphics.map.bounds)?.let { images[picture.id] = it }
        }
        finished = true
        model.briefKept = BriefKept(key, made, images.toMap())
    }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        DialogBarIcons()
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(brief?.title ?: labels.briefTitle) },
                    navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Close") } },
                    actions = {
                        val b = brief
                        if (b != null && finished) {
                            // Drawn off the main thread, one at a time; a failed write shares nothing rather than crashing.
                            IconButton(onClick = {
                                if (sharing) return@IconButton
                                sharing = true
                                val shown = images.toMap()
                                scope.launch {
                                    try {
                                        val file = withContext(Dispatchers.IO) { runCatching { writeBriefPdf(context, b, shown, labels) }.getOrNull() }
                                        file?.let { shareNavlog(context, it, labels.share) }
                                    } finally {
                                        sharing = false
                                    }
                                }
                            }, Modifier.testTag("brief-share")) {
                                Icon(Icons.Filled.Share, labels.share)
                            }
                        }
                    },
                )
            },
        ) { padding ->
            val b = brief
            LazyColumn(Modifier.padding(padding).fillMaxSize().testTag("brief-page")) {
                if (b == null) {
                    item {
                        Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            CircularProgressIndicator()
                            Text(labels.briefBuilding, Modifier.padding(top = 12.dp))
                        }
                    }
                    return@LazyColumn
                }
                item {
                    Card(Modifier.fillMaxWidth().padding(16.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer)) {
                        Text(b.notice, Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium)
                    }
                }
                val g = b.graphics
                item { Heading(labels.briefHazards); BriefHazards(g) }
                g.map.pictures.firstOrNull()?.let { route ->
                    item { Heading(route.title); BriefPictureView("", images[route.id], Modifier.testTag("brief-map").semantics { contentDescription = route.title }) }
                }
                item { Heading(labels.briefProfile); BriefProfileChart(g.profile) }
                item { Heading(labels.briefAirports) }
                items(g.airports) { BriefAirportPanel(it) }
                val weather = g.map.pictures.drop(1)
                if (weather.isNotEmpty()) {
                    item { Heading(labels.briefPictures) }
                    items(weather) { BriefPictureView(it.title, images[it.id], Modifier.padding(bottom = 8.dp)) }
                }
                b.sections.forEach { s ->
                    stickyHeader {
                        Surface(color = MaterialTheme.colorScheme.surface) {
                            Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp)) {
                                Text(s.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                                    color = if (s.adverse) HazardOrange else MaterialTheme.colorScheme.primary)
                                s.age?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                s.warning?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = CautionAmber) }
                            }
                        }
                    }
                    if (s.lines.isEmpty()) s.empty?.let { item { Text(it, Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) } }
                    items(s.lines) { PlanLine(it) }
                }
            }
        }
    }
}

@Composable
private fun Heading(text: String) {
    Text(text, Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 8.dp), style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
}

// Draws the graphics and rows onto US letter pages, the mark in each footer, into a file under the core's name.
private fun writeBriefPdf(context: Context, b: Brief, images: Map<String, Bitmap>, labels: RouteLabels): File {
    val (width, height, margin) = Triple(612, 792, 48f)
    val footer = 20f
    val body = TextPaint(TextPaint.ANTI_ALIAS_FLAG).apply { textSize = 10f }
    val bold = TextPaint(body).apply { typeface = Typeface.DEFAULT_BOLD }
    val small = TextPaint(body).apply { textSize = 8.5f; color = PdfColor.DKGRAY }
    val mono = TextPaint(small).apply { typeface = Typeface.MONOSPACE }
    val heading = TextPaint(bold).apply { textSize = 13f }
    val amber = TextPaint(small).apply { color = PdfColor.rgb(0xB2, 0x6A, 0x00) }
    val red = TextPaint(bold).apply { color = PdfColor.rgb(0xA8, 0x08, 0x08) }
    val amberBold = TextPaint(bold).apply { color = PdfColor.rgb(0x85, 0x40, 0x00) }
    val doc = PdfDocument()
    var page: PdfDocument.Page? = null
    var y = 0f
    val room = width - 2 * margin
    val mark = ContextCompat.getDrawable(context, R.drawable.ic_mark)?.mutate()?.apply { setTint(PdfColor.GRAY) }
    // A new page when the block does not fit, with the mark and name in its footer.
    fun space(needed: Float): android.graphics.Canvas {
        if (page == null || y + needed > height - margin - footer) {
            page?.let(doc::finishPage)
            page = doc.startPage(PdfDocument.PageInfo.Builder(width, height, doc.pages.size + 1).create())
            y = margin
            val c = page!!.canvas
            val name = "Blueside"
            val textX = width - margin - small.measureText(name)
            c.drawText(name, textX, height - margin + 4, small)
            mark?.setBounds((textX - 14).toInt(), (height - margin - 6).toInt(), (textX - 4).toInt(), (height - margin + 4).toInt())
            mark?.draw(c)
        }
        return page!!.canvas
    }
    fun draw(text: String, paint: TextPaint, indent: Float = 0f, value: String? = null) {
        val wide = room - indent - (value?.let { paint.measureText(it) + 12 } ?: 0f)
        val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, wide.toInt()).build()
        val canvas = space(layout.height.toFloat())
        canvas.save()
        canvas.translate(margin + indent, y)
        layout.draw(canvas)
        canvas.restore()
        value?.let { canvas.drawText(it, width - margin - paint.measureText(it), y - paint.ascent(), paint) }
        y += layout.height + 2
    }
    fun picture(bitmap: Bitmap?, w: Float) {
        bitmap ?: return
        val h = w * bitmap.height / bitmap.width
        val canvas = space(h)
        canvas.drawBitmap(bitmap, null, RectF(margin, y, margin + w, y + h), null)
        y += h + 4
    }
    fun bar(a: BriefAirport) {
        val canvas = space(10f)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = PdfColor.rgb(0xE0, 0xE0, 0xE0) }
        canvas.drawRect(margin, y, margin + room, y + 8, paint)
        a.spans.forEach { s ->
            paint.color = categoryColor(s.color).toArgb()
            canvas.drawRect(margin + (s.from * room).toFloat(), y, margin + (s.to * room).toFloat(), y + 8, paint)
        }
        paint.color = PdfColor.BLACK
        canvas.drawRect(margin + (a.mark * room).toFloat() - 1, y, margin + (a.mark * room).toFloat() + 1, y + 8, paint)
        y += 10
        draw(a.times.joinToString("    "), small)
    }
    val g = b.graphics
    draw(b.title, TextPaint(heading).apply { textSize = 18f })
    draw(b.notice, small)
    y += 10
    draw(labels.briefHazards, heading)
    draw(g.counts, body)
    g.hazards.forEach { draw(it.text, if (it.severe) red else amberBold, 8f) }
    g.map.pictures.firstOrNull()?.let { y += 10; draw(it.title, heading); picture(images[it.id], room) }
    y += 10
    draw(labels.briefProfile, heading)
    val chartH = room / 2.4f
    val canvas = space(chartH)
    canvas.save()
    canvas.translate(margin, y)
    val density = Density(1f)
    val measurer = TextMeasurer(createFontFamilyResolver(context), density, LayoutDirection.Ltr)
    CanvasDrawScope().draw(density, LayoutDirection.Ltr, androidx.compose.ui.graphics.Canvas(canvas), Size(room, chartH)) {
        drawProfile(g.profile, measurer, Color.Black)
    }
    canvas.restore()
    y += chartH + 4
    draw(g.profile.caption, small)
    y += 10
    draw(labels.briefAirports, heading)
    g.airports.forEach { a ->
        draw(a.title, bold, value = a.weather.category?.value)
        if (a.weather.lines.isEmpty()) draw(a.weather.note, small, 8f)
        a.weather.lines.forEach { draw(it.title, body, 8f, it.value) }
        a.weather.runways.take(2).forEach { draw("Runway ${it.end}", body, 8f, it.wind) }
        a.tafNote?.let { draw(it, small, 8f) } ?: bar(a)
        y += 6
    }
    val weather = g.map.pictures.drop(1)
    if (weather.isNotEmpty()) {
        y += 10
        draw(labels.briefPictures, heading)
        weather.forEach { draw(it.title, small); picture(images[it.id], room / 2) }
    }
    for (s in b.sections) {
        y += 10
        draw(s.title, TextPaint(heading).apply { if (s.adverse) color = PdfColor.rgb(0xEF, 0x6C, 0x00) })
        s.age?.let { draw(it, small) }
        s.warning?.let { draw(it, amber) }
        if (s.lines.isEmpty()) s.empty?.let { draw(it, body) }
        for (line in s.lines) {
            draw(listOfNotNull(line.title, line.tag).joinToString("  "), bold, value = line.value)
            line.alert?.let { draw(it, small, 12f) }
            line.detail?.let { draw(it, mono, 12f) }
        }
    }
    page?.let(doc::finishPage)
    val file = File(File(context.cacheDir, "brief").apply { mkdirs() }, b.fileName)
    file.outputStream().use(doc::writeTo)
    doc.close()
    return file
}
