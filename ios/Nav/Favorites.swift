import Foundation
import Observation

/// Favorite airports by FAA identifier, in the order added, kept on the device.
@MainActor @Observable final class Favorites {
    private(set) var idents: [String]
    @ObservationIgnored private let defaults: UserDefaults
    static let key = "favoriteAirports"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        idents = defaults.stringArray(forKey: Self.key) ?? []
    }

    func contains(_ ident: String) -> Bool { idents.contains(ident) }

    func toggle(_ ident: String) {
        if contains(ident) { remove(ident) } else { idents.append(ident); save() }
    }

    func remove(_ ident: String) {
        idents.removeAll { $0 == ident }
        save()
    }

    private func save() { defaults.set(idents, forKey: Self.key) }
}
