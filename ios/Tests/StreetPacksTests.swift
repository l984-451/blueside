import Foundation
import Testing
@testable import Blueside

@Suite @MainActor struct StreetPacksTests {
    // Crossing back over a border keeps the style; reaching a pack it lacks, or losing one, changes it.
    @Test func packsOnShowStayWhileTheyServeTheView() {
        let (tx, ok, nm) = (URL(fileURLWithPath: "/p/TX.pmtiles"), URL(fileURLWithPath: "/p/OK.pmtiles"),
                            URL(fileURLWithPath: "/p/NM.pmtiles"))
        let all: Set = [tx, ok, nm]
        #expect(StreetPacks.kept([tx, ok], wanted: [ok], installed: all) == [tx, ok])
        #expect(StreetPacks.kept([tx, ok], wanted: [ok, nm], installed: all) == [ok, nm])
        #expect(StreetPacks.kept([tx, ok], wanted: [ok], installed: [ok]) == [ok])
        #expect(StreetPacks.kept([], wanted: [tx], installed: all) == [tx])
    }
}
