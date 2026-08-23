import Testing
@testable import Ghostty

struct OhMyGhosttyVersionTests {
    @Test func appBundlePublishesReleaseMetadata() {
        let versions = OhMyGhosttyVersion()

        #expect(versions.omg == "0.1.0")
        #expect(versions.ghostty == "1.3.2-dev")
        #expect(versions.ghosttyRevision == "9ae02a326f62bd88f7f5508cf1807c67e7775cb5")
    }

    @Test func readsIndependentOMGAndGhosttyVersions() {
        let versions = OhMyGhosttyVersion(infoDictionary: [
            "OMGVersion": "0.4.2",
            "CFBundleShortVersionString": "9.9.9",
            "GhosttyBaseVersion": "1.3.2-dev",
            "GhosttyBaseRevision": "9ae02a326f62bd88f7f5508cf1807c67e7775cb5",
        ])

        #expect(versions.omg == "0.4.2")
        #expect(versions.ghostty == "1.3.2-dev")
        #expect(versions.ghosttyRevision == "9ae02a326f62bd88f7f5508cf1807c67e7775cb5")
        #expect(versions.releaseTag == "v0.4.2")
    }

    @Test func fallsBackToBundleMarketingVersion() {
        let versions = OhMyGhosttyVersion(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0",
        ])

        #expect(versions.omg == "0.1.0")
        #expect(versions.ghostty == "unknown")
        #expect(versions.ghosttyRevision == "unknown")
        #expect(versions.releaseTag == "v0.1.0")
    }

    @Test func nonSemverOMGVersionDoesNotProduceReleaseTag() {
        let versions = OhMyGhosttyVersion(infoDictionary: [
            "OMGVersion": "0.2.0-dev",
        ])

        #expect(versions.releaseTag == nil)
    }
}
