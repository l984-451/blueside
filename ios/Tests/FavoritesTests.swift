import Foundation
import Testing
@testable import Blueside

@MainActor struct FavoritesTests {
    let defaults: UserDefaults

    init() {
        let name = "favorites-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    @Test func addsInOrderAndRemoves() {
        let favorites = Favorites(defaults: defaults)
        favorites.toggle("AUS")
        favorites.toggle("T82")
        favorites.toggle("EDC")
        #expect(favorites.idents == ["AUS", "T82", "EDC"])
        favorites.toggle("T82")
        #expect(favorites.idents == ["AUS", "EDC"])
        favorites.remove("AUS")
        #expect(favorites.idents == ["EDC"])
        #expect(!favorites.contains("AUS"))
    }

    @Test func survivesARelaunch() {
        Favorites(defaults: defaults).toggle("AUS")
        let first = Favorites(defaults: defaults)
        first.toggle("T82")
        #expect(Favorites(defaults: defaults).idents == ["AUS", "T82"])
    }
}
