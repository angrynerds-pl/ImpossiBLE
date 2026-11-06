import SimBridgeServer
import XCTest
@testable import ImpossiBLEProviderKit

final class ClientTerminationTests: XCTestCase {
    private let ownPid: pid_t = 100
    private let relayPid: pid_t = 200

    private func refusal(pid: pid_t, relay: pid_t? = nil) -> String? {
        MockServer.terminationRefusal(
            for: SocketClientInfo(pid: pid, processName: "client"),
            relayPid: relay,
            ownPid: ownPid
        )
    }

    func testClientWithoutPidIsRefused() {
        XCTAssertNotNil(refusal(pid: 0))
    }

    func testOwnProcessIsRefused() {
        XCTAssertNotNil(refusal(pid: ownPid))
    }

    func testRelayProcessIsRefused() {
        XCTAssertNotNil(refusal(pid: relayPid, relay: relayPid))
    }

    func testSimulatorAppIsAllowed() {
        XCTAssertNil(refusal(pid: 300, relay: relayPid))
    }

    func testTerminateToolReportsAnErrorWithoutAClient() throws {
        let fixture = ToolsFixture()
        XCTAssertNotNil(fixture.server.terminateConnectedClient())
    }
}
