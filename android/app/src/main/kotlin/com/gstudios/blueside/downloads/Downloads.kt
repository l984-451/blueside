package com.gstudios.blueside.downloads

import android.app.DownloadManager
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.StatFs
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.gstudios.blueside.Changed
import com.gstudios.blueside.Configure
import com.gstudios.blueside.Core
import com.gstudios.blueside.CoreCall
import com.gstudios.blueside.ListFetched
import com.gstudios.blueside.Now
import com.gstudios.blueside.PackID
import com.gstudios.blueside.PassArgs
import com.gstudios.blueside.PassResult
import com.gstudios.blueside.Pending
import com.gstudios.blueside.RegionArgs
import com.gstudios.blueside.Rows
import com.gstudios.blueside.RowsArgs
import com.gstudios.blueside.SeedArgs
import com.gstudios.blueside.SeedFile
import com.gstudios.blueside.TransferEvent
import com.gstudios.blueside.coreJson
import com.gstudios.blueside.handleCall
import com.gstudios.blueside.request
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

// One pack store: the core's session decides, this class moves bytes through the system download service.
class PackStore(
    private val context: Context,
    val name: String,
    // The list's path under the server base, such as nav/manifest.json.
    private val list: String,
    private val base: String?,
    config: Configure,
    // The app's scope, whose failures are logged; the Downloads pages launch this store's work in it too.
    val scope: CoroutineScope,
    // Runs when a transfer is handed to the system.
    private val onStarted: () -> Unit,
    // Runs whenever the packs on disk may have changed.
    private val onInstalled: () -> Unit,
) {
    // App storage when shared storage is missing, so a path is never relative.
    val root: File = File(context.getExternalFilesDir(null) ?: context.filesDir, name).apply { mkdirs() }
    private val call: CoreCall = handleCall(Core.open("packs", root.path))
    private val lock = Mutex()
    private val manager = context.getSystemService(DownloadManager::class.java)
    private var changeover: Job? = null

    var rows by mutableStateOf(Rows(emptyList()))
        private set

    // The category page's Downloaded filter, kept for the session. All by default.
    var downloadedOnly by mutableStateOf(false)

    init {
        call.request<Configure, Map<String, String>>("configure", config)
    }

    private suspend inline fun <reified A, reified R> op(name: String, args: A): R =
        withContext(Dispatchers.IO) { lock.withLock { call.request(name, args) } }

    // Fetches the list, switches cycles if it is time, and starts what is missing.
    suspend fun refresh() {
        base?.let { fetchList(it) }
        schedule(op<Now, Changed>("refresh", Now(now())))
        onInstalled()
        pass()
    }

    private suspend fun fetchList(base: String) {
        val fetched = withContext(Dispatchers.IO) {
            try {
                val connection = URL("$base/$list").openConnection() as HttpURLConnection
                connection.connectTimeout = 20_000
                connection.readTimeout = 20_000
                connection.useCaches = false
                try {
                    val status = connection.responseCode
                    ListFetched(status, if (status == 200) connection.inputStream.readBytes().decodeToString() else null)
                } finally {
                    connection.disconnect()
                }
            } catch (_: IOException) {
                ListFetched(-1, null)
            }
        }
        op<ListFetched, Map<String, String>>("listFetched", fetched)
    }

    // Wakes one second after a pack takes effect or expires.
    private fun schedule(changed: Changed) {
        val wait = changed.delay ?: return
        changeover?.cancel()
        changeover = scope.launch {
            delay((wait * 1000).toLong())
            refresh()
        }
    }

    suspend fun pass(stopped: PackID? = null) {
        if (base == null) return publish()
        val (active, free) = withContext(Dispatchers.IO) { ours().map { it.second } to StatFs(root.path).availableBytes }
        val result = op<PassArgs, PassResult>("pass", PassArgs(active, free, now(), stopped))
        result.cancel.forEach { cancel(it) }
        result.start.forEach { start(it) }
        publish()
    }

    suspend fun choose(region: String) {
        op<RegionArgs, Map<String, String>>("choose", RegionArgs(region))
        pass()
    }

    suspend fun retry(region: String) {
        op<RegionArgs, Map<String, String>>("retry", RegionArgs(region))
        pass()
    }

    suspend fun remove(region: String) {
        op<RegionArgs, PassResult>("remove", RegionArgs(region)).cancel.forEach { cancel(it) }
        onInstalled()
        publish()
    }

    suspend fun seed(name: String, files: List<SeedFile>) {
        op<SeedArgs, Map<String, String>>("seed", SeedArgs(name, files, now()))
        onInstalled()
        publish()
    }

    suspend fun publish(waiting: Boolean = false) {
        rows = op("rows", RowsArgs(now(), waiting))
    }

    // A transfer the system cannot take, such as with no shared storage to write to, shows as failed.
    private suspend fun start(pending: Pending) {
        val id = pending.id
        val part = "$name/incoming/${id.cycle}-${id.layer}-${id.region}-${pending.attempt}.part"
        val taken = withContext(Dispatchers.IO) {
            runCatching {
                context.getExternalFilesDir(null)?.let { File(it, part).delete() }
                val request = DownloadManager.Request(Uri.parse("$base/${pending.path}"))
                    .setDestinationInExternalFilesDir(context, null, part)
                    .setTitle("Blueside ${id.region} ${id.layer}")
                    .setDescription(TAG + name + "|" + coreJson.encodeToString(Pending.serializer(), pending))
                manager.enqueue(request)
            }.isSuccess
        }
        if (taken) return onStarted()
        op<TransferEvent, Changed>("event", TransferEvent("failed", pending, code = DownloadManager.ERROR_UNKNOWN, now = now()))
    }

    private suspend fun cancel(region: String) = withContext(Dispatchers.IO) {
        ours().filter { it.second.id.region == region }.forEach { manager.remove(it.first) }
    }

    // This store's transfers the system holds, as download id and pack.
    private fun ours(statuses: Int = RUNNING): List<Pair<Long, Pending>> {
        val prefix = TAG + name + "|"
        return manager.query(DownloadManager.Query().setFilterByStatus(statuses)).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    val text = cursor.string(DownloadManager.COLUMN_DESCRIPTION)
                    if (!text.startsWith(prefix)) continue
                    val pending = runCatching { coreJson.decodeFromString(Pending.serializer(), text.removePrefix(prefix)) }
                        .getOrNull() ?: continue
                    add(cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_ID)) to pending)
                }
            }
        }
    }

    // Reports what the system did since the last poll. Returns true while transfers remain.
    suspend fun poll(waiting: Boolean): Boolean {
        val prefix = TAG + name + "|"
        var live = false
        val rowsOf = withContext(Dispatchers.IO) { manager.query(DownloadManager.Query()).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    val text = cursor.string(DownloadManager.COLUMN_DESCRIPTION)
                    if (!text.startsWith(prefix)) continue
                    val pending = runCatching { coreJson.decodeFromString(Pending.serializer(), text.removePrefix(prefix)) }
                        .getOrNull() ?: continue
                    add(
                        Transfer(
                            cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_ID)), pending,
                            cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)),
                            cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)),
                            cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)),
                            cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)),
                            cursor.string(DownloadManager.COLUMN_LOCAL_URI),
                        ),
                    )
                }
            }
        } }
        if (rowsOf.isEmpty()) return false
        for (t in rowsOf) {
            when (t.status) {
                DownloadManager.STATUS_SUCCESSFUL -> {
                    val file = Uri.parse(t.uri).path ?: ""
                    val hash = withContext(Dispatchers.IO) { sha256(File(file)) }
                    val changed = op<TransferEvent, Changed>("event", TransferEvent("downloaded", t.pending, file = file, sha256 = hash, now = now()))
                    manager.remove(t.id)
                    changed.retry?.let { start(it) }
                    schedule(changed)
                    onInstalled()
                }
                DownloadManager.STATUS_FAILED -> {
                    op<TransferEvent, Changed>("event", TransferEvent("failed", t.pending, code = t.reason, now = now()))
                    manager.remove(t.id)
                }
                else -> {
                    live = true
                    val total = if (t.total > 0) t.total else t.pending.bytes
                    val progress = if (total > 0) t.done.toDouble() / total else 0.0
                    op<TransferEvent, Changed>("event", TransferEvent("progress", t.pending, progress = progress, now = now()))
                }
            }
        }
        // A finished pack may free the next cycle's turn.
        if (rowsOf.any { it.status == DownloadManager.STATUS_SUCCESSFUL }) pass()
        publish(waiting)
        return live
    }

    private class Transfer(val id: Long, val pending: Pending, val status: Int, val reason: Int, val done: Long, val total: Long, val uri: String)

    companion object {
        private const val TAG = "blueside|"
        private const val RUNNING = DownloadManager.STATUS_PENDING or DownloadManager.STATUS_RUNNING or DownloadManager.STATUS_PAUSED

        fun now() = System.currentTimeMillis()

        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}

private fun Cursor.string(column: String): String = getString(getColumnIndexOrThrow(column)) ?: ""

