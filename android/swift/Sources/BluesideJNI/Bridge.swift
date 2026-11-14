import FlightCore

/// The core over one JSON boundary. Arguments and results are JSON; dates are epoch milliseconds.
/// A thrown error comes back as {"error": "..."}.
public enum Bridge {
    enum Failure: Error { case unknownOp(String), unknownKind(String), badHandle, notFound(String) }

    struct Distance: Codable { var from: Coordinate; var to: Coordinate }

    struct Metadata: Encodable {
        var cycle: String
        var effective: Date
        var expires: Date
    }

    static func call(_ op: String, _ args: Data) -> Data {
        respond {
            switch op {
            case "distanceNM":
                let a = try decoder.decode(Distance.self, from: args)
                return ["nm": Geo.distanceNM(from: a.from, to: a.to)]
            case "byteCount":
                return ["text": DownloadPolicy.byteCount(try decoder.decode([String: Int64].self, from: args)["bytes"] ?? 0)]
            case "manifestCheck":
                return ["cycles": try Manifest.decode(args).cycles.count]
            case "mapStyle": return try style(decoder.decode(StyleArgs.self, from: args))
            case "streetKey": return streetKey(try decoder.decode(StreetArgs.self, from: args))
            case "notices": return try notices(decoder.decode(NoticeArgs.self, from: args))
            case "layerCatalog": return catalog
            case "weatherCatalog": return weatherCatalog
            case "plates": return plates(try decoder.decode(PlatesArgs.self, from: args))
            case "plateExtract": return plateExtract(try decoder.decode(ExtractArgs.self, from: args))
            case "platePoint": return platePoint(try decoder.decode(PlatePointArgs.self, from: args))
            case "navLabels": return Labels()
            case "position": return position(try decoder.decode(PositionArgs.self, from: args))
            case "tracking": return tracking(try decoder.decode(TrackingArgs.self, from: args))
            case "reveal": return reveal(try decoder.decode(RevealArgs.self, from: args))
            case "launch": return launch(try decoder.decode(LaunchArgs.self, from: args))
            case "mapMemory": return mapMemory(try decoder.decode(MapMemory.self, from: args))
            case "trafficCatalog": return TrafficCatalog()
            case "chooseFix": return chooseFix(try decoder.decode(ChooseArgs.self, from: args))
            case "background": return background(try decoder.decode(BackgroundArgs.self, from: args))
            default:
                guard let result = try routeCall(op, args) ?? aircraftCall(op, args) else { throw Failure.unknownOp(op) }
                return result
            }
        }
    }

    struct Empty: Codable {}

    static func callHandle(_ object: AnyObject, _ op: String, _ args: Data) -> Data {
        respond {
            func arg<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(type, from: args) }
            switch (object, op) {
            case let (nav as NavSession, _): return try navCall(nav, op, args)
            case let (weather as WeatherSession, _): return try weatherCall(weather, op, args)
            case let (traffic as TrafficSession, _): return try trafficCall(traffic, op, args)
            case let (coverage as PackCoverage, "gap"): return gap(coverage, try arg(GapArgs.self))
            case let (s as PackSession, "configure"): s.configure(try arg(PackSession.Configure.self)); return Empty()
            case let (s as PackSession, "listFetched"): s.listFetched(try arg(PackSession.ListFetched.self)); return Empty()
            case let (s as PackSession, "refresh"): return s.refresh(try arg(PackSession.Now.self))
            case let (s as PackSession, "pass"): return s.pass(try arg(PackSession.PassArgs.self))
            case let (s as PackSession, "event"): return s.event(try arg(PackSession.Event.self))
            case let (s as PackSession, "rows"): return s.rows(try arg(PackSession.RowsArgs.self))
            case let (s as PackSession, "choose"): s.choose(try arg(PackSession.RegionArgs.self)); return Empty()
            case let (s as PackSession, "retry"): s.retry(try arg(PackSession.RegionArgs.self)); return Empty()
            case let (s as PackSession, "remove"): return s.remove(try arg(PackSession.RegionArgs.self))
            case let (s as PackSession, "seed"): s.seed(try arg(PackSession.SeedArgs.self)); return Empty()
            default:
                throw Failure.unknownOp(op)
            }
        }
    }

    /// Opens a stateful object. Kinds: "nav" (a database path), "packs" (a store folder), "weather" (its folder), "coverage" and "traffic" (no path).
    static func open(_ kind: String, _ path: String) throws -> AnyObject {
        switch kind {
        case "nav": return try NavSession(path: path)
        case "packs": return PackSession(root: path)
        case "coverage": return PackCoverage()
        case "weather": return WeatherSession(root: path)
        case "traffic": return TrafficSession()
        default: throw Failure.unknownKind(kind)
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Whole milliseconds: Kotlin reads dates as Long and rejects a fraction.
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func respond(_ body: () throws -> any Encodable) -> Data {
        do {
            return try encoder.encode(body())
        } catch {
            return (try? encoder.encode(["error": "\(error)"])) ?? Data(#"{"error":"encoding"}"#.utf8)
        }
    }
}

#if canImport(Android)
import Android

private func bytes(_ env: UnsafeMutablePointer<JNIEnv?>, _ array: jbyteArray?) -> Data {
    let jni = env.pointee!.pointee
    guard let array else { return Data() }
    var out = [jbyte](repeating: 0, count: Int(jni.GetArrayLength(env, array)))
    if !out.isEmpty { jni.GetByteArrayRegion(env, array, 0, jsize(out.count), &out) }
    return Data(out.map { UInt8(bitPattern: $0) })
}

private func string(_ env: UnsafeMutablePointer<JNIEnv?>, _ text: jstring?) -> String {
    let jni = env.pointee!.pointee
    guard let text, let chars = jni.GetStringUTFChars(env, text, nil) else { return "" }
    defer { jni.ReleaseStringUTFChars(env, text, chars) }
    return String(cString: chars)
}

private func byteArray(_ env: UnsafeMutablePointer<JNIEnv?>, _ data: Data) -> jbyteArray? {
    let jni = env.pointee!.pointee
    guard let array = jni.NewByteArray(env, jsize(data.count)) else { return nil }
    let signed = data.map { jbyte(bitPattern: $0) }
    signed.withUnsafeBufferPointer { jni.SetByteArrayRegion(env, array, 0, jsize(signed.count), $0.baseAddress) }
    return array
}

private func object(_ handle: jlong) -> AnyObject? {
    UnsafeRawPointer(bitPattern: Int(handle)).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
}

@_cdecl("Java_com_gstudios_blueside_Core_call")
public func jniCall(env: UnsafeMutablePointer<JNIEnv?>, thiz: jobject?, op: jstring?, args: jbyteArray?) -> jbyteArray? {
    byteArray(env, Bridge.call(string(env, op), bytes(env, args)))
}

/// Returns 0 when the object cannot be opened.
@_cdecl("Java_com_gstudios_blueside_Core_open")
public func jniOpen(env: UnsafeMutablePointer<JNIEnv?>, thiz: jobject?, kind: jstring?, path: jstring?) -> jlong {
    guard let opened = try? Bridge.open(string(env, kind), string(env, path)) else { return 0 }
    return jlong(Int(bitPattern: Unmanaged.passRetained(opened).toOpaque()))
}

@_cdecl("Java_com_gstudios_blueside_Core_close")
public func jniClose(env: UnsafeMutablePointer<JNIEnv?>, thiz: jobject?, handle: jlong) {
    guard let pointer = UnsafeRawPointer(bitPattern: Int(handle)) else { return }
    Unmanaged<AnyObject>.fromOpaque(pointer).release()
}

@_cdecl("Java_com_gstudios_blueside_Core_callHandle")
public func jniCallHandle(
    env: UnsafeMutablePointer<JNIEnv?>, thiz: jobject?, handle: jlong, op: jstring?, args: jbyteArray?
) -> jbyteArray? {
    let result = object(handle).map { Bridge.callHandle($0, string(env, op), bytes(env, args)) }
        ?? Bridge.respond { throw Bridge.Failure.badHandle }
    return byteArray(env, result)
}
#endif
