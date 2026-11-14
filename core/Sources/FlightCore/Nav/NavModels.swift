public enum NavDatabaseError: Error, Equatable {
    /// The file is missing, unreadable, damaged or not a database.
    case cannotOpen(String)
    /// The schema version is absent (nil) or one this code does not read.
    case unsupportedSchema(found: String?)
    /// A required value in the meta table is absent or malformed, or (key "airports") an index is unfilled.
    case badMetadata(key: String)
    case queryFailed(String)
}

public enum NavCurrency: Equatable, Sendable {
    case notYetEffective
    case current
    case expired
}

public struct NavMetadata: Equatable, Sendable {
    public var schemaVersion: Int
    /// The FAA cycle date, such as 2026-10-01.
    public var cycle: String
    public var effective: Date
    public var expires: Date
    public var builtAt: Date
    /// When the special use airspace was fetched. Nil when the file does not say.
    public var suaSnapshot: Date? = nil

    public init(schemaVersion: Int, cycle: String, effective: Date, expires: Date, builtAt: Date,
                suaSnapshot: Date? = nil) {
        (self.schemaVersion, self.cycle, self.effective, self.expires) = (schemaVersion, cycle, effective, expires)
        (self.builtAt, self.suaSnapshot) = (builtAt, suaSnapshot)
    }

    /// Where the given time falls against the cycle. The caller supplies the time.
    public func currency(at now: Date) -> NavCurrency {
        if now < effective { return .notYetEffective }
        return now < expires ? .current : .expired
    }
}

public struct Airport: Equatable, Sendable, Identifiable {
    public var id: Int64
    /// FAA identifier, such as AUS or T82.
    public var ident: String
    /// Nil for most facilities. Never built from the FAA identifier.
    public var icao: String?
    public var name: String
    public var city: String
    public var state: String
    /// A airport, H heliport, C water landing base, U ultralight, G glider, B balloon.
    public var type: String
    /// PU public, PR private.
    public var use: String
    public var coordinate: Coordinate
    public var elevationFt: Double?
    /// Degrees and direction as published, such as 4E.
    public var magneticVariation: String?
    public var patternAltitude: String?
    /// NON-ATCT, or a value starting ATCT.
    public var tower: String
    public var fuel: String?
    public var artcc: String?
    /// O operational, CI closed indefinitely, CP closed permanently.
    public var status: String

    public var isOperational: Bool { status == "O" }
}

public struct NearbyAirport: Equatable, Sendable {
    public var airport: Airport
    public var distanceNM: Double
    /// Initial true bearing from the query point, in degrees.
    public var bearingTrue: Double
}

public struct RunwayEnd: Equatable, Sendable, Identifiable {
    /// The end's designator, such as 18L.
    public var id: String
    public var trueHeading: Int?
    /// Nil when the FAA does not say.
    public var rightTraffic: Bool?
    public var coordinate: Coordinate?
    public var elevationFt: Double?
    public var displacedThresholdFt: Int?
    public var vgsi: String?
    public var approachLights: String?
    public var toraFt: Int?
    public var ldaFt: Int?
}

public struct Runway: Equatable, Sendable, Identifiable {
    /// The runway's designator, such as 18L/36R, or H1 for a helipad.
    public var id: String
    public var lengthFt: Int?
    public var widthFt: Int?
    public var surface: String?
    public var condition: String?
    public var lights: String?
    public var ends: [RunwayEnd]
}

/// Listed in the order an airport page shows them.
public enum FrequencyKind: String, Sendable, CaseIterable {
    case ctaf, tower, ground, clearance, atis, weather, approach, departure, unicom, emergency, other
}

public struct Frequency: Equatable, Sendable {
    public var kind: FrequencyKind
    /// The FAA's own description, such as LCL/P or APCH/P DEP/P IC.
    public var use: String
    /// As published, such as 121.0.
    public var frequency: String
    public var callSign: String?
    public var sector: String?
    public var remark: String?
}

public struct Remark: Equatable, Sendable {
    public var tab: String?
    public var field: String?
    public var element: String?
    public var seq: Int?
    public var text: String
}

public struct AirportDetail: Equatable, Sendable {
    public var airport: Airport
    public var runways: [Runway]
    public var frequencies: [Frequency]
    public var remarks: [Remark]
    /// Taxiways, aprons, buildings and FBOs mapped in OpenStreetMap, empty when none are or the file predates them.
    public var surface: [SurfaceFeature] = []
}

/// One OpenStreetMap feature on an airport, in feet east and north of the airport's point.
public struct SurfaceFeature: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case taxiway, taxilane, hold, apron, building, fbo
    }

    public var kind: Kind
    /// A taxiway's letter, such as A or B2, or an FBO's name.
    public var name: String?
    /// A line, an open ring for an apron or building, or one point.
    public var points: [[Double]]
}

public enum WaypointKind: String, Hashable, Sendable, Codable, CaseIterable {
    case airport, navaid, fix, user
}

public struct Navaid: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var ident: String
    /// VORTAC, VOR/DME, NDB and so on, in the FAA's wording.
    public var type: String
    public var name: String
    public var city: String?
    public var state: String?
    public var coordinate: Coordinate
    public var elevationFt: Double?
    public var frequency: String?
    public var channel: String?
    /// Degrees and direction as published, such as 6E.
    public var magneticVariation: String?
    /// The FAA's wording, such as OPERATIONAL IFR or SHUTDOWN.
    public var status: String?

    public var isShutDown: Bool { status == "SHUTDOWN" }
    /// False for VOR test signals and fan markers, which share identifiers with real navaids nearby.
    public var isRoutePoint: Bool { type != "VOT" && type != "FAN MARKER" }
}

public struct Fix: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var ident: String
    public var state: String?
    public var coordinate: Coordinate
    public var use: String?
    /// Comma-separated chart types.
    public var charts: String?
}

public struct AirwayPoint: Equatable, Sendable {
    public var ident: String
    public var pointType: String?
    public var coordinate: Coordinate
    public var meaFt: Int?
}

/// Points of one airway that can be flown in sequence, in either direction, without a break.
public struct AirwayRun: Equatable, Sendable {
    /// C contiguous US, A Alaska, H Hawaii.
    public var location: String
    public var points: [AirwayPoint]
}

/// One suggestion for an identifier being typed.
public struct WaypointMatch: Hashable, Sendable {
    public var kind: WaypointKind
    /// FAA identifier.
    public var ident: String
    /// Airports only, and only when the FAA lists one.
    public var icao: String?
    public var name: String
    public var coordinate: Coordinate
    /// Airports only.
    public var elevationFt: Double?

    public init(kind: WaypointKind, ident: String, icao: String? = nil, name: String, coordinate: Coordinate,
                elevationFt: Double? = nil) {
        self.kind = kind
        self.ident = ident
        self.icao = icao
        self.name = name
        self.coordinate = coordinate
        self.elevationFt = elevationFt
    }
}

/// A tower or other obstacle from the FAA obstacle file, 200 ft above ground or taller.
public struct Obstacle: Equatable, Sendable {
    public var coordinate: Coordinate
    public var aglFt: Int
    public var mslFt: Int
    public var type: String?
}
