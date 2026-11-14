import FlightCore
import Foundation
import UIKit

/// Runs pack transfers on a system session, verifies each file and hands it to the store.
final class PackDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case started(PackID)
        case progress(PackID, Double)
        case installed(PackID)
        case failed(PackID, String)
        /// Stopped on request, by the app or by the system. Not a failure.
        case stopped(PackID)

        var id: PackID {
            switch self {
            case .started(let id), .progress(let id, _), .installed(let id), .failed(let id, _), .stopped(let id): id
            }
        }
    }

    static let checksumFailure = DownloadPolicy.checksumFailure
    static let unreadableFailure = DownloadPolicy.unreadableFailure

    private let store: PackStore
    private let onEvent: @Sendable (Event) -> Void
    private var session: URLSession!

    /// A session that keeps transferring with the app closed.
    static func backgroundConfiguration(identifier: String = "packs") -> URLSessionConfiguration {
        let bundle = Bundle.main.bundleIdentifier ?? "blueside"
        let configuration = URLSessionConfiguration.background(withIdentifier: "\(bundle).\(identifier)")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return configuration
    }

    init(store: PackStore, configuration: URLSessionConfiguration, onEvent: @escaping @Sendable (Event) -> Void) {
        self.store = store
        self.onEvent = onEvent
        super.init()
        // Creating the session at once lets transfers from an earlier launch report in.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func start(_ pending: PendingPack) {
        let task = session.downloadTask(with: pending.url)
        task.taskDescription = (try? JSONEncoder().encode(pending)).map { String(decoding: $0, as: UTF8.self) }
        task.resume()
        onEvent(.started(pending.id))
    }

    /// Transfers the system still holds, including ones started before a relaunch.
    func active() async -> [PendingPack] {
        await session.allTasks.filter { $0.state == .running || $0.state == .suspended }
            .compactMap(Self.pending(of:))
    }

    /// Stops every transfer for a region.
    func cancel(region: String) async {
        for task in await session.allTasks where Self.pending(of: task)?.id.region == region { task.cancel() }
    }

    private static func pending(of task: URLSessionTask) -> PendingPack? {
        task.taskDescription.flatMap { try? JSONDecoder().decode(PendingPack.self, from: Data($0.utf8)) }
    }

    // Told once per whole percent, so a fast link does not redraw the list hundreds of times a second.
    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didWriteData sent: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0, written * 100 / expected != (written - sent) * 100 / expected,
              let pending = Self.pending(of: downloadTask) else { return }
        onEvent(.progress(pending.id, Double(written) / Double(expected)))
    }

    // The temporary file is gone when this returns, so the check and the move happen here.
    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let pending = Self.pending(of: downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            onEvent(.failed(pending.id, DownloadPolicy.serverFailure(status: status)))
            return
        }
        do {
            try store.install(pending, from: location)
            onEvent(.installed(pending.id))
        } catch PackStore.StoreError.checksumMismatch where DownloadPolicy.retriesChecksum(attempt: pending.attempt) {
            var again = pending
            again.attempt += 1
            start(again)
        } catch PackStore.StoreError.checksumMismatch {
            onEvent(.failed(pending.id, Self.checksumFailure))
        } catch PackStore.StoreError.rejected {
            onEvent(.failed(pending.id, Self.unreadableFailure))
        } catch {
            onEvent(.failed(pending.id, error.localizedDescription))
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let pending = Self.pending(of: task) else { return }
        let stopped = (error as? URLError)?.code == .cancelled
        onEvent(stopped ? .stopped(pending.id) : .failed(pending.id, error.localizedDescription))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let name = session.configuration.identifier ?? ""
        DispatchQueue.main.async { BackgroundEvents.finish(name) }
    }
}

/// Receives the system's wake-up for finished transfers, one handler per session. The app entry point adopts it.
final class BackgroundEvents: NSObject, UIApplicationDelegate {
    @MainActor private static var completions: [String: @Sendable () -> Void] = [:]
    // Sessions whose events were all delivered before the system handed over their handler, and when.
    @MainActor private static var finished: [String: Date] = [:]
    /// Longer than a background launch runs, so an older finish came from an earlier run and not this wake.
    static let finishKept: TimeInterval = 30

    func application(_: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping @Sendable () -> Void) {
        if let at = Self.finished.removeValue(forKey: identifier), Date().timeIntervalSince(at) < Self.finishKept {
            completionHandler()
        } else {
            Self.completions[identifier] = completionHandler
        }
    }

    /// Calls the session's handler, or keeps its name so a handler that comes soon after is called at once.
    @MainActor static func finish(_ identifier: String, at now: Date = Date()) {
        if let handler = completions.removeValue(forKey: identifier) { handler() } else { finished[identifier] = now }
    }
}
