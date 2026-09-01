import Foundation
import Testing

@testable import MurmrFlow

/// Version arithmetic for the update check — the part that must never lie.
@Suite("Update check")
struct UpdateTests {

    @Test("numeric segments, not string order")
    func numericCompare() {
        #expect(UpdateChecker.isNewer("0.0.10", than: "0.0.9"))
        #expect(!UpdateChecker.isNewer("0.0.9", than: "0.0.10"))
        #expect(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
    }

    @Test("a tag's v prefix is not part of the version")
    func vPrefix() {
        #expect(UpdateChecker.isNewer("v0.0.2", than: "0.0.1"))
        #expect(!UpdateChecker.isNewer("v0.0.1", than: "0.0.1"))
    }

    @Test("missing segments read as zero")
    func shortVersions() {
        #expect(!UpdateChecker.isNewer("1.2", than: "1.2.0"))
        #expect(UpdateChecker.isNewer("1.2.1", than: "1.2"))
    }

    @Test("equal is not newer")
    func equal() {
        #expect(!UpdateChecker.isNewer("0.0.1", than: "0.0.1"))
    }
}
