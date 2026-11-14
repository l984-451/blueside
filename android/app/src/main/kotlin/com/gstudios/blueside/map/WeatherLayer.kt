package com.gstudios.blueside.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import com.gstudios.blueside.WeatherCatalog
import com.gstudios.blueside.WxLayers
import com.gstudios.blueside.WxLoopFrame
import kotlin.math.roundToInt
import org.maplibre.android.style.expressions.Expression.color
import org.maplibre.android.style.expressions.Expression.get
import org.maplibre.android.style.expressions.Expression.step
import org.maplibre.android.style.expressions.Expression.stop
import org.maplibre.android.maps.ImageContent
import org.maplibre.android.maps.ImageStretches
import org.maplibre.android.maps.Style
import org.maplibre.android.style.layers.FillLayer
import org.maplibre.android.style.layers.RasterLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.TransitionOptions
import org.maplibre.android.style.layers.PropertyFactory.fillColor
import org.maplibre.android.style.layers.PropertyFactory.fillOpacity
import org.maplibre.android.style.layers.PropertyFactory.rasterOpacity
import org.maplibre.android.style.layers.PropertyFactory.rasterResampling
import org.maplibre.android.style.layers.PropertyFactory.visibility
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.android.style.sources.RasterSource
import org.maplibre.android.style.sources.VectorSource

// Puts the core's weather GeoJSON into the style's sources and the newest radar picture under its shading.
// The core's barb drawings as SDF images, so the style colors and turns them.
fun installBarbs(style: Style, barbs: List<WeatherCatalog.Barb>, density: Float) {
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; strokeCap = Paint.Cap.ROUND }
    for (b in barbs) {
        val px = (b.size * density).toInt()
        val bitmap = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap).apply { scale(density, density) }
        paint.strokeWidth = b.lineWidth.toFloat()
        paint.style = Paint.Style.STROKE
        b.lines.forEach { canvas.drawLine(it[0].toFloat(), it[1].toFloat(), it[2].toFloat(), it[3].toFloat(), paint) }
        b.ring?.let { canvas.drawCircle((b.size / 2).toFloat(), (b.size / 2).toFloat(), it.toFloat(), paint) }
        paint.style = Paint.Style.FILL
        b.triangles.forEach { t ->
            canvas.drawPath(Path().apply {
                moveTo(t[0].toFloat(), t[1].toFloat()); lineTo(t[2].toFloat(), t[3].toFloat()); lineTo(t[4].toFloat(), t[5].toFloat()); close()
            }, paint)
        }
        style.addImage(b.name, bitmap, true)
    }
}

// Station text's rounded ground, as iOS draws it: white by day, the map ground by night, both 85% with a thin edge.
// Only the middle stretches, so the corners stay round around any text.
fun installPill(style: Style, night: Boolean, density: Float) {
    val side = (12 * density).toInt()
    val inset = 5 * density
    val bitmap = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val box = RectF(density / 2, density / 2, side - density / 2, side - density / 2)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    paint.color = if (night) 0xD91E1D1B.toInt() else 0xD9FFFFFF.toInt()
    canvas.drawRoundRect(box, 5 * density, 5 * density, paint)
    paint.style = Paint.Style.STROKE
    paint.strokeWidth = density
    paint.color = if (night) 0x2EFFFFFF else 0x2E000000
    canvas.drawRoundRect(box, 5 * density, 5 * density, paint)
    val middle = listOf(ImageStretches(inset, side - inset))
    style.addImage("wx-label-pill", bitmap, middle, middle, ImageContent(inset, inset, side - inset, side - inset))
}

fun drawWeather(style: Style, layers: WxLayers, catalog: WeatherCatalog) {
    for ((id, json) in layers.sources) style.getSourceAs<GeoJsonSource>(id)?.setGeoJson(json)
    for ((id, shown) in layers.visible) style.getLayer(id)?.setProperties(visibility(if (shown) Property.VISIBLE else Property.NONE))
    drawRadar(style, layers.radar, catalog)
    drawSatellite(style, layers.satellite, catalog)
}

// The newest satellite picture as a raster under every other weather layer, blurred linearly past its zoom 6.
private fun drawSatellite(style: Style, file: String?, catalog: WeatherCatalog) {
    val id = catalog.satelliteID
    val url = file?.let { "pmtiles://file://$it" }
    if (url == style.getSourceAs<RasterSource>(id)?.uri) return
    style.removeLayer(id)
    style.removeSource(id)
    if (url == null || style.getLayer(catalog.satelliteAnchor) == null) return
    style.addSource(RasterSource(id, url, 256))
    style.addLayerBelow(RasterLayer(id, id).withProperties(
        rasterOpacity(catalog.satelliteOpacity.toFloat()), rasterResampling(Property.RASTER_RESAMPLING_LINEAR)), catalog.satelliteAnchor)
}

private fun drawRadar(style: Style, file: String?, catalog: WeatherCatalog) {
    val id = catalog.frameID
    val url = file?.let { "pmtiles://file://$it" }
    if (url == (style.getSourceAs<VectorSource>(id))?.uri) return
    style.removeLayer(id)
    style.removeSource(id)
    if (url != null) addRadar(style, id, url, catalog)
}

private fun opacity(shown: Boolean) = fillOpacity(if (shown) 1f else 0f)

// Crossfade between loop pictures, shorter than the 0.5 s a picture stays up.
private val fade = TransitionOptions(300, 0)

private fun withAlpha(hex: String, alpha: Double) = (Color.parseColor(hex) and 0xFFFFFF) or ((alpha * 255).roundToInt() shl 24)

private fun addRadar(style: Style, id: String, url: String, catalog: WeatherCatalog, shown: Boolean = true) {
    if (style.getLayer(catalog.shadingID) == null) return
    style.addSource(VectorSource(id, url))
    // Alpha rides in the colors so the layer opacity stays a constant MapLibre can fade:
    // a data-driven opacity does not transition and left the old picture up over the new one.
    // Below the first band floor is no coverage.
    val colors = catalog.bands.map { stop(it.dbz, color(withAlpha(it.color, catalog.echoOpacity))) }.toTypedArray()
    val layer = FillLayer(id, id).withSourceLayer("radar").withProperties(
        fillColor(step(get("dbz"), color(withAlpha(catalog.noCoverageColor, catalog.noCoverageOpacity)), *colors)),
        opacity(shown),
    )
    layer.fillOpacityTransition = fade
    style.addLayerBelow(layer, catalog.shadingID)
}

private fun loopID(i: Int) = "wx-radar-loop-$i"

// Shows picture `showing` of the loop, fading from the one before. Every picture is its own layer, hidden at zero opacity so its tiles
// stay loaded and a swap never flickers. No frames removes the loop and shows the newest again.
fun drawLoop(style: Style, frames: List<WxLoopFrame>, showing: Int, catalog: WeatherCatalog) {
    if (frames.isEmpty()) {
        var i = 0
        while (style.getSource(loopID(i)) != null) {
            style.removeLayer(loopID(i))
            style.removeSource(loopID(i))
            i++
        }
    } else if (style.getSource(loopID(0)) == null) {
        frames.forEachIndexed { i, f -> addRadar(style, loopID(i), "pmtiles://file://${f.file}", catalog, shown = false) }
    }
    frames.indices.forEach { style.getLayer(loopID(it))?.setProperties(opacity(it == showing)) }
    style.getLayer(catalog.frameID)?.setProperties(opacity(frames.isEmpty()))
}
