package com.gstudios.blueside

import android.content.Intent
import android.graphics.Bitmap
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

// Real input on the full-screen chart. No Compose test rule here: its test clock holds pointer coroutines,
// which breaks the double tap timing.
@RunWith(AndroidJUnit4::class)
class PlateTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val automation = instrumentation.uiAutomation

    private fun waitFor(what: String, seconds: Int = 20, check: () -> Boolean) {
        val end = SystemClock.uptimeMillis() + seconds * 1000
        while (!check()) {
            assertTrue("timed out: $what", SystemClock.uptimeMillis() < end)
            SystemClock.sleep(200)
        }
    }

    private fun node(description: String): AccessibilityNodeInfo? {
        fun find(n: AccessibilityNodeInfo?): AccessibilityNodeInfo? = when {
            n == null -> null
            n.contentDescription?.toString() == description -> n
            else -> (0 until n.childCount).firstNotNullOfOrNull { find(n.getChild(it)) }
        }
        return find(automation.rootInActiveWindow)
    }

    private fun shot(): Bitmap {
        SystemClock.sleep(1000)
        return automation.takeScreenshot()
    }

    private fun changed(a: Bitmap, b: Bitmap): Double {
        val pa = IntArray(a.width * a.height).also { a.getPixels(it, 0, a.width, 0, 0, a.width, a.height) }
        val pb = IntArray(b.width * b.height).also { b.getPixels(it, 0, b.width, 0, 0, b.width, b.height) }
        return pa.indices.count { pa[it] != pb[it] }.toDouble() / pa.size
    }

    private fun taps(x: Float, y: Float, count: Int) {
        val start = SystemClock.uptimeMillis()
        for (tap in 0 until count) {
            val down = start + tap * 150
            for ((time, action) in listOf(down to MotionEvent.ACTION_DOWN, down + 50 to MotionEvent.ACTION_UP)) {
                SystemClock.sleep(maxOf(0, time - SystemClock.uptimeMillis()))
                val event = MotionEvent.obtain(down, time, action, x, y, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
                assertTrue(automation.injectInputEvent(event, true))
            }
        }
    }

    // Full screen opens the chart on the whole page; a double tap zooms in on the spot and another returns to the whole page.
    @Test fun doubleTapZoomsInAndBackToTheWholePage() {
        val context = instrumentation.targetContext
        for (p in listOf("ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION")) automation.grantRuntimePermission(context.packageName, "android.permission.$p")
        val intent = Intent(context, MainActivity::class.java).putExtra("reset", "1").putExtra("offline", "1")
            .putExtra("basePack", "nav").putExtra("plateOnMap", "AUS:00556IL18R.PDF").putExtra("show", "plate")
            .putExtra("center", "30.1945,-97.6699").putExtra("zoom", "9")
        ActivityScenario.launch<MainActivity>(intent).use {
            waitFor("full screen button") { node("Full Screen") != null }
            val button = android.graphics.Rect().also { node("Full Screen")!!.getBoundsInScreen(it) }
            taps(button.exactCenterX(), button.exactCenterY(), 1)
            // The full-screen window takes over, and its tree has no Full Screen button.
            waitFor("full-screen chart") { node("Close") != null && node("Full Screen") == null }
            val whole = shot()
            val (x, y) = whole.width / 2f to whole.height / 2f
            taps(x, y, 2)
            val zoomed = shot()
            assertTrue("double tap did not zoom", changed(whole, zoomed) > 0.1)
            taps(x, y, 2)
            val back = shot()
            assertTrue("second double tap did not return to the whole page", changed(whole, back) < 0.01)
        }
    }
}
