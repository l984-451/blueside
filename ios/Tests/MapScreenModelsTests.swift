import Foundation
import Testing
@testable import Blueside

/// The scene builds the map screen again on its updates, so building it must make no download model of its own.
@MainActor @Test func buildingTheMapScreenHoldsOnlyTheDownloadModelsItIsGiven() {
    let given = (0..<5).map { _ in
        DownloadsModel(store: PackStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                       client: nil, configuration: .ephemeral)
    }
    let model = AppModel()
    for _ in 0..<2 {
        let screen = MapScreen(model: model, downloads: given[0], navDownloads: given[1], streetDownloads: given[2],
                               terrainDownloads: given[3], plateDownloads: given[4])
        // Its own models and the one its plates read, in the order declared.
        let held = Mirror(reflecting: screen).children.compactMap { child in
            child.value as? DownloadsModel ?? (Mirror(reflecting: child.value).descendant("_value") as? Plates)?.downloads
        }
        #expect(held.map(ObjectIdentifier.init) == given.map(ObjectIdentifier.init))
    }
}
