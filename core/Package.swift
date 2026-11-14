// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FlightCore",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [.library(name: "FlightCore", targets: ["FlightCore"])],
    targets: [
        // SQLite built from source, so every platform has the same version with FTS5 and R-tree.
        .target(
            name: "CSQLite",
            exclude: ["SQLITE-VERSION.txt"],
            cSettings: [
                .define("SQLITE_ENABLE_RTREE"),
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_DQS", to: "0"),
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
            ]
        ),
        .target(name: "FlightCore", dependencies: ["CSQLite"]),
        .testTarget(name: "FlightCoreTests", dependencies: ["FlightCore", "CSQLite"], exclude: ["Fixtures"]),
    ]
)
