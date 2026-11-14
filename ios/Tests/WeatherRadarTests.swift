import FlightCore
import Foundation
import Testing
@testable import Blueside

private let t0 = WeatherFixture.checked
/// Three pictures: 15, 10 and 4 minutes before the check time.
private let pictures = [t0 - 900, t0 - 600, t0 - 240]

@Suite struct WeatherRadarTests {
    private func makeCache(_ host: WeatherFakeHost, root: URL) -> WeatherCache {
        WeatherCache(root: root, base: WeatherFixture.base, load: host.load)
    }

    private func pass(_ cache: WeatherCache, now: Date) async -> WeatherData {
        _ = await cache.refresh(now: now)
        return await cache.fetchFrames(now: now)
    }

    @Test func onlyTheNewestPictureIsDownloaded() async throws {
        let host = try WeatherFixture.host(frames: pictures)
        let data = await pass(makeCache(host, root: try WeatherFixture.folder()), now: t0 + 60)
        #expect(data.frames.map(\.valid) == [pictures[2]])
        #expect(data.radarLoop(at: t0 + 60).map(\.valid) == [pictures[2]])
        #expect(host.asked.filter { $0.hasPrefix("radar/") } == [WeatherFixture.frameName(pictures[2])])
        for frame in data.frames {
            #expect(try Data(contentsOf: frame.file).starts(with: Data("PMTiles".utf8)))
        }
        #expect(data.status(of: .radar, at: t0 + 60) == .current)
        #expect(data.staleLabel(for: .radar, at: t0 + 60) == nil)
        #expect(data.failures[.radar] == nil)
    }

    @Test func loopIsEmptyOnceTheNewestPictureIsOlderThanTwentyMinutes() async throws {
        let host = try WeatherFixture.host(frames: pictures)
        let data = await pass(makeCache(host, root: try WeatherFixture.folder()), now: t0 + 60)
        let newest = pictures[2]
        #expect(data.radarLoop(at: newest + 19 * 60).count == 1)
        #expect(data.radarLoop(at: newest + 21 * 60).isEmpty)
        #expect(data.status(of: .radar, at: newest + 21 * 60) == .notCurrent(since: newest))
        #expect(data.staleLabel(for: .radar, at: newest + 21 * 60)
            == "Radar not updated since \(WeatherText.zulu(newest))")
    }

    @Test func picturesThatLeftTheIndexAreDeletedAndOnlyNewOnesAreFetched() async throws {
        let root = try WeatherFixture.folder()
        let host = try WeatherFixture.host(frames: pictures)
        let cache = makeCache(host, root: root)
        let first = await pass(cache, now: t0 + 60)
        let kept = try #require(first.frames.first)
        // A picture from an older pass that the index no longer names.
        let dropped = kept.file.deletingLastPathComponent().appendingPathComponent("f1.pmtiles")
        try WeatherFixture.pack("gone").write(to: dropped)
        let newer = t0 + 60
        host.put(WeatherFixture.frameName(newer), WeatherFixture.pack("new"))
        host.put("index.json", WeatherFixture.index(checked: t0 + 300, frames: [pictures[1], pictures[2], newer]))
        host.forget()
        let second = await pass(cache, now: t0 + 360)
        #expect(second.frames.map(\.valid) == [pictures[2], newer])
        #expect(!FileManager.default.fileExists(atPath: dropped.path))
        #expect(host.asked.filter { $0.hasPrefix("radar/") } == [WeatherFixture.frameName(newer)])
        // A new object over the same folder finds the same pictures.
        let reread = await WeatherCache(root: root, base: nil, load: host.load).read()
        #expect(reread.frames == second.frames)
    }

    @Test func somethingThatIsNotAPackFileIsRefused() async throws {
        let host = try WeatherFixture.host(frames: pictures)
        host.put(WeatherFixture.frameName(pictures[2]), Data("<html>error</html>".utf8))
        let data = await pass(makeCache(host, root: try WeatherFixture.folder()), now: t0 + 60)
        #expect(data.frames.isEmpty)
        #expect(data.failures[.radar] != nil)
        #expect(data.radarLoop(at: t0 + 60).isEmpty)
    }

    @Test func nothingIsFetchedWhenTheIndexItselfIsOld() async throws {
        let host = try WeatherFixture.host(frames: pictures)
        let now = pictures[2] + 30 * 60
        let data = await pass(makeCache(host, root: try WeatherFixture.folder()), now: now)
        #expect(host.asked.filter { $0.hasPrefix("radar/") }.isEmpty)
        #expect(data.radarLoop(at: now).isEmpty)
        #expect(data.status(of: .radar, at: now) == .unknown)
        // Nothing on disk, so the label dates radar by the newest picture the index names.
        #expect(data.staleLabel(for: .radar, at: now) == "Radar not updated since \(WeatherText.zulu(pictures[2]))")
    }

    @Test func aPictureCutShortIsRefusedAndFetchedAgain() async throws {
        let host = try WeatherFixture.host(frames: pictures)
        let whole = WeatherFixture.pack("frame-\(pictures[2])")
        host.put(WeatherFixture.frameName(pictures[2]), whole.prefix(whole.count - 3))
        let cache = makeCache(host, root: try WeatherFixture.folder())
        let data = await pass(cache, now: t0 + 60)
        #expect(data.frames.isEmpty && data.failures[.radar] == "Not a whole radar picture")
        host.put(WeatherFixture.frameName(pictures[2]), whole)
        #expect(await pass(cache, now: t0 + 120).frames.count == 1)
        #expect(!WeatherPolicy.isWholePack(Data("PMTiles".utf8)))
    }

    @Test func aPictureFarBehindTheNewestIsLeftOut() async throws {
        let old = t0 - 80 * 60
        let host = try WeatherFixture.host(frames: [old] + pictures)
        let data = await pass(makeCache(host, root: try WeatherFixture.folder()), now: t0 + 60)
        #expect(!host.asked.contains(WeatherFixture.frameName(old)))
        #expect(data.radarLoop(at: t0 + 60).map(\.valid) == [pictures[2]])
    }

    @Test func aMissingNewestPictureLeavesTheLoopJudgedByWhatIsOnDisk() async throws {
        let host = try WeatherFixture.host(frames: pictures)
        host.fail(WeatherFixture.frameName(pictures[2]))
        let data = await pass(makeCache(host, root: try WeatherFixture.folder()), now: t0 + 60)
        #expect(data.frames.isEmpty && data.radarLoop(at: t0 + 60).isEmpty)
        #expect(data.failures[.radar] == "No connection")
        host.fail(WeatherFixture.frameName(pictures[2]), false)
        let next = await pass(WeatherCache(root: try WeatherFixture.folder(), base: WeatherFixture.base, load: host.load),
                              now: t0 + 60)
        #expect(next.frames.count == 1)
    }
}
