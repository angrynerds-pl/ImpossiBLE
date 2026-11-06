// impossible-relay — loopback TCP front door to /tmp/impossible.sock for the Android library.
//
// The first line of every connection must be a hello carrying the shared token.
// The relay forwards it with the token removed and pid forced to 0, then pipes
// bytes both ways. Configuration comes from the environment so the token never
// shows up in `ps`: IMPOSSIBLE_RELAY_TOKEN (required), IMPOSSIBLE_RELAY_PORT,
// IMPOSSIBLE_RELAY_SOCKET.
//
// Exit codes: 64 bad configuration, 75 port already in use, 1 unrecoverable socket error.

import Darwin
import Foundation

let authDeadline: TimeInterval = 3
let firstLineLimit = 4096
let laterLineLimit = 4 * 1024 * 1024
let exitUsage: Int32 = 64
let exitPortInUse: Int32 = 75
let exitFatal: Int32 = 1
/// Connections that have not yet presented the token; more are refused on accept.
let maxUnauthenticated = 8

let unauthenticatedLock = NSLock()
var unauthenticatedCount = 0
// Pre-auth reads block for up to authDeadline; keep them off the shared global pool.
let preAuthQueue = DispatchQueue(label: "impossible.relay.preauth", attributes: .concurrent)
let watchdogQueue = DispatchQueue(label: "impossible.relay.watchdog")

let environment = ProcessInfo.processInfo.environment
let listenPort = UInt16(environment["IMPOSSIBLE_RELAY_PORT"] ?? "") ?? 7700
let providerSocketPath = environment["IMPOSSIBLE_RELAY_SOCKET"] ?? "/tmp/impossible.sock"

func loopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
    return address
}

func harden(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

func writeAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if written < 0 && errno == EINTR { continue }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}

func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    var difference = a.count ^ b.count
    for index in 0..<max(a.count, b.count) {
        difference |= Int(index < a.count ? a[index] : 0) ^ Int(index < b.count ? b[index] : 0)
    }
    return difference == 0
}

/// Reads up to and including the first newline within `limit` bytes and
/// `deadline`. Returns the line (without newline) and whatever followed it.
func readFirstLine(from fd: Int32, limit: Int, deadline: Date) -> (line: Data, rest: Data)? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 1024)
    while true {
        if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            return (buffer.prefix(upTo: newline), buffer.suffix(from: newline + 1))
        }
        if buffer.count > limit { return nil }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return nil }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)) + 1)
        if ready < 0 && errno != EINTR { return nil }
        if ready <= 0 { continue }
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 { return nil }
        buffer.append(contentsOf: chunk[0..<count])
    }
}

func forwardedHello(_ line: Data, token: String) -> Data? {
    guard var hello = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
          hello["type"] as? String == "hello",
          let presented = hello["token"] as? String,
          constantTimeEqual(presented, token) else {
        return nil
    }
    hello.removeValue(forKey: "token")
    hello["pid"] = 0
    guard var data = try? JSONSerialization.data(withJSONObject: hello) else { return nil }
    data.append(UInt8(ascii: "\n"))
    return data
}

func connectToProvider() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    harden(fd)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(providerSocketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        close(fd)
        return nil
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) }) }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    return fd
}

/// Copies bytes until either side ends. With `lineLimit`, a line longer than
/// the limit ends the pipe instead of being passed on.
func pipe(from source: Int32, to destination: Int32, pending: Data = Data(), lineLimit: Int? = nil) {
    var currentLine = 0
    func forward(_ bytes: Data) -> Bool {
        if let lineLimit {
            for byte in bytes {
                currentLine = byte == UInt8(ascii: "\n") ? 0 : currentLine + 1
                if currentLine > lineLimit { return false }
            }
        }
        return writeAll(bytes, to: destination)
    }
    if !pending.isEmpty && !forward(pending) { return }
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let count = read(source, &chunk, chunk.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 || !forward(Data(chunk[0..<count])) { return }
    }
}

func leaveUnauthenticated() {
    unauthenticatedLock.lock()
    unauthenticatedCount -= 1
    unauthenticatedLock.unlock()
}

/// Reserves a pre-auth slot; false when `maxUnauthenticated` are already open.
func enterUnauthenticated() -> Bool {
    unauthenticatedLock.lock()
    defer { unauthenticatedLock.unlock() }
    guard unauthenticatedCount < maxUnauthenticated else { return false }
    unauthenticatedCount += 1
    return true
}

/// Authenticates the client and opens the provider side. Runs on `preAuthQueue`.
func authenticate(client: Int32, token: String) -> (provider: Int32, rest: Data)? {
    defer { leaveUnauthenticated() }
    harden(client)
    let deadline = Date().addingTimeInterval(authDeadline)
    guard let first = readFirstLine(from: client, limit: firstLineLimit, deadline: deadline),
          let hello = forwardedHello(first.line, token: token),
          let provider = connectToProvider() else {
        close(client)
        return nil
    }
    guard writeAll(hello, to: provider) else {
        close(client)
        close(provider)
        return nil
    }
    return (provider, first.rest)
}

func pipeSession(client: Int32, provider: Int32, rest: Data) {
    let finished = DispatchGroup()
    finished.enter()
    DispatchQueue.global().async {
        pipe(from: provider, to: client)
        shutdown(client, SHUT_RDWR)
        shutdown(provider, SHUT_RDWR)
        finished.leave()
    }
    pipe(from: client, to: provider, pending: rest, lineLimit: laterLineLimit)
    shutdown(client, SHUT_RDWR)
    shutdown(provider, SHUT_RDWR)
    finished.wait()
    close(client)
    close(provider)
}

func serve(client: Int32, token: String) {
    guard let session = authenticate(client: client, token: token) else { return }
    DispatchQueue.global().async { pipeSession(client: client, provider: session.provider, rest: session.rest) }
}

func listenOnLoopback() -> Int32 {
    var address = loopbackAddress(port: listenPort)
    func isAnswering() -> Bool {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        if probe < 0 { exit(exitFatal) }
        defer { close(probe) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }
    if isAnswering() { exit(exitPortInUse) }

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { exit(exitFatal) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(fd, 8) == 0 else { exit(exitPortInUse) }
    return fd
}

guard let token = environment["IMPOSSIBLE_RELAY_TOKEN"], !token.isEmpty else { exit(exitUsage) }
signal(SIGPIPE, SIG_IGN)

let server = listenOnLoopback()

// A relay outliving its app would hold the port and show as Blocked next launch.
let parent = getppid()
let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
watchdog.schedule(deadline: .now() + 1, repeating: 1)
watchdog.setEventHandler { if getppid() != parent { exit(0) } }
watchdog.resume()

print("listening")
fflush(stdout)

while true {
    let client = accept(server, nil, nil)
    if client < 0 {
        switch errno {
            case EINTR:
                continue
            case ECONNABORTED, EMFILE, ENFILE, ENOBUFS, ENOMEM:
                usleep(100_000)
            default:
                exit(exitFatal)
        }
        continue
    }
    guard enterUnauthenticated() else {
        close(client)
        continue
    }
    preAuthQueue.async { serve(client: client, token: token) }
}
