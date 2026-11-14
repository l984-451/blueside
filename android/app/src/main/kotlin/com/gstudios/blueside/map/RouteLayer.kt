package com.gstudios.blueside.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import com.gstudios.blueside.Coordinate
import com.gstudios.blueside.DrawnLine
import org.maplibre.android.style.expressions.Expression.get
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.Layer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory.circleColor
import org.maplibre.android.style.layers.PropertyFactory.circleRadius
import org.maplibre.android.style.layers.PropertyFactory.circleStrokeColor
import org.maplibre.android.style.layers.PropertyFactory.circleStrokeWidth
import org.maplibre.android.style.layers.PropertyFactory.iconAllowOverlap
import org.maplibre.android.style.layers.PropertyFactory.iconAnchor
import org.maplibre.android.style.layers.PropertyFactory.iconImage
import org.maplibre.android.style.layers.PropertyFactory.iconOffset
import org.maplibre.android.style.layers.PropertyFactory.lineCap
import org.maplibre.android.style.layers.PropertyFactory.lineColor
import org.maplibre.android.style.layers.PropertyFactory.lineJoin
import org.maplibre.android.style.layers.PropertyFactory.lineOpacity
import org.maplibre.android.style.layers.PropertyFactory.lineWidth
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.android.maps.Style
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point

// Fixed route inks, the same as iOS; night swaps them for the dark map.
private fun routeInk(night: Boolean) = if (night) 0xFFF060D6.toInt() else 0xFFD11FB6.toInt()
private fun casingInk(night: Boolean) = if (night) 0xFF1E1D1B.toInt() else 0xFFFFFFFF.toInt()

// The cased magenta line above the chart and under the point symbols; dots and labels under the aircraft.
fun installRoute(style: Style, night: Boolean, density: Float) {
    val points = style.layers.firstOrNull { it is SymbolLayer || it is CircleLayer }?.id
    fun below(layer: Layer, id: String?) = if (id != null && style.getLayer(id) != null) style.addLayerBelow(layer, id) else style.addLayer(layer)
    for (name in listOf("route", "route-active")) {
        style.addSource(GeoJsonSource(name))
        val wide = name == "route-active"
        // Legs not being flown are dimmer, so the active one stands out.
        val opacity = if (wide) 1f else 0.55f
        val casing = LineLayer("$name-casing", name).withProperties(
            lineWidth(if (wide) 7f else 6f), lineColor(casingInk(night)), lineOpacity(opacity),
            lineCap(Property.LINE_CAP_ROUND), lineJoin(Property.LINE_JOIN_ROUND))
        val core = LineLayer(name, name).withProperties(
            lineWidth(if (wide) 4f else 3f), lineColor(routeInk(night)), lineOpacity(opacity),
            lineCap(Property.LINE_CAP_ROUND), lineJoin(Property.LINE_JOIN_ROUND))
        below(casing, points)
        below(core, points)
    }
    style.addSource(GeoJsonSource("route-points"))
    below(CircleLayer("route-points", "route-points").withProperties(
        circleRadius(4f), circleStrokeWidth(2f), circleColor(routeInk(night)), circleStrokeColor(casingInk(night))), "ownship")
    below(SymbolLayer("route-labels", "route-points").withProperties(
        iconImage(get("label")), iconAnchor(Property.ICON_ANCHOR_LEFT), iconOffset(arrayOf(6f, 0f)), iconAllowOverlap(true)), "ownship")
    labelDensity = density
    labels.clear()
}

// Night inks for the line and dots; the labels take theirs at the next draw.
fun paintRoute(style: Style, night: Boolean) {
    for (name in listOf("route", "route-active")) {
        style.getLayer("$name-casing")?.setProperties(lineColor(casingInk(night)))
        style.getLayer(name)?.setProperties(lineColor(routeInk(night)))
    }
    style.getLayer("route-points")?.setProperties(circleColor(routeInk(night)), circleStrokeColor(casingInk(night)))
}

private var labelDensity = 1f
// Label images already in the style, so a draw makes only new ones.
private val labels = mutableSetOf<String>()

private fun lineFeature(path: List<Coordinate>) = Feature.fromGeometry(LineString.fromLngLats(path.map { Point.fromLngLat(it.longitude, it.latitude) }))

private val empty = FeatureCollection.fromFeatures(emptyList())

fun drawRoute(style: Style, line: DrawnLine?, night: Boolean) {
    val all = style.getSourceAs<GeoJsonSource>("route") ?: return
    val active = style.getSourceAs<GeoJsonSource>("route-active") ?: return
    val points = style.getSourceAs<GeoJsonSource>("route-points") ?: return
    if (line == null) {
        listOf(all, active, points).forEach { it.setGeoJson(empty) }
        return
    }
    all.setGeoJson(lineFeature(line.path))
    line.active?.let { active.setGeoJson(lineFeature(it)) } ?: active.setGeoJson(empty)
    points.setGeoJson(FeatureCollection.fromFeatures(line.dots.map { dot ->
        val name = "route-label-${dot.ident}-$night"
        if (labels.add(name)) style.addImage(name, label(dot.ident, night))
        Feature.fromGeometry(Point.fromLngLat(dot.longitude, dot.latitude)).apply { addStringProperty("label", name) }
    }))
}

// The identifier in route ink on a casing capsule, so it reads over any chart.
private fun label(ident: String, night: Boolean): Bitmap {
    val d = labelDensity
    val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = routeInk(night)
        textSize = 12 * d
        typeface = Typeface.DEFAULT_BOLD
    }
    val width = (text.measureText(ident) + 10 * d).toInt()
    val height = (text.textSize + 6 * d).toInt()
    return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
        val c = Canvas(it)
        c.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), height / 2f, height / 2f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = casingInk(night) })
        c.drawText(ident, 5 * d, height - 3 * d - text.descent(), text)
    }
}
