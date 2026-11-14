import FlightCore
import Foundation
import Observation
import UIKit

/// The weather the app holds and the loop that keeps it fresh. Views read `data` and pass the time to its questions.
@MainActor @Observable final class WeatherStore {
    private(set) var data = WeatherData()
    /// Goes up after a pass that left `data` as it was, so a view that reads both redraws once per pass and
    /// still asks its time questions again.
    private(set) var passes = 0

    @ObservationIgnored private let cache: WeatherCache
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let passLimit: Duration
    /// Set when this build should fetch but has no address, so the gap is reported, not silent.
    @ObservationIgnored var noAddress = false
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var foreground: (any NSObjectProtocol)?

    init(cache: WeatherCache, now: @escaping @Sendable () -> Date = { Date() }, passLimit: Duration = .seconds(WeatherPolicy.passLimit)) {
        self.cache = cache
        self.now = now
        self.passLimit = passLimit
    }

    /// The store the app uses, on the chart list's address. Offline launches and unit test runs fetch nothing.
    static func make(options: LaunchOptions, root: URL = WeatherCache.standardRoot,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     info: [String: Any]? = Bundle.main.infoDictionary,
                     load: @escaping WeatherLoad = WeatherCache.http()) -> WeatherStore {
        let quiet = options.flag("offline") || environment["XCTestConfigurationFilePath"] != nil
        let base = quiet ? nil : ManifestClient.baseURL(options: options, info: info)
        let store = WeatherStore(cache: WeatherCache(root: root, base: base, load: load))
        store.noAddress = !quiet && base == nil
        return store
    }

    /// Shows the disk copy. Touches no network.
    func load() async {
        data = await cache.read()
    }

    /// One pass now, cut off after the pass limit. A pass already under way is joined, not doubled.
    func refresh() async {
        if let running { return await running.value }
        let pass = Task {
            let time = now()
            let before = data
            let work = Task {
                // Published twice: the small files first, then again when the radar pictures are in.
                data = await cache.refresh(now: time)
                data = await cache.fetchFrames(now: time)
            }
            let limit = Task { [passLimit] in
                try await Task.sleep(for: passLimit)
                work.cancel()
            }
            await work.value
            limit.cancel()
            if noAddress {
                for source in WeatherSource.allCases { data.failures[source] = WeatherPolicy.noAddress }
            }
            if data == before { passes += 1 }
            // Cleared here, so a call made right after a pass ends starts a new one.
            running = nil
        }
        running = pass
        await pass.value
    }

    /// Reads the disk, then refreshes every `interval` seconds and each time the app comes to the front.
    func start(interval: TimeInterval = WeatherPolicy.refreshInterval) {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            await self?.load()
            while !Task.isCancelled, self != nil {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    enum LoopState: Equatable {
        case off
        case loading(String)
        case playing([RadarLoopFrame], showing: Int)
    }

    /// The radar loop the clock label plays on request.
    private(set) var loop = LoopState.off
    @ObservationIgnored private var looping: Task<Void, Never>?
    @ObservationIgnored private var cleaning: Task<Void, Never>?

    func toggleLoop() {
        if loop != .off { return stopLoop() }
        loop = .loading(RadarLoop.loading(0, of: 1))
        looping = Task { [cache, now, cleaning] in
            await cleaning?.value
            let frames = await cache.startLoop(now: now()) { done, total in
                await MainActor.run { [weak self] in
                    if case .loading = self?.loop { self?.loop = .loading(RadarLoop.loading(done, of: total)) }
                }
            }
            var i = 0
            while frames.count > 1, !Task.isCancelled {
                loop = .playing(frames, showing: i)
                guard (try? await Task.sleep(for: .seconds(RadarLoop.hold(i, of: frames.count)))) != nil else { return }
                i = (i + 1) % frames.count
                if i == 0, await cache.isLoopExpired(now: now()) { break }
            }
            if !Task.isCancelled { stopLoop() }
        }
    }

    /// Back to the newest picture; the loop's downloads are deleted.
    func stopLoop() {
        guard loop != .off else { return }
        looping?.cancel()
        looping = nil
        loop = .off
        cleaning = Task { [cache] in await cache.stopLoop() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
        foreground = nil
    }
}
