import XCTest
@testable import ImpossiBLEProviderKit

/// Mirrors the library's ReplayRelaxedTests against the Mac app's ports.
final class ReplayRelaxedTests: XCTestCase {
    private static let peripheral = "6B1E0F7A-4C55-4D0B-9C1A-2E3F40516273"
    private static let control = "\(peripheral):CE060020-43E5-11E4-916C-0800200C9A66:0"
    private static let rowingService = "\(peripheral):CE060030-43E5-11E4-916C-0800200C9A66:1"
    private static let command = "\(control):CE060021-43E5-11E4-916C-0800200C9A66:0"
    private static let response = "\(control):CE060022-43E5-11E4-916C-0800200C9A66:1"
    private static let rowing = "\(rowingService):CE060031-43E5-11E4-916C-0800200C9A66:0"
    private static let summary = "\(rowingService):CE060039-43E5-11E4-916C-0800200C9A66:1"

    // MARK: - Relaxed

    func testRelaxedAnswersOutOfOrderSubscriptionsChangedDataAndExtraPolls() {
        let setDateRecorded = Self.csafe([0x76, 0x04, 0x22, 0x02, 0x0B, 0x05])
        let poll = Self.csafe([0x7E, 0x01, 0x80])
        let setDateReply: [UInt8] = [0xF0, 0x00, 0xFD, 0x01, 0x76, 0x01, 0x22, 0x54, 0xF2]
        let pollReply: [UInt8] = [0xF0, 0x00, 0xFD, 0x01, 0x7E, 0x03, 0x80, 0x01, 0x09, 0x76, 0xF2]

        var r = Recording()
        r.app(["type": "setNotify", "id": Self.peripheral, "characteristicId": Self.response, "enabled": true])
        r.provider(["type": "didUpdateNotification", "id": Self.peripheral, "characteristicId": Self.response, "enabled": true, "error": ""])
        r.app(["type": "setNotify", "id": Self.peripheral, "characteristicId": Self.rowing, "enabled": true])
        r.provider(["type": "didUpdateNotification", "id": Self.peripheral, "characteristicId": Self.rowing, "enabled": true, "error": ""])
        r.write(Array(setDateRecorded.prefix(4)))
        r.provider(Self.confirmation)
        r.write(Array(setDateRecorded.dropFirst(4)))
        r.provider(Self.confirmation)
        r.provider(Self.notification(Self.response, setDateReply))
        r.write(poll)
        r.provider(Self.confirmation)
        r.provider(Self.notification(Self.response, pollReply))
        r.provider(Self.notification(Self.rowing, [0x01]), after: 2)

        let passed = expectation(description: "passed")
        let sent = Sent()
        let responder = RelaxedReplayResponder(script: r.script, speed: 20) { status in
            if case .passed = status { passed.fulfill() }
        }
        responder.begin(send: sent.append)

        responder.handle(["type": "setNotify", "id": Self.peripheral, "characteristicId": Self.rowing, "enabled": true])
        responder.handle(["type": "setNotify", "id": Self.peripheral, "characteristicId": Self.response, "enabled": true])
        let setDateNow = Self.csafe([0x76, 0x04, 0x22, 0x02, 0x0C, 0x07])
        responder.handle(Self.write(Array(setDateNow.prefix(5))))
        responder.handle(Self.write(Array(setDateNow.dropFirst(5))))
        responder.handle(Self.write(poll))
        responder.handle(Self.write(poll))
        wait(for: [passed], timeout: 3)

        let values = sent.values(of: Self.response)
        XCTAssertEqual(values, [setDateReply, pollReply, pollReply], "Changed date data matches by command structure; the extra poll reuses the answer")
        XCTAssertEqual(sent.values(of: Self.rowing), [[0x01]])
        XCTAssertEqual(sent.count(of: "didWriteValue"), 4, "Including the synthesized one for the leading chunk")
    }

    func testRelaxedTimelineWaitsForTheFirstRequestOfItsKind() {
        var r = Recording()
        r.app(["type": "scan", "services": [], "options": [:]])
        r.provider(["type": "didDiscover", "id": Self.peripheral, "name": "PM5", "rssi": -50])

        let sent = Sent()
        let passed = expectation(description: "passed")
        let responder = RelaxedReplayResponder(script: r.script) { status in
            if case .passed = status { passed.fulfill() }
        }
        responder.begin(send: sent.append)
        let early = expectation(description: "nothing before the scan")
        early.isInverted = true
        wait(for: [early], timeout: 0.3)
        XCTAssertEqual(sent.count(of: "didDiscover"), 0)

        responder.handle(["type": "scan", "services": [], "options": [:], "_scannerKeys": ["cbs_1"]])
        wait(for: [passed], timeout: 2)
        XCTAssertEqual(sent.count(of: "didDiscover"), 1)
    }

    func testAdvertisingRepeatsWhileScanningUntilConnected() {
        var r = Recording()
        r.app(["type": "scan", "services": [], "options": [:]])
        r.provider(["type": "didDiscover", "id": Self.peripheral, "name": "PM5", "rssi": -50])

        let sent = Sent()
        let responder = RelaxedReplayResponder(script: r.script) { _ in }
        responder.begin(send: sent.append)
        responder.handle(["type": "scan", "services": [], "options": [:]])

        let repeated = expectation(description: "advertising continues")
        repeated.isInverted = true
        wait(for: [repeated], timeout: 2.3)
        XCTAssertGreaterThanOrEqual(sent.count(of: "didDiscover"), 3, "The recorded one, then one a second")

        responder.handle(["type": "connect", "id": Self.peripheral, "options": [:]])
        let afterConnect = sent.count(of: "didDiscover")
        let quiet = expectation(description: "stops once connected")
        quiet.isInverted = true
        wait(for: [quiet], timeout: 1.5)
        XCTAssertEqual(sent.count(of: "didDiscover"), afterConnect)
    }

    // MARK: - PM5 clock

    func testPM5TimestampsMoveToNow() throws {
        let dateTimeReply = Self.reply([0x7E, 0x09, 0x85, 0x07, 0x0B, 0x29, 0x00, 0x0B, 0x06, 0x07, 0xEA])
        let logReply = Self.reply([0x7E, 0x07, 0x6A, 0x05, 0x34, 0x6B, 0x0B, 0x2D, 0x00])
        let summaryValue: [UInt8] = [0x6B, 0x34, 0x2D, 0x0B, 0xD8, 0x2C, 0x00]
        var r = Recording()
        r.provider(Self.notification(Self.response, dateTimeReply))
        r.provider(Self.notification(Self.summary, summaryValue))
        r.provider(Self.notification(Self.response, logReply))
        r.provider(Self.notification(Self.rowing, [0x6B, 0x34, 0x2D, 0x0B]))

        let now = Date()
        let shifted = r.script.shiftingPM5Times(to: now)
        let values = shifted.entries.compactMap(\.valueBytes)

        let logged = PM5Stamp(date: now).log
        let read = PM5Stamp(date: now.addingTimeInterval(-4 * 60))
        XCTAssertEqual(Array(values[1].prefix(4)), logged)
        XCTAssertEqual(Array(values[1].dropFirst(4)), Array(summaryValue.dropFirst(4)))
        let hour12 = read.hour % 12 == 0 ? 12 : read.hour % 12
        XCTAssertEqual(values[0], Self.reply([0x7E, 0x09, 0x85, 0x07, UInt8(hour12), UInt8(read.minute), read.hour >= 12 ? 1 : 0,
                                              UInt8(read.month), UInt8(read.day), UInt8(read.year >> 8), UInt8(read.year & 0xFF)]))
        XCTAssertEqual(values[2], Self.reply([0x7E, 0x07, 0x6A, 0x05, logged[1], logged[0], logged[3], logged[2], 0x00]))
        XCTAssertEqual(values[3], [0x6B, 0x34, 0x2D, 0x0B], "Rowing data is not a timestamp")
    }

    func testCSAFESignatureIgnoresData() {
        XCTAssertEqual(CSAFE.signature(Self.csafe([0x76, 0x04, 0x22, 0x02, 0x0B, 0x05])), "76[22]")
        XCTAssertEqual(CSAFE.signature(Self.csafe([0x7E, 0x02, 0x90, 0x99])), "7E[90 99]")
    }

    // MARK: - Helpers

    private static let confirmation: [String: Any] = ["type": "didWriteValue", "id": peripheral, "characteristicId": command, "error": ""]

    private static func notification(_ characteristic: String, _ value: [UInt8]) -> [String: Any] {
        ["type": "didUpdateValue", "id": peripheral, "characteristicId": characteristic, "value": Data(value).base64EncodedString(), "error": ""]
    }

    private static func write(_ value: [UInt8]) -> [String: Any] {
        ["type": "write", "id": peripheral, "characteristicId": command, "value": Data(value).base64EncodedString(), "writeType": 0]
    }

    static func csafe(_ payload: [UInt8]) -> [UInt8] {
        CSAFE.stuff([0xFD, 0x00] + payload + [payload.reduce(0, ^)])
    }

    static func reply(_ payload: [UInt8]) -> [UInt8] {
        let body: [UInt8] = [0x81] + payload
        return CSAFE.stuff([0x00, 0xFD] + body + [body.reduce(0, ^)])
    }

    private struct Recording {
        private(set) var entries: [ReplayScript.Entry] = []
        private var time = Date(timeIntervalSince1970: 1_800_000_000)

        mutating func app(_ message: [String: Any], after delay: TimeInterval = 0.01) {
            add(message, .fromClient, delay)
        }

        mutating func provider(_ message: [String: Any], after delay: TimeInterval = 0.01) {
            add(message, .toClient, delay)
        }

        mutating func write(_ value: [UInt8]) {
            app(ReplayRelaxedTests.write(value))
        }

        private mutating func add(_ message: [String: Any], _ direction: ReplayScript.Direction, _ delay: TimeInterval) {
            time += delay
            entries.append(.init(seq: entries.count + 1, timestamp: time, direction: direction,
                                 message: message, type: message["type"] as! String))
        }

        var script: ReplayScript { ReplayScript(entries: entries) }
    }

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [[String: Any]] = []

        func append(_ message: [String: Any]) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }

        func count(of type: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return messages.filter { $0["type"] as? String == type }.count
        }

        func values(of characteristic: String) -> [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            return messages.compactMap { message in
                guard message["type"] as? String == "didUpdateValue", message["characteristicId"] as? String == characteristic,
                      let value = message["value"] as? String, let data = Data(base64Encoded: value) else { return nil }
                return Array(data)
            }
        }
    }
}
