import XCTest
@testable import ImpossiBLEProviderKit

final class ControlDTOTests: XCTestCase {
    func testHexAcceptsPrefixAndSeparators() throws {
        XCTAssertEqual(try ControlDTO.optionalHex("0x0A1b", field: "v"), Data([0x0A, 0x1B]))
        XCTAssertEqual(try ControlDTO.optionalHex("0a 1b:2c-3D", field: "v"), Data([0x0A, 0x1B, 0x2C, 0x3D]))
        XCTAssertEqual(try ControlDTO.optionalHex("", field: "v"), Data())
        XCTAssertNil(try ControlDTO.optionalHex(nil, field: "v"))
        XCTAssertNil(try ControlDTO.optionalHex(NSNull(), field: "v"))
    }

    func testHexRejectsOddAndNonHexDigits() {
        XCTAssertThrowsError(try ControlDTO.optionalHex("ABC", field: "v"))
        XCTAssertThrowsError(try ControlDTO.optionalHex("ZZ", field: "v"))
        XCTAssertThrowsError(try ControlDTO.optionalHex(12, field: "v"))
    }

    func testDeviceSurvivesEncodeDecodeRoundTrip() throws {
        let original = StockConfigurations.heartRateMonitor.devices[0]
        let decoded = try ControlDTO.applyDevice(ControlDTO.device(original), to: MockDevice())

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.rssi, original.rssi)
        XCTAssertEqual(decoded.advertisedServiceUUIDs, original.advertisedServiceUUIDs)
        XCTAssertEqual(decoded.services.count, original.services.count)
        for (lhs, rhs) in zip(decoded.services, original.services) {
            XCTAssertEqual(lhs.uuid, rhs.uuid)
            XCTAssertEqual(lhs.characteristics.map(\.uuid), rhs.characteristics.map(\.uuid))
            XCTAssertEqual(lhs.characteristics.map(\.properties), rhs.characteristics.map(\.properties))
            XCTAssertEqual(lhs.characteristics.map(\.value), rhs.characteristics.map(\.value))
            XCTAssertEqual(lhs.characteristics.map { $0.descriptors.map(\.value) },
                           rhs.characteristics.map { $0.descriptors.map(\.value) })
        }
    }

    func testPropertiesAcceptNamesOrBitmask() throws {
        let byName = try ControlDTO.applyDevice(device(characteristic: ["uuid": "2a19", "properties": ["Read", "notify"]]), to: MockDevice())
        let byMask = try ControlDTO.applyDevice(device(characteristic: ["uuid": "2A19", "properties": 0x12]), to: MockDevice())

        XCTAssertEqual(byName.services[0].characteristics[0].properties, 0x12)
        XCTAssertEqual(byMask.services[0].characteristics[0].properties, 0x12)
        XCTAssertEqual(byName.services[0].characteristics[0].uuid, "2A19", "UUIDs are normalized to uppercase")
    }

    func testUnknownPropertyNamesTheValidOnes() {
        XCTAssertThrowsError(try ControlDTO.applyDevice(device(characteristic: ["uuid": "2A19", "properties": ["reed"]]), to: MockDevice())) { error in
            let message = (error as? ToolError)?.message ?? ""
            XCTAssertTrue(message.contains("services[0].characteristics[0].properties"), message)
            XCTAssertTrue(message.contains("writeWithoutResponse"), message)
        }
    }

    func testValueTextIsUTF8AndMustAgreeWithValue() throws {
        let decoded = try ControlDTO.applyDevice(device(characteristic: ["uuid": "2A29", "valueText": "Acme"]), to: MockDevice())
        XCTAssertEqual(decoded.services[0].characteristics[0].value, Data("Acme".utf8))

        let agreeing = try ControlDTO.applyDevice(
            device(characteristic: ["uuid": "2A29", "value": "41", "valueText": "A"]), to: MockDevice())
        XCTAssertEqual(agreeing.services[0].characteristics[0].value, Data("A".utf8), "get_device output can be sent back")
        XCTAssertThrowsError(try ControlDTO.applyDevice(
            device(characteristic: ["uuid": "2A29", "value": "41", "valueText": "B"]), to: MockDevice()))
    }

    func testPrintableTextIgnoresTrailingNULPadding() {
        let padded = ControlDTO.characteristic(MockCharacteristic(value: Data("Concept2".utf8) + Data(repeating: 0, count: 8)))
        XCTAssertEqual(padded["valueText"] as? String, "Concept2")

        let binary = ControlDTO.characteristic(MockCharacteristic(value: Data([0x00])))
        XCTAssertNil(binary["valueText"])

        let embeddedNUL = ControlDTO.characteristic(MockCharacteristic(value: Data([0x41, 0x00, 0x42])))
        XCTAssertNil(embeddedNUL["valueText"], "A NUL followed by data is binary, not padding")
    }

    func testPatchOnlyChangesGivenFields() throws {
        var base = StockConfigurations.heartRateMonitor.devices[0]
        base.isEnabled = true
        let patched = try ControlDTO.applyDevice(["rssi": -80, "isEnabled": false], to: base)

        XCTAssertEqual(patched.rssi, -80)
        XCTAssertFalse(patched.isEnabled)
        XCTAssertEqual(patched.id, base.id)
        XCTAssertEqual(patched.name, base.name)
        XCTAssertEqual(patched.services, base.services)
    }

    func testPairingValidation() throws {
        let passkey = try ControlDTO.applyDevice(["pairingMode": "passkey", "passkey": "123456"], to: MockDevice())
        XCTAssertEqual(passkey.pairingMode, .passkey)
        XCTAssertEqual(passkey.passkey, "123456")

        XCTAssertThrowsError(try ControlDTO.applyDevice(["passkey": "12a456"], to: MockDevice()))
        XCTAssertThrowsError(try ControlDTO.applyDevice(["pairingMode": "secure"], to: MockDevice()))
    }

    func testTypeMismatchesAreReported() {
        XCTAssertThrowsError(try ControlDTO.applyDevice(["rssi": "-50"], to: MockDevice()))
        XCTAssertThrowsError(try ControlDTO.applyDevice(["isEnabled": 1], to: MockDevice()), "Numbers are not booleans")
        XCTAssertThrowsError(try ControlDTO.applyDevice(["rssi": true], to: MockDevice()), "Booleans are not numbers")
        XCTAssertThrowsError(try ControlDTO.applyDevice(["services": [["characteristics": []]]], to: MockDevice()), "uuid is required")
    }

    private func device(characteristic: [String: Any]) -> [String: Any] {
        ["services": [["uuid": "180F", "characteristics": [characteristic]]]]
    }
}
