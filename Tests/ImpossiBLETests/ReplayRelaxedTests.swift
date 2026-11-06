import CoreBluetooth
@testable import ImpossiBLE
import XCTest

#if targetEnvironment(simulator)
/// Replays hand-written recordings through the real CoreBluetooth surface,
/// the way an app under test meets them.
final class ReplayRelaxedTests: XCTestCase {
    private static let peripheralID = "6B1E0F7A-4C55-4D0B-9C1A-2E3F40516273"
    private static let controlService = "\(peripheralID):CE060020-43E5-11E4-916C-0800200C9A66:0"
    private static let rowingService = "\(peripheralID):CE060030-43E5-11E4-916C-0800200C9A66:1"
    private static let command = "\(controlService):CE060021-43E5-11E4-916C-0800200C9A66:0"
    private static let response = "\(controlService):CE060022-43E5-11E4-916C-0800200C9A66:1"
    private static let rowing = "\(rowingService):CE060031-43E5-11E4-916C-0800200C9A66:0"

    private var files: [URL] = []
    private var states: [(ImpossiBLEReplayState, String?)] = []

    override func tearDown() {
        ImpossiBLESetReplayStatusHandler(nil)
        ImpossiBLECleanupReplay(nil)
        ImpossiBLESetReplayOptions(1, .strict)
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    // MARK: - Relaxed

    func testRelaxedReplayToleratesOrderPollingAndChangingCommandData() throws {
        let setDateRecorded = Self.csafe([0x76, 0x04, 0x22, 0x02, 0x0B, 0x05])
        let poll = Self.csafe([0x7E, 0x01, 0x80])
        let setDateReply = Data([0xF0, 0x00, 0xFD, 0x01, 0x76, 0x01, 0x22, 0x54, 0xF2])
        let pollReply = Data([0xF0, 0x00, 0xFD, 0x01, 0x7E, 0x03, 0x80, 0x01, 0x09, 0x76, 0xF2])

        var r = Recording()
        r.app(["type": "scan", "services": [], "options": ["kCBScanOptionAllowDuplicates": false]])
        r.provider(["type": "didDiscover", "id": Self.peripheralID, "name": "PM5 TEST", "rssi": -50, "adv": [:]], after: 0.1)
        r.app(["type": "connect", "id": Self.peripheralID, "options": [:]], after: 0.2)
        r.provider(["type": "didConnect", "id": Self.peripheralID])
        r.app(["type": "discoverServices", "id": Self.peripheralID, "services": []])
        r.provider(["type": "didDiscoverServices", "id": Self.peripheralID, "error": "", "services": [
            ["id": Self.controlService, "uuid": "CE060020-43E5-11E4-916C-0800200C9A66", "primary": true],
            ["id": Self.rowingService, "uuid": "CE060030-43E5-11E4-916C-0800200C9A66", "primary": true],
        ]])
        r.app(["type": "discoverCharacteristics", "id": Self.peripheralID, "serviceId": Self.controlService, "characteristics": []])
        r.provider(["type": "didDiscoverCharacteristics", "id": Self.peripheralID, "serviceId": Self.controlService, "error": "", "characteristics": [
            ["id": Self.command, "uuid": "CE060021-43E5-11E4-916C-0800200C9A66", "properties": 0x08],
            ["id": Self.response, "uuid": "CE060022-43E5-11E4-916C-0800200C9A66", "properties": 0x10],
        ]])
        r.app(["type": "discoverCharacteristics", "id": Self.peripheralID, "serviceId": Self.rowingService, "characteristics": []])
        r.provider(["type": "didDiscoverCharacteristics", "id": Self.peripheralID, "serviceId": Self.rowingService, "error": "", "characteristics": [
            ["id": Self.rowing, "uuid": "CE060031-43E5-11E4-916C-0800200C9A66", "properties": 0x10],
        ]])
        // Recorded response channel first; the app below subscribes rowing first.
        r.app(["type": "setNotify", "id": Self.peripheralID, "characteristicId": Self.response, "enabled": true])
        r.provider(["type": "didUpdateNotification", "id": Self.peripheralID, "characteristicId": Self.response, "enabled": true, "error": ""])
        r.app(["type": "setNotify", "id": Self.peripheralID, "characteristicId": Self.rowing, "enabled": true])
        r.provider(["type": "didUpdateNotification", "id": Self.peripheralID, "characteristicId": Self.rowing, "enabled": true, "error": ""])
        // Set date, written in two chunks.
        r.write(setDateRecorded.prefix(4))
        r.provider(Self.writeConfirmation)
        r.write(setDateRecorded.dropFirst(4))
        r.provider(Self.writeConfirmation)
        r.provider(Self.notification(Self.response, setDateReply), after: 0.05)
        // Status poll; the app below polls one more time than recorded.
        r.write(poll, after: 0.2)
        r.provider(Self.writeConfirmation)
        r.provider(Self.notification(Self.response, pollReply), after: 0.05)
        // Rowing data, on the timeline.
        r.provider(Self.notification(Self.rowing, Data([0x01])), after: 2)
        r.provider(Self.notification(Self.rowing, Data([0x02])), after: 2)
        r.write(poll, after: 0.5)
        r.provider(Self.writeConfirmation)
        r.provider(Self.notification(Self.response, pollReply), after: 0.05)

        let passed = observeResult()
        ImpossiBLESetReplayOptions(20, .relaxed)
        try setUp(r)

        let app = PM5Client()
        app.subscribeOrder = [Self.rowing, Self.response]
        // Same command structure, different date.
        let setDateNow = Self.csafe([0x76, 0x04, 0x22, 0x02, 0x0C, 0x07])
        app.writes = [setDateNow.prefix(5), setDateNow.dropFirst(5), poll, poll, poll]
        let started = Date()
        app.begin()

        wait(for: [passed], timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "Four seconds of recording at 20×")
        XCTAssertEqual(states.last?.0, .passed, "\(states)")

        let received = expectation(description: "every reply")
        app.whenReceived(count: 6) { received.fulfill() }
        wait(for: [received], timeout: 5)
        let responses = app.values[Self.response] ?? []
        XCTAssertEqual(responses.first, setDateReply)
        XCTAssertEqual(Array(responses.dropFirst()), [pollReply, pollReply, pollReply], "The extra poll reuses the last answer")
        XCTAssertEqual(app.values[Self.rowing], [Data([0x01]), Data([0x02])])
        XCTAssertEqual(app.writeConfirmations, 5, "Including the leading chunk")
    }

    func testRelaxedTimelineWaitsForTheRequestItFollows() throws {
        var r = Recording()
        r.app(["type": "scan", "services": [], "options": ["kCBScanOptionAllowDuplicates": false]])
        r.provider(["type": "didDiscover", "id": Self.peripheralID, "name": "PM5 TEST", "rssi": -50, "adv": [:]], after: 0.1)

        ImpossiBLESetReplayOptions(1, .relaxed)
        let passed = observeResult()
        try setUp(r)

        let app = PM5Client()
        app.scans = false
        app.begin()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(app.discovered, "No advertisement before the app scans")
        XCTAssertEqual(states.last?.0, .running)
        XCTAssertTrue(states.last?.1?.contains("waiting for scan") == true, "\(states)")

        app.scan()
        wait(for: [passed], timeout: 5)
        XCTAssertNotNil(app.discovered)
    }

    // MARK: - Speed

    func testSpeedScalesStrictDelays() throws {
        var r = Recording()
        r.app(["type": "scan", "services": [], "options": ["kCBScanOptionAllowDuplicates": false]])
        r.provider(["type": "didDiscover", "id": Self.peripheralID, "name": "PM5 TEST", "rssi": -50, "adv": [:]], after: 5)

        ImpossiBLESetReplayOptions(50, .strict)
        let passed = observeResult()
        try setUp(r)
        let started = Date()
        let app = PM5Client()
        app.begin()

        wait(for: [passed], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "Five seconds at 50×")
        XCTAssertEqual(states.last?.0, .passed)
    }

    // MARK: - Helpers

    private static let writeConfirmation: [String: Any] = ["type": "didWriteValue", "id": peripheralID, "characteristicId": command, "error": ""]

    private static func notification(_ characteristic: String, _ value: Data) -> [String: Any] {
        ["type": "didUpdateValue", "id": peripheralID, "characteristicId": characteristic, "value": value.base64EncodedString(), "error": ""]
    }

    /// An extended CSAFE frame to the PM, as ErgData formats it.
    static func csafe(_ payload: [UInt8]) -> Data {
        let body = [0xFD, 0x00] + payload + [payload.reduce(0, ^)]
        var frame: [UInt8] = [0xF0]
        for byte in body {
            if (0xF0...0xF3).contains(byte) {
                frame += [0xF3, byte - 0xF0]
            } else {
                frame.append(byte)
            }
        }
        return Data(frame + [0xF2])
    }

    private func observeResult() -> XCTestExpectation {
        let done = expectation(description: "replay finished")
        ImpossiBLESetReplayStatusHandler { [weak self] state, detail in
            self?.states.append((state, detail))
            if state == .passed || state == .failed {
                done.fulfill()
            }
        }
        return done
    }

    private func setUp(_ recording: Recording) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString).json")
        try recording.json().write(to: url)
        files.append(url)
        var error: NSError?
        XCTAssertTrue(ImpossiBLESetupReplay(url.path, &error), "\(String(describing: error))")
        XCTAssertTrue(ImpossiBLEStartReplay(&error), "\(String(describing: error))")
    }
}

/// Builds a recording in the Passthrough format.
private struct Recording {
    private var entries: [[String: Any]] = []
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    mutating func app(_ message: [String: Any], after delay: TimeInterval = 0.01) {
        add(message, direction: "fromClient", after: delay)
    }

    mutating func provider(_ message: [String: Any], after delay: TimeInterval = 0.01) {
        add(message, direction: "toClient", after: delay)
    }

    mutating func write<D: DataProtocol>(_ value: D, after delay: TimeInterval = 0.01) {
        app([
            "type": "write",
            "id": "6B1E0F7A-4C55-4D0B-9C1A-2E3F40516273",
            "characteristicId": "6B1E0F7A-4C55-4D0B-9C1A-2E3F40516273:CE060020-43E5-11E4-916C-0800200C9A66:0:CE060021-43E5-11E4-916C-0800200C9A66:0",
            "value": Data(value).base64EncodedString(),
            "writeType": 0,
        ], after: delay)
    }

    private mutating func add(_ message: [String: Any], direction: String, after delay: TimeInterval) {
        time += delay
        entries.append([
            "seq": entries.count + 1,
            "timestamp": formatter.string(from: time),
            "direction": direction,
            "type": message["type"]!,
            "message": message,
        ])
    }

    func json() throws -> Data {
        try JSONSerialization.data(withJSONObject: entries)
    }
}

/// Connects to the first peripheral it finds, discovers everything, subscribes
/// in `subscribeOrder`, then writes `writes` to CE060021 one at a time, each
/// after the previous one was confirmed.
private final class PM5Client: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var scans = true
    var subscribeOrder: [String] = []
    var writes: [Data] = []
    private(set) var discovered: CBPeripheral?
    private(set) var values: [String: [Data]] = [:]
    private(set) var writeConfirmations = 0

    private let queue = DispatchQueue(label: "impossible.tests.replay.client")
    private var central: CBCentralManager!
    private var characteristics: [String: CBCharacteristic] = [:]
    private var pendingServices = 0
    private var pendingSubscriptions = 0
    private var expected: (count: Int, done: () -> Void)?

    /// Clients are never released: a shim peripheral's dealloc currently
    /// trips CoreBluetooth's own KVO teardown (`CBSPeripheral` skips
    /// `CBPeripheral`'s initializer), which is not what these tests are about.
    private static var retained: [PM5Client] = []

    func begin() {
        Self.retained.append(self)
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func scan() {
        queue.async { self.central.scanForPeripherals(withServices: nil) }
    }

    func whenReceived(count: Int, _ done: @escaping () -> Void) {
        queue.async {
            self.expected = (count, done)
            self.checkExpected()
        }
    }

    private func checkExpected() {
        guard let expected, values.values.reduce(0, { $0 + $1.count }) >= expected.count else { return }
        self.expected = nil
        expected.done()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, scans {
            central.scanForPeripherals(withServices: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard discovered == nil else { return }
        discovered = peripheral
        central.stopScan()
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        pendingServices = services.count
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            characteristics[Self.shimID(characteristic)] = characteristic
        }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        let order = subscribeOrder.compactMap { characteristics[$0] }
        pendingSubscriptions = order.count
        order.forEach { peripheral.setNotifyValue(true, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        pendingSubscriptions -= 1
        if pendingSubscriptions == 0 {
            writeNext(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeConfirmations += 1
        writeNext(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        values[Self.shimID(characteristic), default: []].append(value)
        checkExpected()
    }

    private func writeNext(_ peripheral: CBPeripheral) {
        guard !writes.isEmpty, let command = characteristics.first(where: { $0.key.contains("CE060021") })?.value else { return }
        peripheral.writeValue(writes.removeFirst(), for: command, type: .withResponse)
    }

    /// The wire id the shim assigned, which is what recordings address.
    private static func shimID(_ characteristic: CBCharacteristic) -> String {
        (characteristic.value(forKey: "shimId") as? String) ?? characteristic.uuid.uuidString
    }
}
#endif
