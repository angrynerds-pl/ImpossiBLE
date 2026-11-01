import Foundation

struct ReplayScript {
    enum Direction: String {
        case fromClient
        case toClient
    }

    struct Entry {
        let seq: Int
        let timestamp: Date
        let direction: Direction
        let message: [String: Any]
        let type: String

        private static let ignoredKeys: Set<String> = ["value", "valueB64"]

        func matches(_ actual: [String: Any]) -> Bool {
            Self.relevantKeys(of: message) as NSDictionary == Self.relevantKeys(of: actual) as NSDictionary
        }

        private static func relevantKeys(of message: [String: Any]) -> [String: Any] {
            message.filter { !ignoredKeys.contains($0.key) && !$0.key.hasPrefix("_") }
        }
    }

    let entries: [Entry]

    var fromClientCount: Int { entries.filter { $0.direction == .fromClient }.count }
    var toClientCount: Int { entries.filter { $0.direction == .toClient }.count }

    func delay(before index: Int) -> TimeInterval {
        guard index > 0 else { return 0 }
        return max(0, entries[index].timestamp.timeIntervalSince(entries[index - 1].timestamp))
    }

    static func load(from url: URL) throws -> ReplayScript {
        let data = try Data(contentsOf: url)
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ReplayScriptError("Not valid JSON")
        }
        guard let array = json as? [Any] else {
            throw ReplayScriptError("Expected a JSON array of entries")
        }
        guard !array.isEmpty else {
            throw ReplayScriptError("The recording has no entries")
        }

        var seenSeqs = Set<Int>()
        var entries: [Entry] = []
        entries.reserveCapacity(array.count)
        for (index, raw) in array.enumerated() {
            let entry = try parseEntry(raw, index: index)
            guard seenSeqs.insert(entry.seq).inserted else {
                throw ReplayScriptError("Entry \(index): duplicate seq \(entry.seq)")
            }
            entries.append(entry)
        }
        entries.sort { $0.seq < $1.seq }
        return ReplayScript(entries: entries)
    }

    private static func parseEntry(_ raw: Any, index: Int) throws -> Entry {
        guard let object = raw as? [String: Any] else {
            throw ReplayScriptError("Entry \(index): not an object")
        }
        guard let seq = object["seq"] as? Int else {
            throw ReplayScriptError("Entry \(index): missing or non-integer seq")
        }
        guard let timestampString = object["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampString) else {
            throw ReplayScriptError("Entry \(index): missing or invalid timestamp")
        }
        guard let directionString = object["direction"] as? String,
              let direction = Direction(rawValue: directionString) else {
            throw ReplayScriptError("Entry \(index): direction must be fromClient or toClient")
        }
        guard let message = object["message"] as? [String: Any] else {
            throw ReplayScriptError("Entry \(index): missing message object")
        }
        guard let type = message["type"] as? String, !type.isEmpty else {
            throw ReplayScriptError("Entry \(index): message has no type")
        }
        return Entry(seq: seq, timestamp: timestamp, direction: direction, message: message, type: type)
    }

    private static let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondTimestampFormatter = ISO8601DateFormatter()

    private static func parseTimestamp(_ string: String) -> Date? {
        fractionalTimestampFormatter.date(from: string) ?? wholeSecondTimestampFormatter.date(from: string)
    }
}

struct ReplayScriptError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
