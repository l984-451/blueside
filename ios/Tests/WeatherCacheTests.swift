import FlightCore
import Foundation
import Testing
@testable import Blueside

private let t0 = WeatherFixture.checked

/// Answers 304 when the request carries the tag it hands out, like the real host.
private final class TagServer: URLProtocol {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let match = request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\""
        let response = HTTPURLResponse(url: request.url!, statusCode: match ? 304 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["ETag": "\"v1\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !match { client?.urlProtocol(self, didLoad: Data("body".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct WeatherCacheTests {
    private func makeCache(_ host: WeatherFakeHost, root: URL) -> WeatherCache {
        WeatherCache(root: root, base: WeatherFixture.base, load: host.load)
    }

    @Test func firstRefreshDecodesEverySourceAndDatesItFromTheIndex() async throws {
        let host = try WeatherFixture.host()
        let data = await makeCache(host, root: try WeatherFixture.folder()).refresh(now: t0 + 60)
        #expect(data.metars.count == 2547 && data.tafs.count == 768 && data.pireps.count == 122)
        #expect(data.sigmets.count == 6 && data.gairmets.count == 148 && data.tfrs.count == 6)
        #expect(data.failures.isEmpty)
        // The fake index predates winds, satellite and lightning; drop them here once wxpipe's fixture carries them.
        for source in WeatherSource.allCases where ![.radar, .winds, .satellite, .lightning].contains(source) {
            #expect(data.checkedAt[source] == t0)
            #expect(data.status(of: source, at: t0 + 60) == .current)
        }
        #expect(data.index?.checkedAt[.metars] == t0)
    }

    @Test func aNewCacheObjectReadsTheLastGoodCopyWithNoNetwork() async throws {
        let root = try WeatherFixture.folder()
        let host = try WeatherFixture.host()
        let first = await makeCache(host, root: root).refresh(now: t0 + 60)
        host.forget()
        // No address: the folder is only read.
        let offline = WeatherCache(root: root, base: nil, load: host.load)
        let read = await offline.read()
        #expect(read.metars == first.metars && read.tfrs == first.tfrs && read.gairmets == first.gairmets)
        #expect(read.checkedAt == first.checkedAt)
        #expect(await offline.refresh(now: t0 + 120).metars == first.metars)
        #expect(host.asked.isEmpty)
    }

    @Test func aFileThatFailsToDecodeKeepsTheLastGoodCopyAndReportsIt() async throws {
        let root = try WeatherFixture.folder()
        let host = try WeatherFixture.host()
        let cache = makeCache(host, root: root)
        let good = await cache.refresh(now: t0 + 60)
        host.put("metars.json.gz", WeatherFixture.gzip(Data(#"{"not":"a list"}"#.utf8)))
        host.put("index.json", WeatherFixture.index(checked: t0 + 300))
        let after = await cache.refresh(now: t0 + 360)
        #expect(after.metars == good.metars)
        #expect(after.checkedAt[.metars] == t0)
        #expect(after.failures[.metars] == "File could not be read")
        #expect(after.checkedAt[.tafs] == t0 + 300)
        // The old copy keeps its old time, so it ages out on schedule.
        #expect(after.status(of: .metars, at: t0 + 16 * 60) == .notCurrent(since: t0))
        #expect(after.staleLabel(for: .stations, at: t0 + 16 * 60) == "METARs not updated since 0035Z")
        let reread = await WeatherCache(root: root, base: nil, load: host.load).read()
        #expect(reread.metars == good.metars && reread.checkedAt[.metars] == t0)
    }

    @Test func anEmptyOrPlainFileIsAFailureToo() async throws {
        let host = try WeatherFixture.host()
        let cache = makeCache(host, root: try WeatherFixture.folder())
        let good = await cache.refresh(now: t0 + 60)
        host.put("tfrs.geojson.gz", WeatherFixture.gzip(Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)))
        host.put("tafs.json.gz", Data("<html>sign in</html>".utf8))
        host.put("index.json", WeatherFixture.index(checked: t0 + 300))
        let after = await cache.refresh(now: t0 + 360)
        #expect(after.tfrs == good.tfrs && after.checkedAt[.tfrs] == t0)
        #expect(after.failures[.tfrs] == "File could not be read")
        #expect(after.tafs == good.tafs && after.failures[.tafs] == "Not a gzip file")
    }

    @Test func oneFailingSourceDoesNotBlockTheOthers() async throws {
        let host = try WeatherFixture.host()
        host.fail("tafs.json.gz")
        let cache = makeCache(host, root: try WeatherFixture.folder())
        let data = await cache.refresh(now: t0 + 60)
        #expect(data.tafs.isEmpty)
        #expect(data.failures == [.tafs: "No connection"])
        #expect(data.status(of: .tafs, at: t0 + 60) == .unknown)
        #expect(data.metars.count == 2547 && data.tfrs.count == 6)
        // The next pass picks the missing file up.
        host.fail("tafs.json.gz", false)
        let next = await cache.refresh(now: t0 + 120)
        #expect(next.tafs.count == 768 && next.failures.isEmpty)
    }

    @Test func eachKindOfTransportFailureIsNamed() async throws {
        let host = try WeatherFixture.host()
        host.fail("metars.json.gz", with: .notConnectedToInternet)
        host.fail("tafs.json.gz", with: .timedOut)
        host.fail("pireps.json.gz", with: .serverCertificateUntrusted)
        host.fail("tfrs.geojson.gz", with: .cannotFindHost)
        let data = await makeCache(host, root: try WeatherFixture.folder()).refresh(now: t0 + 60)
        #expect(data.failures == [.metars: "No connection", .tafs: "Timed out",
                                  .pireps: "Secure connection failed", .tfrs: "Server not reachable"])
    }

    @Test func aDiskThatCannotSaveStillShowsTheNewWeather() async throws {
        let root = try WeatherFixture.folder()
        // A folder where each file would go makes every write fail.
        for name in ["index.json", "metars.json"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let host = try WeatherFixture.host()
        let data = await makeCache(host, root: root).refresh(now: t0 + 60)
        #expect(data.failures.isEmpty)
        #expect(data.metars.count == 2547 && data.checkedAt[.metars] == t0)
        #expect(data.tfrs.count == 6 && data.checkedAt[.tfrs] == t0)
        // Nothing unsaved is paired with a time on disk.
        #expect(await WeatherCache(root: root, base: nil, load: host.load).read().checkedAt[.metars] == nil)
    }

    @Test func anUnchangedCheckTimeAsksForNothingButTheIndex() async throws {
        let host = try WeatherFixture.host()
        let cache = makeCache(host, root: try WeatherFixture.folder())
        _ = await cache.refresh(now: t0 + 60)
        host.forget()
        _ = await cache.refresh(now: t0 + 120)
        #expect(host.asked == ["index.json"])
    }

    @Test func anUnchangedFileIsAnsweredWith304AndTakesTheNewCheckTime() async throws {
        let host = try WeatherFixture.host()
        let cache = makeCache(host, root: try WeatherFixture.folder())
        let first = await cache.refresh(now: t0 + 60)
        host.forget()
        host.put("index.json", WeatherFixture.index(checked: t0 + 300))
        let second = await cache.refresh(now: t0 + 360)
        #expect(Set(host.asked) == Set(WeatherFixture.files + ["index.json"]))
        for name in WeatherFixture.files { #expect(host.tag(sentFor: name) != nil) }
        #expect(second.metars == first.metars)
        #expect(second.checkedAt[.metars] == t0 + 300 && second.checkedAt[.tfrs] == t0 + 300)
        #expect(second.failures.isEmpty)
    }

    @Test func aBadIndexChangesNothing() async throws {
        let host = try WeatherFixture.host()
        let cache = makeCache(host, root: try WeatherFixture.folder())
        let good = await cache.refresh(now: t0 + 60)
        host.put("index.json", WeatherFixture.index(checked: t0 + 300, version: 2))
        let newer = await cache.refresh(now: t0 + 360)
        #expect(newer.metars == good.metars && newer.checkedAt == good.checkedAt)
        #expect(newer.failures[.metars] == "Needs a newer app" && newer.failures[.radar] == "Needs a newer app")
        host.fail("index.json")
        let down = await cache.refresh(now: t0 + 420)
        #expect(down.checkedAt == good.checkedAt && down.failures[.tfrs] == "No connection")
    }

    @Test func aSourceTheIndexHasNeverCheckedIsLeftAlone() async throws {
        let host = try WeatherFixture.host()
        host.put("index.json", WeatherFixture.index(checked: nil))
        let data = await makeCache(host, root: try WeatherFixture.folder()).refresh(now: t0)
        #expect(host.asked == ["index.json"])
        #expect(data.metars.isEmpty && data.status(of: .metars, at: t0) == .unknown)
    }

    @Test @MainActor func fetchingRunsOffTheMainThread() async throws {
        let host = try WeatherFixture.host()
        let data = await makeCache(host, root: try WeatherFixture.folder()).refresh(now: t0 + 60)
        #expect(data.metars.count == 2547)
        #expect(host.asked.count == 8)
        #expect(!host.usedMainThread)
    }

    @Test func httpLoaderSendsTheTagAndPassesA304Through() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TagServer.self]
        let load = WeatherCache.http(configuration)
        let url = WeatherFixture.base.appendingPathComponent("wx/metars.json.gz")
        let first = try await load(url, nil)
        #expect(first.status == 200 && first.etag == "\"v1\"" && first.data == Data("body".utf8))
        let second = try await load(url, first.etag)
        #expect(second.status == 304 && second.data.isEmpty)
    }
}
