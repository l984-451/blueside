package com.gstudios.blueside.map

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

// A style that changes only in paint repaints in place; any other change loads the style again.
class PaintChangesTest {
    private fun style(ground: String, pack: String = "a.pmtiles", ink: String = "\"line-color\":\"#1557b0\"") =
        """{"version":8,"sources":{"s":{"type":"raster","url":"$pack"}},"layers":[
            {"id":"background","type":"background","paint":{"background-color":"$ground"}},
            {"id":"s","type":"raster","source":"s","paint":{"raster-brightness-max":1}},
            {"id":"airway","type":"line","source":"s","paint":{$ink}}]}"""

    @Test
    fun nightRepaintsOnlyWhatChanged() {
        val changes = paintChanges(style("#ffffff"), style("#1e1d1b", ink = "\"line-color\":\"#7fb0f2\""))!!
        assertEquals(listOf("background" to "background-color", "airway" to "line-color"), changes.map { it.first to it.second.name })
        assertEquals(listOf("#1e1d1b", "#7fb0f2"), changes.map { it.second.value })
    }

    @Test
    fun anythingButPaintLoadsAgain() {
        assertNull(paintChanges(style("#ffffff"), style("#ffffff", pack = "b.pmtiles")))
        assertNull(paintChanges(style("#ffffff"), style("#ffffff", ink = "\"line-color\":\"#1557b0\",\"line-width\":2")))
    }

    @Test
    fun aChangedArrayThatIsNotAnExpressionLoadsAgain() {
        val dashed = { gap: Int -> "\"line-color\":\"#1557b0\",\"line-dasharray\":[2,$gap]" }
        assertNull(paintChanges(style("#ffffff", ink = dashed(1)), style("#ffffff", ink = dashed(2))))
    }
}
