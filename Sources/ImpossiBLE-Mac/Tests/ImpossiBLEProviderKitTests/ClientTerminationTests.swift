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

    func testTargetIsOnlyTheClientThatWasValidated() {
        func target(current: pid_t?, expected: pid_t) -> pid_t? {
            MockServer.terminationTarget(
                current: current.map { SocketClientInfo(pid: $0, processName: "c") },
                expectedPid: expected, relayPid: relayPid, ownPid: ownPid)
        }
        XCTAssertEqual(target(current: 300, expected: 300), 300)
        XCTAssertNil(target(current: relayPid, expected: 300), "A takeover by the relay must not be signalled")
        XCTAssertNil(target(current: 301, expected: 300), "A different app must not be signalled")
        XCTAssertNil(target(current: nil, expected: 300), "A disconnected client must not be signalled")
    }

    func testTerminateToolReportsAnErrorWithoutAClient() throws {
        let fixture = ToolsFixture()
        XCTAssertNotNil(fixture.server.terminateConnectedClient())
    }
}
