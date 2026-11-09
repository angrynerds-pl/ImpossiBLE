import SimBridgeServer
import XCTest
@testable import ImpossiBLEProviderKit

final class WriteCompletionTests: XCTestCase {
    private func reply(writeType: Int, relayClient: Bool) -> [String: Any]? {
        MockServer.writeCompletionReply(peripheralUUID: "P", charId: "P:s:0:c:0", writeType: writeType,
                                        completesWritesWithoutResponse: relayClient)
    }

    func testIOSClientNeverGetsAReplyForWriteWithoutResponse() {
        XCTAssertNil(reply(writeType: 1, relayClient: false))
    }

    func testWriteWithResponseIsAlwaysAnswered() {
        XCTAssertEqual(reply(writeType: 0, relayClient: false)?["type"] as? String, "didWriteValue")
        XCTAssertNil(reply(writeType: 0, relayClient: true)?["writeType"])
    }

    func testRelayClientGetsATypedReplyForWriteWithoutResponse() {
        XCTAssertEqual(reply(writeType: 1, relayClient: true)?["writeType"] as? Int, 1)
    }

    func testInjectedWriteErrorIsAnsweredForRelayWithoutResponseOnly() {
        func errorReply(writeType: Int, relayClient: Bool) -> [String: Any]? {
            MockServer.injectedWriteErrorReply(
                rule: MockFailureRule(id: 1, operation: .write, deviceID: "P", characteristicUUID: nil,
                                       behavior: .error(message: "boom", attError: 3), remaining: nil),
                peripheralUUID: "P", charId: "P:s:0:c:0", writeType: writeType, completesWritesWithoutResponse: relayClient)
        }
        XCTAssertNil(errorReply(writeType: 1, relayClient: false))
        XCTAssertEqual(errorReply(writeType: 1, relayClient: true)?["errorCode"] as? Int, 3)
        XCTAssertEqual(errorReply(writeType: 0, relayClient: false)?["errorCode"] as? Int, 3)
    }

    func testOnlyTheRelayProcessIsARelayClient() {
        func client(_ pid: pid_t) -> SocketClientInfo { SocketClientInfo(pid: pid, processName: "c") }
        XCTAssertTrue(MockServer.isRelayClient(client(200), relayPid: 200))
        XCTAssertFalse(MockServer.isRelayClient(client(300), relayPid: 200))
        XCTAssertFalse(MockServer.isRelayClient(client(0), relayPid: 0), "pid 0 is an unattributed client")
        XCTAssertFalse(MockServer.isRelayClient(client(200), relayPid: nil))
        XCTAssertFalse(MockServer.isRelayClient(nil, relayPid: 200))
    }
}

final class AndroidRelayPolicyTests: XCTestCase {
    func testRestartBudgetAllowsLimitWithinWindowThenRecovers() {
        var budget = RestartBudget(limit: 5, window: 60)
        let start = Date()
        for second in 0..<5 { XCTAssertTrue(budget.consume(now: start.addingTimeInterval(Double(second)))) }
        XCTAssertFalse(budget.consume(now: start.addingTimeInterval(10)))
        XCTAssertTrue(budget.consume(now: start.addingTimeInterval(61)), "The oldest start has left the window")
    }

    func testResetClearsTheBudget() {
        var budget = RestartBudget(limit: 1, window: 60)
        XCTAssertTrue(budget.consume())
        XCTAssertFalse(budget.consume())
        budget.reset()
        XCTAssertTrue(budget.consume())
    }

    func testTokenIsHexOfTheRandomBytes() {
        let token = AndroidRelay.makeToken(random: { count, buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0xAB, count: count)
            return errSecSuccess
        })
        XCTAssertEqual(token, String(repeating: "ab", count: 16))
    }

    func testRandomFailureYieldsNoTokenInsteadOfZeros() {
        XCTAssertNil(AndroidRelay.makeToken(random: { _, _ in errSecParam }))
    }

    func testDefaultTokensDiffer() {
        XCTAssertNotEqual(AndroidRelay.makeToken(), AndroidRelay.makeToken())
    }
}
