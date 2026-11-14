package com.gstudios.blueside.map

import android.graphics.PointF
import android.graphics.RectF
import android.view.MotionEvent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.gstudios.blueside.AppModel
import com.gstudios.blueside.Coordinate
import com.gstudios.blueside.GrabArgs
import com.gstudios.blueside.Hit
import com.gstudios.blueside.Place
import com.gstudios.blueside.RouteEdit
import com.gstudios.blueside.RulerArgs
import com.gstudios.blueside.ScreenPoint
import com.gstudios.blueside.SnapArgs
import com.gstudios.blueside.StationHit
import com.gstudios.blueside.grab
import com.gstudios.blueside.ruler
import com.gstudios.blueside.snap
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.geojson.Point
import kotlin.math.hypot

// The rubber band while it is dragged, in view pixels: the fixed ends, the finger, and what it would snap to.
data class Band(val anchors: List<PointF>, val finger: PointF, val target: PointF?, val label: String?)

data class Ruler(val start: PointF, val end: PointF, val text: String)

// The places under a finger with their distances in dp, the units the core's ties are measured in.
fun hitsAt(map: MapLibreMap, layers: List<String>, box: Double, density: Float, at: PointF): List<Hit> {
    val half = (box * density / 2).toFloat()
    val rect = RectF(at.x - half, at.y - half, at.x + half, at.y + half)
    return map.queryRenderedFeatures(rect, *layers.toTypedArray()).mapNotNull { feature ->
        val point = feature.geometry() as? Point ?: return@mapNotNull null
        val ident = feature.getStringProperty("ident") ?: return@mapNotNull null
        val kind = feature.getStringProperty("kind") ?: return@mapNotNull null
        val name = if (feature.hasProperty("name")) feature.getStringProperty("name") else ident
        val icao = if (feature.hasProperty("icao")) feature.getStringProperty("icao") else null
        val on = map.projection.toScreenLocation(LatLng(point.latitude(), point.longitude()))
        Hit(Place(kind, ident, icao, name, point.latitude(), point.longitude()), hypot((on.x - at.x).toDouble(), (on.y - at.y).toDouble()) / density)
    }
}

// Weather station dots under a finger, which the core opens as their airports.
fun stationsAt(map: MapLibreMap, layer: String, box: Double, density: Float, at: PointF): List<StationHit> {
    val half = (box * density / 2).toFloat()
    val rect = RectF(at.x - half, at.y - half, at.x + half, at.y + half)
    return map.queryRenderedFeatures(rect, layer).mapNotNull { feature ->
        val point = feature.geometry() as? Point ?: return@mapNotNull null
        val station = feature.getStringProperty("station") ?: return@mapNotNull null
        val on = map.projection.toScreenLocation(LatLng(point.latitude(), point.longitude()))
        StationHit(station, point.latitude(), point.longitude(), hypot((on.x - at.x).toDouble(), (on.y - at.y).toDouble()) / density)
    }
}

// A held finger bends the route line; two fingers held still for 0.3 s measure. The core decides both.
class MapEdit(private val view: MapView, private val map: MapLibreMap, private val model: AppModel) {
    var band by mutableStateOf<Band?>(null)
        private set
    var ruler by mutableStateOf<Ruler?>(null)
        private set
    private val density = view.resources.displayMetrics.density
    private val labels = model.nav.labels
    private var grabbed: com.gstudios.blueside.Grab? = null
    private var drawnCount = 0
    private var twoAt: List<PointF>? = null
    private val startRuler = Runnable { twoAt?.let { measure(it) } }

    private fun screen(c: Coordinate) = map.projection.toScreenLocation(LatLng(c.latitude, c.longitude))
    private fun ground(p: PointF) = map.projection.fromScreenLocation(p).let { Coordinate(it.latitude, it.longitude) }
    private fun hits(p: PointF) = hitsAt(map, labels.pickLayers, labels.pickBox, density, p)

    // A long press on the line grabs it and holds the map still. False leaves the press to drop a pin.
    fun hold(at: LatLng): Boolean {
        val line = model.route.view?.line ?: return false
        val points = line.points.map(::screen)
        val finger = map.projection.toScreenLocation(at)
        val found = runCatching {
            grab(GrabArgs(points.map { ScreenPoint(it.x / density.toDouble(), it.y / density.toDouble()) }, line.firstDot,
                ScreenPoint(finger.x / density.toDouble(), finger.y / density.toDouble())))
        }.getOrNull() ?: return false
        grabbed = found.grab ?: return false
        drawnCount = points.size
        map.uiSettings.isScrollGesturesEnabled = false
        band = Band(found.anchors.map { points[it] }, finger, null, null)
        bend(finger)
        return true
    }

    private fun bend(finger: PointF) {
        val snapped = runCatching { snap(SnapArgs(hits(finger))) }.getOrNull()
        band = band?.copy(finger = finger, label = snapped?.label,
            target = snapped?.target?.let { screen(Coordinate(it.latitude, it.longitude)) })
    }

    private fun letGo() {
        grabbed = null
        band = null
        map.uiSettings.isScrollGesturesEnabled = true
    }

    private fun measure(fingers: List<PointF>) {
        if (ruler == null) {
            map.uiSettings.isScrollGesturesEnabled = false
            map.uiSettings.isZoomGesturesEnabled = false
        }
        val text = runCatching {
            ruler(RulerArgs(ground(fingers[0]), ground(fingers[1]), model.currentFix, model.approximate, System.currentTimeMillis()))
        }.getOrDefault("")
        ruler = Ruler(fingers[0], fingers[1], text)
    }

    private fun stopMeasuring() {
        view.removeCallbacks(startRuler)
        twoAt = null
        if (ruler == null) return
        ruler = null
        map.uiSettings.isScrollGesturesEnabled = true
        map.uiSettings.isZoomGesturesEnabled = true
    }

    // Sees every touch before MapLibre and never consumes one, so the map's own gestures stay whole.
    fun touched(event: MotionEvent) {
        val fingers = (0 until event.pointerCount).map { PointF(event.getX(it), event.getY(it)) }
        grabbed?.let { grab ->
            when (event.actionMasked) {
                MotionEvent.ACTION_MOVE -> bend(fingers[0])
                MotionEvent.ACTION_UP -> {
                    val finger = PointF(event.x, event.y)
                    val at = ground(finger)
                    val scale = map.projection.getMetersPerPixelAtLatitude(at.latitude) * density
                    val edit = RouteEdit("bend", grab = grab, drawnCount = drawnCount, hits = hits(finger), at = at, metersPerPoint = scale)
                    letGo()
                    model.bent(edit, finger.x, finger.y + 90 * density)
                }
                MotionEvent.ACTION_CANCEL -> letGo()
            }
            return
        }
        when (event.actionMasked) {
            MotionEvent.ACTION_POINTER_DOWN -> if (event.pointerCount == 2) {
                twoAt = fingers
                view.postDelayed(startRuler, 300)
            } else stopMeasuring()
            MotionEvent.ACTION_MOVE -> when {
                ruler != null && fingers.size >= 2 -> measure(fingers)
                // Fingers that move before the hold ends are a pinch, not a ruler.
                twoAt != null && fingers.size >= 2 && fingers.zip(twoAt!!).any { (a, b) -> hypot(a.x - b.x, a.y - b.y) > 10 * density } -> {
                    view.removeCallbacks(startRuler)
                    twoAt = null
                }
            }
            MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> stopMeasuring()
        }
    }
}

private val BandInk = Color(0xFFD11FB6)
private val RulerInk = Color(0xFF1A73E8)

// The band, ring and ruler drawn over the map.
@Composable
fun MapEditOverlay(edit: MapEdit?) {
    val band = edit?.band
    val ruler = edit?.ruler
    Box(Modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize()) {
            band?.let { b ->
                val finger = Offset(b.finger.x, b.finger.y)
                val dash = PathEffect.dashPathEffect(floatArrayOf(8.dp.toPx(), 6.dp.toPx()))
                b.anchors.forEach { drawLine(BandInk, Offset(it.x, it.y), finger, 4.dp.toPx(), StrokeCap.Round, dash) }
                b.target?.let { drawCircle(BandInk, 6.dp.toPx(), Offset(it.x, it.y)) }
                if (b.label != null) drawCircle(BandInk.copy(alpha = 0.2f), 22.dp.toPx(), finger)
                drawCircle(BandInk, 22.dp.toPx(), finger, style = Stroke(3.dp.toPx()))
            }
            ruler?.let { r ->
                val a = Offset(r.start.x, r.start.y)
                val b = Offset(r.end.x, r.end.y)
                drawLine(RulerInk, a, b, 3.dp.toPx(), StrokeCap.Round)
                drawCircle(RulerInk, 6.dp.toPx(), a)
                drawCircle(RulerInk, 6.dp.toPx(), b)
            }
        }
        band?.label?.let { Pill(it, band.finger.x, band.finger.y - 60 * density()) }
        ruler?.let { Pill(it.text, (it.start.x + it.end.x) / 2, (it.start.y + it.end.y) / 2) }
    }
}

// The "Use instead?" card beside a dropped point, drawn over the route drawer and the other map overlays.
@Composable
fun OfferCard(model: AppModel) {
    model.route.offer?.let { shown ->
        val labels = model.route.labels
        Surface(
            Modifier.centeredAt(shown.x, shown.y).widthIn(max = 260.dp),
            shape = MaterialTheme.shapes.large, tonalElevation = 3.dp, shadowElevation = 6.dp,
        ) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(labels.useInstead, style = MaterialTheme.typography.titleSmall)
                shown.offer.places.forEach { item ->
                    OutlinedButton(onClick = { model.useInstead(shown.offer.target, item.place) }) {
                        Text(listOfNotNull(item.row.title, item.row.name).joinToString("  "), maxLines = 1)
                    }
                }
                TextButton(onClick = { model.route.offer = null }) { Text(labels.keepPoint) }
            }
        }
    }
}

@Composable
private fun density() = androidx.compose.ui.platform.LocalDensity.current.density

// A label centered on a view point, as the map notices are drawn.
@Composable
private fun Pill(text: String, x: Float, y: Float) {
    Surface(Modifier.centeredAt(x, y), shape = MaterialTheme.shapes.extraLarge, tonalElevation = 3.dp, shadowElevation = 3.dp) {
        Text(text, Modifier.padding(horizontal = 12.dp, vertical = 6.dp), fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.labelLarge)
    }
}

// Takes the whole overlay so touches reach the content where it is drawn; kept inside the overlay.
private fun Modifier.centeredAt(x: Float, y: Float) = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints.copy(minWidth = 0, minHeight = 0))
    layout(constraints.maxWidth, constraints.maxHeight) {
        placeable.place(IntOffset(
            (x - placeable.width / 2f).toInt().coerceIn(0, maxOf(0, constraints.maxWidth - placeable.width)),
            (y - placeable.height / 2f).toInt().coerceIn(0, maxOf(0, constraints.maxHeight - placeable.height)),
        ))
    }
}
