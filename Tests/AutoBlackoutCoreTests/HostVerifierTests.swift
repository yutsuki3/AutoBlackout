import AutoBlackoutCore
import XCTest

final class HostVerifierTests: XCTestCase {
    private let shipped = HostKey(model: "Mac15,12", osBuild: "25G229")
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "HostVerifierTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func verifier(_ host: HostKey, allowlist: Set<HostKey>? = nil) -> HostVerifier {
        HostVerifier(current: host, shippedAllowlist: allowlist ?? [shipped], defaults: defaults)
    }

    func testShippedHostIsVerifiedWithoutLocalRecord() {
        let v = verifier(shipped)
        XCTAssertTrue(v.isVerified)
        XCTAssertEqual(v.source, .shippedAllowlist)
    }

    func testUnlistedHostIsUnverified() {
        let v = verifier(HostKey(model: "Mac14,2", osBuild: "24A335"))
        XCTAssertFalse(v.isVerified)
        XCTAssertEqual(v.source, .unverified)
    }

    func testSameModelWithDifferentBuildIsUnverified() {
        // A macOS update changes the build, so a listed model must be re-verified.
        XCTAssertFalse(verifier(HostKey(model: "Mac15,12", osBuild: "25G300")).isVerified)
    }

    func testSameBuildOnDifferentModelIsUnverified() {
        XCTAssertFalse(verifier(HostKey(model: "Mac15,13", osBuild: "25G229")).isVerified)
    }

    func testMarkVerifiedMakesHostVerifiedLocally() {
        let host = HostKey(model: "Mac14,2", osBuild: "24A335")
        let v = verifier(host)
        v.markVerified()
        XCTAssertTrue(v.isVerified)
        XCTAssertEqual(v.source, .localVerification)
    }

    func testLocalVerificationPersistsAcrossInstances() {
        let host = HostKey(model: "Mac14,2", osBuild: "24A335")
        verifier(host).markVerified()
        XCTAssertTrue(verifier(host).isVerified)
    }

    func testLocalVerificationDoesNotCarryOverToNewBuild() {
        verifier(HostKey(model: "Mac14,2", osBuild: "24A335")).markVerified()
        XCTAssertFalse(verifier(HostKey(model: "Mac14,2", osBuild: "24A400")).isVerified)
    }

    func testNewLocalVerificationReplacesPreviousOne() {
        let old = HostKey(model: "Mac14,2", osBuild: "24A335")
        let new = HostKey(model: "Mac14,2", osBuild: "24A400")
        verifier(old).markVerified()
        verifier(new).markVerified()
        XCTAssertTrue(verifier(new).isVerified)
        XCTAssertFalse(verifier(old).isVerified)
    }

    func testShippedHostReportsShippedEvenIfAlsoVerifiedLocally() {
        let v = verifier(shipped)
        v.markVerified()
        XCTAssertEqual(v.source, .shippedAllowlist)
    }

    func testUnidentifiableHostIsNeverVerified() {
        for host in [HostKey(model: "unknown", osBuild: "25G229"),
                     HostKey(model: "Mac15,12", osBuild: "unknown"),
                     HostKey(model: "unknown", osBuild: "unknown")] {
            let v = verifier(host, allowlist: [host])
            XCTAssertFalse(v.isVerified, "\(host)")
            v.markVerified()
            XCTAssertFalse(v.isVerified, "\(host) after markVerified")
        }
    }

    func testEmptyAllowlistWithNoLocalRecordIsUnverified() {
        XCTAssertFalse(verifier(shipped, allowlist: []).isVerified)
    }

    func testHostKeyDescriptionIsModelSlashBuild() {
        XCTAssertEqual(shipped.description, "Mac15,12/25G229")
    }
}
