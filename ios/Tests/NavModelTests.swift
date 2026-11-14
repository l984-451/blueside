import FlightCore
import Foundation
import Testing
@testable import Blueside

private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

// The path of a full national database on the host. Set for one run only; unset, that test is skipped.
private let nationalDatabase = ProcessInfo.processInfo.environment["NAV_NATIONAL_DB"]

@MainActor private func openModel() async throws -> NavModel {
    let model = NavModel()
    await model.use(NavFiles.bundledTest).value
    try #require(model.database != nil, "\(model.problem ?? "no reason given")")
    return model
}

@Suite @MainActor struct NavModelTests {
    @Test func aListRowCarriesTheAtAGlanceItemsOnOneLine() async throws {
        let model = try await openModel()
        model.search("AUS")
        let aus = try #require(model.results.first { $0.ident == "AUS" })
        #expect(model.quickLine(aus) == "ATIS 124.4 · Tower 121.0 · 18R/36L 12,250 ft")
    }

    @Test func atAGlanceFitsTheKindOfAirport() async throws {
        let model = try await openModel()
        func glance(_ ident: String) throws -> [String] {
            model.search(ident)
            model.show(try #require(model.results.first { $0.ident == ident }))
            return NavText.glance(try #require(model.detail)).map { "\($0.label) \($0.value)" }
        }
        // Towered: the airport's weather, the tower, the longest open runway.
        #expect(try glance("AUS") == ["ATIS 124.4", "Tower 121.0", "Longest runway 18R/36L"])
        // Non-towered: automated weather and the common traffic frequency.
        #expect(try glance("T82").prefix(2) == ["AWOS-3 120.0", "CTAF 122.7"])
    }

    @Test func threeSpellingsReachTheSamePage() async throws {
        let model = try await openModel()
        for text in ["AUS", "KAUS", "Bergstrom", "aus", " kaus "] {
            model.search(text)
            let first = try #require(model.results.first, "\(text) found nothing")
            model.show(first)
            #expect(model.detail?.airport.id == 1, "\(text)")
            #expect(model.detail?.airport.ident == "AUS", "\(text)")
            #expect(model.detail?.runways.first?.id == "18R/36L", "\(text)")
        }
        model.closePage()
        #expect(model.detail == nil)
    }

    @Test func aKPrefixIsNeverInvented() async throws {
        let model = try await openModel()
        model.search("KT82")
        #expect(model.results.isEmpty)
        model.search("T82")
        let field = try #require(model.results.first)
        #expect(field.icao == nil)
        #expect(NavText.title(field) == "T82")
        #expect(NavText.faaCode(field) == nil)
        model.search("KEDC")
        let edc = try #require(model.results.first)
        #expect(NavText.title(edc) == "KEDC")
        #expect(NavText.faaCode(edc) == nil)
        var odd = edc
        odd.icao = "PAED"
        #expect(NavText.faaCode(odd) == "EDC")
        #expect(NavText.placeLine(edc) == "Austin, TX · 620 ft")
    }

    @Test func aClosedAirportIsLabeledClosed() async throws {
        let model = try await openModel()
        model.search("TS01")
        let landry = try #require(model.results.first)
        #expect(NavText.closedLabel(landry) == "Closed")
        model.search("AUS")
        let bergstrom = try #require(model.results.first)
        #expect(NavText.closedLabel(bergstrom) == nil)
    }

    @Test func dataDatesComeFromTheDatabaseAndSayWhenNotCurrent() async throws {
        let metadata = try #require(try await openModel().database?.metadata)
        let line = "FAA data effective 01 Oct 2026 to 29 Oct 2026"
        let current = NavText.dataDates(metadata, now: date("2026-10-13T12:00:00Z"))
        #expect(current.line == line)
        #expect(current.warning == nil)
        let lastSecond = NavText.dataDates(metadata, now: date("2026-10-29T09:00:59Z"))
        #expect(lastSecond.warning == nil)
        // The warning starts at the database's own expiry second.
        let expired = NavText.dataDates(metadata, now: date("2026-10-29T09:01:00Z"))
        #expect(expired.line == line)
        #expect(expired.warning == "Not current: expired 29 Oct 2026")
        let early = NavText.dataDates(metadata, now: date("2026-10-01T09:00:59Z"))
        #expect(early.line == line)
        #expect(early.warning == "Not current: not in effect until 01 Oct 2026")
    }

    @Test func mapNoticeCoversEveryState() async throws {
        let metadata = try #require(try await openModel().database?.metadata)
        let during = date("2026-10-13T12:00:00Z")
        #expect(NavText.mapNotice(metadata: metadata, hasTiles: true, overlayWanted: true, now: during) == nil)
        #expect(NavText.mapNotice(metadata: metadata, hasTiles: true, overlayWanted: false,
                                  now: date("2026-10-29T09:01:00Z")) == "Nav data expired 29 Oct 2026")
        #expect(NavText.mapNotice(metadata: metadata, hasTiles: true, overlayWanted: true,
                                  now: date("2026-10-01T09:00:59Z")) == "Nav data not in effect until 01 Oct 2026")
        #expect(NavText.mapNotice(metadata: nil, hasTiles: false, overlayWanted: true, now: during)
                == "Navigation data not downloaded")
        #expect(NavText.mapNotice(metadata: nil, hasTiles: false, overlayWanted: false, now: during) == nil)
        #expect(NavText.mapNotice(metadata: metadata, hasTiles: false, overlayWanted: true, now: during)
                == "Navigation overlay not downloaded")
    }

    @Test func theDownloadOfferSaysWhyNothingHappens() {
        #expect(NavText.downloadNotice(nil, hasList: false) == nil)
        #expect(NavText.downloadNotice(.noConnection, hasList: false)
            == "No connection. Connect to the internet to download navigation data.")
        #expect(NavText.downloadNotice(.unreadable, hasList: false)
            == "Update the app. This version cannot read the navigation data list.")
        #expect(NavText.downloadNotice(.server, hasList: false) == "Navigation data server error. Try again later.")
        #expect(NavText.downloadNotice(.noConnection, hasList: true) == "Navigation data list not updated")
    }

    @Test func aTransferWithNoNetworkSaysItIsWaiting() {
        #expect(DownloadPolicy.statusText(.downloading(0), waiting: true) == "Waiting for network")
        #expect(DownloadPolicy.statusText(.downloading(0.4), waiting: false) == "Downloading 40%")
        #expect(DownloadPolicy.statusText(.ready, waiting: true) == "Ready")
    }

    @Test func theMapSaysWhenDataCannotBeRead() async throws {
        let metadata = try #require(try await openModel().database?.metadata)
        let now = metadata.effective.addingTimeInterval(3600)
        #expect(NavText.mapNotice(metadata: nil, unreadable: true, hasTiles: false, overlayWanted: false, now: now)
            == "Navigation data could not be read")
        #expect(NavText.mapNotice(metadata: metadata, hasTiles: true, overlayWanted: true, now: now) == nil)
    }

    @Test func aMissingOrUnreadableDatabaseSaysSo() async {
        let model = NavModel()
        await model.use(nil).value
        #expect(model.problem == NavModel.notDownloaded)
        #expect(NavModel.notDownloaded == "Navigation data is not downloaded")
        await model.use(NavFiles(database: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nav-absent.sqlite"),
                                   tiles: nil)).value
        #expect(model.database == nil)
        #expect(model.problem == "Navigation data could not be read")
        model.search("AUS")
        #expect(model.results.isEmpty)
        #expect(model.problem == "Navigation data could not be read")
    }

    @Test func runwayLineLeavesOutWhatTheFAADoesNotGive() async throws {
        let model = try await openModel()
        model.search("AUS")
        model.show(try #require(model.results.first))
        #expect(model.detail.map { NavText.runwayLine($0.runways[0]) }
                == "12,250 × 150 ft · Concrete · HIRL")
        #expect(model.detail.map { NavText.runways($0).map(\.lengthFt) } == [12250, 9000])
        let order = try #require(model.detail).frequencies
        #expect(NavText.frequencies(order).map(NavText.frequencyLabel)
                == ["ATIS", "Clearance", "Ground", "Tower", "Tower", "Approach West", "Approach East", "UNICOM",
                    "RAMP CTL"])
        model.search("TX05")
        model.show(try #require(model.results.first))
        #expect(model.detail.map { NavText.runwayLine($0.runways[0]) } == "2,300 × 60 ft · Turf")
    }

    @Test func privateFieldsAndHeliportsAreNamedInWords() async throws {
        let model = try await openModel()
        func label(_ ident: String) throws -> String? {
            model.search(ident)
            return NavText.kindLabel(try #require(model.results.first))
        }
        #expect(try label("AUS") == nil)
        #expect(try label("TX05") == "PRIVATE")
        #expect(try label("68TX") == "PRIVATE HELIPORT")
    }

    @Test func usingFilesOpensThemAndRunsTheFirstSearchOnce() async throws {
        let model = NavModel()
        model.configure(options: LaunchOptions(arguments: ["-navQuery", "KAUS", "-navNow", "2026-11-05T12:00:00Z"]))
        await model.use(NavFiles.bundledTest).value
        #expect(model.database?.metadata.cycle == "2026-10-01")
        #expect(model.results.first?.ident == "AUS")
        // The clock is past the expiry here: the style is still made, and the map label says expired.
        #expect(model.styleFile != nil)
        #expect(model.fixedNow == date("2026-11-05T12:00:00Z"))
        model.search("")
        await model.use(NavFiles.bundledTest).value
        #expect(model.results.isEmpty, "the same files twice must not open or search again")
    }

    @Test func newFilesKeepTheTypedSearchAndTheOpenPage() async throws {
        let model = NavModel()
        await model.use(NavFiles(database: try #require(NavFiles.bundledTest?.database), tiles: nil)).value
        model.search("AUS")
        model.show(try #require(model.results.first))
        await model.use(NavFiles.bundledTest).value
        #expect(model.query == "AUS")
        #expect(model.results.first?.ident == "AUS")
        #expect(model.detail?.airport.ident == "AUS")
        #expect(model.problem == nil)
        // Files that cannot be read leave the text, no rows, no page, and the reason.
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nav-absent.sqlite")
        await model.use(NavFiles(database: missing, tiles: nil)).value
        #expect(model.query == "AUS")
        #expect(model.results.isEmpty)
        #expect(model.detail == nil)
        #expect(model.problem == "Navigation data could not be read")
    }

    // The first open says so while it runs; a switch with a database already open does not.
    @Test func theFirstOpenIsMarkedWhileItRuns() async throws {
        let model = NavModel()
        let first = model.use(NavFiles(database: try #require(NavFiles.bundledTest?.database), tiles: nil))
        #expect(model.isOpeningFirst)
        await first.value
        #expect(!model.isOpeningFirst)
        let next = model.use(NavFiles.bundledTest)
        #expect(!model.isOpeningFirst)
        await next.value
        #expect(model.styleFile != nil)
        #expect(!model.isOpeningFirst)
    }

    @Test func withNoFilesNothingIsOpenAndThePanelSaysNotDownloaded() {
        let model = NavModel()
        model.use(nil)
        #expect(model.database == nil)
        #expect(model.styleFile == nil)
        #expect(model.problem == NavModel.notDownloaded)
        model.search("AUS")
        #expect(model.results.isEmpty)
    }

    @Test func aDatabaseWithNoTileFileOpensWithNoMapStyle() async throws {
        let model = NavModel()
        await model.use(NavFiles(database: try #require(NavFiles.bundledTest?.database), tiles: nil)).value
        #expect(model.database != nil)
        #expect(model.styleFile == nil)
    }

    @Test func filesThatCannotBeReadLeaveNoStyleEither() async {
        let model = NavModel()
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nav-absent.sqlite")
        await model.use(NavFiles(database: missing, tiles: NavFiles.bundledTest?.tiles)).value
        #expect(model.database == nil)
        #expect(model.styleFile == nil)
        #expect(model.problem == "Navigation data could not be read")
    }

    @Test func anIdentifierFromTheMapOpensThePage() async throws {
        let model = try await openModel()
        model.show(ident: "AUS")
        #expect(model.detail?.airport.icao == "KAUS")
        model.closePage()
        model.show(ident: "NOPE")
        #expect(model.detail == nil)
        // An unknown identifier must not leave another airport's page open.
        model.show(ident: "AUS")
        model.show(ident: "NOPE")
        #expect(model.detail == nil)
    }

    @Test func remarksNameTheRunwayOrItemTheyAreAbout() async throws {
        let model = try await openModel()
        model.search("T82")
        model.show(try #require(model.results.first))
        let field = try #require(model.detail)
        #expect(NavText.runwayRemarks(field.runways[0], in: field.remarks)
                == ["14: 3 FT FENCE 190-200 FT FM THLD 216 FT RIGHT."])
        #expect(field.frequencies.first { $0.use == "CTAF" }?.remark
                == "RWY 14/32 MIRL PRESET LOW INTST; TO INCR INTST ACTVT - CTAF.")
        let fuel = try #require(field.remarks.first { $0.tab == "FUEL_TYPE" })
        #expect(NavText.remarkLine(fuel).hasPrefix("100LL: "))
        model.search("AUS")
        model.show(try #require(model.results.first))
        let austin = try #require(model.detail)
        for runway in austin.runways { #expect(NavText.runwayRemarks(runway, in: austin.remarks).isEmpty) }
        #expect(austin.remarks.allSatisfy { NavText.remarkLine($0) == $0.text })
    }

    // The join between a runway and its remarks, on the real file. Skipped unless NAV_NATIONAL_DB names it.
    @Test(.enabled(if: nationalDatabase != nil)) func theNationalFileLabelsClosuresAndDeadFrequenciesTruthfully() async throws {
        let model = NavModel()
        await model.use(NavFiles(database: URL(fileURLWithPath: try #require(nationalDatabase)), tiles: nil)).value
        func page(_ ident: String) throws -> AirportDetail {
            model.show(ident: ident)
            let detail = try #require(model.detail)
            #expect(detail.airport.ident == ident)
            return detail
        }
        func note(_ ident: String, _ runway: String) throws -> String? {
            let detail = try page(ident)
            return NavText.runwayNote(try #require(detail.runways.first { $0.id == runway }), in: detail.remarks)
        }
        func dead(_ ident: String) throws -> [String] {
            try page(ident).frequencies
                .filter { NavText.outOfService(use: $0.use, frequency: $0.frequency, remark: $0.remark) }.map(\.use)
        }
        #expect(try note("PGA", "07/25") == "CLOSED")
        #expect(try note("PGA", "15/33")?.hasPrefix("CLOSURE REMARK: RWY 15/33 CLSD TO ACR OPS") == true)
        // Filed against the airport, with the runway named in the text.
        #expect(try note("BYS", "13/31") == "CLOSED")
        #expect(try note("BYS", "04/22") == nil)
        #expect(try note("DGL", "18/36") == "CLOSED")
        #expect(try note("DTW", "09R/27L") == "CLOSURE REMARK: WEST 1713 FT CLSD INDEFLY.")
        #expect(try note("DTW", "04R/22L") == nil)
        // Filed against one end.
        #expect(try note("E68", "07/25") == "CLOSURE REMARK: END 07 CLSD INDEFLY.")
        #expect(try note("L66", "18/36") == "CLOSURE REMARK: NORTH 1000 FT OF RY CLSD INDEFLY.")
        #expect(try dead("2F4") == ["UNICOM"])
        #expect(try dead("3G5").isEmpty)
        #expect(try dead("CLP").isEmpty)
    }

    @Test(.enabled(if: nationalDatabase != nil)) func nationalDatabaseAnswersTheSameSearches() async throws {
        let model = NavModel()
        await model.use(NavFiles(database: URL(fileURLWithPath: try #require(nationalDatabase)), tiles: nil)).value
        try #require(model.database != nil, "\(model.problem ?? "no reason given")")
        for text in ["AUS", "KAUS", "Bergstrom"] {
            model.search(text)
            #expect(model.results.first?.ident == "AUS", "\(text)")
        }
        model.search("KT82")
        #expect(model.results.isEmpty)
    }
}
