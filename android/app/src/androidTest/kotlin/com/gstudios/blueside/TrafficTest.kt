package com.gstudios.blueside

import android.content.Intent
import android.graphics.RectF
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.concurrent.thread

// A receiver on the device's own network sends GDL 90; the targets reach the map and the receiver reaches Settings.
@RunWith(AndroidJUnit4::class)
class TrafficTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var model: AppModel

    // A permission prompt would cover the app.
    @Before fun grant() {
        for (p in listOf("ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION")) {
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, "android.permission.$p")
        }
    }

    @After fun close() {
        if (::scenario.isInitialized) scenario.close()
    }

    // One second of tools/gdl90sim.py near KBHM: heartbeat with GPS, device ID, ownship at 3,500 ft and four
    // targets, one 1.2 nm away and 300 ft above.
    private val datagram = (
        "7e00810100000000bc9c7e7e650001ffffffffffffffff53696d2047444c20426c7565736964652053696d2020202000000001f74d7e" +
        "7e0a00c0ffee17ea13c24f020b498906400040014e314253202020200075047e7e0b02bc000acef07e7e1400a1b2c317e841c252cb0c" +
        "098906eff5ce014e313233414220200042637e7e1400a2b3c417f496c2564c0d898908c00040014e3435364344202000d1957e7e1400" +
        "a3b4c517dc6cc2329b05c9890dc0125c01535741313233342000f2737e7e1400a4b5c6180af2c2480c16898912c000c00144414c3838" +
        "202020007c927e"
        ).chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun receiverTrafficReachesTheMapAndSettings() {
        val port = 4321
        val intent = Intent(context, MainActivity::class.java).putExtra("reset", "1").putExtra("offline", "1")
            .putExtra("center", "33.6296,-86.7535").putExtra("zoom", "10").putExtra("gdl90Port", "$port")
        scenario = ActivityScenario.launch(intent)
        scenario.onActivity { model = ViewModelProvider(it)[AppModel::class.java] }
        val sender = thread {
            DatagramSocket().use { socket ->
                repeat(15) {
                    socket.send(DatagramPacket(datagram, datagram.size, InetAddress.getLoopbackAddress(), port))
                    Thread.sleep(1000)
                }
            }
        }
        compose.waitUntil(15_000) { model.traffic?.batch?.count == 4 }
        // The first batch can come before any fix; the next one measures from the receiver's own.
        compose.waitUntil(5_000) { model.traffic?.batch?.alerts == 1 }
        compose.waitUntil(5_000) { compose.onAllNodes(hasContentDescription("ADS-B receiver connected")).fetchSemanticsNodes().isNotEmpty() }
        // The receiver's GPS places the aircraft.
        compose.waitUntil(5_000) { model.currentFix?.latitude?.let { it > 33.62 } == true }

        val map = mapOf(mapView())
        compose.waitUntil(10_000) {
            var drawn = 0
            instrumentation.runOnMainSync {
                drawn = map.queryRenderedFeatures(RectF(0f, 0f, 4000f, 4000f), "traffic").size
            }
            drawn == 4
        }
        compose.onNodeWithContentDescription("Settings").performClick()
        compose.onNodeWithText("Devices").performClick()
        compose.waitUntil(5_000) { compose.onAllNodes(androidx.compose.ui.test.hasText("Blueside Sim")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Valid").assertExists()
        sender.join()
    }

    private fun mapView(): MapView {
        var found: MapView? = null
        instrumentation.runOnMainSync {
            scenario.onActivity { activity ->
                fun walk(v: View) {
                    if (v is MapView) found = v else if (v is ViewGroup) (0 until v.childCount).forEach { walk(v.getChildAt(it)) }
                }
                walk(activity.window.decorView)
            }
        }
        return found!!
    }

    private fun mapOf(view: MapView): MapLibreMap {
        var map: MapLibreMap? = null
        compose.waitUntil(30_000) {
            instrumentation.runOnMainSync { view.getMapAsync { map = it } }
            map?.style?.isFullyLoaded == true
        }
        return map!!
    }
}
