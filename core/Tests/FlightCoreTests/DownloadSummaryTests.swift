import Testing
@testable import FlightCore

@Suite struct DownloadSummaryTests {
    @Test func countsRegionsOnDiskAndAddsTheirSizes() {
        let summary = DownloadSummary(states: [.ready, .notDownloaded, .ready], sizes: [100_000_000, 5, 312_000_000],
                                      unit: "state")
        #expect(summary.text == "2 states, 412 MB")
        #expect(summary.state == .ready)
        #expect(DownloadSummary(states: [.ready], sizes: [1_000_000], unit: nil).text == "1 MB")
        #expect(DownloadSummary(states: [.notDownloaded], sizes: [9], unit: "state").text == "Not downloaded")
        #expect(DownloadSummary.used([summary, summary]) == "824 MB")
    }

    @Test func progressAndTroubleOutrankTheCount() {
        // A region not chosen never drags the progress down.
        #expect(DownloadSummary(states: [.ready, .downloading(0), .notDownloaded], sizes: [1, 1, 1], unit: "state").text
                == "Downloading 50%")
        #expect(DownloadSummary(states: [.downloading(0.5)], sizes: [1], unit: nil, waiting: true).text
                == "Waiting for network")
        #expect(DownloadSummary(states: [.ready, .failed("x")], sizes: [1, 1], unit: "state").text == "Failed")
        #expect(DownloadSummary(states: [.ready, .expired], sizes: [1, 1], unit: "state").text == "Update available")
        #expect([PackState.ready, .notDownloaded, .downloading(0.1), .expired, .failed("x")]
            .filter(DownloadSummary.isDownloaded).count == 4)
    }
}
