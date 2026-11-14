package com.gstudios.blueside.route

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.text.TextPaint
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.gstudios.blueside.Navlog
import com.gstudios.blueside.R
import java.io.File

// Draws the core's nav log on US letter pages turned wide, the mark in each footer. Slow, so call it off the main thread.
fun writeNavlog(context: Context, log: Navlog): File {
    val (width, height, margin, footer) = listOf(792, 612, 32, 20).map { it.toFloat() }
    val room = width - 2 * margin
    val body = TextPaint(TextPaint.ANTI_ALIAS_FLAG).apply { textSize = 9f; color = Color.BLACK }
    val bold = TextPaint(body).apply { typeface = Typeface.DEFAULT_BOLD }
    val mono = TextPaint(body).apply { typeface = Typeface.MONOSPACE }
    val heading = TextPaint(bold).apply { textSize = 11f }
    val stroke = Paint().apply { color = Color.BLACK; style = Paint.Style.STROKE; strokeWidth = 0.5f }
    val gray = TextPaint(body).apply { textSize = 8f; color = Color.GRAY }
    val mark = ContextCompat.getDrawable(context, R.drawable.ic_mark)?.mutate()?.apply { setTint(Color.GRAY) }
    val doc = PdfDocument()
    var page: PdfDocument.Page? = null
    var y = margin
    // A new page when the block does not fit, with the mark and name in its footer.
    fun space(needed: Float): android.graphics.Canvas {
        if (page == null || y + needed > height - margin - footer) {
            page?.let(doc::finishPage)
            page = doc.startPage(PdfDocument.PageInfo.Builder(width.toInt(), height.toInt(), doc.pages.size + 1).create())
            y = margin
            val c = page!!.canvas
            val textX = width - margin - gray.measureText("Blueside")
            c.drawText("Blueside", textX, height - margin + 8, gray)
            mark?.setBounds((textX - 12).toInt(), (height - margin).toInt(), (textX - 3).toInt(), (height - margin + 9).toInt())
            mark?.draw(c)
        }
        return page!!.canvas
    }
    fun text(c: android.graphics.Canvas, s: String, x: Float, w: Float, top: Float, paint: TextPaint, right: Boolean = false) {
        val fit = android.text.TextUtils.ellipsize(s, paint, w, android.text.TextUtils.TruncateAt.END).toString()
        c.drawText(fit, if (right) x + w - paint.measureText(fit) else x, top - paint.ascent(), paint)
    }
    // A grid; the first column is wider and the last may stay empty to write in.
    fun table(title: String, columns: List<String>, rows: List<List<String>>, totals: List<String>?, weights: List<Float>) {
        val rowHeight = 18f
        val total = weights.sum()
        val xs = weights.runningFold(0f) { sum, w -> sum + room * w / total }
        fun row(cells: List<String>, bolded: Boolean, numbers: Boolean) {
            val c = space(rowHeight)
            cells.forEachIndexed { i, cell ->
                val right = numbers && i > 0
                text(c, cell, margin + xs[i] + 3, xs[i + 1] - xs[i] - 6, y + 4, if (bolded) bold else if (right) mono else body, right)
            }
            xs.forEach { c.drawLine(margin + it, y, margin + it, y + rowHeight, stroke) }
            c.drawLine(margin, y + rowHeight, margin + room, y + rowHeight, stroke)
            y += rowHeight
        }
        fun header() {
            space(rowHeight).drawLine(margin, y, margin + room, y, stroke)
            row(columns, true, false)
        }
        space(rowHeight * 3 + 20)
        if (title.isNotEmpty()) {
            text(page!!.canvas, title, margin, room, y, heading)
            y += 16
        }
        header()
        rows.forEach { r ->
            // A new page repeats the header.
            if (y + rowHeight > height - margin - footer) {
                space(Float.MAX_VALUE)
                header()
            }
            row(r, false, true)
        }
        totals?.let { row(it, true, true) }
        y += 10
    }

    space(0f)
    text(page!!.canvas, log.title, margin, room, y, TextPaint(heading).apply { textSize = 16f })
    y += 26
    table("", log.columns, log.rows, log.totals, listOf(2.4f) + List(log.columns.size - 2) { 1f } + listOf(1.8f))

    // Summary, fuel and weights side by side as name and value lines.
    val blocks = listOfNotNull(log.summary, log.fuel, log.weights)
    val gap = 20f
    val column = (room - gap * (blocks.size - 1)) / blocks.size
    val tallest = blocks.maxOf { it.lines.size }
    val canvas = space(tallest * 14f + 30)
    blocks.forEachIndexed { b, block ->
        val x = margin + b * (column + gap)
        text(canvas, block.title, x, column, y, heading)
        block.lines.forEachIndexed { i, line ->
            val top = y + 16 + i * 14
            text(canvas, line.title, x, column / 2.5f, top, body)
            text(canvas, line.value.orEmpty(), x + column / 2.5f, column * 0.6f, top, bold, right = true)
        }
    }
    y += tallest * 14f + 26

    table(log.frequencies.title, log.frequencies.columns, log.frequencies.rows, null, listOf(1.4f, 2f, 2f))

    val boxes = space(70f)
    text(boxes, log.boxesTitle, margin, room, y, heading)
    y += 18
    val box = room / log.boxes.size
    log.boxes.forEachIndexed { i, label ->
        val left = margin + i * box
        boxes.drawRect(left, y, left + box - 10, y + 40, stroke)
        text(boxes, label, left + 4, box - 18, y + 3, body)
    }
    page?.let(doc::finishPage)
    val file = File(File(context.cacheDir, "brief").apply { mkdirs() }, log.fileName)
    file.outputStream().use(doc::writeTo)
    doc.close()
    return file
}

// The share sheet for the PDF, as the brief offers its own.
fun shareNavlog(context: Context, file: File, label: String) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    val send = Intent(Intent.ACTION_SEND).setType("application/pdf").putExtra(Intent.EXTRA_STREAM, uri)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, label).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}
