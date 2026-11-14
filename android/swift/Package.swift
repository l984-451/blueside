// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BluesideJNI",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BluesideJNI", type: .dynamic, targets: ["BluesideJNI"])],
    dependencies: [.package(path: "../../core")],
    targets: [
        .target(name: "BluesideJNI", dependencies: [.product(name: "FlightCore", package: "core")]),
        .testTarget(name: "BluesideJNITests", dependencies: ["BluesideJNI"], exclude: ["Fixtures"]),
    ]
)
