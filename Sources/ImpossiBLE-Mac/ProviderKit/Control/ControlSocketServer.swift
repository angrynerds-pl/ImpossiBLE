import Foundation

/// The Unix socket agents reach the provider on, through the `impossible-mcp`
/// shim. Deliberately separate from `/tmp/impossible.sock`: that one serves a
/// single simulator app with last-connection-wins takeover, while any number
/// of agents may be connected here at once, and none of them may ever evict
/// the simulator.
///
/// Access is limited to the user running the app: the socket file is 0600 and
/// every peer's uid is checked. Like `ProtocolServer`, it never steals the path
/// from a live listener — only a stale file is unlinked.
///
/// All state is guarded by `queue`.
final class ControlSocketServer {
    enum Status: Equatable {
        case stopped
        case listening
        case blocked(String)
        case failed(String)
    }

    private struct Client {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        var session: MCPSession?
    }

    /// Called on the main thread.
    var onStatusChange: ((Status) -> Void)?
    /// Called on the main thread with the number of connected agents.
    var onClientCountChange: ((Int) -> Void)?

    private let path: String
    private let makeSession: (_ send: @escaping ([String: Any]) -> Void) -> MCPSession
    private let queue = DispatchQueue(label: "impossible.control.io")
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [UInt64: Client] = [:]
    private var nextClientID: UInt64 = 0

    /// A misbehaving peer must not grow a line buffer without bound.
    private static let maxLineLength = 8 * 1024 * 1024

    init(path: String, makeSession: @escaping (_ send: @escaping ([String: Any]) -> Void) -> MCPSession) {
        self.path = path
        self.makeSession = makeSession
    }

    func start() {
        queue.async { [self] in
            guard listenFd < 0 else { return }

            if access(path, F_OK) == 0, Self.probeListener(at: path) {
                NSLog("ImpossiBLE-Control: another provider is already serving %@ — refusing to start", path)
                publish(.blocked("Another provider is already serving \(path)"))
                return
            }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                publish(.failed("socket() failed: errno \(errno)"))
                return
            }
            unlink(path)
            guard Self.withAddress(path, { Darwin.bind(fd, $0, $1) }) == 0 else {
                let error = errno
                close(fd)
                publish(.failed("bind() failed: errno \(error)"))
                return
            }
            chmod(path, 0o600)
            guard listen(fd, 8) == 0 else {
                let error = errno
                close(fd)
                unlink(path)
                publish(.failed("listen() failed: errno \(error)"))
                return
            }

            listenFd = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptClient()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            acceptSource = source
            publish(.listening)
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            for id in Array(clients.keys) {
                dropClient(id)
            }
            if listenFd >= 0 {
                acceptSource?.cancel()
                acceptSource = nil
                listenFd = -1
                unlink(path)
            }
            publish(.stopped)
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    // MARK: - Clients (queue)

    private func acceptClient() {
        let fd = accept(listenFd, nil, nil)
        guard fd >= 0 else { return }

        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            NSLog("ImpossiBLE-Control: rejected a connection from another user")
            close(fd)
            return
        }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // A peer that stops reading must not wedge the queue in write().
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        nextClientID &+= 1
        let id = nextClientID
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readFromClient(id)
        }
        source.setCancelHandler {
            close(fd)
        }
        clients[id] = Client(fd: fd, source: source)
        clients[id]?.session = makeSession { [weak self] message in
            self?.queue.async {
                self?.write(message, to: id)
            }
        }
        source.resume()
        publishClientCount()
    }

    private func readFromClient(_ id: UInt64) {
        guard var client = clients[id] else { return }
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        let n = read(client.fd, &buf, buf.count)
        guard n > 0 else {
            dropClient(id)
            return
        }
        client.buffer.append(contentsOf: buf[0..<n])

        var lines: [Data] = []
        while let newline = client.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = client.buffer[client.buffer.startIndex..<newline]
            client.buffer.removeSubrange(client.buffer.startIndex...newline)
            if !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) {
                lines.append(Data(line))
            }
        }
        guard client.buffer.count <= Self.maxLineLength else {
            NSLog("ImpossiBLE-Control: dropped a client that sent an oversized line")
            dropClient(id)
            return
        }
        clients[id] = client
        lines.forEach { client.session?.receive($0) }
    }

    private func write(_ message: [String: Any], to id: UInt64) {
        guard let client = clients[id],
              let data = try? JSONSerialization.data(withJSONObject: message)
        else { return }
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        let ok = payload.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            var written = 0
            while written < payload.count {
                let n = Darwin.write(client.fd, base.advanced(by: written), payload.count - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
        if !ok {
            dropClient(id)
        }
    }

    private func dropClient(_ id: UInt64) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.source.cancel()
        publishClientCount()
    }

    private func publish(_ status: Status) {
        DispatchQueue.main.async { [onStatusChange] in
            onStatusChange?(status)
        }
    }

    private func publishClientCount() {
        let count = clients.count
        DispatchQueue.main.async { [onClientCountChange] in
            onClientCountChange?(count)
        }
    }

    // MARK: - Socket plumbing

    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(capacity - 1))
            raw.copyBytes(from: bytes)
        }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// True when a live listener answers; a stale file refuses the connection.
    private static func probeListener(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withAddress(path) { Darwin.connect(fd, $0, $1) } == 0
    }
}
