package com.gstudios.blueside

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.PointF
import android.graphics.RectF
import android.net.Uri
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Collections
import kotlin.concurrent.thread
import kotlin.math.cos
import kotlin.math.sin

// The whole app on a device, driving the flows a person does by hand: touches go straight to the map view.
@RunWith(AndroidJUnit4::class)
class FlowTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var model: AppModel
    private val monitors = mutableListOf<Instrumentation.ActivityMonitor>()

    @Before fun grant() {
        for (p in listOf("ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION")) {
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, "android.permission.$p")
        }
    }

    @After fun close() {
        monitors.forEach(instrumentation::removeMonitor)
        if (::scenario.isInitialized) scenario.close()
    }

    private fun launch(vararg extras: Pair<String, String>) {
        val intent = Intent(context, MainActivity::class.java).putExtra("reset", "1")
        extras.forEach { (k, v) -> intent.putExtra(k, v) }
        scenario = ActivityScenario.launch(intent)
        scenario.onActivity { model = ViewModelProvider(it)[AppModel::class.java] }
    }

    private fun <T> main(block: () -> T): T {
        var out: T? = null
        instrumentation.runOnMainSync { out = block() }
        @Suppress("UNCHECKED_CAST") return out as T
    }

    private fun mapView(): MapView = main {
        var found: MapView? = null
        scenario.onActivity { activity ->
            fun walk(v: View) {
                if (v is MapView) found = v else if (v is ViewGroup) (0 until v.childCount).forEach { walk(v.getChildAt(it)) }
            }
            walk(activity.window.decorView)
        }
        found!!
    }

    private fun mapOf(view: MapView): MapLibreMap {
        var map: MapLibreMap? = null
        compose.waitUntil(30_000) { main { view.getMapAsync { map = it } }; map?.style?.isFullyLoaded == true }
        return map!!
    }

    // Raw touches on the map view, as the screen would send them.
    private fun touch(view: MapView, down: Long, action: Int, vararg at: PointF) {
        val props = at.indices.map { MotionEvent.PointerProperties().apply { id = it; toolType = MotionEvent.TOOL_TYPE_FINGER } }
        val coords = at.map { MotionEvent.PointerCoords().apply { x = it.x; y = it.y; pressure = 1f; size = 1f } }
        val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, at.size, props.toTypedArray(),
            coords.toTypedArray(), 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
        instrumentation.runOnMainSync { view.dispatchTouchEvent(event) }
        event.recycle()
    }

    private fun screenTap(x: Float, y: Float) {
        val down = SystemClock.uptimeMillis()
        for ((time, action) in listOf(down to MotionEvent.ACTION_DOWN, down + 60 to MotionEvent.ACTION_UP)) {
            SystemClock.sleep(maxOf(0, time - SystemClock.uptimeMillis()))
            val event = MotionEvent.obtain(down, time, action, x, y, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            assertTrue(instrumentation.uiAutomation.injectInputEvent(event, true))
        }
    }

    private val austin = arrayOf("offline" to "1", "basePack" to "nav")

    // Hold the route line, drag it near Centex VORTAC but outside its pick box, let go: the core adds a plain
    // point and offers the nearby places; Use instead swaps the point for the VORTAC.
    @Test fun bendingTheRouteLineOffersNearbyPlacesToUseInstead() {
        launch(*austin, "center" to "30.25,-97.62", "zoom" to "10", "navRoute" to "KAUS SAT")
        compose.waitUntil(30_000) { model.route.view?.line != null }
        val view = mapView()
        val map = mapOf(view)
        val density = context.resources.displayMetrics.density
        val cwk = LatLng(30.37855, -97.52984722)
        val box = model.nav.labels.pickBox.toFloat() * density / 2
        fun near(p: PointF) = map.queryRenderedFeatures(RectF(p.x - box, p.y - box, p.x + box, p.y + box), *model.nav.labels.pickLayers.toTypedArray())
        compose.waitUntil(30_000) { main { near(map.projection.toScreenLocation(cwk)).any { it.getStringProperty("ident") == "CWK" } } }
        val (from, drop) = main {
            val ends = model.route.view!!.line!!.points.map { map.projection.toScreenLocation(LatLng(it.latitude, it.longitude)) }
            // A third of the way along the first leg, clear of the waypoint dots.
            val from = PointF(ends[0].x + (ends[1].x - ends[0].x) / 3, ends[0].y + (ends[1].y - ends[0].y) / 3)
            val c = map.projection.toScreenLocation(cwk)
            val drop = (0 until 8).map { i -> PointF(c.x + 60 * density * cos(i * Math.PI / 4).toFloat(), c.y + 60 * density * sin(i * Math.PI / 4).toFloat()) }
                .first { near(it).isEmpty() }
            from to drop
        }
        val down = SystemClock.uptimeMillis()
        touch(view, down, MotionEvent.ACTION_DOWN, from)
        Thread.sleep(1200)
        for (step in 1..10) {
            touch(view, down, MotionEvent.ACTION_MOVE, PointF(from.x + (drop.x - from.x) * step / 10, from.y + (drop.y - from.y) * step / 10))
            Thread.sleep(30)
        }
        touch(view, down, MotionEvent.ACTION_UP, drop)
        compose.waitUntil(10_000) { model.route.offer != null }
        assertEquals(3, model.route.view?.line?.points?.size)
        compose.onNodeWithText(model.route.labels.useInstead).assertExists()
        val offered = model.route.offer!!.offer.places.map { it.row.title }
        assertTrue("offered $offered", "CWK" in offered)
        // A real tap on the screen, so a card hidden under another panel fails here.
        val button = compose.onNode(hasClickAction() and hasText("CWK", substring = true)).fetchSemanticsNode()
        screenTap(button.positionOnScreen.x + button.size.width / 2f, button.positionOnScreen.y + button.size.height / 2f)
        compose.waitUntil(10_000) { model.route.view?.text == "KAUS CWK SAT" }
        compose.onNodeWithText(model.route.labels.useInstead).assertDoesNotExist()
    }

    // A tapped airport moves clear of the pane or sheet and is ringed; closing the panel takes the ring away.
    @Test fun tappedAirportMovesClearOfThePanelAndIsRinged() {
        launch(*austin, "center" to "30.1945,-97.6699", "zoom" to "11")
        val view = mapView()
        val map = mapOf(view)
        val kaus = LatLng(30.1945, -97.6699)
        compose.waitUntil(30_000) {
            main { map.queryRenderedFeatures(map.projection.toScreenLocation(kaus), *model.nav.labels.pickLayers.toTypedArray()).isNotEmpty() }
        }
        compose.waitUntil(30_000) { main { model.nav.open } }
        val p = main { map.projection.toScreenLocation(kaus) }
        val down = SystemClock.uptimeMillis()
        touch(view, down, MotionEvent.ACTION_DOWN, p)
        touch(view, down, MotionEvent.ACTION_UP, p)
        compose.waitUntil(10_000) { main { model.shownPlace } != null }
        val place = main { model.shownPlace }!!
        // Settled in the middle 60 percent of the part of the map no pane, sheet or strip covers.
        compose.waitUntil(5_000) {
            main {
                val p = map.projection.toScreenLocation(LatLng(place.latitude, place.longitude))
                val (left, top) = model.paneRight to model.stripBottom
                val bottom = model.sheetTop ?: view.height.toFloat()
                val (w, h) = view.width - left to bottom - top
                p.x in left + w * 0.2f..left + w * 0.8f && p.y in top + h * 0.2f..top + h * 0.8f &&
                    map.queryRenderedFeatures(RectF(p.x - 30, p.y - 30, p.x + 30, p.y + 30), "place-ring").isNotEmpty()
            }
        }
        InstrumentationRegistry.getArguments().getString("shot")?.let { name ->
            SystemClock.sleep(1500)
            // Taken as the shell, so the file outlives the app's uninstall: adb pull /data/local/tmp/<name>.png
            instrumentation.uiAutomation.executeShellCommand("screencap -p /data/local/tmp/$name.png").close()
            SystemClock.sleep(2000)
        }
        main { model.panelClosed() }
        compose.waitUntil(5_000) { main { map.style?.getSourceAs<org.maplibre.android.style.sources.GeoJsonSource>("place-ring")
            ?.querySourceFeatures(null)?.isEmpty() } == true }
    }

    // Two fingers held still measure between them; lifting one ends it.
    @Test fun twoFingersHeldMeasureDistanceAndBearing() {
        launch(*austin, "center" to "30.1945,-97.6699", "zoom" to "9")
        val view = mapView()
        mapOf(view)
        val a = PointF(view.width * 0.3f, view.height * 0.4f)
        val b = PointF(view.width * 0.7f, view.height * 0.6f)
        val measured = hasText(" NM · ", substring = true)
        val down = SystemClock.uptimeMillis()
        touch(view, down, MotionEvent.ACTION_DOWN, a)
        touch(view, down, MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), a, b)
        Thread.sleep(800)
        compose.waitUntil(5_000) { compose.onAllNodes(measured).fetchSemanticsNodes().isNotEmpty() }
        // The figure follows the fingers.
        fun shown() = compose.onNode(measured).fetchSemanticsNode().config.getOrNull(SemanticsProperties.Text)?.joinToString()
        val before = shown()
        touch(view, down, MotionEvent.ACTION_MOVE, a, PointF(b.x, b.y + 200))
        compose.waitUntil(5_000) { shown() != before }
        touch(view, down, MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), a, PointF(b.x, b.y + 200))
        touch(view, down, MotionEvent.ACTION_UP, a)
        compose.waitUntil(5_000) { compose.onAllNodes(measured).fetchSemanticsNodes().isEmpty() }
    }

    // The brief builds in the background, shows its hazards, map and profile, then opens again at once from the kept copy.
    @Test fun briefShowsItsGraphics() {
        launch(*austin, "show" to "route", "navRoute" to "KAUS CWK SAT")
        compose.waitUntil(30_000) { model.route.view?.line != null }
        val title = model.route.labels.briefTitle
        val button = hasText(title) and hasClickAction()
        compose.waitUntil(30_000) { compose.onAllNodes(button).fetchSemanticsNodes().isNotEmpty() }
        compose.onNode(button).performScrollTo().performClick()
        compose.waitUntil(30_000) { compose.onAllNodes(hasTestTag("brief-hazards")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNode(hasTestTag("brief-map")).assertExists()
        compose.waitUntil(60_000) { compose.onAllNodes(hasTestTag("brief-share")).fetchSemanticsNodes().isNotEmpty() }
        fun shot(name: String) {
            // Taken as the shell, so the file outlives the app's uninstall: adb pull /data/local/tmp/<name>.png
            SystemClock.sleep(1000)
            instrumentation.uiAutomation.executeShellCommand("screencap -p /data/local/tmp/$name.png").close()
            SystemClock.sleep(1500)
        }
        shot("brief-top")
        compose.onNode(hasTestTag("brief-page")).performScrollToNode(hasTestTag("brief-profile"))
        compose.onNode(hasTestTag("brief-profile")).assertExists()
        shot("brief-profile")
        compose.onAllNodesWithContentDescription("Close").onLast().performClick()
        compose.onNode(button).performScrollTo().performClick()
        compose.waitUntil(3_000) { compose.onAllNodes(hasTestTag("brief-share")).fetchSemanticsNodes().isNotEmpty() }
    }

    // A local weather server with four radar pictures: Play fetches the older three and runs the loop; Stop ends it.
    @Test fun radarLoopPlaysAndStops() {
        val pack = context.assets.open("test-ifr-low.pmtiles").use { it.readBytes() }
        val now = Instant.now().truncatedTo(ChronoUnit.SECONDS)
        val stamp = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss").withZone(ZoneOffset.UTC)
        val frames = listOf(15L, 10L, 5L, 1L).map { now.minus(it, ChronoUnit.MINUTES) }
        val index = """{"version": 1, "checked_at": {"radar": "$now"}, "frames": [${
            frames.joinToString { """{"valid": "$it", "path": "wx/radar/${stamp.format(it)}.pmtiles"}""" }
        }]}"""
        val asked = Collections.synchronizedList(mutableListOf<String>())
        val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val socket = runCatching { server.accept() }.getOrNull() ?: break
                socket.use { s ->
                    val reader = s.getInputStream().bufferedReader()
                    val path = reader.readLine()?.split(" ")?.getOrNull(1).orEmpty()
                    while (reader.readLine()?.isNotEmpty() == true) {}
                    asked.add(path)
                    val body = when {
                        path == "/wx/index.json" -> index.toByteArray()
                        path.startsWith("/wx/radar/") -> pack
                        else -> null
                    }
                    val head = if (body == null) "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" else "HTTP/1.1 200 OK\r\nContent-Length: ${body.size}\r\n"
                    s.getOutputStream().apply { write("${head}Connection: close\r\n\r\n".toByteArray()); body?.let(::write); flush() }
                }
            }
        }
        try {
            launch("manifestBase" to "http://127.0.0.1:${server.localPort}", "overlaysOn" to "weather-radar",
                "center" to "30.1945,-97.6699", "zoom" to "7")
            compose.waitUntil(30_000) { compose.onAllNodes(hasContentDescription("Play radar loop")).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Play radar loop").performClick()
            compose.waitUntil(30_000) { model.weather.loop?.frames?.size == 4 }
            compose.onNodeWithContentDescription("Stop radar loop").assertExists()
            assertEquals(4, asked.count { it.startsWith("/wx/radar/") })
            compose.onNodeWithContentDescription("Stop radar loop").performClick()
            compose.waitUntil(5_000) { model.weather.loop == null }
            compose.onNodeWithContentDescription("Play radar loop").assertExists()
        } finally {
            server.close()
        }
    }

    // Starts the next activity of this kind as answered, keeping the intent asked for.
    private fun answer(action: String, result: Instrumentation.ActivityResult?): MutableList<Intent> {
        val seen = mutableListOf<Intent>()
        val monitor = object : Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? =
                if (intent.action == action) { seen.add(intent); result ?: Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null) } else null
        }
        instrumentation.addMonitor(monitor)
        monitors.add(monitor)
        return seen
    }

    // Export hands the share sheet a file; importing that file brings the aircraft back, and again asks Replace or Keep both.
    @Test fun aircraftExportImportRoundTrip() {
        File(context.filesDir, "aircraft.json").delete()
        launch("offline" to "1")
        val labels = model.aircraft.labels
        val tail = "N451BS"
        main {
            val template = model.aircraft.list.templates.first().profile
            assertTrue(model.aircraft.save(JsonObject(template + mapOf("id" to JsonPrimitive(java.util.UUID.randomUUID().toString()), "tail" to JsonPrimitive(tail)))).isEmpty())
            model.settingsOpen = true
        }
        compose.onNodeWithText("Aircraft").performClick()
        compose.onNodeWithText(tail).performClick()
        val shared = answer(Intent.ACTION_CHOOSER, null)
        compose.onAllNodes(hasScrollToNodeAction()).onLast().performScrollToNode(hasText(labels.export))
        compose.onNodeWithText(labels.export).performClick()
        compose.waitUntil(5_000) { shared.isNotEmpty() }
        @Suppress("DEPRECATION")
        val uri = shared[0].getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)!!
        val text = context.contentResolver.openInputStream(uri)!!.use { it.readBytes().decodeToString() }
        assertTrue(text.contains(tail))

        compose.onNodeWithText(labels.delete).performClick()
        compose.waitUntil(5_000) { model.aircraft.list.aircraft.isEmpty() }
        compose.onNodeWithText(labels.empty).assertExists()

        answer(Intent.ACTION_OPEN_DOCUMENT, Instrumentation.ActivityResult(Activity.RESULT_OK, Intent().setData(uri)))
        compose.onNodeWithText(labels.importFile).performClick()
        compose.waitUntil(5_000) { model.aircraft.list.aircraft.size == 1 }
        compose.onNodeWithText(tail).assertExists()

        compose.onNodeWithText(labels.importFile).performClick()
        compose.onNodeWithText(labels.conflict).assertExists()
        compose.onNodeWithText(labels.keepBoth).performClick()
        compose.waitUntil(5_000) { model.aircraft.list.aircraft.size == 2 }
        assertEquals(2, compose.onAllNodesWithText(tail).fetchSemanticsNodes().size)
    }
}
