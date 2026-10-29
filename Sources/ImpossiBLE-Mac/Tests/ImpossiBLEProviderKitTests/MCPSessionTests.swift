import XCTest
import SimBridgeShell
@testable import ImpossiBLEProviderKit

/// Tools wired to a throwaway store and a server that is never started, so
/// nothing touches the user's configurations or the real sockets.
final class ToolsFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let suiteName = "ImpossiBLEProviderKitTests.\(UUID().uuidString)"
    let store: MockStore
    let server = MockServer(autoStart: false)
    let modeController = ModeTransitionController<ProviderMode>(initial: .off) { _, completion in completion() }
    let tools: ProviderTools

    init() {
        store = MockStore(directory: directory, defaults: UserDefaults(suiteName: suiteName)!)
        server.store = store
        tools = ProviderTools(store: store, server: server, modeController: modeController)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }
}

final class MCPSessionTests: XCTestCase {
    private var fixture: ToolsFixture!
    private var session: MCPSession!
    private var sent: [[String: Any]] = []
    private var onSend: (() -> Void)?

    override func setUp() {
        fixture = ToolsFixture()
        sent = []
        session = MCPSession(tools: fixture.tools) { [unowned self] message in
            sent.append(message)
            onSend?()
        }
    }

    private func send(_ message: [String: Any]) {
        session.receive(try! JSONSerialization.data(withJSONObject: message))
    }

    /// Sends a tools/call and waits for its reply (calls complete on main).
    @discardableResult
    private func call(_ name: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        let replied = expectation(description: name)
        let before = sent.count
        onSend = { if self.sent.count > before { replied.fulfill() } }
        send(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        wait(for: [replied], timeout: 5)
        onSend = nil
        return sent.last?["result"] as? [String: Any] ?? [:]
    }

    func testInitializeNegotiatesTheProtocolVersion() throws {
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        send(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])

        let versions = sent.compactMap { ($0["result"] as? [String: Any])?["protocolVersion"] as? String }
        XCTAssertEqual(versions, ["2025-06-18", MCPSession.supportedProtocolVersions[0]])
        let capabilities = (sent[0]["result"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertNotNil(capabilities?["tools"])
    }

    func testNotificationsAndResponsesGetNoReply() {
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        send(["jsonrpc": "2.0", "id": 3, "result": [:]])
        XCTAssertTrue(sent.isEmpty)
    }

    func testProtocolErrors() {
        session.receive(Data("not json".utf8))
        send(["jsonrpc": "2.0", "id": 4, "method": "resources/list"])

        XCTAssertEqual((sent[0]["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertEqual((sent[1]["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(sent[1]["id"] as? Int, 4)
    }

    func testToolListingIsValidAndUnique() throws {
        send(["jsonrpc": "2.0", "id": 5, "method": "tools/list"])
        let tools = try XCTUnwrap((sent[0]["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }

        XCTAssertEqual(Set(names).count, names.count)
        for expected in ["set_mode", "capture_save", "set_characteristic_value", "mock_activity", "inject_failure", "export_configuration"] {
            XCTAssertTrue(names.contains(expected), expected)
        }
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any], "\(tool["name"]!)")
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool))
            for required in schema["required"] as? [String] ?? [] {
                XCTAssertNotNil((schema["properties"] as? [String: Any])?[required], "\(tool["name"]!).\(required)")
            }
        }
    }

    func testToolErrorsAreResultsNotProtocolErrors() {
        let unknown = call("no_such_tool")
        XCTAssertEqual(unknown["isError"] as? Bool, true)

        let builtIn = call("delete_configuration", ["configuration": "Heart Rate Monitor"])
        XCTAssertEqual(builtIn["isError"] as? Bool, true)
        let text = (builtIn["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("built in"), text)
    }

    func testConfigurationLifecycle() throws {
        let created = call("create_configuration", [
            "name": "Thermo",
            "devices": [["name": "T1", "services": [["uuid": "181A", "characteristics": [["uuid": "2A6E", "value": "E803"]]]]]],
        ])
        XCTAssertNil(created["isError"])
        XCTAssertEqual(fixture.store.activeConfigurationName, "Thermo")
        XCTAssertEqual(fixture.store.devices.first?.services.first?.characteristics.first?.value, Data([0xE8, 0x03]))

        XCTAssertEqual(call("create_configuration", ["name": "Thermo", "devices": []])["isError"] as? Bool, true,
                       "Existing names need replace")

        XCTAssertNil(call("rename_configuration", ["configuration": "thermo", "newName": "Thermo 2"])["isError"])
        XCTAssertEqual(fixture.store.activeConfigurationName, "Thermo 2")

        let exported = call("export_configuration", ["configuration": "Thermo 2"])
        let json = try XCTUnwrap((exported["structuredContent"] as? [String: Any])?["json"] as? String)
        let decoded = try JSONDecoder().decode(MockConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "Thermo 2")
        XCTAssertEqual(decoded.devices.first?.services.first?.characteristics.first?.value, Data([0xE8, 0x03]),
                       "Export decodes as the setMockConfiguration wire format")

        XCTAssertNil(call("delete_configuration", ["configuration": "Thermo 2"])["isError"])
        XCTAssertTrue(fixture.store.configurations.isEmpty)
    }

    func testExportWritesFilesOnlyWhenAllowed() throws {
        let path = fixture.directory.appendingPathComponent("out/fixture.json").path
        XCTAssertNil(call("export_configuration", ["configuration": "Heart Rate Monitor", "path": path])["isError"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        XCTAssertEqual(call("export_configuration", ["configuration": "Heart Rate Monitor", "path": path])["isError"] as? Bool, true)
        XCTAssertNil(call("export_configuration", ["configuration": "Heart Rate Monitor", "path": path, "overwrite": true])["isError"])
        XCTAssertEqual(call("export_configuration", ["configuration": "Heart Rate Monitor", "path": "relative.json"])["isError"] as? Bool, true)
    }

    func testDeviceToolsResolveByNameOrID() {
        fixture.store.loadConfiguration(StockConfigurations.heartRateMonitor)
        let id = fixture.store.devices[0].id.uuidString

        XCTAssertNil(call("set_device_enabled", ["device": "polar h10", "enabled": false])["isError"])
        XCTAssertFalse(fixture.store.devices[0].isEnabled)
        XCTAssertNil(call("update_device", ["device": id, "changes": ["rssi": -90]])["isError"])
        XCTAssertEqual(fixture.store.devices[0].rssi, -90)
        XCTAssertEqual(call("get_device", ["device": "nope"])["isError"] as? Bool, true)
    }

    func testLiveToolsRefuseOutsideMockServing() {
        fixture.store.loadConfiguration(StockConfigurations.heartRateMonitor)
        let push = call("set_characteristic_value", ["device": "Polar H10", "characteristic": "2A37", "value": "0050"])
        XCTAssertEqual(push["isError"] as? Bool, true, "No app is connected to a server that never started")

        let badCharacteristic = call("inject_failure", ["device": "Polar H10", "operation": "connect", "characteristic": "2A37"])
        XCTAssertEqual(badCharacteristic["isError"] as? Bool, true, "connect is not characteristic-level")
    }

    func testFailureRulesCanBeArmedListedAndCleared() throws {
        fixture.store.loadConfiguration(StockConfigurations.heartRateMonitor)
        let armed = call("inject_failure", ["device": "Polar H10", "operation": "read", "characteristic": "2a38",
                                            "attError": 2, "count": 0])
        let rule = try XCTUnwrap(armed["structuredContent"] as? [String: Any])
        XCTAssertEqual(rule["remaining"] as? String, "untilCleared")
        XCTAssertEqual(rule["attError"] as? Int, 2)

        let listed = call("list_failures")["structuredContent"] as? [String: Any]
        XCTAssertEqual((listed?["failures"] as? [Any])?.count, 1)
        XCTAssertEqual((call("clear_failures")["structuredContent"] as? [String: Any])?["cleared"] as? Int, 1)
    }

    func testMockActivityStartsEmpty() throws {
        let activity = try XCTUnwrap(call("mock_activity")["structuredContent"] as? [String: Any])
        XCTAssertEqual((activity["events"] as? [Any])?.count, 0)
        XCTAssertEqual(activity["lastSeq"] as? Int, 0)
        XCTAssertEqual(activity["mockServing"] as? Bool, false)
    }
}

final class ControlSocketServerTests: XCTestCase {
    func testServesMCPOverTheSocketAndNeverStealsIt() throws {
        let fixture = ToolsFixture()
        let path = "/tmp/ibt-\(UUID().uuidString.prefix(8)).sock"
        let listening = expectation(description: "listening")
        let server = ControlSocketServer(path: path) { MCPSession(tools: fixture.tools, send: $0) }
        server.onStatusChange = { if $0 == .listening { listening.fulfill() } }
        server.start()
        wait(for: [listening], timeout: 5)
        defer {
            let stopped = expectation(description: "stopped")
            server.stop { stopped.fulfill() }
            wait(for: [stopped], timeout: 5)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Stopping unlinks the socket")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // A second server must refuse rather than unlink a live socket.
        let blocked = expectation(description: "blocked")
        let rival = ControlSocketServer(path: path) { MCPSession(tools: fixture.tools, send: $0) }
        rival.onStatusChange = { if case .blocked = $0 { blocked.fulfill() } }
        rival.start()
        wait(for: [blocked], timeout: 5)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)

        let request = Data(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#.utf8 + [UInt8(ascii: "\n")])
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, request.count) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &buffer, buffer.count)
        XCTAssertGreaterThan(n, 0)
        let reply = try JSONSerialization.jsonObject(with: Data(buffer[0..<max(n, 0)])) as? [String: Any]
        XCTAssertEqual(reply?["id"] as? Int, 9)
        XCTAssertNotNil(reply?["result"])
    }
}
