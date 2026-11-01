import Foundation
import SimBridgeShell

public enum ImpossiBLEMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case mock
    case passthrough
    case replay

    public var id: String { rawValue }

    public var title: String {
        switch self {
            case .off: "Off"
            case .mock: "Mock"
            case .passthrough: "Passthrough"
            case .replay: "Replay"
        }
    }

    public static let defaultsKey = ProviderMode.defaultsKey

    public static func persisted(key: String = defaultsKey, legacyServerEnabledKey: String? = nil) -> ImpossiBLEMode {
        if let rawValue = UserDefaults.standard.string(forKey: key),
           let mode = ImpossiBLEMode(rawValue: rawValue) {
            return mode
        }
        if let legacyServerEnabledKey, UserDefaults.standard.bool(forKey: legacyServerEnabledKey) {
            return .mock
        }
        return .off
    }

    public func persist(key: String = Self.defaultsKey) {
        UserDefaults.standard.set(rawValue, forKey: key)
    }
}
