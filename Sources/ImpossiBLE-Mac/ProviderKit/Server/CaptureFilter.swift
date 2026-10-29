import Foundation

/// The capture result filters, shared by the capture window and the MCP
/// control tools so both select exactly the same devices.
struct CaptureFilter {
    var onlyConnectable = false
    var showUnnamed = false
    var nameContains = ""
    var advertisingService = ""

    /// The service UUIDs to hand to the scan itself; empty scans for everything.
    var requestedServiceUUIDs: [String] {
        let service = advertisingService.trimmingCharacters(in: .whitespacesAndNewlines)
        return service.isEmpty ? [] : [service.uppercased()]
    }

    func matches(_ device: CapturedDevice) -> Bool {
        if onlyConnectable && !device.isConnectable {
            return false
        }

        if !showUnnamed && !device.hasName {
            return false
        }

        let nameFilter = nameContains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nameFilter.isEmpty,
           device.displayName.range(of: nameFilter, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }

        let serviceFilter = advertisingService.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !serviceFilter.isEmpty,
           !device.advertisedServiceUUIDs.contains(where: { $0.uppercased() == serviceFilter }) {
            return false
        }

        return true
    }

    static func defaultConfigurationName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Capture \(formatter.string(from: Date()))"
    }
}
