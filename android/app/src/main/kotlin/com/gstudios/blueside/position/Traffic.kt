package com.gstudios.blueside.position

import android.content.Context
import android.net.wifi.WifiManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.gstudios.blueside.Core
import com.gstudios.blueside.CoreCall
import com.gstudios.blueside.Fix
import com.gstudios.blueside.coreJson
import com.gstudios.blueside.decodeResult
import com.gstudios.blueside.request
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress

@Serializable data class TrafficCatalog(val sources: List<Source>, val sourceKey: String, val port: Int, val notListening: String) {
    @Serializable data class Source(val id: String, val title: String)
}

@Serializable data class TrafficBatch(
    val shapes: String,
    val count: Int,
    val alerts: Int,
    val status: Status,
    val receiver: Fix? = null,
    val next: Double? = null,
) {
    @Serializable data class Status(
        val name: String? = null,
        val connected: Boolean,
        val heard: Boolean,
        val gpsValid: Boolean,
        val lastMessage: String,
        val lastMessageNext: Double? = null,
        val lastMessageAt: Long? = null,
    )
}

@Serializable data class TrafficBatchArgs(val reference: Fix?, val now: Long)

@Serializable data class ChooseFixArgs(val source: String, val device: Fix?, val receiver: Fix?, val now: Long)

fun trafficCatalog(call: CoreCall = Core::call): TrafficCatalog = decodeResult(call("trafficCatalog", ByteArray(0)))

// "receiver", "device" or "none": which fix the map uses.
fun chooseFix(args: ChooseFixArgs, call: CoreCall = Core::call): String =
    call.request<ChooseFixArgs, Map<String, String>>("chooseFix", args).getValue("use")

// heard is when the receiver last sent anything; lastFast goes back as the last result gave it.
@Serializable data class BackgroundArgs(val fix: Fix?, val lastFast: Long?, val heard: Long?, val now: Long)

@Serializable data class BackgroundResult(val until: Long? = null, val lastFast: Long? = null)

// Until when the app keeps running out of the front; null or past lets it sleep.
fun background(args: BackgroundArgs, call: CoreCall = Core::call): BackgroundResult = call.request("background", args)

// GDL 90 from an ADS-B receiver on UDP. Datagrams go to the core as they come; the map gets at most one batch
// a second, and with no new data one more only when the core says something ages out.
class TrafficReceiver(
    private val context: Context,
    private val scope: CoroutineScope,
    private val port: Int,
    private val reference: () -> Fix?,
    private val onBatch: (TrafficBatch) -> Unit,
) {
    var batch by mutableStateOf<TrafficBatch?>(null)
        private set
    // True while the socket is bound.
    var socketOpen by mutableStateOf(false)
        private set

    private val handle = Core.open("traffic", "")
    private val arrived = Channel<Unit>(Channel.CONFLATED)
    private var listening: Job? = null
    // The open socket, which stop() closes to end a blocking receive. Guarded by sockets.
    private var socket: DatagramSocket? = null
    private val sockets = Any()

    init {
        scope.launch { batches() }
    }

    // The session is touched from the socket thread and the batch thread.
    private fun call(op: String, args: ByteArray) = synchronized(this) { Core.callHandle(handle, op, args) }

    // Listens while the app is in front. A bind that fails, or a socket that drops, is tried again after a pause.
    fun start() {
        if (listening != null) return
        listening = scope.launch(Dispatchers.IO) {
            while (true) {
                listen { isActive }
                delay(RETRY_MS)
            }
        }
        // A batch now, so traffic that aged out while the device slept goes.
        arrived.trySend(Unit)
    }

    fun stop() {
        synchronized(sockets) {
            listening?.cancel()
            listening = null
            socket?.close()
        }
    }

    private fun listen(active: () -> Boolean) {
        // Many receivers broadcast; Wi-Fi drops broadcast frames to save power without this lock.
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
        val lock = wifi?.createMulticastLock("blueside-gdl90")?.apply { setReferenceCounted(false); acquire() }
        try {
            DatagramSocket(null).use { s ->
                // A stop that came first leaves this socket unused.
                synchronized(sockets) { if (!active()) return; socket = s }
                s.reuseAddress = true
                s.broadcast = true
                s.bind(InetSocketAddress(port))
                socketOpen = true
                val buffer = ByteArray(4096)
                while (true) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    s.receive(packet)
                    call("receive", buffer.copyOf(packet.length))
                    arrived.trySend(Unit)
                }
            }
        } catch (_: Exception) {
            // Port taken, socket closed, or stopped: start() tries again while the app is in front.
        } finally {
            socketOpen = false
            lock?.release()
        }
    }

    private suspend fun batches() {
        var last = 0L
        var next: Long? = null
        while (true) {
            val wait = next?.let { it - System.currentTimeMillis() }
            if (wait == null) arrived.receive() else withTimeoutOrNull(wait.coerceAtLeast(1)) { arrived.receive() }
            delay((last + 1000 - System.currentTimeMillis()).coerceAtLeast(0))
            val now = System.currentTimeMillis()
            last = now
            val args = coreJson.encodeToString(TrafficBatchArgs(reference(), now)).encodeToByteArray()
            val result = withContext(Dispatchers.Default) { runCatching { decodeResult<TrafficBatch>(call("batch", args)) }.getOrNull() }
                ?: continue
            next = result.next?.toLong()?.plus(1)
            batch = result
            onBatch(result)
        }
    }

    private companion object {
        const val RETRY_MS = 3_000L
    }
}
