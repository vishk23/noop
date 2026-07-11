import XCTest
@testable import Strand

final class OuraCredentialsTests: XCTestCase {
    func testParsesCompleteInfoDict() {
        let info: [String: Any] = [
            "OURA_CLIENT_ID": "cid", "OURA_CLIENT_SECRET": "secret",
            "OURA_REDIRECT_URI": "noop://oura/callback",
        ]
        let c = OuraCredentials.from(info)
        XCTAssertEqual(c, OuraCredentials(clientId: "cid", clientSecret: "secret",
                                          redirectURI: "noop://oura/callback"))
    }

    func testNilWhenAnyKeyMissingOrBlank() {
        XCTAssertNil(OuraCredentials.from(["OURA_CLIENT_ID": "cid", "OURA_CLIENT_SECRET": "s"]))  // no redirect
        XCTAssertNil(OuraCredentials.from([
            "OURA_CLIENT_ID": "", "OURA_CLIENT_SECRET": "s", "OURA_REDIRECT_URI": "noop://x",
        ]))  // blank id
    }
}
