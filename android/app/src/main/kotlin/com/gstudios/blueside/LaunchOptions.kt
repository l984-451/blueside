package com.gstudios.blueside

import android.content.Intent

// Test hooks as intent extras, such as: am start -n com.gstudios.blueside/.MainActivity --es base vfr --es night 1.
// Keys: base, night, center (lat,lon), zoom, follow, seedPacks, offline, manifestBase, show (layers, downloads),
// overlaysOn (switch ids, comma separated), orientation (northUp, trackUp), reset (forget the saved setup).
data class LaunchOptions(private val values: Map<String, String>) {
    fun string(key: String): String? = values[key]

    fun double(key: String): Double? = values[key]?.toDoubleOrNull()?.takeIf { it.isFinite() }

    fun flag(key: String): Boolean = values[key]?.lowercase() in setOf("1", "true", "yes")

    // Reads "latitude,longitude". Null when a part is missing, not a number, or out of range.
    fun coordinate(key: String): Coordinate? {
        val parts = values[key]?.split(",")?.map { it.trim().toDoubleOrNull() } ?: return null
        val (lat, lon) = parts.takeIf { it.size == 2 } ?: return null
        if (lat == null || lon == null || lat !in -90.0..90.0 || lon !in -180.0..180.0) return null
        return Coordinate(lat, lon)
    }

    companion object {
        fun from(intent: Intent?): LaunchOptions {
            val extras = intent?.extras ?: return LaunchOptions(emptyMap())
            return LaunchOptions(extras.keySet().associateWith { extras.getString(it) ?: "" })
        }
    }
}
