package com.gstudios.blueside.route

import com.gstudios.blueside.RouteResult
import com.gstudios.blueside.decodeResult
import kotlinx.serialization.json.JsonNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

// A new fix leaves the route panel alone; only its live leaves read the active leg.
class StillRouteTest {
    private val direct = decodeResult<RouteResult>(
        checkNotNull(javaClass.classLoader?.getResourceAsStream("routeDirect.result.json")).readBytes())

    @Test
    fun aFixThatMovesOnlyTheActiveLegChangesNothingStill() {
        val editor = checkNotNull(direct.editor)
        val moved = direct.copy(rows = emptyList(), summary = null, editor = editor.copy(
            totals = editor.totals.map { it.copy(value = "1.0 NM") },
            points = editor.points.map { p -> p.leg?.takeIf { it.isActive }?.let { p.copy(leg = it.copy(distance = "1.0 NM", time = "0:01")) } ?: p },
        ))
        assertNotEquals(direct.editor, moved.editor)
        assertEquals(direct.still(), moved.still())
        assertNotEquals(direct.still(), direct.copy(planKey = JsonNull).still())
    }
}
