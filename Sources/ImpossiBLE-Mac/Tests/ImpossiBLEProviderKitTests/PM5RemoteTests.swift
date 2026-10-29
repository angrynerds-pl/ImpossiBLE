import XCTest
@testable import ImpossiBLEProviderKit

final class CSAFETests: XCTestCase {
    func testScreenStateFrameMatchesErgData() throws {
        // Virtual key A: 76 04 13 02 01 2F, checksum 4D, no stuffing needed.
        XCTAssertEqual(try CSAFE.frame(PM5Command.screenState(PM5Key.a.screenValue)),
                       [0xF0, 0xFD, 0x00, 0x76, 0x04, 0x13, 0x02, 0x01, 0x2F, 0x4D, 0xF2])
    }

    func testFlagBytesAreStuffedIncludingTheChecksum() throws {
        // Payload F1 00 has checksum F1: both get stuffed.
        XCTAssertEqual(try CSAFE.frame([0xF1, 0x00]), [0xF0, 0xFD, 0x00, 0xF3, 0x01, 0x00, 0xF3, 0x01, 0xF2])
    }

    func testUnframeRoundTripsAndValidates() throws {
        let payload: [UInt8] = [0x01, 0x76, 0x01, 0x13, 0xF2, 0x00]
        let unframed = try XCTUnwrap(CSAFE.unframe(CSAFE.frame(payload)))
        XCTAssertEqual(unframed.content, payload)
        XCTAssertTrue(unframed.checksumValid)

        // Standard frames from the PM: F1 <status> <data> <checksum> F2.
        let standard = try XCTUnwrap(CSAFE.unframe([0xF1, 0x81, 0x76, 0x01, 0x13, 0x81 ^ 0x76 ^ 0x01 ^ 0x13, 0xF2]))
        XCTAssertEqual(standard.content, [0x81, 0x76, 0x01, 0x13])
        XCTAssertTrue(standard.checksumValid)

        XCTAssertFalse(try XCTUnwrap(CSAFE.unframe([0xF1, 0x81, 0x76, 0x00, 0xF2])).checksumValid)
        XCTAssertNil(CSAFE.unframe([0xF1, 0x81, 0x76]), "No end flag")
        XCTAssertNil(CSAFE.unframe([0x42, 0x00, 0xF2]), "No start flag")
    }

    func testOversizedFramesAreRefused() {
        XCTAssertThrowsError(try CSAFE.frame([UInt8](repeating: 0x01, count: 120)))
    }
}

final class PM5RemoteEngineTests: XCTestCase {
    private let pm5 = "PM5-ID"
    private let commandID = "svc:CE060021:0"
    private let responseID = "svc:CE060022:1"

    private var toBridge: [[String: Any]] = []
    private var toApp: [[String: Any]] = []
    private var scheduled: [() -> Void] = []
    private var published: [PM5Connection] = []
    private var engine: PM5RemoteEngine!

    override func setUp() {
        toBridge = []
        toApp = []
        scheduled = []
        engine = PM5RemoteEngine(
            sendToBridge: { [unowned self] in toBridge.append($0) },
            sendToApp: { [unowned self] in toApp.append($0) },
            schedule: { [unowned self] _, work in scheduled.append(work) },
            publish: { [unowned self] in published = $0 },
            note: { _ in }
        )
        engine.isEnabled = true
    }

    /// Replays what the bridge reports while the app connects and subscribes.
    private func connectPM5(subscribe: Bool = true) {
        _ = engine.bridgeMessage(["type": "didDiscover", "id": pm5, "name": "PM5 431407616"])
        _ = engine.bridgeMessage(["type": "didConnect", "id": pm5])
        _ = engine.bridgeMessage(["type": "didDiscoverCharacteristics", "id": pm5, "characteristics": [
            ["id": commandID, "uuid": "CE060021-43E5-11E4-916C-0800200C9A66"],
            ["id": responseID, "uuid": "ce060022-43e5-11e4-916c-0800200c9a66"],
        ]])
        if subscribe {
            _ = engine.bridgeMessage(["type": "didUpdateNotification", "id": pm5, "characteristicId": responseID, "enabled": true])
        }
    }

    private func response(_ bytes: [UInt8]) -> [String: Any] {
        ["type": "didUpdateValue", "id": pm5, "characteristicId": responseID, "value": Data(bytes).base64EncodedString()]
    }

    private func appWrite(_ bytes: [UInt8]) -> [String: Any] {
        ["type": "write", "characteristicId": commandID, "value": Data(bytes).base64EncodedString(), "writeType": 0]
    }

    private func submitKeyA(_ done: XCTestExpectation, into result: UnsafeMutablePointer<Result<PM5Response?, ToolError>?>? = nil) {
        engine.submit(PM5Injection(deviceID: nil, payload: PM5Command.screenState(PM5Key.a.screenValue),
                                   label: "A", swallowResponse: true) { outcome in
            result?.pointee = outcome
            done.fulfill()
        })
    }

    private static let ack: [UInt8] = {
        let content: [UInt8] = [0x81, 0x76, 0x01, 0x13]
        return [0xF1] + content + [content.reduce(0, ^), 0xF2]
    }()

    func testReadyOnlyOnceTheAppSubscribed() {
        connectPM5(subscribe: false)
        XCTAssertEqual(published, [PM5Connection(id: pm5, name: "PM5 431407616", isReady: false)])
        _ = engine.bridgeMessage(["type": "didUpdateNotification", "id": pm5, "characteristicId": responseID, "enabled": true])
        XCTAssertEqual(published.first?.isReady, true)
    }

    func testKeyPressIsInvisibleToTheApp() throws {
        connectPM5()
        let done = expectation(description: "done")
        var result: Result<PM5Response?, ToolError>?
        submitKeyA(done, into: &result)

        XCTAssertEqual(toBridge.count, 1)
        XCTAssertEqual(toBridge[0]["characteristicId"] as? String, commandID)
        XCTAssertEqual((toBridge[0]["value"] as? String).flatMap { Data(base64Encoded: $0) },
                       Data(try CSAFE.frame(PM5Command.screenState(47))))

        // The app's own command while ours is in flight waits.
        XCTAssertTrue(engine.appMessage(appWrite([0xF0, 0xFD, 0x00, 0x7E, 0x01, 0x86, 0xF9, 0xF2])))
        // Our write confirmation and our reply never reach the app.
        XCTAssertTrue(engine.bridgeMessage(["type": "didWriteValue", "id": pm5, "characteristicId": commandID, "error": ""]))
        XCTAssertTrue(engine.bridgeMessage(response(Array(Self.ack.prefix(3)))), "First chunk of a split reply")
        XCTAssertTrue(engine.bridgeMessage(response(Array(Self.ack.dropFirst(3)))))

        wait(for: [done], timeout: 1)
        let response = try XCTUnwrap(try XCTUnwrap(result).get())
        XCTAssertEqual(response.status, 0x81)
        XCTAssertTrue(toApp.isEmpty)
        XCTAssertEqual(toBridge.count, 2, "The held app command goes out afterwards")
        XCTAssertFalse(engine.appMessage(appWrite([0xF2])), "Nothing is held once done")
    }

    func testRepliesThatAreNotOursGoToTheApp() {
        connectPM5()
        let done = expectation(description: "done")
        submitKeyA(done)

        // A late reply to an earlier GETPMCFG from the app.
        let content: [UInt8] = [0x81, 0x7E, 0x02, 0x86, 0x01]
        let foreign = response([0xF1] + content + [content.reduce(0, ^), 0xF2])
        XCTAssertTrue(engine.bridgeMessage(foreign))
        XCTAssertEqual(toApp.count, 1, "Forwarded as soon as it is known not to be ours")

        XCTAssertTrue(engine.bridgeMessage(response(Self.ack)))
        wait(for: [done], timeout: 1)
        XCTAssertEqual(toApp.count, 1)
    }

    func testWaitsWhileTheAppIsMidFrame() {
        connectPM5()
        XCTAssertFalse(engine.appMessage(appWrite([0xF0, 0xFD, 0x00, 0x76])), "First chunk of an app frame")
        let done = expectation(description: "done")
        submitKeyA(done)
        XCTAssertTrue(toBridge.isEmpty, "Never splits the app's frame")
        XCTAssertEqual(scheduled.count, 1)

        XCTAssertFalse(engine.appMessage(appWrite([0x01, 0x76, 0xF2])))
        XCTAssertFalse(engine.bridgeMessage(response(Self.ack)), "The app's own reply passes through untouched")
        scheduled.removeFirst()()
        XCTAssertEqual(toBridge.count, 1, "Sent once the app is between commands")

        _ = engine.bridgeMessage(["type": "didWriteValue", "id": pm5, "characteristicId": commandID, "error": ""])
        _ = engine.bridgeMessage(response(Self.ack))
        wait(for: [done], timeout: 1)
    }

    func testTimeoutReleasesHeldTrafficAndReports() throws {
        connectPM5()
        let done = expectation(description: "done")
        var result: Result<PM5Response?, ToolError>?
        submitKeyA(done, into: &result)
        XCTAssertTrue(engine.appMessage(appWrite([0xF0, 0xF2])))

        let timeout = try XCTUnwrap(scheduled.last)
        timeout()
        wait(for: [done], timeout: 1)
        if case .success = try XCTUnwrap(result) { XCTFail("Expected a timeout") }
        XCTAssertEqual(toBridge.count, 2, "The held app command is released")
    }

    func testRefusesWhenOffOrNotConnected() throws {
        let noPM5 = expectation(description: "no PM5")
        var result: Result<PM5Response?, ToolError>?
        submitKeyA(noPM5, into: &result)
        wait(for: [noPM5], timeout: 1)
        XCTAssertThrowsError(try XCTUnwrap(result).get())

        connectPM5()
        engine.setEnabled(false)
        let off = expectation(description: "off")
        submitKeyA(off, into: &result)
        wait(for: [off], timeout: 1)
        XCTAssertThrowsError(try XCTUnwrap(result).get())
        XCTAssertTrue(toBridge.isEmpty)
    }

    func testDisconnectFailsTheCommandInFlight() throws {
        connectPM5()
        let done = expectation(description: "done")
        var result: Result<PM5Response?, ToolError>?
        submitKeyA(done, into: &result)
        _ = engine.bridgeMessage(["type": "didDisconnect", "id": pm5])
        wait(for: [done], timeout: 1)
        XCTAssertThrowsError(try XCTUnwrap(result).get())
        XCTAssertTrue(published.isEmpty)
    }
}

final class PM5StateTests: XCTestCase {
    func testQueryIsOneGetConfigFrame() {
        XCTAssertEqual(PM5State.queryPayload, [0x7E, 0x09, 0x8F, 0x8D, 0x93, 0x89, 0x8E, 0x8A, 0x8B, 0x97, 0x86])
    }

    func testDecodesEachReportedField() throws {
        let replies: [UInt8] = [
            0x8F, 0x01, 0x02,             // operational: workout
            0x8D, 0x01, 0x01,             // workout state: workoutRow
            0x93, 0x01, 0x01,             // rowing: active
            0x89, 0x01, 0x05,             // fixedTimeSplits
            0x8E, 0x01, 0xFF,             // interval: none
            0x8A, 0x01, 0x01,             // display: forceVelocity
            0x8B, 0x01, 0x01,             // units: pace
            0x97, 0x01, 0x55,             // battery 85 %
            0x86, 0x03, 0x01, 0x2F, 0x00, // last screen command: workout / key A / inactive
        ]
        let state = try XCTUnwrap(PM5State(response: [0x81, 0x7E, UInt8(replies.count)] + replies))

        XCTAssertEqual(state.operationalState?.name, "workout")
        XCTAssertEqual(state.workoutState?.name, "workoutRow")
        XCTAssertEqual(state.rowingState?.name, "active")
        XCTAssertEqual(state.workoutType?.name, "fixedTimeSplits")
        XCTAssertEqual(state.intervalType?.name, "none")
        XCTAssertEqual(state.displayType?.name, "forceVelocity")
        XCTAssertEqual(state.displayUnits?.name, "pace")
        XCTAssertEqual(state.batteryPercent, 85)
        XCTAssertEqual(state.screenCommand?.value, 47)
        XCTAssertEqual(state.screenCommand?.status.name, "inactive")
        XCTAssertEqual(state.summary, "Workout · Workout row · Force velocity")
    }

    func testMenusSummarizeAsReadyAndUnknownValuesKeepTheirNumber() throws {
        let state = try XCTUnwrap(PM5State(response: [0x81, 0x7E, 0x06, 0x8F, 0x01, 0x01, 0x8D, 0x01, 0x63]))
        XCTAssertEqual(state.summary, "Ready")
        XCTAssertEqual(state.workoutState?.raw, 99)
        XCTAssertNil(state.workoutState?.name)
        XCTAssertNil(state.displayType)
    }

    func testRejectsOtherRepliesAndTruncatedData() {
        XCTAssertNil(PM5State(response: [0x81, 0x76, 0x01, 0x13]))
        XCTAssertNil(PM5State(response: [0x81, 0x7E, 0x04, 0x8F, 0x05, 0x01, 0x02]))
    }
}
