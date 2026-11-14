import FlightCore
import Foundation
import Observation
import os
import Testing
@testable import Blueside

/// A view's initializer builds Plates inside a tracked body: a read there would rebuild the body when it changes.
@MainActor @Test func buildingPlatesReadsNothingAndStartsNothingUntilTheMapAppears() async throws {
    // A plates pack on disk, so taking it away below changes what the downloads list holds.
    let staged = Plates.root.appendingPathComponent("staged.pmtiles")
    try Data("pack".utf8).write(to: staged)
    try PackStore(root: Plates.root).install(PendingPack(id: PackID(cycle: "test", layer: PlateLibrary.layer, region: "ZZ"),
                                                         url: URL(filePath: "/"), sha256: Checksum.sha256(of: staged), bytes: 4,
                                                         effective: .distantPast, expires: .distantFuture, attempt: 1), from: staged)
    let read = OSAllocatedUnfairLock(initialState: false)
    let none = LaunchOptions(arguments: [])
    let downloaded = withObservationTracking { Plates(options: none, downloads: .plates(options: none)) } onChange: { read.withLock { $0 = true } }
    let bundled = withObservationTracking {
        Plates(options: LaunchOptions(arguments: ["-basePack", "nav", "-plateOnMap", "00556IL18R.PDF"]), downloads: .plates(options: none))
    } onChange: { read.withLock { $0 = true } }
    try await Task.sleep(for: .milliseconds(300))
    #expect(bundled.onMap.isEmpty, "the plates were restored before the map appeared")

    downloaded.start()
    bundled.start()
    for _ in 0..<50 where bundled.onMap.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(bundled.onMap.map(\.file) == ["00556IL18R.PDF"])
    await downloaded.downloads.remove("ZZ")
    #expect(downloaded.downloads.installed.isEmpty)
    #expect(!read.withLock { $0 }, "building Plates read state that changed since")
}

/// A camera settle before the index is read saves the map memory; it keeps the saved plates, not none.
@MainActor @Test func theMapMemoryKeepsTheSavedPlatesUntilTheyAreBackOnTheMap() async throws {
    let saved = [MapMemory.PlacedPlate(airport: "AUS", file: "00556IL18R.PDF")]
    // The test pack has no georeferenced plate, so the launch option names the one that comes back.
    let plates = Plates(options: LaunchOptions(arguments: ["-basePack", "nav", "-plateOnMap", "00556IL18R.PDF"]),
                        placed: saved, downloads: .plates(options: LaunchOptions(arguments: [])))
    #expect(plates.placed == saved)
    plates.start()
    #expect(plates.onMap.isEmpty && plates.placed == saved)
    for _ in 0..<50 where plates.onMap.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(plates.onMap.map(\.placed) == saved && plates.placed == saved)
    plates.toggle(try #require(plates.onMap.first))
    #expect(plates.placed.isEmpty)
}
