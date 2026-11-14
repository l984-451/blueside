import Testing
@testable import FlightCore

// NGS data sheets: PID, latitude, longitude, NAD 83 ellipsoid height, orthometric height on the area's vertical
// datum, in meters. Leveled heights except American Samoa's, which NGS gives from GPS.
private let surveyed: [(pid: String, latitude: Double, longitude: Double, ellipsoid: Double, orthometric: Double)] = [
    ("DN7763", 30.182324, -97.686952, 122.563, 148.600),   // P 1521, Austin TX, NAVD 88
    ("DR6931", 38.575598, -121.491676, -24.585, 6.318),    // MONTEREY, Sacramento CA, NAVD 88
    ("AA2846", 44.804532, -68.810319, 21.707, 46.602),     // BANG A, Bangor ME, NAVD 88
    ("TT0396", 60.134475, -149.426420, 21.847, 9.949),     // X 74, Seward AK, NAVD 88
    ("AA6427", 21.332892, -157.891596, 18.459, 2.175),     // B 111, Honolulu HI, LMSL
    ("DE5469", 18.443523, -66.080025, -36.804, 5.845),     // DIAZ, San Juan PR, PRVD02
    ("DK7153", 17.737095, -64.720172, 28.672, 69.962),     // B 1012, St Croix VI, VIVD09
    ("DH3104", 13.480310, 144.730033, 65.180, 10.752),     // GGN 0001, Guam, GUVD04
    ("DG3974", 15.217691, 145.728800, 56.520, 2.073),      // AMP 1, Saipan MP, NMVD03
    ("AA3712", -14.276408, -170.680734, 36.274, 2.7),      // NO 1, Pago Pago AS, LMSL
]

@Test func ellipsoidHeightMinusGeoidIsTheSurveyedHeight() throws {
    // NAD 83 and the local datums sit up to about 2 m off WGS-84 and EGM96, beside the table's 2.5 m.
    for mark in surveyed {
        let geoid = try #require(Geoid.height(latitude: mark.latitude, longitude: mark.longitude))
        #expect(abs(mark.ellipsoid - geoid - mark.orthometric) < 4, "\(mark.pid) gave \(geoid)")
    }
}

// EGM96 at table corners, from egm96_15.gtx, including the Aleutians west of 180.
@Test func geoidMatchesTheSourceGridAtTableCorners() throws {
    let corners: [(Double, Double, Double)] = [
        (38.75, -77.25, -33.162), (61.0, -150.0, 8.159), (52.5, 174.0, 8.319), (21.25, -157.75, 15.439),
        (26.0, -170.0, 3.034), (18.25, -66.25, -41.229), (13.5, 144.75, 54.778), (-14.25, -170.0, 30.512),
    ]
    for (latitude, longitude, egm96) in corners {
        let got = try #require(Geoid.height(latitude: latitude, longitude: longitude))
        #expect(abs(got - egm96) <= 0.5, "\(latitude) \(longitude) gave \(got)")
    }
}

@Test func geoidIsUnknownOutsideTheTable() {
    #expect(Geoid.height(latitude: 51.5, longitude: -0.1) == nil)
    #expect(Geoid.height(latitude: .nan, longitude: -97.7) == nil)
    #expect(Geoid.height(latitude: 30.2, longitude: .infinity) == nil)
}
