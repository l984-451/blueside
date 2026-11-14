package com.gstudios.blueside

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

// The shared Swift core over one JSON boundary. Dates cross as epoch milliseconds.
object Core {
    init {
        System.loadLibrary("BluesideJNI")
    }

    external fun call(op: String, args: ByteArray): ByteArray

    // Returns 0 when the object cannot be opened. Kinds: "nav".
    external fun open(kind: String, path: String): Long

    external fun close(handle: Long)

    external fun callHandle(handle: Long, op: String, args: ByteArray): ByteArray
}

typealias CoreCall = (String, ByteArray) -> ByteArray

class CoreException(message: String) : Exception(message)

// Every field is sent, except nulls, which Swift reads as absent optionals.
val coreJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = false
}

// Decodes a core result, or throws the core's {"error": …}.
inline fun <reified R> decodeResult(bytes: ByteArray): R {
    val element = coreJson.parseToJsonElement(bytes.decodeToString())
    element.jsonObject["error"]?.let { throw CoreException(it.jsonPrimitive.content) }
    return coreJson.decodeFromJsonElement<R>(element)
}

inline fun <reified A, reified R> CoreCall.request(op: String, args: A): R =
    decodeResult(this(op, coreJson.encodeToString(args).encodeToByteArray()))

@Serializable data class Coordinate(val latitude: Double, val longitude: Double)

@Serializable data class DistanceArgs(val from: Coordinate, val to: Coordinate)

@Serializable data class DistanceResult(val nm: Double)

@Serializable data class ManifestResult(val cycles: Int)

@Serializable data class NavMetadata(val cycle: String, val effective: Long, val expires: Long)

fun distanceNM(from: Coordinate, to: Coordinate, call: CoreCall = Core::call): Double =
    call.request<DistanceArgs, DistanceResult>("distanceNM", DistanceArgs(from, to)).nm

// A size in the core's words, such as 412 MB.
fun byteCount(bytes: Long, call: CoreCall = Core::call): String =
    call.request<Map<String, Long>, Map<String, String>>("byteCount", mapOf("bytes" to bytes)).getValue("text")

fun manifestCycles(manifest: ByteArray, call: CoreCall = Core::call): Int =
    decodeResult<ManifestResult>(call("manifestCheck", manifest)).cycles

// Takes a call bound to an open nav handle, such as { op, args -> Core.callHandle(handle, op, args) }.
fun navMetadata(call: CoreCall): NavMetadata = decodeResult(call("metadata", ByteArray(0)))
