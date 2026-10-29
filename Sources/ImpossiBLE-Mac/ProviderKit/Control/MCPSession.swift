import Foundation

/// One agent connection speaking MCP (JSON-RPC 2.0, one message per line) —
/// the same framing as MCP's stdio transport, so the `impossible-mcp` shim only
/// has to pipe bytes. Only tools are offered.
///
/// `initialize` is answered but not required: when the app relaunches, the shim
/// reconnects transparently and the agent keeps calling tools on what it
/// believes is the same session.
final class MCPSession {
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let tools: ProviderTools
    private let send: ([String: Any]) -> Void

    init(tools: ProviderTools, send: @escaping ([String: Any]) -> Void) {
        self.tools = tools
        self.send = send
    }

    /// Handles one line. Callable from any queue.
    func receive(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            sendError(id: NSNull(), code: -32700, message: "Parse error: expected one JSON-RPC object per line")
            return
        }
        guard let method = message["method"] as? String else {
            // A response to a server request; this server never sends any.
            return
        }
        guard let id = message["id"], !(id is NSNull) else {
            // Notifications (initialized, cancelled, …) need no reply.
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
            case "initialize":
                let requested = params["protocolVersion"] as? String
                let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                    ?? Self.supportedProtocolVersions[0]
                sendResult(id: id, [
                    "protocolVersion": version,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "impossible", "title": "ImpossiBLE", "version": AppVersion.current],
                    "instructions": Self.instructions,
                ])
            case "ping":
                sendResult(id: id, [:])
            case "tools/list":
                sendResult(id: id, ["tools": tools.listing])
            case "tools/call":
                callTool(id: id, params: params)
            default:
                sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func callTool(id: Any, params: [String: Any]) {
        guard let name = params["name"] as? String else {
            sendError(id: id, code: -32602, message: "tools/call needs a tool name")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let progressToken = (params["_meta"] as? [String: Any])?["progressToken"]

        DispatchQueue.main.async { [self] in
            var progress: ToolProgress?
            if let progressToken {
                // The spec requires strictly increasing progress; several
                // phases of one device report the same index.
                var last = -1.0
                progress = { [self] value, total, message in
                    let next = max(value, last + 0.01)
                    last = next
                    var params: [String: Any] = ["progressToken": progressToken, "progress": next, "message": message]
                    if let total {
                        params["total"] = total
                    }
                    send(["jsonrpc": "2.0", "method": "notifications/progress", "params": params])
                }
            }
            tools.call(name: name, arguments: arguments, progress: progress) { [self] result in
                switch result {
                    case .success(let payload):
                        var response: [String: Any] = ["content": [["type": "text", "text": Self.render(payload)]]]
                        if payload is [String: Any] {
                            response["structuredContent"] = payload
                        }
                        sendResult(id: id, response)
                    case .failure(let error):
                        sendResult(id: id, [
                            "content": [["type": "text", "text": error.message]],
                            "isError": true,
                        ])
                }
            }
        }
    }

    private func sendResult(id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func sendError(id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func render(_ payload: Any) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: payload) }
        return text
    }

    private static let instructions = """
        ImpossiBLE makes CoreBluetooth work in the iOS Simulator. Apps in the simulator that link the \
        ImpossiBLE library talk to this Mac provider, which either serves virtual devices (mock mode), \
        forwards to the Mac's real Bluetooth hardware (passthrough mode), or reports Bluetooth powered off \
        (off). Start with get_status. In mock mode the simulator sees the enabled devices of the working \
        set; load one with select_configuration, edit it with the device tools, or record real devices with \
        capture_start → capture_results → capture_save. If the app uploaded its own configuration, that one \
        is served instead and cannot be edited here. To test an app in mock mode: drive it with \
        set_characteristic_value (live values and notifications), disconnect_device, and inject_failure, \
        and check what it did with mock_activity (reads, writes with their bytes, subscriptions). \
        export_configuration turns a configuration into a fixture for ImpossiBLESetMockConfiguration().
        """
}
