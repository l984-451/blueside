package com.gstudios.blueside

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.gstudios.blueside.aircraft.AircraftModel
import com.gstudios.blueside.downloads.PackStore
import com.gstudios.blueside.nav.NavModel
import com.gstudios.blueside.nav.NavPage
import com.gstudios.blueside.plates.PlateRef
import com.gstudios.blueside.plates.PlatesArgs
import com.gstudios.blueside.plates.plates as platesAt
import com.gstudios.blueside.position.BackgroundArgs
import com.gstudios.blueside.position.ChooseFixArgs
import com.gstudios.blueside.position.LocationSource
import com.gstudios.blueside.position.PositionService
import com.gstudios.blueside.position.TrafficReceiver
import com.gstudios.blueside.position.background
import com.gstudios.blueside.position.chooseFix
import com.gstudios.blueside.position.trafficCatalog
import com.gstudios.blueside.route.PendingBend
import com.gstudios.blueside.route.RouteModel
import com.gstudios.blueside.route.Shown
import com.gstudios.blueside.weather.WeatherModel
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.TimeZone

enum class Panel { Layers, Nav, Route }

// What the camera stood at, kept here so a rotation puts it back.
data class CameraState(val latitude: Double, val longitude: Double, val zoom: Double, val heading: Double)

// App state behind the map. It lives in a ViewModel so a rotation keeps it; decisions come from the core.
class AppModel(app: Application) : AndroidViewModel(app) {
    private val context = app.applicationContext
    var options = LaunchOptions(emptyMap())
        private set
    private var started = false
    // The app's work: a failure in it is logged, never the end of the process.
    val scope = viewModelScope + CoroutineExceptionHandler { _, e -> Log.e("Blueside", "work failed", e) }
    // Bumped on each return to the front. Deadline waits wake on it, since their clock stops while the device sleeps.
    private val wakes = MutableStateFlow(0)
    private var front by mutableStateOf(false)

    val catalog: Catalog = layerCatalog()
    var base by mutableStateOf("vfr")
    var night by mutableStateOf(false)
    var following by mutableStateOf(true)
    var orientation by mutableStateOf("northUp")
    var trackingLabel by mutableStateOf("")
    var panel by mutableStateOf<Panel?>(null)
    // Wide windows let the route panel grow into the planning page; places tapped then open over the map beside it.
    var wideWindow by mutableStateOf(false)
    var routeWide by mutableStateOf(false)
    var wideNav by mutableStateOf(false)
    val planning get() = routeWide && wideWindow && panel == Panel.Route
    private fun showNav() { if (planning) wideNav = true else panel = Panel.Nav }
    var settingsOpen by mutableStateOf(false)
    lateinit var weather: WeatherModel
        private set
    val overlays = mutableStateMapOf<String, Boolean>().apply { catalog.overlays.forEach { put(it.id, it.startsOn) }
        put(catalog.traffic.id, catalog.traffic.startsOn)
    }
    // Nav switches, then the TFRs and weather ones, with the style layers each shows.
    val switchGroups: List<Catalog.Group> get() = catalog.overlays + catalog.traffic + weather.catalog.tfrs + weather.catalog.toggles
    // Ids of the switches that are on.
    val switchedOn: List<String> get() = overlays.filterValues { it }.keys.toList()
    // The cruise altitude winds aloft default to, while there is a route.
    val cruiseFt: Int? get() = if (route.plan == null) null else route.inputs?.inputs?.number("cruiseAltitudeFt")?.toInt()

    var style by mutableStateOf<StyleResult?>(null)
        private set
    var coverage by mutableStateOf<String?>(null)
        private set
    var notices by mutableStateOf(Notices())
        private set
    var reading by mutableStateOf<PositionResult?>(null)
        private set
    // The default network reaches the internet, as the system checked it.
    var online by mutableStateOf(true)
        private set
    // The aerial service answered the last tile asked for.
    private var aerialReachable by mutableStateOf(true)
    private var packsVersion by mutableIntStateOf(0)
    // Bumped when plates packs may have changed, so open airport pages reread their charts.
    var platesVersion by mutableIntStateOf(0)
        private set
    // Georeferenced plates drawn on the map, in the order placed.
    val platesOnMap = mutableStateListOf<PlateRef>()
    // Plates the Layers panel asks the map to fit.
    val plateFits = Channel<PlateRef>(Channel.CONFLATED)
    private var savedPlates = emptyList<PlacedPlate>()
    // The last settled view, and the street packs it shows: the street style is made again only when those change.
    private var streetView: ViewBox? = null
    private var streetPacks by mutableStateOf<String?>(null)
    private var streetJob: Job? = null

    var camera: CameraState? = null
    var zoomedToFirstFix = false
    // Camera moves the core asks for; the map host applies them.
    val cameraMoves = Channel<PositionResult.Camera>(Channel.UNLIMITED)

    private var fix: Fix? = null
    private val prefs = context.getSharedPreferences("blueside", Context.MODE_PRIVATE)
    private var savedRoute: String? = null
    // Bumped on each fix; follow() reads the strip, route and nav page from it.
    private val fixes = MutableStateFlow(0L)
    private var deviceFix: Fix? = null
    private val location = LocationSource(context, { deviceFix = it; chooseFix() }) { fixes.value++ }
    val trafficCatalog = trafficCatalog()
    var ownshipSource by mutableStateOf("auto")
        private set
    // Null until start(); listens for an ADS-B receiver's GDL 90.
    var traffic: TrafficReceiver? = null
        private set
    val nav: NavModel = NavModel(context, { fix }, { approximate }, { route.plan })
    val route: RouteModel = RouteModel(context, nav, { fix }, { approximate })
    val aircraft = AircraftModel(context, route) {
        runCatching { airborne(FixArgs(fix, approximate, System.currentTimeMillis())) }.getOrDefault(false)
    }
    val currentFix: Fix? get() = fix
    // Only the device's own fix can be approximate.
    val approximate: Boolean get() = location.approximate && fix === deviceFix
    private var navPath: String? = null
    private var navMeta: NavMetadata? = null

    private val templates = File(context.filesDir, "MapAssets")
    lateinit var stores: List<PackStore>
        private set
    lateinit var charts: PackStore
        private set
    lateinit var street: PackStore
        private set
    lateinit var terrain: PackStore
        private set
    lateinit var navData: PackStore
        private set
    lateinit var plates: PackStore
        private set

    // Called once with the launch intent. Later intents are ignored, as on iOS.
    fun start(launchOptions: LaunchOptions) {
        if (started) return
        started = true
        options = launchOptions
        val offline = options.flag("offline")
        val server = if (offline) null else options.string("manifestBase") ?: MANIFEST_BASE
        val bump: () -> Unit = { packsVersion++ }
        val transferring: () -> Unit = { transfers.trySend(Unit) }
        charts = PackStore(context, "Packs", "manifest.json", server, Configure(skipLayers = listOf("street", "terrain"), category = "charts"), scope, transferring, bump)
        street = PackStore(context, "Street", "manifest.json", server, Configure(layers = listOf("street"), category = "street"), scope, transferring, bump)
        terrain = PackStore(context, "Terrain", "manifest.json", server, Configure(layers = listOf("terrain"), category = "terrain"), scope, transferring, bump)
        navData = PackStore(context, "NavData", "nav/manifest.json", server, Configure(always = listOf("US"), nav = true, category = "nav"), scope, transferring, bump)
        plates = PackStore(context, "Plates", "plates/manifest.json", server, Configure(category = "procedures"), scope, transferring) { platesVersion++ }
        stores = listOf(navData, charts, plates, street, terrain) // Downloads list order
        // Tests pass reset so each run starts from a first launch.
        if (options.flag("reset")) prefs.edit().clear().commit()
        ownshipSource = prefs.getString(trafficCatalog.sourceKey, null) ?: "auto"
        // Listens only while the app is in front; toFront starts it. Its batch loop is long-lived, so it has no handler.
        traffic = TrafficReceiver(context, viewModelScope, options.string("gdl90Port")?.toIntOrNull() ?: trafficCatalog.port,
            { fix }) { chooseFix() }
        weather = WeatherModel(context, server)
        weather.restore(overlays)
        options.string("overlaysOn")?.split(",")?.forEach { overlays[it.trim()] = true }

        val first = launch(LaunchArgs(prefs.getString(catalog.memoryKey, null), options.string("base"),
            options.string("night")?.let { options.flag("night") }, options.string("orientation"),
            options.coordinate("center"), options.double("zoom"), options.flag("follow")))
        base = first.base
        night = first.night
        orientation = first.orientation
        following = first.following
        trackingLabel = first.label
        savedRoute = first.route
        savedPlates = first.plates
        camera = CameraState(first.camera.latitude, first.camera.longitude, first.camera.zoom, 0.0)
        if (options.string("show") == "layers") panel = Panel.Layers
        if (options.string("show") == "nav") panel = Panel.Nav
        if (options.string("show") == "route") panel = Panel.Route
        options.string("navQuery")?.let { nav.query = it }
        if (options.string("show") == "downloads") settingsOpen = true

        watchNetwork()
        // The long-lived loops each run on their own under the ViewModel's scope, without the handler:
        // a throw in one crashes where it can be seen, rather than quietly stopping it and the others.
        viewModelScope.launch {
            withContext(Dispatchers.IO) { copyTemplates() }
            options.string("seedPacks")?.let { seed(it) }
            if (options.string("basePack") == "nav") seedNav()
            restorePlates()
            viewModelScope.launch { styles() }
            viewModelScope.launch { watchNotices() }
            viewModelScope.launch { follow() }
            viewModelScope.launch { keepRunning() }
            viewModelScope.launch { polls() }
            viewModelScope.launch { weatherPasses() }
            viewModelScope.launch { probeAerial() }
            viewModelScope.launch {
                snapshotFlow { aircraft.current }.collect {
                    aircraft.follow(it)
                    if (route.plan != null) route.edit()
                }
            }
            viewModelScope.launch {
                snapshotFlow { nav.open }.first { it }
                route.setInputs()
                val old = aircraft.takeOldChoice()
                if (old != null && route.inputs?.inputs?.text("aircraftID") == null) route.setInputs(PlanInputArgs(now = 0, aircraft = old))
            }
            // The lists are fetched at launch, on each return to the front and then hourly, so an app left open
            // learns of the next cycle; each refresh also sets the changeover wake again.
            while (true) {
                val seen = wakes.value
                stores.forEach { runCatching { it.refresh() } }
                sleepUntil(System.currentTimeMillis() + 3_600_000, seen)
            }
        }
    }

    private suspend fun seed(name: String) {
        val files = withContext(Dispatchers.IO) {
            listOf("vfr", "vfr-tac", "ifr-low", "ifr-area").map { layer ->
                val out = File(context.cacheDir, "test-$layer.pmtiles")
                context.assets.open("test-$layer.pmtiles").use { input -> out.outputStream().use { input.copyTo(it) } }
                SeedFile(layer, out.path)
            }
        }
        charts.seed(name, files)
    }

    // The bundled test database and tiles, installed as the current nav cycle.
    private suspend fun seedNav() {
        val files = withContext(Dispatchers.IO) {
            listOf("nav-db" to "nav-test.sqlite", "nav-tiles" to "nav-tiles.pmtiles").map { (layer, name) ->
                val out = File(context.cacheDir, name)
                context.assets.open(name).use { input -> out.outputStream().use { input.copyTo(it) } }
                SeedFile(layer, out.path)
            }
        }
        navData.seed("current", files)
        // platesPack swaps in a real plates pack; plateOnMap ("BHM:00050IL6.PDF") puts one of its plates on the map.
        val platesFile = options.string("platesPack")?.let(::File) ?: withContext(Dispatchers.IO) {
            File(context.cacheDir, "plates-test.sqlite").also { out ->
                context.assets.open("plates-test.sqlite").use { input -> out.outputStream().use { input.copyTo(it) } }
            }
        }
        plates.seed("current", listOf(SeedFile("plates", platesFile.path)))
        val (ident, file) = options.string("plateOnMap")?.split(":")?.takeIf { it.size == 2 } ?: return
        val found = withContext(Dispatchers.IO) {
            runCatching { platesAt(PlatesArgs(plates.root.path, ident, System.currentTimeMillis())) }.getOrNull()
        } ?: return
        val plate = found.groups.flatMap { it.plates }.firstOrNull { it.file == file } ?: return
        if (plate !in platesOnMap) platesOnMap.add(plate)
        if (options.string("show") == "plate") {
            panel = Panel.Nav
            nav.push(NavPage.Chart(plate, found))
        }
    }

    private fun copyTemplates() {
        templates.mkdirs()
        for (name in listOf("empty.json", "nav-style.json", "street-light.json", "street-dark.json")) {
            context.assets.open(name).use { input -> File(templates, name).outputStream().use { input.copyTo(it) } }
        }
    }

    private val storeRoots get() = listOf(charts.root.path, street.root.path, terrain.root.path)

    // Rebuilds the style whenever what it depends on changes. Equal text leaves the map alone.
    private suspend fun styles() {
        snapshotFlow { listOf(base, night, packsVersion, online && aerialReachable, if (base == "street") streetPacks else null) }
            .collectLatest {
                val args = StyleArgs(base, night, System.currentTimeMillis(), storeRoots, navData.root.path, templates.path,
                    "asset:/", streetView, online && aerialReachable)
                val made = withContext(Dispatchers.IO) { runCatching { mapStyle(args) }.getOrNull() } ?: return@collectLatest
                if (made.navDatabase != navPath) openNav(made.navDatabase)
                if (made != style) style = made
            }
    }

    // The search, open page and favorites are read again from the new file.
    private suspend fun openNav(path: String?) {
        nav.use(path)
        navMeta = nav.metadata()
        // Set last: a style rebuild can cancel this midway, and the next one must try again.
        navPath = path
        // A test route, typed as the editor would type it, or else the route left at the last close.
        val test = options.string("navRoute")
        if (test != null && route.plan == null) route.edit(RouteEdit("typed", text = test))
        if (test == null && path != null) savedRoute?.let { route.edit(RouteEdit("restore", text = it)) }
        if (path != null) savedRoute = null
    }

    // The banners, the nav notice and the weather labels are read again when an input changes,
    // and otherwise only at the next time the core says their words can change.
    private suspend fun watchNotices() {
        snapshotFlow {
            listOf(base, packsVersion, platesVersion, style, nav.open, nav.unreadable, overlays.toMap(), weather.passes,
                weather.show, weather.windsChoice, cruiseFt)
        }.collectLatest {
            while (true) {
                val meta = navMeta
                val navState = navPath?.let {
                    NavState(meta?.cycle, meta?.effective, meta?.expires, unreadable = nav.unreadable, hasTiles = style?.navTiles != null)
                }
                val now = System.currentTimeMillis()
                val args = NoticeArgs(base, storeRoots, now, navState, catalog.overlays.any { overlays[it.id] == true }, plates.root.path)
                withContext(Dispatchers.IO) { runCatching { notices(args) }.getOrNull() }?.let { if (it != notices) notices = it }
                weather.tick(switchedOn, now, cruiseFt)
                sleepUntil(listOfNotNull(notices.next, weather.notices.next).minOrNull() ?: break)
            }
        }
    }

    // Each fix, and each nav page change, reads the strip, the route and the open nav page again;
    // with neither they are read again only when the fix goes stale or the page's words can change.
    private suspend fun follow() {
        var seen = -1L
        combine(fixes, snapshotFlow { Triple(panel, nav.top, nav.next) }) { n, _ -> n }.collectLatest { n ->
            // Only a new fix moves the camera.
            var moveCamera = n != seen
            seen = n
            while (true) {
                val reading = readPosition(moveCamera)
                if (route.plan != null) route.edit()
                if (panel == Panel.Nav) nav.refresh()
                moveCamera = false
                sleepUntil(listOfNotNull(reading?.staleAt, nav.next.takeIf { panel == Panel.Nav }).minOrNull() ?: break)
            }
        }
    }

    // The latest live fix at flying speed, as the core's background rule last gave it.
    private var lastFast: Long? = null
    // The position service was asked to start and not yet to stop.
    private var asked = false
    // The rule's deadline the wake lock was last taken for.
    private var deadline: Long? = null
    // Holds the device awake to the rule's deadline, so the hold ends on time when nothing else arrives.
    private val awake = context.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "blueside:position").apply { setReferenceCounted(false) }

    // Out of the front the app keeps running while flying or while a receiver talks, as the core's rule says, and sleeps
    // on the ground. The service starts only in front, the one place Android lets it begin, and ends with the rule.
    private suspend fun keepRunning() {
        combine(fixes, snapshotFlow { Triple(front, traffic?.batch?.status?.lastMessageAt, PositionService.running) }) { _, state -> state }
            .collectLatest { (inFront, heard, running) ->
                val now = System.currentTimeMillis()
                val args = BackgroundArgs(fix, lastFast, heard, now)
                // A failed call ends the hold, as no deadline does.
                val rule = withContext(Dispatchers.Default) { runCatching { background(args) }.getOrNull() }
                rule?.let { lastFast = it.lastFast }
                val until = rule?.until?.takeIf { it > now }
                // Asked again in front whenever it is not running: refused, or stopped since.
                if (until != null && inFront && !running && location.permitted) {
                    asked = PositionService.start(context) || asked
                }
                // Out of the front without the service, nothing may keep position and the receiver going.
                if (until == null || !asked || !inFront && !running) return@collectLatest letGo()
                if (until != deadline) {
                    awake.acquire(until - now + 10_000)
                    deadline = until
                }
                delay(until - now)
                letGo()
            }
    }

    private fun letGo() {
        deadline = null
        if (awake.isHeld) awake.release()
        // Running unasked too: a start that came through after the hold was let go.
        if (asked || PositionService.running) PositionService.stop(context)
        asked = false
        if (!front) {
            location.stop()
            traffic?.stop()
        }
    }

    // Wakes at the time, or early on a return to the front after seen.
    suspend fun sleepUntil(time: Long, seen: Int = wakes.value) {
        withTimeoutOrNull((time - System.currentTimeMillis()).coerceAtLeast(1)) { wakes.first { it != seen } }
    }

    // Signaled when a store hands the system a transfer.
    private val transfers = Channel<Unit>(Channel.CONFLATED)

    // Polls the system download service each second while any store has a transfer, else waits for one to start.
    // A poll that throws counts as live, so its transfers are polled again.
    private suspend fun polls() {
        while (true) {
            val live = stores.map { runCatching { it.poll(!online) }.getOrDefault(true) }
            if (live.any { it }) delay(1000) else transfers.receive()
        }
    }

    // A network can pass the system's check and still not reach the imagery, so one aerial tile is asked for when the
    // aerial base is chosen, on each return to the front and on each change of network. The last answer stands meanwhile.
    private suspend fun probeAerial() {
        combine(wakes, snapshotFlow { Triple(base == "aerial", defaultNetwork, online) }) { _, wanted -> wanted }
            .collectLatest { (aerial, _, reaches) ->
                if (aerial && reaches && front && !options.flag("offline")) {
                    aerialReachable = withContext(Dispatchers.IO) { answers(catalog.aerialProbe) }
                }
            }
    }

    private fun answers(url: String): Boolean = runCatching {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 8_000
        connection.readTimeout = 8_000
        connection.useCaches = false
        try { connection.responseCode == 200 } finally { connection.disconnect() }
    }.getOrDefault(false)

    // A weather pass now and then every refresh interval; switches and the map setup are saved as they change.
    private suspend fun weatherPasses() {
        viewModelScope.launch { snapshotFlow { overlays.toMap() }.collect { weather.save(it) } }
        viewModelScope.launch { snapshotFlow { listOf(base, night, orientation, following, route.view?.text, platesOnMap.toList()) }.collect { remember() } }
        while (true) {
            weather.refresh()
            delay((weather.catalog.refreshSeconds * 1000).toLong())
        }
    }

    // Back at the front: position, the receiver, a weather pass, the chart lists and every deadline start again.
    fun toFront() {
        front = true
        startLocation()
        if (!started) return
        traffic?.start()
        // The same pass as the weather loop's, so a failure in it is as loud.
        viewModelScope.launch { weather.refresh() }
        wakes.value++
    }

    // The camera is saved here rather than at every settle, which follows each fix.
    // While the position service runs or is starting, position and the receiver run on; the hold stops them if it lets go.
    fun toBack() {
        front = false
        if (!asked && !PositionService.running) {
            location.stop()
            traffic?.stop()
        }
        if (started) remember()
    }

    private suspend fun readPosition(moveCamera: Boolean): PositionResult? {
        val cam = camera
        val args = PositionArgs(fix, System.currentTimeMillis(), approximate, location.accessOff, following,
            orientation, cam?.heading ?: 0.0, cam?.zoom ?: 4.0, zoomedToFirstFix)
        val result = withContext(Dispatchers.Default) { runCatching { position(args) }.getOrNull() } ?: return null
        if (result != reading) reading = result
        if (moveCamera && fix != null) result.camera?.let {
            if (it.zoom != null || it.latitude != null) zoomedToFirstFix = true
            cameraMoves.trySend(it)
        }
        return result
    }

    // A fresh start also catches a permission granted since the last one.
    fun startLocation() {
        location.start()
        fixes.value++
    }

    fun chooseOwnshipSource(id: String) {
        ownshipSource = id
        prefs.edit().putString(trafficCatalog.sourceKey, id).apply()
        chooseFix()
    }

    // The device's fix or the receiver's, as the source setting says. A traffic batch with the same fix moves nothing.
    private fun chooseFix() {
        val receiver = traffic?.batch?.receiver
        val chosen = when (chooseFix(ChooseFixArgs(ownshipSource, deviceFix, receiver, System.currentTimeMillis()))) {
            "receiver" -> receiver
            "device" -> deviceFix
            else -> null
        }
        val changed = chosen != fix
        fix = chosen
        if (changed) fixes.value++
    }

    fun tapTracking() {
        val next = tracking(TrackingArgs(following, orientation))
        following = next.following
        orientation = next.orientation
        trackingLabel = next.label
        settleCamera()
    }

    // Applies a new orientation or a recenter at once, with or without a fix.
    private fun settleCamera() {
        val cam = camera
        val args = PositionArgs(fix, System.currentTimeMillis(), approximate, location.accessOff, following,
            orientation, cam?.heading ?: 0.0, cam?.zoom ?: 4.0, zoomedToFirstFix)
        runCatching { position(args) }.getOrNull()?.camera?.let { cameraMoves.trySend(it) }
    }

    // A pan stops following; a pinch zooms around the aircraft.
    fun userPanned() {
        if (!following) return
        following = false
        trackingLabel = tracking(TrackingArgs(false, orientation, tap = false)).label
    }

    // A tap's hits or a long press's point, turned by the core into a page, a card or the Here list.
    fun picked(args: PickArgs) {
        scope.launch {
            val result = nav.pick(args) ?: return@launch
            when (result.open) {
                "airport" -> nav.reset(NavPage.Airport(result.ident ?: return@launch))
                "place" -> nav.reset(NavPage.Card(result.place ?: return@launch))
                "here" -> nav.reset(NavPage.Here(result.here))
                // Open map leaves the planning page alone.
                else -> return@launch if (planning) Unit else panelClosed()
            }
            showNav()
        }
    }

    // Where a page's or row's Direct To and Add to Route meet the route.
    fun directTo(place: Place) {
        scope.launch {
            route.direct(place)
            panelClosed()
        }
    }

    fun addToRoute(place: Place) {
        scope.launch {
            route.add(place)
            nav.refresh()
        }
    }

    // A let-go rubber band: the core edits the route, offers places near a plain point, or asks which place.
    fun bent(edit: RouteEdit, x: Float, y: Float) {
        scope.launch {
            val result = route.edit(edit, undoable = true) ?: return@launch
            result.choose?.let { places ->
                route.pending = PendingBend(edit.grab ?: return@launch, edit.drawnCount ?: return@launch)
                nav.reset(NavPage.Here(places, bend = true))
                showNav()
            }
            result.offer?.let { offer ->
                val shown = Shown(offer, x, y)
                route.offer = shown
                delay((route.labels.offerSeconds * 1000).toLong())
                if (route.offer == shown) route.offer = null
            }
        }
    }

    fun pickBend(place: Place) {
        val bend = route.pending ?: return
        route.pending = null
        scope.launch {
            route.edit(RouteEdit("bendTo", place = place, grab = bend.grab, drawnCount = bend.drawnCount), undoable = true)
            panelClosed()
        }
    }

    fun useInstead(target: Int, place: Place) {
        scope.launch { route.edit(RouteEdit("replace", place = place, target = target)) }
    }

    fun routeEdit(edit: RouteEdit) {
        scope.launch { route.edit(edit) }
    }

    fun planEdit(change: PlanInputArgs) {
        scope.launch { route.setInputs(change) }
    }

    // The plan and brief arguments: the route, its inputs, and the flight's aircraft with its W&B load.
    fun planArgs(): PlanArgs? {
        val plan = route.plan ?: return null
        val inputs = route.inputs?.inputs ?: return null
        val craft = aircraft.current
        val load = aircraft.load
        val stations = (craft?.get("stations") as? JsonArray)?.size ?: 0
        val now = System.currentTimeMillis()
        // Local times print with the offset in force at departure.
        val departure = inputs.number("departure")?.toLong() ?: now
        return PlanArgs(plan, fix, approximate, now, inputs, craft, load.startFuel.toDoubleOrNull(),
            List(stations) { load.weights[it]?.toDoubleOrNull() ?: 0.0 }, load.burned?.toDoubleOrNull(),
            TimeZone.getDefault().getOffset(departure) / 1000, stored = route.inputs?.stored, navDatabase = navPath,
            plates = plates.root.path)
    }

    // The last finished brief, shown again at once while its arguments and the weather are unchanged.
    var briefKept: com.gstudios.blueside.route.BriefKept? = null

    // The brief's arguments: the plan's, with the packs and map assets for its pictures.
    fun briefArgs(): PlanArgs? = planArgs()?.copy(stores = storeRoots, templates = templates.path, assets = "asset:/")

    fun undoRoute() {
        scope.launch { route.undoEdit() }
    }

    fun openRoute() {
        panel = if (panel == Panel.Route) null else Panel.Route
    }

    fun downloadNav(region: String) {
        scope.launch {
            runCatching { navData.retry(region); navData.refresh() }
        }
    }

    fun openSearch() {
        if (panel == Panel.Nav) return panelClosed()
        panel = Panel.Nav
        scope.launch { nav.refresh() }
    }

    // Closing the nav panel starts it over at the search next time, as a dropped pin goes away.
    // The route panel's own close shuts the planning page and any place beside it at once.
    fun routeClosed() {
        wideNav = false
        panelClosed()
    }

    fun panelClosed() {
        if (wideNav) {
            wideNav = false
            route.pending = null
            scope.launch { nav.reset(NavPage.Search) }
            return
        }
        panel = null
        routeWide = false
        route.pending = null
        scope.launch { nav.reset(NavPage.Search) }
    }

    fun navigate(action: suspend NavModel.() -> Unit) {
        scope.launch { nav.action() }
    }

    // The dropped pin, drawn while its card is open.
    val pin: Coordinate?
        get() = (nav.top as? NavPage.Card)?.place?.takeIf { (panel == Panel.Nav || wideNav) && it.kind == "user" }
            ?.let { Coordinate(it.latitude, it.longitude) }

    // Puts back the plates saved with the map once the plates packs can be read.
    private suspend fun restorePlates() {
        val saved = savedPlates.takeIf { it.isNotEmpty() } ?: return
        val found = withContext(Dispatchers.IO) {
            saved.mapNotNull { p ->
                runCatching { platesAt(PlatesArgs(plates.root.path, p.airport, System.currentTimeMillis())) }.getOrNull()
                    ?.groups?.flatMap { it.plates }?.firstOrNull { it.file == p.file && it.geo != null }
            }
        }
        savedPlates = emptyList()
        platesOnMap.addAll(0, found.filter { it !in platesOnMap })
    }

    fun showPlate(plate: PlateRef) {
        userPanned()
        plateFits.trySend(plate)
    }

    // Stops following, rings the place and centers it in the open map at the core's zoom.
    fun showOnMap(place: Place) {
        userPanned()
        val at = Coordinate(place.latitude, place.longitude)
        focus = Triple(at, panel, nav.top)
        reveals.trySend(at)
    }

    // Show on Map's place, kept only while the same panel page stays open.
    private var focus by mutableStateOf<Triple<Coordinate, Panel?, NavPage?>?>(null)

    // Places Show on Map moves to whatever their place on screen.
    val reveals = Channel<Coordinate>(Channel.CONFLATED)

    // The place the open panel shows: the airport page or place card on top, else the last Show on Map.
    val shownPlace: Coordinate?
        get() {
            val open = panel ?: return null
            if (open == Panel.Nav) when (val top = nav.top) {
                is NavPage.Airport -> nav.airport?.place?.takeIf { top.ident == it.ident || top.ident == it.icao }?.let { return Coordinate(it.latitude, it.longitude) }
                is NavPage.Card -> return Coordinate(top.place.latitude, top.place.longitude)
                else -> {}
            }
            return focus?.takeIf { it.second == open && it.third == nav.top }?.first
        }

    // Edges of what covers the map, in px from its top left: the pane's right, the sheet's top, the strip's bottom.
    var paneRight by mutableStateOf(0f)
    var sheetTop by mutableStateOf<Float?>(null)
    var stripBottom by mutableStateOf(0f)

    private val coverageHandle by lazy { Core.open("coverage", "") }
    // The coverage session is not safe across threads: one call at a time, and only the newest camera's.
    private val coverageThread = Dispatchers.IO.limitedParallelism(1)
    private var coverageJob: Job? = null

    fun cameraIdle(state: CameraState, view: ViewBox) {
        camera = state
        streetView = view
        if (base == "street") {
            val args = StreetArgs(storeRoots, System.currentTimeMillis(), view)
            streetJob?.cancel()
            streetJob = scope.launch {
                withContext(Dispatchers.IO) { runCatching { streetKey(args) }.getOrNull() }?.let { streetPacks = it }
            }
        }
        val rasters = style?.rasters.orEmpty()
        coverageJob?.cancel()
        coverageJob = scope.launch {
            coverage = if (rasters.isEmpty()) null else withContext(coverageThread) {
                runCatching {
                    handleCall(coverageHandle).request<GapArgs, Gap>("gap", GapArgs(rasters, state.latitude, state.longitude, state.zoom)).text
                }.getOrNull()
            }
        }
    }

    private fun remember() {
        val cam = camera?.let { MapCamera(it.latitude, it.longitude, it.zoom) }
        // Until the nav data opens, the saved route is kept as it was.
        val routeText = route.view?.text?.ifEmpty { null } ?: savedRoute
        // Until the plates packs are read, the saved plates are kept as they were.
        val placed = if (savedPlates.isEmpty()) platesOnMap.map { PlacedPlate(it.airport, it.file) } else savedPlates
        val text = runCatching { mapMemory(MapMemory(base, night, orientation, following, cam, routeText, placed)) }.getOrNull() ?: return
        if (text != prefs.getString(catalog.memoryKey, null)) prefs.edit().putString(catalog.memoryKey, text).apply()
    }

    private val connectivity = context.getSystemService(ConnectivityManager::class.java)

    // The default network, so a change of network can be told from a change in its signal.
    private var defaultNetwork by mutableStateOf<Network?>(null)

    // The default network counts once the system has checked it reaches the internet; a receiver's Wi-Fi does not.
    private val network = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            defaultNetwork = network
            online = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        }

        override fun onLost(network: Network) {
            defaultNetwork = null
            online = false
        }
    }

    private fun watchNetwork() {
        defaultNetwork = connectivity.activeNetwork
        online = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
            ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        connectivity.registerDefaultNetworkCallback(network, Handler(Looper.getMainLooper()))
    }

    override fun onCleared() {
        letGo()
        location.close()
        traffic?.stop()
        if (started) connectivity.unregisterNetworkCallback(network)
    }

    companion object {
        // The public chart server, the same one iOS reads.
        const val MANIFEST_BASE = "https://pub-b4d06f1c406b4312b314d87c67ecf862.r2.dev"
    }
}
