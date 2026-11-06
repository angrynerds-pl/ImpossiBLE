import Foundation

// Moves a Concept2 PM5's clock in a recording to the time of the replay, so a
// replayed workout is logged as a new result instead of being rejected by the
// Concept2 Logbook as a duplicate of the recorded one.
//
// Mirrors the library's CBSReplayPM5Time.m; keep the two in step. All PM5
// timestamps move by the one offset that makes the last workout summary read
// as `now` (minute precision). Rewritten:
//
//   CE060039 / CE06003A workout summaries        bytes 0–3
//   CE060080 multiplexed 0x39 / 0x3A / 0x3C       bytes 1–4
//   CSAFE replies on response channels: GET_DATETIME (0x85) and any summary
//   stamp inside reply data, little or big endian (0x6A is big endian)
//
// Log date is month (4 bits) | day (5) | year - 2000 (7), little endian, then
// minutes, hours (24 h), on the PM5's local clock.

extension ReplayScript {
    func shiftingPM5Times(to now: Date, responseChannels: Set<String> = ["CE060022"]) -> ReplayScript {
        var stamps: [[UInt8]] = []
        var reference: PM5Stamp?
        for entry in entries where entry.direction == .toClient && entry.type == "didUpdateValue" {
            guard let bytes = entry.valueBytes,
                  let offset = PM5Stamp.summaryOffset(uuid: entry.characteristicUUID, bytes: bytes) else { continue }
            let raw = Array(bytes[offset ..< offset + 4])
            guard let stamp = PM5Stamp(log: raw) else { continue }
            if !stamps.contains(raw) { stamps.append(raw) }
            reference = stamp
        }

        guard let referenceDate = reference?.date ?? entries.first?.timestamp else { return self }
        let offset = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 - referenceDate.timeIntervalSinceReferenceDate
        let shift: (PM5Stamp) -> PM5Stamp = { stamp in
            stamp.date.map { PM5Stamp(date: $0.addingTimeInterval(offset)) } ?? stamp
        }

        let shifted = entries.map { entry -> Entry in
            guard entry.direction == .toClient, entry.type == "didUpdateValue", let bytes = entry.valueBytes else { return entry }
            let uuid = entry.characteristicUUID
            var replacement: [UInt8]?
            if let summaryOffset = PM5Stamp.summaryOffset(uuid: uuid, bytes: bytes),
               let stamp = PM5Stamp(log: Array(bytes[summaryOffset ..< summaryOffset + 4])) {
                var copy = bytes
                copy.replaceSubrange(summaryOffset ..< summaryOffset + 4, with: shift(stamp).log)
                replacement = copy
            } else if let uuid, responseChannels.contains(where: { uuid.hasPrefix($0) }) {
                replacement = CSAFE.rewritingReply(bytes, stamps: stamps, shift: shift)
            }
            guard let replacement else { return entry }
            var message = entry.message
            message["value"] = Data(replacement).base64EncodedString()
            return Entry(seq: entry.seq, timestamp: entry.timestamp, direction: entry.direction, message: message, type: entry.type)
        }
        return ReplayScript(entries: shifted)
    }
}

extension ReplayScript.Entry {
    var valueBytes: [UInt8]? {
        guard let value = message["value"] as? String ?? message["valueB64"] as? String,
              let data = Data(base64Encoded: value) else { return nil }
        return Array(data)
    }

    /// The characteristic UUID in a `<service id>:<UUID>:<index>` characteristic id.
    var characteristicUUID: String? {
        guard let id = message["characteristicId"] as? String else { return nil }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count >= 2 ? parts[parts.count - 2].uppercased() : nil
    }
}

struct PM5Stamp: Equatable {
    var year, month, day, hour, minute: Int

    init(year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        (self.year, self.month, self.day, self.hour, self.minute) = (year, month, day, hour, minute)
    }

    /// From the 4-byte log form: date little endian, minutes, hours.
    init?(log b: [UInt8]) {
        guard b.count == 4 else { return nil }
        let date = Int(b[0]) | Int(b[1]) << 8
        self.init(year: 2000 + (date >> 9), month: date & 0x0F, day: (date >> 4) & 0x1F, hour: Int(b[3]), minute: Int(b[2]))
        guard (1 ... 12).contains(month), (1 ... 31).contains(day), hour < 24, minute < 60 else { return nil }
    }

    init(date: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        self.init(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1, hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    var log: [UInt8] {
        let date = (month & 0x0F) | (day & 0x1F) << 4 | ((year - 2000) & 0x7F) << 9
        return [UInt8(date & 0xFF), UInt8(date >> 8), UInt8(minute), UInt8(hour)]
    }

    var date: Date? {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }

    /// Where a workout summary's log stamp sits in a notification.
    static func summaryOffset(uuid: String?, bytes: [UInt8]) -> Int? {
        guard let uuid else { return nil }
        if uuid.hasPrefix("CE060039") || uuid.hasPrefix("CE06003A") { return bytes.count >= 4 ? 0 : nil }
        if uuid.hasPrefix("CE060080"), bytes.count >= 5, [0x39, 0x3A, 0x3C].contains(bytes[0]) { return 1 }
        return nil
    }
}

/// Replay helpers on CSAFE framing as the PM5 uses it: `F0 [dst src] … checksum F2`, with
/// `F0…F3` stuffed as `F3 0x`. The checksum is the XOR of everything after the
/// addresses.
extension CSAFE {
    static func unstuff(_ frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= 3, frame.first == 0xF0, frame.last == 0xF2 else { return nil }
        var content: [UInt8] = []
        var i = 1
        while i < frame.count - 1 {
            var byte = frame[i]
            if byte == 0xF3 {
                guard i + 1 < frame.count - 1, frame[i + 1] <= 0x03 else { return nil }
                i += 1
                byte = 0xF0 + frame[i]
            } else if (0xF0 ... 0xF3).contains(byte) {
                return nil
            }
            content.append(byte)
            i += 1
        }
        return content
    }

    static func stuff(_ content: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0xF0]
        for byte in content {
            if (0xF0 ... 0xF3).contains(byte) {
                frame += [0xF3, byte - 0xF0]
            } else {
                frame.append(byte)
            }
        }
        return frame + [0xF2]
    }

    private static let wrappers: Set<UInt8> = [0x1A, 0x76, 0x77, 0x7E, 0x7F]

    /// The command structure of a request frame, data left out: `76[13] 7E[80 81]`.
    static func signature(_ frame: [UInt8]) -> String? {
        guard var content = unstuff(frame), content.count >= 2 else { return nil }
        content.removeLast() // checksum
        let start = content.count >= 3 && content[0] == 0xFD ? 2 : 0
        guard let parts = commands(Array(content[start...])), !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    private static func commands(_ b: [UInt8]) -> [String]? {
        var parts: [String] = []
        var i = 0
        while i < b.count {
            let command = b[i]
            i += 1
            if command >= 0x80 {
                parts.append(String(format: "%02X", command))
                continue
            }
            guard i < b.count else { return nil }
            let length = Int(b[i])
            i += 1
            guard i + length <= b.count else { return nil }
            if wrappers.contains(command) {
                guard let inner = commands(Array(b[i ..< i + length])) else { return nil }
                parts.append(String(format: "%02X[%@]", command, inner.joined(separator: " ")))
            } else {
                parts.append(String(format: "%02X", command))
            }
            i += length
        }
        return parts
    }

    /// A reply frame with its PM5 timestamps moved, or nil when nothing changed.
    static func rewritingReply(_ frame: [UInt8], stamps: [[UInt8]], shift: (PM5Stamp) -> PM5Stamp) -> [UInt8]? {
        guard var content = unstuff(frame), content.count >= 3 else { return nil }
        let header = content.count >= 4 && content[0] == 0x00 && content[1] == 0xFD ? 2 : 0
        let start = header + 1 // status
        let end = content.count - 1 // checksum
        guard start < end else { return nil }

        var changed = rewriteDateTime(&content, range: start ..< end, shift: shift)
        for stamp in stamps {
            let bigEndian = [stamp[1], stamp[0], stamp[3], stamp[2]]
            var i = start
            while i + 4 <= end {
                let window = Array(content[i ..< i + 4])
                let little = window == stamp
                guard little || window == bigEndian else {
                    i += 1
                    continue
                }
                let normal = little ? window : [window[1], window[0], window[3], window[2]]
                if let decoded = PM5Stamp(log: normal) {
                    let moved = shift(decoded).log
                    content.replaceSubrange(i ..< i + 4, with: little ? moved : [moved[1], moved[0], moved[3], moved[2]])
                    changed = true
                }
                i += 4
            }
        }
        guard changed else { return nil }
        content[end] = content[header ..< end].reduce(0, ^)
        return stuff(content)
    }

    /// GET_DATETIME (0x85): hour 1–12, minute, AM/PM, month, day, year big endian.
    private static func rewriteDateTime(_ b: inout [UInt8], range: Range<Int>, shift: (PM5Stamp) -> PM5Stamp) -> Bool {
        var changed = false
        var i = range.lowerBound
        while i + 1 < range.upperBound {
            let command = b[i]
            let length = Int(b[i + 1])
            let data = i + 2
            guard data + length <= range.upperBound else { break }
            if wrappers.contains(command) {
                changed = rewriteDateTime(&b, range: data ..< data + length, shift: shift) || changed
            } else if command == 0x85, length == 7, (1 ... 12).contains(b[data]) {
                let hour = Int(b[data]) % 12 + (b[data + 2] != 0 ? 12 : 0)
                let stamp = PM5Stamp(year: Int(b[data + 5]) << 8 | Int(b[data + 6]), month: Int(b[data + 3]),
                                     day: Int(b[data + 4]), hour: hour, minute: Int(b[data + 1]))
                let moved = shift(stamp)
                b[data] = UInt8(moved.hour % 12 == 0 ? 12 : moved.hour % 12)
                b[data + 1] = UInt8(moved.minute)
                b[data + 2] = moved.hour >= 12 ? 1 : 0
                b[data + 3] = UInt8(moved.month)
                b[data + 4] = UInt8(moved.day)
                b[data + 5] = UInt8(moved.year >> 8)
                b[data + 6] = UInt8(moved.year & 0xFF)
                changed = true
            }
            i = data + length
        }
        return changed
    }
}
