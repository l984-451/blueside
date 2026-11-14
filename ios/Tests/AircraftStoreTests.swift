import FlightCore
import Foundation
import Testing
@testable import Blueside

@MainActor struct AircraftStoreTests {
    let defaults: UserDefaults
    let file = URL.temporaryDirectory.appendingPathComponent("aircraft-\(UUID().uuidString).json")

    init() {
        let name = "aircraft-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    @Test func oldSpeedAndBurnMigrateOnceIntoTheFile() {
        defaults.set(120.0, forKey: RoutePages.speedKey)
        defaults.set(9.5, forKey: RoutePages.burnKey)
        let store = AircraftStore(file: file, defaults: defaults)
        #expect(store.list.count == 1)
        #expect(store.aircraft(for: nil)?.tail == AircraftProfile.migratedTail)
        #expect(store.aircraft(for: nil)?.cruiseTASKt == 120 && store.aircraft(for: nil)?.burnGPH == 9.5)
        #expect(defaults.object(forKey: RoutePages.speedKey) == nil)
        // A relaunch reads the file and keeps the choice.
        let again = AircraftStore(file: file, defaults: defaults)
        #expect(again.list == store.list && again.aircraft(for: nil)?.id == store.aircraft(for: nil)?.id)
    }

    private var flightAircraftID: UUID? {
        RoutePages.planInputs(stored: defaults.data(forKey: RoutePages.planInputsKey), now: .now).aircraftID
    }

    @Test func theOldChoiceMovesIntoTheFlight() {
        var first = AircraftTemplates.c172s, second = AircraftTemplates.c172s
        first.tail = "N1"
        second.tail = "N2"
        second.id = UUID()
        AircraftStore(file: file, defaults: defaults).add(first, replace: false)
        AircraftStore(file: file, defaults: defaults).add(second, replace: false)
        defaults.set(second.id.uuidString, forKey: AircraftPages.selectedKey)
        let store = AircraftStore(file: file, defaults: defaults)
        #expect(flightAircraftID == second.id)
        #expect(defaults.object(forKey: AircraftPages.selectedKey) == nil)
        #expect(store.aircraft(for: flightAircraftID)?.tail == "N2")
    }

    @Test func aNewAircraftBecomesTheFlights() {
        let store = AircraftStore(file: file, defaults: defaults)
        var p = AircraftTemplates.c172s
        p.tail = "N12345"
        #expect(store.save(p).isEmpty)
        #expect(flightAircraftID == p.id)
    }

    @Test func saveRefusesWhatTheCoreRejectsAndDeleteRemoves() {
        let store = AircraftStore(file: file, defaults: defaults)
        #expect(!store.save(AircraftTemplates.c172s).isEmpty)
        var p = AircraftTemplates.c172s
        p.tail = "N12345"
        #expect(store.save(p).isEmpty)
        #expect(AircraftStore(file: file, defaults: defaults).list == [p])
        store.delete(p.id)
        #expect(AircraftStore(file: file, defaults: defaults).list.isEmpty)
    }

    @Test func importAsksBeforeReplacingATail() throws {
        let store = AircraftStore(file: file, defaults: defaults)
        var p = AircraftTemplates.pa28181
        p.tail = "N8100"
        _ = store.save(p)
        var other = p
        other.id = UUID()
        let data = try other.exported().data
        #expect(store.importFile(data) == .conflict(other))
        #expect(store.importFile(data, replace: false) == .added)
        #expect(store.list.count == 2)
        #expect(store.importFile(Data("{}".utf8)) != .added)
    }

    @Test func aLoadOutlivesARelaunchAndGoesWithItsAircraft() {
        let store = AircraftStore(file: file, defaults: defaults)
        var p = AircraftTemplates.c172s
        p.tail = "N12345"
        #expect(store.save(p).isEmpty)
        let load = AircraftStore.Load(weights: [340, nil, 20], startFuel: 53, burned: 20)
        store.loads[p.id] = load
        #expect(AircraftStore(file: file, defaults: defaults).loads == [p.id: load])
        store.delete(p.id)
        #expect(AircraftStore(file: file, defaults: defaults).loads.isEmpty)
    }
}
