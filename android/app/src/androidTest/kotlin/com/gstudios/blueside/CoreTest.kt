package com.gstudios.blueside

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

// Runs the real native library on a device.
@RunWith(AndroidJUnit4::class)
class CoreTest {
    @Test
    fun distanceAustinToDallas() {
        assertEquals(165.436, distanceNM(Coordinate(30.1945, -97.6699), Coordinate(32.8968, -97.0380)), 0.01)
    }

    @Test
    fun countsCyclesInTheFixtureManifest() {
        val assets = InstrumentationRegistry.getInstrumentation().targetContext.assets
        assertEquals(2, manifestCycles(assets.open("manifest.json").readBytes()))
    }

    @Test
    fun reportsAnUnsupportedVersion() {
        val error = assertThrows(CoreException::class.java) {
            manifestCycles("""{"version": 2, "cycles": []}""".toByteArray())
        }
        assertEquals("unsupportedVersion(2)", error.message)
    }

    @Test
    fun searchesTheTestDatabase() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = java.io.File(context.cacheDir, "nav-test-search.sqlite")
        context.assets.open("nav-test.sqlite").use { input -> file.outputStream().use { input.copyTo(it) } }
        val handle = Core.open("nav", file.path)
        try {
            val page = navSearch(SearchArgs("AUS", emptyList(), now = System.currentTimeMillis()), handleCall(handle))
            assertEquals("KAUS", page.sections.first().items.first().row.title)
        } finally {
            Core.close(handle)
        }
    }

    @Test
    fun badHandlesFailCleanly() {
        assertEquals(0L, Core.open("nav", "/nonexistent.sqlite"))
        assertThrows(CoreException::class.java) { navMetadata { op, args -> Core.callHandle(0, op, args) } }
    }
}
