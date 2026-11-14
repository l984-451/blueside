package com.gstudios.blueside.position

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.altitude.AltitudeConverter
import android.os.Build
import android.os.SystemClock
import com.gstudios.blueside.Fix
import java.util.concurrent.Executors

// Raw fixes from LocationManager. The AOSP emulator image has no Play services, so no fused client.
// onState runs when location services turn on or off, which no fix would report.
class LocationSource(private val context: Context, private val onFix: (Fix) -> Unit, private val onState: () -> Unit) {
    private val manager = context.getSystemService(LocationManager::class.java)
    // Fixes are read on their own thread, where the geoid model behind MSL altitude may be read from disk.
    private val thread = Executors.newSingleThreadExecutor()
    // The newest fix's age stamp, so an older fix never replaces it. Read and written on the fix thread only.
    private var newest = 0L
    // Between start() and stop(), on the main thread; a fix posted after stop() is dropped.
    private var running = false
    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            if (location.elapsedRealtimeNanos < newest) return
            newest = location.elapsedRealtimeNanos
            val fix = location.toFix(msl(location))
            context.mainExecutor.execute { if (running) onFix(fix) }
        }

        override fun onProviderEnabled(provider: String) = context.mainExecutor.execute { if (running) onState() }
        override fun onProviderDisabled(provider: String) = context.mainExecutor.execute { if (running) onState() }
    }

    // A coarse-only grant reads as approximate; the core judges a fix's own error.
    val approximate: Boolean get() = granted(Manifest.permission.ACCESS_COARSE_LOCATION) && !fine
    // No permission, or location services off.
    val accessOff: Boolean get() = !permitted || !manager.isLocationEnabled
    val permitted: Boolean get() = granted(Manifest.permission.ACCESS_COARSE_LOCATION) || fine
    private val fine get() = granted(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun granted(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    fun start() {
        stop()
        if (!permitted) return
        val provider = if (fine) LocationManager.GPS_PROVIDER else LocationManager.NETWORK_PROVIDER
        if (!manager.allProviders.contains(provider)) return
        running = true
        manager.requestLocationUpdates(provider, 1000L, 0f, thread, listener)
        thread.execute { manager.getLastKnownLocation(provider)?.let(listener::onLocationChanged) }
    }

    fun stop() {
        running = false
        manager.removeUpdates(listener)
    }

    // For good: the fix thread ends too.
    fun close() {
        stop()
        thread.shutdown()
    }

    // Kept, so the geoid model is read once.
    private val converter by lazy { AltitudeConverter() }

    // Height above mean sea level: the system's where it gives one, else from its geoid model (Android 14 on).
    // Before that there is no model, and the height above the ellipsoid is never passed off as MSL.
    private fun msl(location: Location): Double? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return null
        if (!location.hasMslAltitude() && location.hasAltitude()) {
            runCatching { converter.addMslAltitudeToLocation(context, location) }
        }
        return if (location.hasMslAltitude()) location.mslAltitudeMeters else null
    }
}

// Negative course or speed means unknown, as the core reads them. The time is the fix's age on this device's clock,
// so a wrong clock never makes a live fix look stale. Without an MSL height the ellipsoid one goes for the core to convert.
private fun Location.toFix(msl: Double?) = Fix(
    latitude = latitude,
    longitude = longitude,
    course = if (hasBearing()) bearing.toDouble() else -1.0,
    speed = if (hasSpeed()) speed.toDouble() else -1.0,
    altitude = msl,
    ellipsoidAltitude = if (msl == null && hasAltitude()) altitude else null,
    time = System.currentTimeMillis() - (SystemClock.elapsedRealtimeNanos() - elapsedRealtimeNanos) / 1_000_000,
    accuracy = if (hasAccuracy()) accuracy.toDouble() else null,
)
