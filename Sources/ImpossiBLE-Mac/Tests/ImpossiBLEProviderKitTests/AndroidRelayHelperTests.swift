import XCTest

/// Runs the real `impossible-relay` binary against a fake provider socket.
final class AndroidRelayHelperTests: XCTestCase {
    private let relayToken = "TEST_ONLY_relay_token"
    private var relay: Process?
    private var port: UInt16 = 0
    private var providerPath = ""
    private var provider: FakeProvider?

    override func setUpWithError() throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("impossible-relay")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "impossible-relay not built")
        port = UInt16.random(in: 20000..<40000)
        providerPath = "/tmp/irt-\(UUID().uuidString.prefix(8)).sock"
        provider = try FakeProvider(path: providerPath)
        let process = Process()
        process.executableURL = helper
        process.environment = [
            "IMPOSSIBLE_RELAY_TOKEN": relayToken,
            "IMPOSSIBLE_RELAY_PORT": String(port),
            "IMPOSSIBLE_RELAY_SOCKET": providerPath,
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        relay = process
        XCTAssertEqual(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self), "listening\n")
    }

    override func tearDown() {
        relay?.terminate()
        relay?.waitUntilExit()
        provider?.close()
        unlink(providerPath)
    }

    func testBadTokenIsClosedWithoutReachingTheProvider() throws {
        let fd = try connectToRelay()
        defer { close(fd) }
        send(#"{"type":"hello","token":"wrong"}"# + "\n", to: fd)
        XCTAssertTrue(waitForClose(fd, within: 2))
        XCTAssertFalse(provider!.acceptedConnection)
    }

    func testMissingTokenIsClosed() throws {
        let fd = try connectToRelay()
        defer { close(fd) }
        send(#"{"type":"hello","pid":0}"# + "\n", to: fd)
        XCTAssertTrue(waitForClose(fd, within: 2))
    }

    func testNonHelloFirstLineIsClosed() throws {
        let fd = try connectToRelay()
        defer { close(fd) }
        send(#"{"type":"scan","token":"\#(relayToken)"}"# + "\n", to: fd)
        XCTAssertTrue(waitForClose(fd, within: 2))
        XCTAssertFalse(provider!.acceptedConnection)
    }

    func testNoHelloWithinTheDeadlineIsClosed() throws {
        let fd = try connectToRelay()
        defer { close(fd) }
        XCTAssertFalse(waitForClose(fd, within: 1.5))
        XCTAssertTrue(waitForClose(fd, within: 3))
    }

    func testOversizeFirstLineIsClosedBeforeTheDeadline() throws {
        let fd = try connectToRelay()
        defer { close(fd) }
        send(String(repeating: "a", count: 6000), to: fd)
        XCTAssertTrue(waitForClose(fd, within: 1))
    }

    func testNewlineTerminatedHelloOverTheLimitIsClosed() throws {
        let fd = try connectToRelay()
        defer { close(fd) }
        let hello = #"{"type":"hello","token":"\#(relayToken)","pad":""# + String(repeating: "a", count: 4800) + #""}"#
        XCTAssertGreaterThan(hello.utf8.count, 4096)
        send(String(hello.prefix(4096)), to: fd)
        Thread.sleep(forTimeInterval: 0.3)
        send(String(hello.dropFirst(4096)) + "\n", to: fd)
        XCTAssertTrue(waitForClose(fd, within: 2))
        XCTAssertFalse(provider!.acceptedConnection)
    }

    func testValidHelloIsForwardedWithoutTokenAndWithPidZero() throws {
        let fd = try connectToRelay()
        defer { close(fd) }
        send(
            #"{"type":"hello","clientVersion":"1","bundleId":"a.b","pid":4242,"platform":"android","token":"\#(relayToken)"}"#
                + "\n",
            to: fd
        )
        let hello = try XCTUnwrap(provider!.readLine(within: 3))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hello.utf8)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "hello")
        XCTAssertNil(json["token"])
        XCTAssertEqual(json["pid"] as? Int, 0)
        XCTAssertEqual(json["platform"] as? String, "android")
        XCTAssertEqual(json["bundleId"] as? String, "a.b")
    }

    func testBytesPipeBothWaysAfterTheHello() throws {
        let fd = try connectToRelay()
        defer { close(fd) }
        send(#"{"type":"hello","token":"\#(relayToken)"}"# + "\n" + #"{"type":"scan"}"# + "\n", to: fd)
        XCTAssertNotNil(provider!.readLine(within: 3))
        XCTAssertEqual(provider!.readLine(within: 3), #"{"type":"scan"}"#)
        provider!.send(#"{"type":"didUpdateState"}"# + "\n")
        XCTAssertEqual(readLine(from: fd, within: 3), #"{"type":"didUpdateState"}"#)
    }

    func testProviderClosingEndsTheClientConnection() throws {
        let fd = try connectToRelay()
        defer { close(fd) }
        send(#"{"type":"hello","token":"\#(relayToken)"}"# + "\n", to: fd)
        XCTAssertNotNil(provider!.readLine(within: 3))
        provider!.closeClient()
        XCTAssertTrue(waitForClose(fd, within: 2))
    }

    func testOversizeLaterLineEndsTheConnection() throws {
        let fd = try connectToRelay()
        defer { close(fd) }
        send(#"{"type":"hello","token":"\#(relayToken)"}"# + "\n", to: fd)
        XCTAssertNotNil(provider!.readLine(within: 3))
        send(String(repeating: "a", count: 4 * 1024 * 1024 + 1024), to: fd)
        XCTAssertTrue(waitForClose(fd, within: 3))
    }

    func testConnectionsBeyondTheUnauthenticatedCapAreClosedImmediately() throws {
        let held = try (0..<8).map { _ in try connectToRelay() }
        defer { held.forEach { close($0) } }
        Thread.sleep(forTimeInterval: 0.3)
        let extra = try connectToRelay()
        defer { close(extra) }
        XCTAssertTrue(waitForClose(extra, within: 1), "The ninth idle connection is refused, not queued")
        XCTAssertFalse(waitForClose(held[0], within: 0.3), "Connections within the cap are still waiting for a hello")
    }

    func testSlotsAreReleasedWhenIdleConnectionsTimeOut() throws {
        let held = try (0..<8).map { _ in try connectToRelay() }
        defer { held.forEach { close($0) } }
        XCTAssertTrue(waitForClose(held[0], within: 5), "Idle connection hits the auth deadline")
        let fd = try connectToRelay()
        defer { close(fd) }
        send(#"{"type":"hello","token":"\#(relayToken)"}"# + "\n", to: fd)
        XCTAssertNotNil(provider!.readLine(within: 3))
    }

    func testAuthenticatedConnectionsDoNotCountAgainstTheCap() throws {
        var live: [Int32] = []
        defer { live.forEach { close($0) } }
        for _ in 0..<10 {
            let fd = try connectToRelay()
            live.append(fd)
            send(#"{"type":"hello","token":"\#(relayToken)"}"# + "\n", to: fd)
            provider!.closeClient()
            Thread.sleep(forTimeInterval: 0.05)
        }
        let late = try connectToRelay()
        defer { close(late) }
        XCTAssertFalse(waitForClose(late, within: 0.5))
    }

    private func connectToRelay() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(result, 0, "connect failed: \(errno)")
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func send(_ text: String, to fd: Int32) {
        Array(text.utf8).withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                if count <= 0 { return }
                sent += count
            }
        }
    }

    /// True once the peer has closed (end of stream or reset); incoming data is discarded.
    private func waitForClose(_ fd: Int32, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var chunk = [UInt8](repeating: 0, count: 1024)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) != 0 else { continue }
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return true }
        }
        return false
    }

    private func readLine(from fd: Int32, within seconds: TimeInterval) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) != 0 else { continue }
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return String(decoding: buffer.prefix(upTo: newline), as: UTF8.self)
            }
        }
        return nil
    }
}

/// A Unix listener standing in for the provider's socket.
private final class FakeProvider {
    private let server: Int32
    private var client: Int32 = -1
    private var buffer = Data()

    init(path: String) throws {
        unlink(path)
        server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0 && listen(server, 1) == 0, "fake provider could not listen")
        _ = fcntl(server, F_SETFL, fcntl(server, F_GETFL) | O_NONBLOCK)
    }

    /// Whether the relay has connected so far.
    var acceptedConnection: Bool {
        Thread.sleep(forTimeInterval: 0.2)
        return acceptIfPending()
    }

    private func acceptIfPending() -> Bool {
        if client >= 0 { return true }
        let fd = accept(server, nil, nil)
        guard fd >= 0 else { return false }
        client = fd
        return true
    }

    func readLine(within seconds: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        var chunk = [UInt8](repeating: 0, count: 1024)
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer.prefix(upTo: newline), as: UTF8.self)
                buffer.removeSubrange(...newline)
                return line
            }
            guard acceptIfPending() else {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
        return nil
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = write(client, bytes, bytes.count)
    }

    func closeClient() {
        Darwin.close(client)
        client = -1
    }

    func close() {
        if client >= 0 { Darwin.close(client) }
        Darwin.close(server)
    }
}
