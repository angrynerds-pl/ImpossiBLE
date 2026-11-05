import XCTest
@testable import ImpossiBLEProviderKit

final class AndroidRelayLifecycleTests: XCTestCase {
    private func makeRelay(script: String) throws -> AndroidRelay {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "relay-\(UUID().uuidString)")!
        return AndroidRelay(server: MockServer(autoStart: false), defaults: defaults, helperURL: url)
    }

    func testRegenerateTokenRestartsAFailedRelay() throws {
        let relay = try makeRelay(script: "exit 64")
        relay.setEnabled(true)
        let failed = expectation(description: "failed")
        let watch = relay.$status.sink { if case .failed = $0 { failed.fulfill() } }
        wait(for: [failed], timeout: 5)
        watch.cancel()
        XCTAssertNil(relay.pid)

        relay.regenerateToken()
        XCTAssertNotNil(relay.pid, "A failed but enabled relay is started again with the new token")
        relay.stop()
    }
}
