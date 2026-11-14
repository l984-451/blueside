package com.gstudios.blueside.map

import android.content.ComponentCallbacks2
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.view.HapticFeedbackConstants
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.gstudios.blueside.AppModel
import com.gstudios.blueside.CameraState
import com.gstudios.blueside.Coordinate
import com.gstudios.blueside.PickArgs
import com.gstudios.blueside.PositionResult
import com.gstudios.blueside.RevealArgs
import com.gstudios.blueside.ScreenRect
import com.gstudios.blueside.coreJson
import com.gstudios.blueside.reveal
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.drop
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.PaintPropertyValue
import org.maplibre.android.style.layers.PropertyFactory.circleColor
import org.maplibre.android.style.layers.PropertyFactory.circleOpacity
import org.maplibre.android.style.layers.PropertyFactory.circleRadius
import org.maplibre.android.style.layers.PropertyFactory.circleStrokeColor
import org.maplibre.android.style.layers.PropertyFactory.circleStrokeWidth
import org.maplibre.android.style.layers.TransitionOptions
import com.gstudios.blueside.ViewBox
import com.gstudios.blueside.plates.PlateRef
import com.gstudios.blueside.plates.planBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.gestures.MoveGestureDetector
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression.get
import org.maplibre.android.geometry.LatLngQuad
import org.maplibre.android.style.layers.BackgroundLayer
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory.rasterBrightnessMax
import org.maplibre.android.style.layers.PropertyFactory.rasterBrightnessMin
import org.maplibre.android.style.layers.PropertyFactory.rasterFadeDuration
import org.maplibre.android.style.layers.PropertyFactory.rasterHueRotate
import org.maplibre.android.style.layers.RasterLayer
import org.maplibre.android.style.sources.ImageSource
import org.maplibre.android.style.layers.PropertyFactory.iconAllowOverlap
import org.maplibre.android.style.layers.PropertyFactory.iconIgnorePlacement
import org.maplibre.android.style.layers.PropertyFactory.iconImage
import org.maplibre.android.style.layers.PropertyFactory.iconRotate
import org.maplibre.android.style.layers.PropertyFactory.iconRotationAlignment
import org.maplibre.android.style.layers.PropertyFactory.visibility
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.Point
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

// The MapLibre view in Compose. It draws what the model holds: style, overlay switches, aircraft and camera.
@Composable
fun MapHost(model: AppModel, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val view = remember {
        MapLibre.getInstance(context)
        MapView(context).apply { onCreate(null) }
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> view.onStart()
                Lifecycle.Event.ON_RESUME -> view.onResume()
                Lifecycle.Event.ON_PAUSE -> view.onPause()
                Lifecycle.Event.ON_STOP -> view.onStop()
                else -> {}
            }
        }
        // Memory pressure trims the map's caches before the system takes the app.
        val memory = object : ComponentCallbacks2 {
            override fun onTrimMemory(level: Int) {
                if (level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND) view.onLowMemory()
            }

            @Deprecated("Deprecated in Java")
            override fun onLowMemory() = view.onLowMemory()
            override fun onConfigurationChanged(newConfig: Configuration) {}
        }
        lifecycle.addObserver(observer)
        context.registerComponentCallbacks(memory)
        onDispose {
            context.unregisterComponentCallbacks(memory)
            lifecycle.removeObserver(observer)
            view.onDestroy()
        }
    }
    var edit by remember { mutableStateOf<MapEdit?>(null) }
    Box(modifier) {
        AndroidView(factory = { view }, modifier = Modifier.fillMaxSize())
        MapEditOverlay(edit)
    }

    var loaded by remember { mutableStateOf<Style?>(null) }
    // Draws only on the style now loaded: once setStyle starts, the old style throws on every call.
    fun on(style: Style, draw: () -> Unit) { if (style === loaded) draw() }
    LaunchedEffect(view) {
        val map = suspendCoroutine { done -> view.getMapAsync { done.resume(it) } }
        setUp(map, model)
        val editor = MapEdit(view, map, model)
        edit = editor
        listenForPicks(view, map, model, editor)
        // Moves start only after setUp placed the first camera, so a fix that came early is not undone.
        launch { model.cameraMoves.receiveAsFlow().collect { move(map, it) } }
        launch { model.plateFits.receiveAsFlow().collect { fit(map, it, context.resources.displayMetrics.density) } }
        launch { revealPlaces(view, map, model) }
        // The text asked for last, and the text of the style now loaded.
        var styleText: String? = null
        var loadedText: String? = null
        snapshotFlow { model.style }.collect { result ->
            if (result == null || result.style == styleText) return@collect
            val live = loaded?.takeIf { loadedText == styleText }
            styleText = result.style
            // A change of paint alone, such as night, repaints the live style; anything else loads it again.
            val from = loadedText
            val paints = if (live == null || from == null) null else withContext(Dispatchers.Default) { paintChanges(from, result.style) }
            if (live != null && paints != null && live === loaded) {
                paints.forEach { (layer, paint) -> live.getLayer(layer)?.setProperties(paint) }
                loadedText = result.style
                return@collect
            }
            val text = result.style
            // The old style refuses every call once the new one starts loading, so nothing draws on it meanwhile.
            loaded = null
            map.setStyle(Style.Builder().fromJson(text)) { style ->
                installOwnship(style, context.resources.displayMetrics.density)
                installPin(style, context.resources.displayMetrics.density)
                installRoute(style, model.night, context.resources.displayMetrics.density)
                installTraffic(style, model.night, context.resources.displayMetrics.density)
                installBarbs(style, model.weather.catalog.barbs, context.resources.displayMetrics.density)
                installPill(style, model.night, context.resources.displayMetrics.density)
                installRing(style)
                loadedText = text
                loaded = style
            }
        }
    }
    // Night inks for what the app draws itself; the core's layers repaint with the style above.
    LaunchedEffect(view, loaded) {
        val style = loaded ?: return@LaunchedEffect
        snapshotFlow { model.night }.drop(1).collect { night ->
            on(style) {
                paintRoute(style, night)
                paintTraffic(style, model.traffic?.batch, night)
                installPill(style, night, context.resources.displayMetrics.density)
            }
        }
    }
    LaunchedEffect(view, loaded) {
        val style = loaded ?: return@LaunchedEffect
        snapshotFlow { model.overlays.toMap() }.collect { switches ->
            on(style) {
                for (group in model.switchGroups) {
                    val shown = if (switches[group.id] == true) Property.VISIBLE else Property.NONE
                    group.layers.forEach { style.getLayer(it)?.setProperties(visibility(shown)) }
                }
            }
        }
    }
    LaunchedEffect(view, loaded) {
        val style = loaded ?: return@LaunchedEffect
        val weather = model.weather
        // Asked again after each pass, so freshness follows the clock.
        snapshotFlow { listOf(weather.passes, model.switchedOn, weather.show, weather.windsChoice, model.cruiseFt) }.collect {
            weather.layers(model.switchedOn, System.currentTimeMillis(), model.cruiseFt)?.let {
                on(style) { drawWeather(style, it, weather.catalog) }
                if (it.radar == null) weather.stopLoop(model.scope)
            }
        }
    }
    LaunchedEffect(view, loaded) {
        val style = loaded ?: return@LaunchedEffect
        snapshotFlow { model.weather.loop }.collect { on(style) { drawLoop(style, it?.frames.orEmpty(), it?.showing ?: 0, model.weather.catalog) } }
    }
    LaunchedEffect(view, loaded) {
        val style = loaded ?: return@LaunchedEffect
        snapshotFlow { model.reading?.ownship }.collect { on(style) { drawOwnship(style, it) } }
    }
    LaunchedEffect(view, loaded) {
        val style = loaded ?: return@LaunchedEffect
        snapshotFlow { model.pin }.collect { on(style) { drawPin(style, it) } }
    }
    val accent = MaterialTheme.colorScheme.primary.toArgb()
    LaunchedEffect(view, loaded, accent) {
        val style = loaded ?: return@LaunchedEffect
        // A dropped pin has its own mark.
        snapshotFlow { Triple(model.shownPlace?.takeIf { it != model.pin }, model.night, accent) }
            .collect { (place, night, ink) -> on(style) { drawRing(style, place, if (night) ink and 0xBFFFFFFF.toInt() else ink) } }
    }
    // Plan images kept by plate, so placing one more does not render every PDF again.
    val planCache = remember { mutableMapOf<PlateRef, Bitmap>() }
    val plateImage by produceState(emptyList<Pair<PlateRef, Bitmap>>(), model.platesOnMap.toList()) {
        val shown = model.platesOnMap.toList()
        planCache.keys.retainAll(shown.toSet())
        value = withContext(Dispatchers.IO) { shown.mapNotNull { p -> (planCache[p] ?: planBitmap(context, p))?.let { planCache[p] = it; p to it } } }
    }
    val rasterPaint = model.style?.rasterPaint
    LaunchedEffect(loaded, plateImage, rasterPaint) {
        val style = loaded ?: return@LaunchedEffect
        on(style) { drawPlate(style, plateImage, rasterPaint) }
    }
    LaunchedEffect(view, loaded) {
        val style = loaded ?: return@LaunchedEffect
        snapshotFlow { model.route.view?.line to model.night }.collect { (line, night) -> on(style) { drawRoute(style, line, night) } }
    }
    LaunchedEffect(view, loaded) {
        val style = loaded ?: return@LaunchedEffect
        snapshotFlow { model.traffic?.batch }.collect { on(style) { drawTraffic(style, it, model.night) } }
    }
}

// The paint changes from one core style to the next, by layer id. Null when anything but paint differs,
// or a value cannot be set in place, and the style must load again.
internal fun paintChanges(from: String, to: String): List<Pair<String, PaintPropertyValue<*>>>? = runCatching {
    val old = coreJson.parseToJsonElement(from).jsonObject
    val new = coreJson.parseToJsonElement(to).jsonObject
    if (old - "layers" != new - "layers") return null
    val before = old["layers"]?.jsonArray.orEmpty()
    val after = new["layers"]?.jsonArray.orEmpty()
    if (before.size != after.size) return null
    before.zip(after).flatMap { (a, b) ->
        val was = a.jsonObject
        val now = b.jsonObject
        if (was - "paint" != now - "paint") return null
        val oldPaint = was["paint"]?.jsonObject.orEmpty()
        val newPaint = now["paint"]?.jsonObject.orEmpty()
        if (oldPaint.keys != newPaint.keys) return null
        val id = now["id"]?.jsonPrimitive?.content ?: return null
        newPaint.filter { (key, value) -> oldPaint[key] != value }.map { (key, value) -> id to PaintPropertyValue(key, paintValue(value) ?: return null) }
    }
}.getOrNull()

// A style value as MapLibre takes it in place: an expression, or a plain text, number or flag.
// An array that is not an expression, such as a dash pattern, is left to a reload.
private fun paintValue(json: JsonElement): Any? = when {
    json is JsonArray -> if ((json.firstOrNull() as? JsonPrimitive)?.isString == true) Expression.Converter.convert(json.toString()) else null
    json is JsonPrimitive && json.isString -> json.content
    json is JsonPrimitive -> json.booleanOrNull ?: json.doubleOrNull?.toFloat()
    else -> null
}

private fun setUp(map: MapLibreMap, model: AppModel) {
    // The tracking button is the only way to turn the map.
    map.uiSettings.isRotateGesturesEnabled = false
    map.uiSettings.isTiltGesturesEnabled = false
    map.uiSettings.isCompassEnabled = false
    // MapLibre is credited under Legal in Settings.
    map.uiSettings.isLogoEnabled = false
    map.uiSettings.isAttributionEnabled = false
    // Center of the lower 48 until an option, the last camera or a fix says otherwise.
    val start = model.camera ?: CameraState(39.5, -98.35, 4.0, 0.0)
    map.cameraPosition = CameraPosition.Builder().target(LatLng(start.latitude, start.longitude))
        .zoom(start.zoom).bearing(start.heading).build()
    map.addOnMoveListener(object : MapLibreMap.OnMoveListener {
        override fun onMoveBegin(detector: MoveGestureDetector) = model.userPanned()
        override fun onMove(detector: MoveGestureDetector) {}
        override fun onMoveEnd(detector: MoveGestureDetector) {}
    })
    map.addOnCameraIdleListener {
        val at = map.cameraPosition
        val target = at.target ?: return@addOnCameraIdleListener
        val seen = map.projection.visibleRegion.latLngBounds
        model.cameraIdle(CameraState(target.latitude, target.longitude, at.zoom, at.bearing),
            ViewBox(seen.latitudeSouth, seen.longitudeWest, seen.latitudeNorth, seen.longitudeEast))
    }
}

// A tap sends what lies under the finger to the core; a long press bends the route or drops a pin.
private fun listenForPicks(view: MapView, map: MapLibreMap, model: AppModel, edit: MapEdit) {
    val density = view.resources.displayMetrics.density
    val labels = model.nav.labels
    view.setOnTouchListener { _, event ->
        edit.touched(event)
        false
    }
    map.addOnMapClickListener { at ->
        val point = map.projection.toScreenLocation(at)
        model.picked(PickArgs(hits = hitsAt(map, labels.pickLayers, labels.pickBox, density, point),
            stations = stationsAt(map, model.weather.catalog.stationLayer, labels.pickBox, density, point)))
        true
    }
    map.addOnMapLongClickListener { at ->
        view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        if (!edit.hold(at)) model.picked(PickArgs(pin = Coordinate(at.latitude, at.longitude)))
        true
    }
}

private const val PIN = "pin"

private fun installPin(style: Style, density: Float) {
    style.addImage(PIN, canvas((28 * density).toInt()) { c ->
        drawCircle(c, c, c * 0.6f, fill(PIN_RED))
        drawCircle(c, c, c * 0.6f, outline(3 * density))
    })
    style.addSource(GeoJsonSource(PIN))
    style.addLayer(SymbolLayer(PIN, PIN).withProperties(iconImage(PIN), iconAllowOverlap(true), iconIgnorePlacement(true)))
}

private fun drawPin(style: Style, pin: Coordinate?) {
    val source = style.getSourceAs<GeoJsonSource>(PIN) ?: return
    if (pin == null) return source.setGeoJson(FeatureCollection.fromFeatures(emptyList()))
    source.setGeoJson(Feature.fromGeometry(Point.fromLngLat(pin.longitude, pin.latitude)))
}

private const val RING = "place-ring"

// The ring at the open panel's place: over the nav symbols, under the route points and ownship.
private fun installRing(style: Style) {
    style.addSource(GeoJsonSource(RING))
    val ring = CircleLayer(RING, RING).withProperties(circleRadius(0f), circleStrokeWidth(3f), circleOpacity(0.2f))
    // Grows in once as a place opens; nothing moves after that.
    ring.circleRadiusTransition = TransitionOptions(300, 0)
    if (style.getLayer("route-points") != null) style.addLayerBelow(ring, "route-points") else style.addLayerBelow(ring, OWNSHIP)
}

private fun drawRing(style: Style, place: Coordinate?, ink: Int) {
    val source = style.getSourceAs<GeoJsonSource>(RING) ?: return
    style.getLayer(RING)?.setProperties(circleColor(ink), circleStrokeColor(ink), circleRadius(if (place == null) 0f else 22f))
    if (place == null) return source.setGeoJson(FeatureCollection.fromFeatures(emptyList()))
    source.setGeoJson(Feature.fromGeometry(Point.fromLngLat(place.longitude, place.latitude)))
}

// Eases each newly shown place clear of the pane or sheet when it is not there already; Show on Map always moves.
// A turn or a settled sheet moves the place again, unless the map was panned since.
private suspend fun revealPlaces(view: MapView, map: MapLibreMap, model: AppModel) {
    var revealed: Coordinate? = null
    map.addOnMoveListener(object : MapLibreMap.OnMoveListener {
        override fun onMoveBegin(detector: MoveGestureDetector) { revealed = null }
        override fun onMove(detector: MoveGestureDetector) {}
        override fun onMoveEnd(detector: MoveGestureDetector) {}
    })
    fun go(place: Coordinate, force: Boolean) {
        revealed = place
        val density = view.resources.displayMetrics.density
        val (w, h) = view.width / density to view.height / density
        if (w <= 0f) return
        val left = model.paneRight / density
        val bottom = (model.sheetTop?.div(density) ?: h).coerceAtMost(h)
        val top = (model.stripBottom / density).coerceAtMost(bottom)
        val at = map.projection.toScreenLocation(LatLng(place.latitude, place.longitude))
        val now = map.cameraPosition
        val camera = runCatching {
            reveal(RevealArgs(place, at.x / density.toDouble(), at.y / density.toDouble(),
                ScreenRect(left.toDouble(), top.toDouble(), (w - left).toDouble(), (bottom - top).toDouble()),
                w.toDouble(), h.toDouble(), now.zoom, now.bearing, force))
        }.getOrNull()?.camera ?: return
        // Moving off the aircraft stops following, as a pan does.
        model.userPanned()
        map.animateCamera(CameraUpdateFactory.newCameraPosition(CameraPosition.Builder(now)
            .target(LatLng(camera.center.latitude, camera.center.longitude)).zoom(camera.zoom).build()), 350)
    }
    coroutineScope {
        launch { model.reveals.receiveAsFlow().collect { go(it, force = true) } }
        snapshotFlow { model.shownPlace to (model.paneRight to model.sheetTop) }.collectLatest { (place, _) ->
            when {
                place == null -> revealed = null
                place != revealed -> go(place, force = false)
                // The same place with the pane or sheet moved: wait for it to settle.
                else -> { delay(400); go(place, force = false) }
            }
        }
    }
}

private fun move(map: MapLibreMap, camera: PositionResult.Camera) {
    val now = map.cameraPosition
    val builder = CameraPosition.Builder(now).bearing(camera.heading)
    if (camera.latitude != null && camera.longitude != null) builder.target(LatLng(camera.latitude, camera.longitude))
    camera.zoom?.let { builder.zoom(it) }
    map.moveCamera(CameraUpdateFactory.newCameraPosition(builder.build()))
}

private const val PLATE = "plate-overlay"

private fun corners(plate: PlateRef) = plate.geo?.corners?.takeIf { c -> c.size == 4 && c.all { it.size == 2 } }?.map { LatLng(it[1], it[0]) }

// Each plate's plan view stretched over its true corners, over the base rasters and under everything else, the last placed on top.
private fun drawPlate(style: Style, shown: List<Pair<PlateRef, Bitmap>>, paint: List<Double>?) {
    style.layers.filter { it.id.startsWith(PLATE) }.forEach { style.removeLayer(it) }
    style.sources.filter { it.id.startsWith(PLATE) }.forEach { style.removeSource(it) }
    val (min, max, hue) = paint?.takeIf { it.size == 3 } ?: listOf(0.0, 1.0, 0.0)
    // Over the base, under airspace, weather, route and ownship. On the street map the base is vector layers too.
    val overlay = style.layers.firstOrNull { it.id.startsWith("wx-") || (it as? LineLayer)?.sourceId == "nav" || (it as? CircleLayer)?.sourceId == "nav" }
    val above = overlay ?: style.layers.firstOrNull { it !is RasterLayer && it !is BackgroundLayer }
    shown.forEachIndexed { i, (plate, image) ->
        val at = corners(plate) ?: return@forEachIndexed
        val id = "$PLATE-$i"
        style.addSource(ImageSource(id, LatLngQuad(at[0], at[1], at[2], at[3]), image))
        val layer = RasterLayer(id, id).withProperties(rasterFadeDuration(0f),
            rasterBrightnessMin(min.toFloat()), rasterBrightnessMax(max.toFloat()), rasterHueRotate(hue.toFloat()))
        if (above != null) style.addLayerBelow(layer, above.id) else style.addLayer(layer)
    }
}

// Fits a placed plate's plan view on the map.
private fun fit(map: MapLibreMap, plate: PlateRef, density: Float) {
    val at = corners(plate) ?: return
    val pad = (48 * density).toInt()
    map.animateCamera(CameraUpdateFactory.newLatLngBounds(LatLngBounds.fromLatLngs(at), pad))
}

private const val OWNSHIP = "ownship"

// Fixed colors: aviation meaning never follows the dynamic scheme.
private const val OWNSHIP_LIVE = 0xFF1A73E8.toInt()
private const val OWNSHIP_STALE = 0xFF8E8E93.toInt()
private const val PIN_RED = 0xFFE53935.toInt()

private fun installOwnship(style: Style, density: Float) {
    for ((name, color) in listOf("live" to OWNSHIP_LIVE, "stale" to OWNSHIP_STALE)) {
        style.addImage("ownship-$name", arrow(color, density))
        style.addImage("ownship-$name-dot", dot(color, density))
        style.addImage("ownship-$name-ring", ring(color, density))
    }
    style.addSource(GeoJsonSource(OWNSHIP))
    style.addLayer(
        SymbolLayer(OWNSHIP, OWNSHIP).withProperties(
            iconImage(get("image")),
            iconRotate(get("track")),
            iconRotationAlignment(Property.ICON_ROTATION_ALIGNMENT_MAP),
            iconAllowOverlap(true),
            iconIgnorePlacement(true),
        ),
    )
}

private fun drawOwnship(style: Style, ownship: PositionResult.Ownship?) {
    val source = style.getSourceAs<GeoJsonSource>(OWNSHIP) ?: return
    if (ownship == null) return source.setGeoJson(FeatureCollection.fromFeatures(emptyList()))
    val feature = Feature.fromGeometry(Point.fromLngLat(ownship.longitude, ownship.latitude))
    feature.addStringProperty("image", ownship.image)
    feature.addNumberProperty("track", ownship.track)
    source.setGeoJson(feature)
}

private fun canvas(size: Int, draw: Canvas.(Float) -> Unit): Bitmap =
    Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also { Canvas(it).draw(size / 2f) }

private fun fill(color: Int) = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }

private fun outline(width: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = 0xFFFFFFFF.toInt()
    style = Paint.Style.STROKE
    strokeWidth = width
    strokeJoin = Paint.Join.ROUND
}

// An arrow pointing up (north), turned by the layer along track.
private fun arrow(color: Int, density: Float) = canvas((36 * density).toInt()) { c ->
    val r = c * 0.85f
    val path = Path().apply {
        moveTo(c, c - r)
        lineTo(c + r * 0.7f, c + r * 0.8f)
        lineTo(c, c + r * 0.35f)
        lineTo(c - r * 0.7f, c + r * 0.8f)
        close()
    }
    drawPath(path, fill(color))
    drawPath(path, outline(2 * density))
}

private fun dot(color: Int, density: Float) = canvas((24 * density).toInt()) { c ->
    drawCircle(c, c, c * 0.7f, fill(color))
    drawCircle(c, c, c * 0.7f, outline(2 * density))
}

// A wide ring, so an approximate fix never reads as the exact spot.
private fun ring(color: Int, density: Float) = canvas((64 * density).toInt()) { c ->
    drawCircle(c, c, c * 0.85f, fill(color and 0x33FFFFFF))
    drawCircle(c, c, c * 0.85f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        style = Paint.Style.STROKE
        strokeWidth = 2 * density
        pathEffect = android.graphics.DashPathEffect(floatArrayOf(6 * density, 4 * density), 0f)
    })
}
