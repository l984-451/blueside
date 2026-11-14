package com.gstudios.blueside

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

// Decodes the golden JSON the Swift bridge tests write, so a shape change on either side fails here.
class CoreContractTest {
    private fun fixture(name: String): ByteArray =
        checkNotNull(javaClass.classLoader?.getResourceAsStream(name)) { "missing fixture $name" }.readBytes()

    // A fake core that answers one op with the fixture result and records the args it was sent.
    private class Fake(val op: String, val result: ByteArray) : CoreCall {
        var sent: ByteArray? = null
        override fun invoke(op: String, args: ByteArray): ByteArray {
            assertEquals(this.op, op)
            sent = args
            return result
        }
    }

    @Test
    fun distanceArgsAndResultMatchTheBridge() {
        val fake = Fake("distanceNM", fixture("distanceNM.result.json"))
        val nm = distanceNM(Coordinate(30.1945, -97.6699), Coordinate(32.8968, -97.0380), fake)
        assertEquals(165.436, nm, 0.01)
        assertEquals(
            Json.parseToJsonElement(fixture("distanceNM.args.json").decodeToString()),
            Json.parseToJsonElement(fake.sent!!.decodeToString()),
        )
    }

    @Test
    fun manifestResult() {
        assertEquals(2, manifestCycles(ByteArray(0), Fake("manifestCheck", fixture("manifestCheck.result.json"))))
    }

    @Test
    fun navMetadataDatesAreEpochMilliseconds() {
        val meta = navMetadata(Fake("metadata", fixture("metadata.result.json")))
        assertEquals("2026-10-01", meta.cycle)
        assertEquals(1_790_845_260_000, meta.effective)
    }

    // Args the Swift tests sent decode into the Kotlin types, so field names agree both ways.
    private inline fun <reified T> args(name: String): T = coreJson.decodeFromString(fixture("$name.args.json").decodeToString())

    @Test
    fun mapMemoryShapes() {
        val sent = args<MapMemory>("mapMemory")
        val text = mapMemory(sent, Fake("mapMemory", fixture("mapMemory.result.json")))
        val first = launch(args<LaunchArgs>("launch").copy(saved = text), Fake("launch", fixture("launch.result.json")))
        assertEquals("ifr-high", first.base)
        assertEquals(false, first.night)
        assertEquals(9.0, first.camera.zoom, 0.0)
        assertEquals("KAUS CWK", first.route)
    }

    @Test
    fun mapStyleShapes() {
        val sent = args<StyleArgs>("mapStyle")
        assertEquals("vfr", sent.base)
        val style = mapStyle(sent, Fake("mapStyle", fixture("mapStyle.result.json")))
        assertEquals("No VFR chart downloaded", style.notice)
        assertEquals(false, style.overlay)
    }

    @Test
    fun positionShapes() {
        val sent = args<PositionArgs>("position")
        assertEquals("trackUp", sent.orientation)
        val reading = position(sent, Fake("position", fixture("position.result.json")))
        assertEquals("100 kt", reading.strip.groundspeed)
        assertEquals("ownship-live", reading.ownship?.image)
        assertEquals(10.0, reading.camera?.zoom)
    }

    @Test
    fun noticesCatalogAndDownloadShapes() {
        val shown = decodeResult<Notices>(fixture("notices.result.json"))
        assertEquals("Navigation data not downloaded", shown.nav)
        val catalog = layerCatalog(Fake("layerCatalog", fixture("layerCatalog.result.json")))
        assertEquals("vfr", catalog.bases.first().id)
        val pass = decodeResult<PassResult>(fixture("pass.result.json"))
        assertEquals(3, pass.start.size)
        val rows = decodeResult<Rows>(fixture("rows.result.json"))
        assertEquals("Downloading 59%", rows.rows.first().text)
    }

    @Test
    fun navShapes() {
        val search = navSearch(args("search"), Fake("search", fixture("search.result.json")))
        assertEquals("Favorites", search.sections.first().title)
        assertEquals("AUS", search.sections[1].items.first().row.ident)
        val page = airportPage(args("airportPage"), Fake("airportPage", fixture("airportPage.result.json")))
        assertEquals("KAUS", page.page.title)
        assertEquals("Runways", page.page.runways.title)
        val card = placeCard(args("placeCard"), Fake("placeCard", fixture("placeCard.result.json")))
        assertEquals("Dropped Pin", card.card.subtitle)
        assertEquals(3, card.nearby.size)
        val picked = pick(args("pick"), Fake("pick", fixture("pick.result.json")))
        assertEquals("here", picked.open)
        assertEquals("airports", navLabels(Fake("navLabels", fixture("labels.result.json"))).pickLayers.first())
    }

    @Test
    fun routeShapes() {
        val direct = route(args("routeDirect"), Fake("route", fixture("routeDirect.result.json")))
        assertEquals("Direct To", direct.title)
        assertEquals(1, direct.line?.firstDot)
        assertEquals(true, direct.rows.first().row.isActive)
        // The plan and its key go back whole, so the core reads its own JSON. The key leaves out the plan it sits beside.
        val typedArgs = args<RouteArgs>("routeTyped")
        assert(direct.plan != null && typedArgs.plan != null && direct.planKey != null)
        assertEquals(null, direct.planKey?.jsonObject?.get("route"))
        val typed = route(typedArgs, Fake("route", fixture("routeTyped.result.json")))
        assertEquals("KAUS CWK", typed.text)
        assertEquals(listOf("Distance", "Time", "Fuel"), typed.editor?.totals?.map { it.title })
        assertEquals(listOf(0, 1), grab(args("grab"), Fake("grab", fixture("grab.result.json"))).anchors)
        assert(ruler(args("ruler"), Fake("ruler", fixture("ruler.result.json"))).startsWith("165"))
        assertEquals("Use instead?", routeLabels(Fake("routeLabels", fixture("routeLabels.result.json"))).useInstead)
    }

    @Test
    fun weatherShapes() {
        val catalog = weatherCatalog(Fake("weatherCatalog", fixture("weatherCatalog.result.json")))
        assertEquals(listOf("Radar", "Satellite", "Stations", "AIR/SIGMET/CWA", "PIREPs", "Lightning", "Winds Aloft"), catalog.toggles.map { it.title })
        assertEquals("wx-satellite-anchor", catalog.satelliteAnchor)
        assertEquals("wind-barb-65", catalog.barbs[13].name)
        assertEquals(1, catalog.barbs[13].triangles.size)
        assertEquals("TFRs", catalog.tfrs.title)
        assertEquals(14, catalog.bands.size)
        val notices = decodeResult<WxNotices>(fixture("weatherNotices.result.json"))
        assertEquals("radar", notices.labels.first().id)
    }

    @Test
    fun aircraftShapes() {
        val sent = args<WeightArgs>("weightBalance")
        assertEquals("N181PA", sent.profile.text("tail"))
        val result = weightBalance(sent, Fake("weightBalance", fixture("weightBalance.result.json")))
        assertEquals("Within limits", result.balance?.status)
        assertEquals(4, result.balance?.rows?.size)
        assertEquals("T", result.takeoffLabel)
        val labels = aircraftLabels(Fake("aircraftLabels", fixture("aircraftLabels.result.json")))
        assertEquals("tail", labels.sections.first().fields.first().key)
        assertEquals("selectedAircraft", labels.selectedKey)
    }

    @Test
    fun planAndBriefShapes() {
        val sent = args<PlanInputArgs>("planInputs")
        assertEquals("kaus", sent.alternate)
        val inputs = planInputs(sent, Fake("planInputs", fixture("planInputs.result.json")))
        assertEquals("KAUS", inputs.alternate)
        assertEquals(6500.0, inputs.inputs.number("cruiseAltitudeFt"))
        val plan = decodeResult<PlanView>(fixture("planView.result.json"))
        assertEquals(0, plan.legs.first().target)
        assertEquals(true, plan.altitudes.first().picked)
        assertEquals(0, plan.logShown.first())
        assert(plan.next != null)
        assertEquals(listOf("Distance", "Departure", "Time en route", "ETA", "Fuel required"), plan.summary.map { it.title })
        assertEquals(listOf("Taxi", "Trip", "Reserve"), plan.fuelLines.map { it.title })
        val briefArgs = args<PlanArgs>("flightBrief")
        val brief = flightBrief(briefArgs, Fake("flightBrief", fixture("flightBrief.result.json")))
        assert(brief.fileName.endsWith(".pdf"))
        assertEquals("Flight", brief.sections.first().title)
        val log = navlog(args<PlanArgs>("navlog"), Fake("navlog", fixture("navlog.result.json")))
        assertEquals(14, log.columns.size)
        assertEquals("Actual", log.columns.last())
        assertEquals(listOf("Out", "Off", "On", "In", "Hobbs"), log.boxes)
        assertEquals(null, log.weights)
        val labels = routeLabels(Fake("routeLabels", fixture("routeLabels.result.json")))
        assertEquals("Brief", labels.briefTitle)
        assertEquals("Fuel", labels.fuelBlock)
        assertEquals("Time", labels.logColumns[labels.logTime])

        val savedArgs = args<SavedArgs>("savedRoutes")
        // Central time on 15 Jan 2027 as java.time gives it is what the bridge was sent.
        assertEquals(savedArgs.localOffset, localOffset(Instant.ofEpochMilli(1_800_000_000_000), ZoneId.of("America/Chicago")))
        val saved = savedRoutes(savedArgs, Fake("savedRoutes", fixture("savedRoutes.result.json")))
        assertEquals("Hill Country", saved.saved.first().name)
        assertEquals("KAUS to CWK", saved.defaultName)
        val loaded = loadRoute(args<LoadRouteArgs>("loadRoute"), Fake("loadRoute", fixture("loadRoute.result.json")))
        assertEquals("KAUS CWK", loaded.text)
        assertEquals("KAUS", loaded.inputs.alternate)
    }

    @Test
    fun platePointShapes() {
        val sent = args<com.gstudios.blueside.plates.PlatePointArgs>("platePoint")
        val point = com.gstudios.blueside.plates.platePoint(sent, Fake("platePoint", fixture("platePoint.result.json")))
        assertEquals(2, point?.size)
        assertEquals(4, sent.geo.corners.size)
    }

    @Test
    fun trafficCatalogAndFixChoice() {
        val catalog = com.gstudios.blueside.position.trafficCatalog(Fake("trafficCatalog", fixture("trafficCatalog.result.json")))
        assertEquals(listOf("auto", "device", "receiver"), catalog.sources.map { it.id })
        assertEquals(4000, catalog.port)
        val sent = args<com.gstudios.blueside.position.ChooseFixArgs>("chooseFix")
        assertEquals(33.6, sent.receiver?.latitude)
        // A device with no MSL height sends its ellipsoid height alone.
        assertEquals(1000.5, sent.device?.ellipsoidAltitude)
        assertEquals(null, sent.device?.altitude)
        assertEquals("receiver", com.gstudios.blueside.position.chooseFix(sent, Fake("chooseFix", fixture("chooseFix.result.json"))))
    }

    @Test
    fun coreErrorsThrow() {
        val error = assertThrows(CoreException::class.java) {
            manifestCycles(ByteArray(0), Fake("manifestCheck", fixture("error.result.json")))
        }
        assertEquals("unsupportedVersion(2)", error.message)
    }
}
