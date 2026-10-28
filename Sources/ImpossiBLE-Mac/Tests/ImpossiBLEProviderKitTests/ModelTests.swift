import XCTest
@testable import ImpossiBLEProviderKit

final class MockSimulationTests: XCTestCase {
    func testCharacteristicAddressMatchesDiscoveryWireID() throws {
        let device = StockConfigurations.heartRateMonitor.devices[0]
        let address = try device.characteristicAddress(service: nil, characteristic: "2a19")

        // Discovery builds peripheral:serviceUUID:serviceIndex:charUUID:charIndex.
        XCTAssertEqual(address.wireID, "\(device.id.uuidString):180F:1:2A19:0")
        XCTAssertEqual(address.serviceUUID, "180F")
    }

    func testAmbiguousCharacteristicNeedsService() throws {
        var device = MockDevice()
        device.services = [
            MockService(uuid: "180A", characteristics: [MockCharacteristic(uuid: "2A29")]),
            MockService(uuid: "181A", characteristics: [MockCharacteristic(uuid: "2A29")]),
        ]
        XCTAssertThrowsError(try device.characteristicAddress(service: nil, characteristic: "2A29"))
        XCTAssertEqual(try device.characteristicAddress(service: "181a", characteristic: "2A29").wireID,
                       "\(device.id.uuidString):181A:1:2A29:0")
        XCTAssertThrowsError(try device.characteristicAddress(service: nil, characteristic: "FFFF"))
    }

    func testActivityLogIsBoundedAndKeepsSequenceNumbers() {
        var log = MockActivityLog()
        for _ in 0..<(MockActivityLog.capacity + 5) {
            log.append("read")
        }
        XCTAssertEqual(log.events.count, MockActivityLog.capacity)
        XCTAssertEqual(log.events.first?.sequence, 6)
        XCTAssertEqual(log.lastSequence, MockActivityLog.capacity + 5)
        XCTAssertEqual(log.events(after: log.lastSequence - 2, limit: 10).map(\.sequence),
                       [log.lastSequence - 1, log.lastSequence])

        log.clear()
        log.append("write")
        XCTAssertEqual(log.events.map(\.sequence), [MockActivityLog.capacity + 6], "Clearing never reuses sequence numbers")
    }

    func testFailureRuleMatching() {
        let any = MockFailureRule(id: 1, operation: .read, deviceID: "D", characteristicUUID: nil,
                                  behavior: .noResponse, remaining: 1)
        let narrow = MockFailureRule(id: 2, operation: .read, deviceID: "D", characteristicUUID: "2A19",
                                     behavior: .noResponse, remaining: 1)

        XCTAssertTrue(any.matches(.read, deviceID: "D", characteristicUUID: "2A00"))
        XCTAssertFalse(any.matches(.write, deviceID: "D", characteristicUUID: "2A00"))
        XCTAssertFalse(any.matches(.read, deviceID: "E", characteristicUUID: "2A00"))
        XCTAssertTrue(narrow.matches(.read, deviceID: "D", characteristicUUID: "2a19"))
        XCTAssertFalse(narrow.matches(.read, deviceID: "D", characteristicUUID: "2A00"))
    }
}

final class CaptureFilterTests: XCTestCase {
    private func captured(_ name: String, connectable: Bool = true, services: [String] = []) -> CapturedDevice {
        CapturedDevice(id: UUID().uuidString, name: name, rssi: -60, isConnectable: connectable,
                       advertisedServiceUUIDs: services, manufacturerData: nil,
                       firstSeen: Date(), lastSeen: Date(), seenCount: 1)
    }

    func testDefaultsHideUnnamedDevices() {
        let filter = CaptureFilter()
        XCTAssertTrue(filter.matches(captured("PM5")))
        XCTAssertFalse(filter.matches(captured("  ")))
        XCTAssertTrue(CaptureFilter(showUnnamed: true).matches(captured("")))
    }

    func testFiltersCombine() {
        let filter = CaptureFilter(onlyConnectable: true, nameContains: "pm", advertisingService: "1826")
        XCTAssertTrue(filter.matches(captured("PM5 431", services: ["1826"])))
        XCTAssertFalse(filter.matches(captured("PM5 431", connectable: false, services: ["1826"])))
        XCTAssertFalse(filter.matches(captured("Polar", services: ["1826"])))
        XCTAssertFalse(filter.matches(captured("PM5 431", services: ["180D"])))
        XCTAssertEqual(filter.requestedServiceUUIDs, ["1826"])
    }

    func testUnknownRSSIIsKeptOutOfTheMockDevice() {
        var device = captured("PM5")
        device.rssi = nil
        XCTAssertEqual(device.makeMockDevice().rssi, MockDevice().rssi)
    }
}

final class MockStoreTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        suiteName = "ImpossiBLEProviderKitTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRenameFollowsTheActiveConfiguration() {
        let store = MockStore(directory: directory, defaults: defaults)
        store.saveConfiguration(name: "A", devices: [MockDevice()], loadImmediately: true)
        let id = store.configurations[0].id

        XCTAssertTrue(store.renameConfiguration(id: id, to: "B"))
        XCTAssertEqual(store.activeConfigurationName, "B")
        XCTAssertEqual(MockStore(directory: directory, defaults: defaults).configurations.map(\.name), ["B"],
                       "Renames are persisted")
    }

    func testDuplicateGetsFreshIdentifiersThroughout() {
        let store = MockStore(directory: directory, defaults: defaults)
        let source = StockConfigurations.heartRateMonitor
        let copy = store.duplicateConfiguration(source, name: "Copy")

        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertNotEqual(copy.devices[0].id, source.devices[0].id)
        XCTAssertNotEqual(copy.devices[0].services[0].id, source.devices[0].services[0].id)
        XCTAssertNotEqual(copy.devices[0].services[0].characteristics[0].descriptors[0].id,
                          source.devices[0].services[0].characteristics[0].descriptors[0].id)
        XCTAssertEqual(copy.devices[0].services.map(\.uuid), source.devices[0].services.map(\.uuid))
    }

    func testWorkingSetEdits() {
        let store = MockStore(directory: directory, defaults: defaults)
        var device = MockDevice()
        store.addDevice(device)
        XCTAssertTrue(store.setDeviceEnabled(id: device.id, false))
        XCTAssertTrue(store.enabledDevices.isEmpty)

        device.name = "Renamed"
        device.isEnabled = true
        XCTAssertTrue(store.updateDevice(device))
        XCTAssertEqual(MockStore(directory: directory, defaults: defaults).devices.map(\.name), ["Renamed"])
        XCTAssertFalse(store.updateDevice(MockDevice()), "Unknown ids are not added")
    }
}
