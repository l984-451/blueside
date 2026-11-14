package com.gstudios.blueside.route

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.gstudios.blueside.BriefAirport
import com.gstudios.blueside.BriefGraphics
import com.gstudios.blueside.BriefPicture
import com.gstudios.blueside.BriefProfile
import com.gstudios.blueside.map.CautionAmber
import com.gstudios.blueside.nav.categoryColors
import kotlinx.coroutines.suspendCancellableCoroutine
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.Style
import org.maplibre.android.snapshotter.MapSnapshotter
import kotlin.coroutines.resume

// Snapshot size in dp, as the core sets it.
const val PictureWidth = 600
const val PictureHeight = 360
private const val RouteInk = 0xFFD11FB6
private val DangerRed = Color(0xFFD32F2F)

fun categoryColor(name: String?): Color = categoryColors[name] ?: Color.Gray

// The counts, then the worst items in red or amber.
@Composable
fun BriefHazards(g: BriefGraphics) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag("brief-hazards"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(g.counts, style = MaterialTheme.typography.bodyMedium)
        g.hazards.forEach { h ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Warning, null, Modifier.height(18.dp), tint = if (h.severe) DangerRed else CautionAmber)
                Text(h.text, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold,
                    color = if (h.severe) DangerRed else CautionAmber)
            }
        }
    }
}

// A map snapshot, or a tinted box with a spinner until it is drawn.
@Composable
fun BriefPictureView(title: String, image: Bitmap?, modifier: Modifier = Modifier) {
    Column(modifier.padding(horizontal = 16.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(PictureWidth.toFloat() / PictureHeight).clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
            if (image != null) Image(image.asImageBitmap(), null, Modifier.fillMaxWidth())
            else CircularProgressIndicator()
        }
        if (title.isNotEmpty()) Text(title, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// The side view drawn from the core's geometry.
@Composable
fun BriefProfileChart(p: BriefProfile, ink: Color = MaterialTheme.colorScheme.onSurface) {
    val measurer = rememberTextMeasurer()
    Column(Modifier.padding(horizontal = 16.dp)) {
        Canvas(Modifier.fillMaxWidth().aspectRatio(2.4f).testTag("brief-profile").semantics { contentDescription = p.caption }) {
            drawProfile(p, measurer, ink)
        }
        Text(p.caption, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

fun DrawScope.drawProfile(p: BriefProfile, measurer: TextMeasurer, ink: Color) {
    val labels = 16.dp.toPx()
    val w = size.width
    val h = size.height - labels
    val length = maxOf(p.lengthNM, 1.0)
    fun x(nm: Double) = (nm / length * w).toFloat()
    fun y(ft: Double) = (h - ft / p.topFt * h).toFloat()
    val small = TextStyle(fontSize = 10.sp, color = ink.copy(alpha = 0.6f))
    drawRect(ink.copy(alpha = 0.05f), size = Size(w, h))
    p.grid.forEach { t ->
        drawLine(ink.copy(alpha = 0.25f), Offset(0f, y(t.value)), Offset(w, y(t.value)), 1f)
        drawText(measurer, t.text, Offset(2f, y(t.value) - 14.sp.toPx()), small)
    }
    p.ground.forEach { g -> drawRect(Color.Gray.copy(alpha = 0.55f), Offset(x(g.fromNM), y(g.ft.toDouble())), Size(x(g.toNM) - x(g.fromNM), h - y(g.ft.toDouble()))) }
    p.freezing.filter { it.isNotEmpty() }.forEach { run ->
        val path = Path().apply { moveTo(x(run[0][0]), y(run[0][1])); run.drop(1).forEach { lineTo(x(it[0]), y(it[1])) } }
        drawPath(path, Color(0xFF1F5FD0), style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 6f))))
    }
    p.clouds.forEach { c ->
        val color = categoryColor(c.color)
        drawCircle(color, 4.dp.toPx(), Offset(x(c.nm), h))
        c.ft?.let { drawRect(color.copy(alpha = if (c.ceiling) 1f else 0.5f), Offset(x(c.nm) - 10.dp.toPx(), y(it.toDouble()) - 2.dp.toPx()), Size(20.dp.toPx(), 4.dp.toPx())) }
    }
    drawLine(Color(RouteInk), Offset(0f, y(p.cruiseFt.toDouble())), Offset(w, y(p.cruiseFt.toDouble())), 2.5.dp.toPx())
    val unit = density
    p.winds.forEach { b ->
        val at = Offset(x(b.nm), y(b.ft.toDouble()))
        fun pt(xx: Double, yy: Double) = Offset(at.x + (xx * unit).toFloat(), at.y + (yy * unit).toFloat())
        b.lines.filter { it.size == 4 }.forEach { drawLine(ink, pt(it[0], it[1]), pt(it[2], it[3]), (b.lineWidth * 1.6 * unit).toFloat(), StrokeCap.Round) }
        b.triangles.filter { it.size == 6 }.forEach { t ->
            drawPath(Path().apply { val a = pt(t[0], t[1]); moveTo(a.x, a.y); pt(t[2], t[3]).let { lineTo(it.x, it.y) }; pt(t[4], t[5]).let { lineTo(it.x, it.y) }; close() }, ink)
        }
        b.ring?.let { drawCircle(ink, (it * unit).toFloat(), at, style = Stroke(1f)) }
    }
    p.waypoints.forEachIndexed { n, m ->
        drawLine(ink.copy(alpha = 0.6f), Offset(x(m.value), h), Offset(x(m.value), h + 4.dp.toPx()), 1f)
        val text = measurer.measure(m.text, TextStyle(fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = ink))
        val left = when (n) { 0 -> x(m.value); p.waypoints.size - 1 -> x(m.value) - text.size.width; else -> x(m.value) - text.size.width / 2 }
        drawText(text, topLeft = Offset(left, h + 3.dp.toPx()))
    }
}

// An airport's category, weather rows, best runways and the TAF bar across its time.
@Composable
fun BriefAirportPanel(a: BriefAirport) {
    val wx = a.weather
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(a.title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
            wx.category?.value?.let {
                Text(it, Modifier.clip(CircleShape).background(categoryColor(wx.color)).padding(horizontal = 10.dp, vertical = 2.dp),
                    color = Color.White, style = MaterialTheme.typography.labelMedium)
            }
        }
        if (wx.lines.isEmpty()) Text(wx.note, style = MaterialTheme.typography.bodySmall)
        (wx.lines.map { it.title to (it.value ?: "") } + wx.runways.take(2).map { "Runway ${it.end}" to it.wind }).forEach { (k, v) ->
            Row { Text(k, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium); Text(v, style = MaterialTheme.typography.bodyMedium) }
        }
        val note = a.tafNote
        if (note != null) Text(note, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        else {
            val track = MaterialTheme.colorScheme.surfaceVariant
            val mark = MaterialTheme.colorScheme.onSurface
            Canvas(Modifier.fillMaxWidth().height(10.dp).clip(CircleShape)) {
                drawRect(track)
                a.spans.forEach { s -> drawRect(categoryColor(s.color), Offset((s.from * size.width).toFloat(), 0f), Size(((s.to - s.from) * size.width).toFloat(), size.height)) }
                drawRect(mark, Offset((a.mark * size.width).toFloat() - 1.dp.toPx(), 0f), Size(2.dp.toPx(), size.height))
            }
            Row { a.times.forEachIndexed { n, t ->
                if (n > 0) Box(Modifier.weight(1f))
                Text(t, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } }
        }
    }
}

// Renders one core style over the brief's box. MapLibre draws off the main thread; closing the brief cancels it.
suspend fun snapshot(context: Context, picture: BriefPicture, bounds: com.gstudios.blueside.BriefBox): Bitmap? =
    suspendCancellableCoroutine { done ->
        val options = MapSnapshotter.Options(PictureWidth, PictureHeight)
            .withStyleBuilder(Style.Builder().fromJson(picture.style))
            .withRegion(LatLngBounds.from(bounds.maxLatitude, bounds.maxLongitude, bounds.minLatitude, bounds.minLongitude))
            .withPixelRatio(context.resources.displayMetrics.density)
            .withLogo(false)
        val shooter = MapSnapshotter(context, options)
        done.invokeOnCancellation { Handler(Looper.getMainLooper()).post { shooter.cancel() } }
        shooter.start({ shot -> if (done.isActive) done.resume(shot.bitmap) }, { if (done.isActive) done.resume(null) })
    }
