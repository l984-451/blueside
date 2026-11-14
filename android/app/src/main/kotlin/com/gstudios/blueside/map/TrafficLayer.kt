package com.gstudios.blueside.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import com.gstudios.blueside.position.TrafficBatch
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression.eq
import org.maplibre.android.style.expressions.Expression.get
import org.maplibre.android.style.expressions.Expression.literal
import org.maplibre.android.style.expressions.Expression.switchCase
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory.iconAllowOverlap
import org.maplibre.android.style.layers.PropertyFactory.iconAnchor
import org.maplibre.android.style.layers.PropertyFactory.iconIgnorePlacement
import org.maplibre.android.style.layers.PropertyFactory.iconImage
import org.maplibre.android.style.layers.PropertyFactory.iconOffset
import org.maplibre.android.style.layers.PropertyFactory.iconOpacity
import org.maplibre.android.style.layers.PropertyFactory.iconRotate
import org.maplibre.android.style.layers.PropertyFactory.iconRotationAlignment
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource

// Inks as iOS draws them: label ink for other and proximate traffic, orange on alert, on the route's casing.
private fun trafficInk(alert: String, night: Boolean) = when {
    alert == "alert" -> if (night) 0xFFFF9F0A.toInt() else 0xFFFF9500.toInt()
    night -> 0xFFFFFFFF.toInt()
    else -> 0xFF000000.toInt()
}

private fun trafficCasing(night: Boolean) = if (night) 0xFF1E1D1B.toInt() else 0xFFFFFFFF.toInt()

private var trafficDensity = 1f
// Tag images already in the style in the current inks, so a batch makes only new ones.
private val tags = mutableSetOf<String>()

// Chevrons along the track (circles for a target with none), the relative altitude beside them and the callsign
// below from zoom 9; under ownship.
fun installTraffic(style: Style, night: Boolean, density: Float) {
    trafficDensity = density
    tags.clear()
    style.addSource(GeoJsonSource("traffic"))
    addSymbols(style, night)
    val fade = iconOpacity(switchCase(eq(get("stale"), literal(1)), literal(0.4f), literal(1f)))
    val layers = listOf(
        SymbolLayer("traffic", "traffic").withProperties(iconImage(get("icon")), iconRotate(get("track")),
            iconRotationAlignment(Property.ICON_ROTATION_ALIGNMENT_MAP)),
        SymbolLayer("traffic-label", "traffic").withProperties(iconImage(get("labelIcon")),
            iconAnchor(Property.ICON_ANCHOR_LEFT), iconOffset(arrayOf(14f, 0f))),
        SymbolLayer("traffic-callsign", "traffic").withProperties(iconImage(get("callsignIcon")),
            iconAnchor(Property.ICON_ANCHOR_TOP), iconOffset(arrayOf(0f, 14f))).apply { minZoom = 9f },
    )
    for (layer in layers) {
        layer.setProperties(iconAllowOverlap(true), iconIgnorePlacement(true), fade)
        if (style.getLayer("ownship") != null) style.addLayerBelow(layer, "ownship") else style.addLayer(layer)
    }
}

// One GeoJSON update per batch; images for new data blocks and callsigns are made as they first appear.
fun drawTraffic(style: Style, batch: TrafficBatch?, night: Boolean) {
    val source = style.getSourceAs<GeoJsonSource>("traffic") ?: return
    val shapes = batch?.shapes ?: """{"type":"FeatureCollection","features":[]}"""
    for (name in Regex("\"(labelIcon|callsignIcon)\":\"([^\"]+)\"").findAll(shapes).map { it.groupValues[2] }) {
        if (tags.add(name)) style.addImage(name, tag(name, night))
    }
    source.setGeoJson(shapes)
}

// Night inks for the chevrons and the batch shown; older tags are made again if they come back.
fun paintTraffic(style: Style, batch: TrafficBatch?, night: Boolean) {
    addSymbols(style, night)
    tags.clear()
    drawTraffic(style, batch, night)
}

private fun addSymbols(style: Style, night: Boolean) {
    for (alert in listOf("other", "proximate", "alert")) {
        style.addImage("traffic-$alert", symbol(alert, directed = true, night))
        style.addImage("traffic-$alert-circle", symbol(alert, directed = false, night))
    }
}

// The tag a core image name stands for: a callsign, or an alert level and relative altitude.
private fun tag(name: String, night: Boolean): Bitmap {
    val (text, alert) = if (name.startsWith("traffic-callsign-")) name.removePrefix("traffic-callsign-") to "other"
        else name.removePrefix("traffic-label-").let { it.substringAfter('-') to it.substringBefore('-') }
    return tag(text, trafficInk(alert, night), night)
}

// An arrowhead pointing up, or a circle 18 across for a target with no track.
private fun symbol(alert: String, directed: Boolean, night: Boolean): Bitmap {
    val d = trafficDensity
    val size = (30 * d).toInt()
    val path = Path().apply {
        if (directed) { moveTo(15 * d, 3 * d); lineTo(26 * d, 26 * d); lineTo(15 * d, 20 * d); lineTo(4 * d, 26 * d); close() }
        else addCircle(15 * d, 15 * d, 9 * d, Path.Direction.CW)
    }
    return Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also {
        val c = Canvas(it)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeJoin = Paint.Join.ROUND }
        c.drawPath(path, paint.apply { style = Paint.Style.STROKE; strokeWidth = 5 * d; color = trafficCasing(night) })
        paint.color = trafficInk(alert, night)
        if (alert == "other") c.drawPath(path, paint.apply { strokeWidth = 2 * d })
        else c.drawPath(path, paint.apply { style = Paint.Style.FILL_AND_STROKE; strokeWidth = 1 * d })
    }
}

private fun tag(text: String, ink: Int, night: Boolean): Bitmap {
    val d = trafficDensity
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ink; textSize = 12 * d; typeface = Typeface.DEFAULT_BOLD }
    val width = (paint.measureText(text) + 8 * d).toInt()
    val height = (paint.textSize + 6 * d).toInt()
    return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
        val c = Canvas(it)
        c.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), height / 2f, height / 2f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = trafficCasing(night); alpha = 217 })
        c.drawText(text, 4 * d, height - 3 * d - paint.descent(), paint)
    }
}
