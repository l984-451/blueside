import Foundation
import Testing
@testable import FlightCore

// Foundation's formatters are the reference: the core must write exactly what the app wrote before.
private func utc(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = format
    return formatter
}

@Suite struct NavTextTests {
    @Test func datesMatchTheUTCFormatter() {
        let day = utc("dd MMM yyyy"), clock = utc("HH:mm:ss'Z'"), stamp = utc("dd MMM HH:mm:ss'Z'")
        var generator = SystemRandomNumberGenerator()
        let fixed: [TimeInterval] = [0, -1, -0.5, 86399.9, 951_782_400, 4_107_542_399, 1_790_812_800, 1_791_158_400.7,
                                     -2_208_988_800, Date.distantFuture.timeIntervalSince1970]
        let random = (0..<5000).map { _ in Double(Int64.random(in: -3_000_000_000...6_000_000_000, using: &generator)) / 10 }
        for seconds in fixed + random {
            let date = Date(timeIntervalSince1970: seconds)
            #expect(NavText.day(date) == day.string(from: date), "\(seconds)")
            #expect(NavText.clock(date) == clock.string(from: date), "\(seconds)")
            #expect(NavText.stamp(date) == stamp.string(from: date), "\(seconds)")
        }
        #expect(NavText.day(Date(timeIntervalSince1970: 1_790_812_800)) == "01 Oct 2026")
        #expect(NavText.stamp(Date(timeIntervalSince1970: 1_768_464_000)) == "15 Jan 08:00:00Z")
    }

    @Test func numbersMatchPrintf() {
        var generator = SystemRandomNumberGenerator()
        let ties: [Double] = [0, -0.0, 0.05, 0.15, 0.25, 0.35, 2.675, 542.5, 543.5, 1.005, 9.95, 99.95, -0.04, 0.5, 1.5,
                              2.5, 12345.65, 1e-9, 59.995, 4.9999999]
        let random = (0..<20000).map { _ in Double.random(in: -20000...20000, using: &generator) }
        let rounded = (0..<5000).map { _ in Double(Int.random(in: -200_000...200_000, using: &generator)) / 1000 }
        for value in ties + random + rounded {
            for digits in 0...3 {
                #expect(NavText.fixed(value, digits) == String(format: "%.\(digits)f", value), "\(value) \(digits)")
            }
        }
        for value in [0, 7, 999, 1000, 12250, -1_234_567, 10_000_000] {
            #expect(NavText.grouped(value) == value.formatted(), "\(value)")
        }
        #expect(NavText.pad(7, 3) == "007")
        #expect(NavText.pad(1234, 3) == "1234")
    }

    @Test func wordsAreCapitalizedAsFoundationDoes() {
        for text in ["DALLAS-FORT WORTH", "COEUR D'ALENE", "ST. LOUIS", "O'NEILL", "MC ALLEN", "FT.WORTH",
                     "SAN JUAN/ISLA", "3RD LAKE", "A1B", "PRIVATE SEAPLANE BASE", "LA(GRANGE)", "X_Y", "ab,cd",
                     "1st", "AUSTIN-BERGSTROM INTL", "", "  TWO  SPACES "] {
            #expect(NavText.capitalized(text) == text.capitalized, "\(text)")
        }
    }

    @Test func shortTextsReadAsBefore() {
        #expect(NavText.distance(12.34) == "12.3 NM")
        #expect(NavText.distance(.infinity) == "---")
        #expect(NavText.duration(3900) == "1:05")
        #expect(NavText.duration(-1) == "---")
        #expect(NavText.degreesMinutes(Coordinate(latitude: 30.195, longitude: -97.67)) == "30°11.70′N 097°40.20′W")
        #expect(NavText.degreesMinutes(Coordinate(latitude: -0.5, longitude: 0.25)) == "00°30.00′S 000°15.00′E")
        #expect(NavText.elevation(542.4) == "542 ft")
        #expect(NavText.fuel(12.25) == "12.2 gal")
        let year = Date(timeIntervalSince1970: 1_790_812_800)
        #expect(NavText.bearing(0, from: Coordinate(latitude: 0, longitude: 0), date: Date.distantFuture) == "360°T")
        #expect(NavText.bearing(11, from: Coordinate(latitude: 0, longitude: 0), date: Date.distantFuture) == "011°T")
        #expect(NavText.bearing(90, from: Coordinate(latitude: 30.2, longitude: -97.7), date: year).hasSuffix("°M"))
    }

    @Test func onlyAWholeRunwayClosedOutrightReadsClosed() {
        #expect(NavText.runwayClosure(id: "18/36", remarks: ["CLSD INDEFLY. 2 FT BUMP XG TWY TO RWY 03/21"]) == "CLOSED")
        #expect(NavText.runwayClosure(id: "14/32", remarks: ["RWY 14/32 CLSD INDEFLY DUE TO FLOOD DMG, CULVERTS WASHED OUT."])
                == "CLOSED")
        #expect(NavText.runwayClosure(id: "01/19", remarks: ["RWY CLSD."]) == "CLOSED")
        #expect(NavText.runwayClosure(id: "07/25", remarks: ["RWY 7/25 CLSD PERMLY."]) == "CLOSED")
        #expect(NavText.runwayClosure(id: "H1", remarks: ["HELIPAD H1 TEMP CLSD."]) == "CLOSED")
        #expect(NavText.runwayClosure(id: "N/S", remarks: ["CLSD UFN."]) == "CLOSED")
        // An outright closure wins over an earlier remark that closes it to some traffic only.
        let airlines = "RWY 7/25 CLSD TO SKED ACR OPS MORE THAN 9 PAX SEATS"
        #expect(NavText.runwayClosure(id: "07/25", remarks: [airlines, "CLSD INDEFLY."]) == "CLOSED")
        #expect(NavText.runwayClosure(id: "07/25", remarks: [airlines]) == "CLOSURE REMARK: " + airlines)
    }

    @Test func aPartOrTimedClosureIsQuotedAndNeverReadsClosed() {
        for remark in ["WEST 1713 FT CLSD INDEFLY.", "NORTH 1000 FT OF RY CLSD INDEFLY.",
                       "CLSD NIGHTS INDEFLY; ONLY VFR OPNS DURG DAY.", "CLSD WHEN ATCT CLSD.",
                       "RWY 08/26 CLSD WINTER MONTHS DUE TO LACK OF SNOW REMOVAL.", "END 07 CLSD INDEFLY."] {
            #expect(NavText.runwayClosure(id: "07/25", remarks: [remark]) == "CLOSURE REMARK: " + remark, "\(remark)")
        }
        // Another runway's number in front is not this runway closing outright.
        #expect(NavText.runwayClosure(id: "07/25", remarks: ["RWY 15/33 CLSD."]) == "CLOSURE REMARK: RWY 15/33 CLSD.")
    }

    @Test func aTowerOrAirportClosingIsNotARunwayClosure() {
        for remark in ["RWY 10 TKOFS & LDGS NA WHEN ATCT CLSD.", "WHEN ATCT CLSD LND RWY 31", "ARPT CLSD AT NIGHT.",
                       "PAR TWY CLSD INDEFLY.", "ENCLSD HANGARS NEAR RWY 09.", "RWY 18/36 NOT AVBL FOR PART 121 OPS."] {
            #expect(NavText.runwayClosure(id: "10/28", remarks: [remark]) == nil, "\(remark)")
        }
        #expect(NavText.runwayClosure(id: "10/28", remarks: []) == nil)
    }

    @Test func aFrequencyIsOutOfServiceOnlyWhenItsOwnRemarkSaysSo() {
        #expect(NavText.outOfService(use: "UNICOM", frequency: "122.8", remark: "UNICOM OTS INDEFLY."))
        #expect(NavText.outOfService(use: "49T AWOS-3", frequency: "135.425", remark: "AWOS FREQ OTS INDEFLY."))
        #expect(NavText.outOfService(use: "CD/P", frequency: "127.2",
                                     remark: "CD FREQ 127.2 OTS INDEFLY AT GASTONIA MUNI (AKH), GASTONIA, NC."))
        #expect(NavText.outOfService(use: "CTAF", frequency: "122.8",
                                     remark: "CTAF OTS INDEFLY.; ACTVT MIRL RY 14/32 AND PAPI & REIL RYS 14 & 32 - CTAF."))
        #expect(NavText.outOfService(use: "UNICOM", frequency: "122.8", remark: "OTS INDEFLY."))
        #expect(NavText.outOfService(use: "ATIS", frequency: "118.0", remark: "ATIS OUT OF SERVICE UFN"))
        #expect(NavText.outOfService(use: "AWOS-3 DCMSND", frequency: "118.0", remark: nil))
    }

    @Test func aLightOrABackupSiteOutOfServiceDoesNotMarkTheFrequency() {
        #expect(!NavText.outOfService(use: "CTAF", frequency: "122.9",
                                      remark: "ACTVT REILS RWY 05 & 23; LIRL RWY 05/23 - CTAF. PAPI RWY 05 & 23 OTS."))
        #expect(!NavText.outOfService(use: "CTAF", frequency: "122.9",
                                      remark: "ACTVT NSTD LIRL RWY 15/33 - CTAF. PAPI RWY 33 OTS INDEFLY."))
        #expect(!NavText.outOfService(use: "DILLINGHAM RCAG", frequency: "132.75",
                                      remark: "KING SALMON RCAG IS BACKUP WHEN DILLINGHAM RCAG OTS."))
        // A bare OTS after a sentence about lights is about the lights.
        #expect(!NavText.outOfService(use: "CTAF", frequency: "123.0", remark: "ACTVT LIRL RWY 15/33 - CTAF. OTS INDEFLY."))
        // DOTSS is a fix name; the letters inside a longer word do not count.
        #expect(!NavText.outOfService(use: "DOTSS DP", frequency: "124.3", remark: nil))
        #expect(!NavText.outOfService(use: "CTAF", frequency: "122.8", remark: nil))
    }

}
