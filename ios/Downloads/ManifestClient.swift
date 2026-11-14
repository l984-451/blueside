import FlightCore
import Foundation

/// Fetches the manifest and keeps the last good copy on disk for use with no network.
struct ManifestClient: Sendable {
    let base: URL
    let cache: URL
    /// The list's path under the base. Pack paths resolve from the base itself.
    let list: String
    let load: @Sendable (URL) async throws -> Data

    init(base: URL, cache: URL, list: String = "manifest.json",
         load: @escaping @Sendable (URL) async throws -> Data = ManifestClient.http) {
        self.base = base
        self.cache = cache
        self.list = list
        self.load = load
    }

    func url(for path: String) -> URL { base.appendingPathComponent(path) }

    func cached() -> Manifest? {
        (try? Data(contentsOf: cache)).flatMap { try? Manifest.decode($0) }
    }

    /// The server answered, with something other than the file.
    struct BadStatus: Error { var code: Int }

    /// A fresh manifest, or the cached one and the reason when the network or the file is bad.
    func fetch() async -> (manifest: Manifest?, failure: ListFailure?) {
        let data: Data
        do {
            data = try await load(url(for: list))
        } catch {
            return (cached(), error is BadStatus ? .server : .noConnection)
        }
        do {
            let manifest = try Manifest.decode(data)
            try? data.write(to: cache, options: .atomic)
            return (manifest, nil)
        } catch ManifestError.unsupportedVersion {
            return (cached(), .unreadable)
        } catch {
            // Anything else that is not a list, such as a sign-in page, is the server's fault.
            return (cached(), .server)
        }
    }

    static func http(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw BadStatus(code: code) }
        return data
    }

    /// The launch option wins, then the address built into the app.
    static func baseURL(options: LaunchOptions, info: [String: Any]? = Bundle.main.infoDictionary) -> URL? {
        let text = options.string("manifestBase") ?? info?["ManifestBaseURL"] as? String ?? ""
        return text.isEmpty ? nil : URL(string: text)
    }
}
