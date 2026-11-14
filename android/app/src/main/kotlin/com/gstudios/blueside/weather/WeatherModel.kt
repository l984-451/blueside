package com.gstudios.blueside.weather

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.gstudios.blueside.Brief
import com.gstudios.blueside.Navlog
import com.gstudios.blueside.Core
import com.gstudios.blueside.CoreCall
import com.gstudios.blueside.CoreException
import com.gstudios.blueside.PlanArgs
import com.gstudios.blueside.PlanView
import com.gstudios.blueside.WeatherCatalog
import com.gstudios.blueside.WxFetch
import com.gstudios.blueside.WxFrameArgs
import com.gstudios.blueside.WxIndexArgs
import com.gstudios.blueside.WxKept
import com.gstudios.blueside.WxLayers
import com.gstudios.blueside.WxLoopFrame
import com.gstudios.blueside.WxLoopPlay
import com.gstudios.blueside.WxLoopStart
import com.gstudios.blueside.WxNotices
import com.gstudios.blueside.WxNow
import com.gstudios.blueside.WxPlan
import com.gstudios.blueside.WxReply
import com.gstudios.blueside.WxShowArgs
import com.gstudios.blueside.WxSourceArgs
import com.gstudios.blueside.WxStation
import com.gstudios.blueside.WxStationArgs
import com.gstudios.blueside.WxTfr
import com.gstudios.blueside.handleCall
import com.gstudios.blueside.request
import com.gstudios.blueside.weatherCatalog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import javax.net.ssl.SSLException

// The weather folder and its fetches. Kotlin only makes requests and keeps reply bodies; the core decides.
class WeatherModel(private val context: Context, private val server: String?) {
    val catalog: WeatherCatalog = weatherCatalog()
    private val prefs = context.getSharedPreferences("blueside", Context.MODE_PRIVATE)
    // Weather is fetched again in seconds, so it stays out of backups.
    private val root = File(context.noBackupFilesDir, "Weather")
    private val call: CoreCall by lazy { handleCall(Core.open("weather", root.path)) }
    private val lock = Mutex()
    private val passLock = Mutex()

    // Goes up after each pass, so what is drawn is asked for again.
    var passes by mutableIntStateOf(0)
        private set
    var notices by mutableStateOf(WxNotices())
        private set
    var show by mutableStateOf(prefs.getString(catalog.showKey, null) ?: catalog.shows.first().id)
        private set

    // The winds aloft level the pilot picked, null until one is; the core picks the default.
    var windsChoice by mutableStateOf(if (prefs.contains(catalog.windsLevelKey)) prefs.getInt(catalog.windsLevelKey, 0) else null)
        private set
    // The level drawn now, as the core last said.
    var windsLevel by mutableIntStateOf(catalog.windsLevels.first().ft)
        private set

    fun chooseLevel(ft: Int) {
        windsChoice = ft
        prefs.edit().putInt(catalog.windsLevelKey, ft).apply()
    }

    fun choose(show: String) {
        this.show = show
        prefs.edit().putString(catalog.showKey, show).apply()
    }

    // Saved switches under the same keys iOS uses.
    fun restore(into: MutableMap<String, Boolean>) {
        for (id in catalog.saved) if (prefs.contains("overlay-$id")) into[id] = prefs.getBoolean("overlay-$id", false)
    }

    fun save(on: Map<String, Boolean>) {
        prefs.edit().apply { for (id in catalog.saved) on[id]?.let { putBoolean("overlay-$id", it) } }.apply()
    }

    private suspend inline fun <reified A, reified R> op(name: String, args: A): R =
        withContext(Dispatchers.IO) { lock.withLock { call.request(name, args) } }

    suspend fun tick(on: List<String>, now: Long, cruiseFt: Int?) {
        val next = runCatching { op<WxShowArgs, WxNotices>("notices", WxShowArgs(now, on, show, windsChoice, cruiseFt)) }.getOrNull() ?: return
        if (next != notices) notices = next
    }

    // Notices with no drawn area, listed under the TFR switch.
    var tfrsWithoutArea by mutableStateOf(emptyList<WxTfr>())
        private set

    suspend fun layers(on: List<String>, now: Long, cruiseFt: Int?): WxLayers? =
        runCatching { op<WxShowArgs, WxLayers>("layers", WxShowArgs(now, on, show, windsChoice, cruiseFt)) }.getOrNull()
            ?.also {
                if (it.tfrsWithoutArea != tfrsWithoutArea) tfrsWithoutArea = it.tfrsWithoutArea
                windsLevel = it.windsLevel
            }

    suspend fun planView(args: PlanArgs): PlanView? = runCatching { op<PlanArgs, PlanView>("planView", args) }.getOrNull()

    suspend fun navlog(args: PlanArgs): Navlog? = runCatching { op<PlanArgs, Navlog>("navlog", args) }.getOrNull()

    suspend fun brief(args: PlanArgs): Brief? = runCatching { op<PlanArgs, Brief>("flightBrief", args) }.getOrNull()

    suspend fun station(ident: String, icao: String?): WxStation =
        runCatching { op<WxStationArgs, WxStation>("station", WxStationArgs(ident, icao)) }.getOrDefault(WxStation())

    // One pass, cut off at the pass limit. A pass already running is not doubled. A reply the core cannot take
    // ends the pass; what it did not bring in then reads as not current.
    suspend fun refresh() {
        if (!passLock.tryLock()) return
        try {
            withTimeoutOrNull((catalog.passLimitSeconds * 1000).toLong()) { pass() }
        } catch (e: CoreException) {
            Log.w("Blueside", "weather pass failed", e)
        } finally {
            passes++
            passLock.unlock()
        }
    }

    private suspend fun pass() {
        val base = server ?: return
        val plan = op<WxIndexArgs, WxPlan>("index", WxIndexArgs(get("$base/${catalog.indexPath}", null), System.currentTimeMillis()))
        // All files at once, so a slow or broken one never holds up another.
        coroutineScope {
            plan.jobs.map { job ->
                async { op<WxSourceArgs, JsonObject>("source", WxSourceArgs(job.source, get("$base/${job.path}", job.etag))) }
            }.awaitAll()
        }
        // One failed picture ends the pass, so a dead link costs one timeout.
        for (frame: WxFetch in plan.frames) {
            if (!op<WxFrameArgs, WxKept>("frame", WxFrameArgs(frame.path, get("$base/${frame.path}", null))).kept) break
        }
    }

    // The radar loop the clock plays on request: the words it shows, and while playing the pictures and the one up.
    data class LoopShow(val text: String, val frames: List<WxLoopFrame> = emptyList(), val showing: Int = 0)

    var loop by mutableStateOf<LoopShow?>(null)
        private set
    private var looping: Job? = null

    fun toggleLoop(scope: CoroutineScope) {
        if (looping != null) return stopLoop(scope)
        looping = scope.launch {
            runCatching {
                val base = server ?: return@runCatching
                val start = op<WxNow, WxLoopStart>("loopStart", WxNow(System.currentTimeMillis()))
                for (f in start.fetch ?: return@runCatching) {
                    loop = LoopShow(f.loading)
                    if (!op<WxFrameArgs, WxKept>("loopFrame", WxFrameArgs(f.path, get("$base/${f.path}", null))).kept) break
                }
                while (true) {
                    val frames = op<WxNow, WxLoopPlay>("loopPlay", WxNow(System.currentTimeMillis())).frames
                    if (frames.isEmpty()) break
                    frames.forEachIndexed { i, f ->
                        loop = LoopShow(f.clock, frames, i)
                        delay((f.seconds * 1000).toLong())
                    }
                }
            }
            if (isActive) stopLoop(scope)
        }
    }

    // Back to the newest picture; the loop's downloads are deleted.
    fun stopLoop(scope: CoroutineScope) {
        val job = looping ?: return
        looping = null
        loop = null
        job.cancel()
        scope.launch { runCatching { op<JsonObject, JsonObject>("loopStop", JsonObject(emptyMap())) } }
    }

    // A conditional GET with the body saved to a file the core reads and deletes. No file to save to fails the reply.
    private suspend fun get(url: String, etag: String?): WxReply = withContext(Dispatchers.IO) {
        val out = runCatching { File.createTempFile("weather", null, context.cacheDir) }.getOrNull()
            ?: return@withContext WxReply(failed = "other")
        try {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 20_000
            connection.readTimeout = 20_000
            connection.useCaches = false
            etag?.let { connection.setRequestProperty("If-None-Match", it) }
            try {
                val status = connection.responseCode
                if (status == 200) connection.inputStream.use { input -> out.outputStream().use { input.copyTo(it) } }
                WxReply(status, out.path, connection.getHeaderField("ETag"))
            } finally {
                connection.disconnect()
            }
        } catch (e: Exception) {
            out.delete()
            WxReply(failed = when (e) {
                is UnknownHostException -> "offline"
                is SocketTimeoutException -> "timeout"
                is SSLException -> "tls"
                else -> "other"
            })
        }
    }
}
