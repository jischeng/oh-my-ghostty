import XCTest
@testable import OMGMobileCore

final class MobileSessionRouteTests: XCTestCase {
    private let endpoint = String(repeating: "a", count: 64)
    private let session = "12345678-1234-1234-1234-123456789abc"
    private let generation = String(repeating: "b", count: 32)

    func testRowIdentityPreservesTheExactSessionAndGeneration() {
        let route = MobileSessionRoute("\(endpoint)/\(session)/\(generation)")
        XCTAssertEqual(route?.endpointID, endpoint)
        XCTAssertEqual(route?.sessionID, session)
        XCTAssertEqual(route?.generation, generation)
    }

    func testMissingGenerationCannotBecomeAnAttachmentToTheLatestProcess() {
        XCTAssertNil(MobileSessionRoute("\(endpoint)/\(session)"))
        XCTAssertNil(MobileSessionRoute("\(endpoint)/\(session)/"))
    }

    func testMalformedAndPathLikeIdentitiesAreRejected() {
        for value in [
            "../\(session)/\(generation)", "\(endpoint)/../\(generation)",
            "\(endpoint)/\(session)/\(generation)/extra", "\(endpoint)/\(session)/invalid",
            "/\(session)/\(generation)",
        ] {
            XCTAssertNil(MobileSessionRoute(value))
        }
    }
}
