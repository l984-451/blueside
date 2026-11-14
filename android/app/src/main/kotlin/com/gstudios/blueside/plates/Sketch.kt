package com.gstudios.blueside.plates

import android.content.Context
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import kotlinx.serialization.Serializable
import java.io.File

// Core's airport sketch in page units from top left, drawn here as given: areas, under, runways, lines, labels.

@Serializable data class SketchRunway(val id: String, val outline: List<List<Double>>, val paved: Boolean, val closed: Boolean)

@Serializable data class SketchArea(val outline: List<List<Double>>, val shade: Double)

@Serializable
data class SketchLine(
    val points: List<List<Double>>,
    val width: Double,
    val white: Boolean = false,
    val dash: List<Double>? = null,
    val shade: Double = 1.0,
)

@Serializable
data class SketchLabel(
    val text: String,
    val x: Double,
    val y: Double,
    val size: Double,
    val rotation: Double = 0.0,
    val leading: Boolean = false,
    val bold: Boolean = false,
    val shade: Double = 1.0,
)

@Serializable
data class AirportSketch(
    val width: Double,
    val height: Double,
    val areas: List<SketchArea>,
    val under: List<SketchLine> = emptyList(),
    val runways: List<SketchRunway>,
    val lines: List<SketchLine>,
    val labels: List<SketchLabel>,
    val geo: PlateGeo,
)

@Serializable
data class SketchRef(
    val sketch: AirportSketch,
    val title: String,
    val fullScreen: String,
    val showOnMap: String,
    val unavailable: String,
) {
    // Stands in for a chart, so the chart viewer, ownship and the map fit take it as one.
    val plate get() = PlateRef(name = title, file = "", pack = "", geo = sketch.geo)
}

// The sketch as a one-page PDF on chart paper, so it opens and zooms like an FAA chart.
fun sketchPdf(context: Context, sketch: AirportSketch): File? = runCatching {
    val doc = PdfDocument()
    val page = doc.startPage(PdfDocument.PageInfo.Builder(sketch.width.toInt(), sketch.height.toInt(), 1).create())
    val canvas = page.canvas
    canvas.drawColor(android.graphics.Color.WHITE)
    val ink = android.graphics.Color.DKGRAY
    val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = ink }
    val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = ink; strokeWidth = 1f }
    fun path(points: List<List<Double>>, closed: Boolean) = Path().apply {
        points.forEachIndexed { i, p -> if (i == 0) moveTo(p[0].toFloat(), p[1].toFloat()) else lineTo(p[0].toFloat(), p[1].toFloat()) }
        if (closed) close()
    }
    for (a in sketch.areas) {
        fill.alpha = (a.shade * 255).toInt()
        canvas.drawPath(path(a.outline, true), fill)
    }
    // Taxiways round-ended, so their joins close.
    val under = Paint(line).apply { strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
    for (l in sketch.under) {
        under.strokeWidth = l.width.toFloat()
        under.alpha = (l.shade * 255).toInt()
        canvas.drawPath(path(l.points, false), under)
    }
    for (r in sketch.runways) {
        val outline = path(r.outline, true)
        fill.alpha = ((if (r.closed) 0.3 else if (r.paved) 1.0 else 0.45) * 255).toInt()
        canvas.drawPath(outline, fill)
        canvas.drawPath(outline, line)
    }
    val stroke = Paint(line)
    for (l in sketch.lines) {
        stroke.color = if (l.white) android.graphics.Color.WHITE else ink
        if (!l.white) stroke.alpha = (l.shade * 255).toInt()
        stroke.strokeWidth = l.width.toFloat()
        stroke.pathEffect = l.dash?.let { DashPathEffect(it.map(Double::toFloat).toFloatArray(), 0f) }
        canvas.drawPath(path(l.points, false), stroke)
    }
    val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.BLACK }
    for (l in sketch.labels) {
        text.textSize = l.size.toFloat()
        text.alpha = (l.shade * 255).toInt()
        text.typeface = if (l.bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        text.textAlign = if (l.leading) Paint.Align.LEFT else Paint.Align.CENTER
        canvas.save()
        canvas.translate(l.x.toFloat(), l.y.toFloat())
        canvas.rotate(l.rotation.toFloat())
        // Centered on the point vertically, as the label's middle.
        canvas.drawText(l.text, 0f, -(text.ascent() + text.descent()) / 2, text)
        canvas.restore()
    }
    doc.finishPage(page)
    val out = File(context.cacheDir, "plates/sketch-${sketch.hashCode()}.pdf")
    out.parentFile?.mkdirs()
    if (out.length() == 0L) out.outputStream().use { doc.writeTo(it) }
    doc.close()
    out
}.getOrNull()
