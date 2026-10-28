// impossible-mcp — the MCP server agents launch (stdio transport).
//
// All MCP logic lives in ImpossiBLE-Mac; this only pipes newline-delimited
// JSON-RPC between stdio and the app's control socket. It launches the app
// when it is not running, reconnects when it relaunches, and answers requests
// that cannot be delivered (or were in flight when the app went away) with a
// JSON-RPC error, so the agent never waits on a reply that will not come.

import Foundation
import Darwin

let socketPath = "/tmp/impossible-control.sock"
let bundleID = "com.impossible.ble-mac"
let launchTimeout: TimeInterval = 15
let unreachableMessage = """
    ImpossiBLE-Mac is not reachable at \(socketPath). Make sure the app is installed and running, and that \
    agent control (the terminal icon in the panel footer) is on.
    """

final class Bridge {
    private let lock = NSLock()
    private let outputLock = NSLock()
    private var fd: Int32 = -1
    private var generation = 0
    /// Requests forwarded and not yet answered, keyed by their encoded id.
    private var pending: [String: Any] = [:]

    func forward(_ line: String) {
        let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        let requestID = message.flatMap { $0["method"] != nil ? $0["id"] : nil }

        var payload = Data(line.utf8)
        payload.append(UInt8(ascii: "\n"))

        // A second attempt covers a connection that died since the last line.
        for _ in 0..<2 {
            guard let (socket, gen) = connection() else { break }
            if let requestID {
                lock.withLock { pending[key(requestID)] = requestID }
            }
            if writeAll(payload, to: socket) {
                return
            }
            disconnect(generation: gen)
        }
        if let requestID {
            lock.withLock { _ = pending.removeValue(forKey: key(requestID)) }
            emitError(id: requestID, message: unreachableMessage)
        }
    }

    // MARK: - Connection

    private func connection() -> (Int32, Int)? {
        if let current = lock.withLock({ fd >= 0 ? (fd, generation) : nil }) {
            return current
        }
        guard let socket = connectOrLaunch() else { return nil }
        let gen = lock.withLock { () -> Int in
            fd = socket
            generation += 1
            return generation
        }
        Thread.detachNewThread { [self] in
            readLoop(socket: socket, generation: gen)
        }
        return (socket, gen)
    }

    private func connectOrLaunch() -> Int32? {
        if let socket = connectSocket() {
            return socket
        }
        launchApp()
        let deadline = Date().addingTimeInterval(launchTimeout)
        while Date() < deadline {
            usleep(200_000)
            if let socket = connectSocket() {
                return socket
            }
        }
        return nil
    }

    private func connectSocket() -> Int32? {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(socketPath.utf8.prefix(capacity - 1)))
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(socket)
            return nil
        }
        return socket
    }

    /// Prefers the app this binary is bundled in, so a development build's
    /// shim starts that build rather than an installed one.
    private func launchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let app = enclosingApp() {
            process.arguments = ["-g", app.path]
        } else {
            process.arguments = ["-g", "-b", bundleID]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private func enclosingApp() -> URL? {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        var url = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                return url
            }
        }
        return nil
    }

    private func disconnect(generation gen: Int) {
        let orphaned = lock.withLock { () -> [Any]? in
            guard gen == generation, fd >= 0 else { return nil }
            close(fd)
            fd = -1
            let ids = Array(pending.values)
            pending.removeAll()
            return ids
        }
        orphaned?.forEach { emitError(id: $0, message: "ImpossiBLE-Mac closed the connection before replying; retry the call.") }
    }

    // MARK: - App → agent

    private func readLoop(socket: Int32, generation gen: Int) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(socket, &chunk, chunk.count)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex...newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                   message["method"] == nil, let id = message["id"] {
                    lock.withLock { _ = pending.removeValue(forKey: key(id)) }
                }
                emit(line)
            }
        }
        disconnect(generation: gen)
    }

    private func emitError(id: Any, message: String) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": -32000, "message": message],
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
        data.append(UInt8(ascii: "\n"))
        emit(data)
    }

    private func emit(_ data: Data) {
        outputLock.withLock {
            // The agent went away; nothing left to serve.
            if !writeAll(data, to: STDOUT_FILENO) {
                exit(0)
            }
        }
    }

    private func key(_ id: Any) -> String {
        if let string = id as? String {
            return "s:" + string
        }
        return "n:\(id)"
    }
}

private func writeAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { ptr in
        guard let base = ptr.baseAddress else { return false }
        var written = 0
        while written < data.count {
            let n = write(fd, base.advanced(by: written), data.count - written)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            written += n
        }
        return true
    }
}

signal(SIGPIPE, SIG_IGN)
let bridge = Bridge()
while let line = readLine(strippingNewline: true) {
    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    bridge.forward(line)
}
exit(0)
