import FlightCore
import Foundation
import Testing
import UIKit
@testable import Blueside

private let t0 = WeatherFixture.checked

@MainActor private func eventually(_ what: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if what() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return what()
}

@Suite @MainActor struct WeatherStoreTests {
    private func makeStore(_ host: WeatherFakeHost, root: URL, base: URL? = WeatherFixture.base) -> WeatherStore {
        WeatherStore(cache: WeatherCache(root: root, base: base, load: host.load), now: { t0 + 60 })
    }

    @Test func nothingIsReadUntilLoadAndLoadShowsTheDiskCopy() async throws {
        let root = try WeatherFixture.folder()
        let host = try WeatherFixture.host()
        await makeStore(host, root: root).refresh()
        host.forget()
        let cold = makeStore(host, root: root, base: nil)
        #expect(cold.data == WeatherData())
        await cold.load()
        #expect(cold.data.metars.count == 2547)
        #expect(cold.data.status(of: .metars, at: t0 + 60) == .current)
        #expect(cold.data.staleLabel(for: .stations, at: t0 + 31 * 60) == "METARs not updated since 0035Z")
        #expect(host.asked.isEmpty)
    }

    @Test func refreshOnDemandPublishesNewDataAndCountsOnlyAPassThatChangedNothing() async throws {
        let host = try WeatherFixture.host(frames: [t0 - 240])
        let store = makeStore(host, root: try WeatherFixture.folder())
        await store.refresh()
        #expect(store.data.tfrs.count == 6)
        #expect(store.data.radarLoop(at: t0 + 60).count == 1)
        // The new data already redraws the map; only a pass with nothing new counts, so each pass redraws once.
        #expect(store.passes == 0)
        await store.refresh()
        #expect(store.passes == 1)
        // The store lives on the main thread; its fetching must not.
        #expect(host.asked.contains(WeatherFixture.frameName(t0 - 240)) && !host.usedMainThread)
    }

    @Test func offlineOptionMeansNoRequestIsEverMade() async throws {
        let host = try WeatherFixture.host()
        let address = ["-manifestBase", "http://127.0.0.1:9"]
        let offline = WeatherStore.make(options: LaunchOptions(arguments: address + ["-offline", "1"]),
                                        root: try WeatherFixture.folder(), environment: [:], load: host.load)
        await offline.refresh()
        offline.start(interval: 0.05)
        try await Task.sleep(for: .milliseconds(300))
        offline.stop()
        #expect(host.asked.isEmpty)
        #expect(offline.data.metars.isEmpty)
        // The same call without the option does fetch, so the check above can fail.
        let online = WeatherStore.make(options: LaunchOptions(arguments: address),
                                       root: try WeatherFixture.folder(), environment: [:], load: host.load)
        await online.refresh()
        #expect(host.asked.contains("index.json"))
        #expect(online.data.metars.count == 2547)
    }

    @Test func aUnitTestRunStaysOffTheNetwork() async throws {
        let host = try WeatherFixture.host()
        let store = WeatherStore.make(options: LaunchOptions(arguments: ["-manifestBase", "http://127.0.0.1:9"]),
                                      root: try WeatherFixture.folder(), load: host.load)
        await store.refresh()
        #expect(host.asked.isEmpty)
    }

    @Test func theTimerRefreshesAgainAndAgain() async throws {
        let host = try WeatherFixture.host()
        let store = makeStore(host, root: try WeatherFixture.folder())
        store.start(interval: 0.1)
        #expect(await eventually { host.asked.filter { $0 == "index.json" }.count >= 3 })
        store.stop()
        #expect(store.data.metars.count == 2547)
    }

    @Test func comingToTheFrontRefreshes() async throws {
        let host = try WeatherFixture.host()
        let store = makeStore(host, root: try WeatherFixture.folder())
        store.start(interval: 3600)
        #expect(await eventually { host.asked.filter { $0 == "index.json" }.count == 1 })
        // Lets the first pass end, so the second is not joined to it.
        try await Task.sleep(for: .milliseconds(500))
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(await eventually { host.asked.filter { $0 == "index.json" }.count == 2 })
        store.stop()
    }

    @Test func aHungPassIsCutOffAndReported() async throws {
        let host = try WeatherFixture.host()
        let hung: WeatherLoad = { url, tag in
            if url.lastPathComponent == "metars.json.gz" { try await Task.sleep(for: .seconds(60)) }
            return try await host.load(url, tag)
        }
        let store = WeatherStore(cache: WeatherCache(root: try WeatherFixture.folder(), base: WeatherFixture.base, load: hung),
                                 now: { t0 + 60 }, passLimit: .milliseconds(300))
        let start = ContinuousClock.now
        await store.refresh()
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(store.data.failures[.metars] == "Timed out")
    }

    @Test func aBuildWithNoAddressSaysSo() async throws {
        let host = try WeatherFixture.host()
        let store = WeatherStore.make(options: LaunchOptions(arguments: []), root: try WeatherFixture.folder(),
                                      environment: [:], info: [:], load: host.load)
        await store.refresh()
        #expect(store.data.failures[.metars] == "No server address in this build")
        #expect(host.asked.isEmpty)
    }

    @Test func twoRefreshesAtOnceMakeOnePass() async throws {
        let host = try WeatherFixture.host()
        let store = makeStore(host, root: try WeatherFixture.folder())
        async let one: Void = store.refresh()
        async let two: Void = store.refresh()
        _ = await (one, two)
        #expect(host.asked.filter { $0 == "index.json" }.count == 1)
    }
}
