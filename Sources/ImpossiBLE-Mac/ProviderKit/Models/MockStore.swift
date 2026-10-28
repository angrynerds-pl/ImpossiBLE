import Foundation
import Combine

public final class MockStore: ObservableObject {
    @Published var devices: [MockDevice] = []
    @Published var configurations: [MockConfiguration] = []
    @Published var activeConfigurationName: String = "" {
        didSet { UserDefaults.standard.set(activeConfigurationName, forKey: "ActiveConfigurationName") }
    }

    private let devicesURL: URL
    private let configsURL: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ImpossiBLE", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.devicesURL = dir.appendingPathComponent("mock-devices.json")
        self.configsURL = dir.appendingPathComponent("mock-configurations.json")
        loadConfigurations()
        loadDevices()
        activeConfigurationName = UserDefaults.standard.string(forKey: "ActiveConfigurationName") ?? ""
    }

    // MARK: - Active Devices

    func loadDevices() {
        guard FileManager.default.fileExists(atPath: devicesURL.path) else { return }
        do {
            let data = try Data(contentsOf: devicesURL)
            devices = try JSONDecoder().decode([MockDevice].self, from: data)
        } catch {
            NSLog("ImpossiBLE-Mock: failed to load devices: %@", error.localizedDescription)
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(devices)
            try data.write(to: devicesURL, options: .atomic)
        } catch {
            NSLog("ImpossiBLE-Mock: failed to save devices: %@", error.localizedDescription)
        }
    }

    func addDevice() {
        var device = MockDevice()
        device.name = "Mock Device \(devices.count + 1)"
        devices.append(device)
        save()
    }

    func deleteDevice(at offsets: IndexSet) {
        devices.remove(atOffsets: offsets)
        save()
    }

    func deleteDevice(id: UUID) {
        devices.removeAll { $0.id == id }
        save()
    }

    func duplicateDevice(id: UUID) {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        var copy = device.withFreshIdentifiers()
        copy.name = device.name + " Copy"
        devices.append(copy)
        save()
    }

    func addDevice(_ device: MockDevice) {
        devices.append(device)
        save()
    }

    /// Replaces the device with the same id. Returns false when it is gone.
    @discardableResult
    func updateDevice(_ device: MockDevice) -> Bool {
        guard let idx = devices.firstIndex(where: { $0.id == device.id }) else { return false }
        devices[idx] = device
        save()
        return true
    }

    @discardableResult
    func setDeviceEnabled(id: UUID, _ isEnabled: Bool) -> Bool {
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return false }
        devices[idx].isEnabled = isEnabled
        save()
        return true
    }

    var enabledDevices: [MockDevice] {
        devices.filter(\.isEnabled)
    }

    // MARK: - Configurations

    func loadConfigurations() {
        guard FileManager.default.fileExists(atPath: configsURL.path) else { return }
        do {
            let data = try Data(contentsOf: configsURL)
            configurations = try JSONDecoder().decode([MockConfiguration].self, from: data)
        } catch {
            NSLog("ImpossiBLE-Mock: failed to load configs: %@", error.localizedDescription)
        }
    }

    func saveConfigurations() {
        do {
            let data = try JSONEncoder().encode(configurations)
            try data.write(to: configsURL, options: .atomic)
        } catch {
            NSLog("ImpossiBLE-Mock: failed to save configs: %@", error.localizedDescription)
        }
    }

    func saveCurrentAsConfiguration(name: String) {
        upsertConfiguration(MockConfiguration(name: name, devices: devices))
    }

    /// Stores `config`, replacing any user configuration with the same name.
    func upsertConfiguration(_ config: MockConfiguration) {
        if let idx = configurations.firstIndex(where: { $0.name == config.name }) {
            configurations[idx] = config
        } else {
            configurations.append(config)
        }
        saveConfigurations()
    }

    func saveConfiguration(name: String, devices newDevices: [MockDevice], loadImmediately: Bool) {
        let config = MockConfiguration(name: name, devices: newDevices)
        upsertConfiguration(config)

        if loadImmediately {
            loadConfiguration(config)
        } else {
            activeConfigurationName = name
        }
    }

    func loadConfiguration(_ config: MockConfiguration) {
        // Deep copy with fresh IDs so multiple loads don't share identifiers
        devices = config.devices.map { $0.withFreshIdentifiers() }
        activeConfigurationName = config.name
        save()
    }

    func deleteConfiguration(id: UUID) {
        configurations.removeAll { $0.id == id }
        saveConfigurations()
    }

    /// Renames a user configuration, following it with the active name when it
    /// is the loaded one. Built-ins are not stored and cannot be renamed.
    @discardableResult
    func renameConfiguration(id: UUID, to name: String) -> Bool {
        guard let idx = configurations.firstIndex(where: { $0.id == id }) else { return false }
        let oldName = configurations[idx].name
        configurations[idx].name = name
        saveConfigurations()
        if activeConfigurationName == oldName {
            activeConfigurationName = name
        }
        return true
    }

    /// Stores a copy of any configuration, built-ins included, under a new name.
    func duplicateConfiguration(_ config: MockConfiguration, name: String) -> MockConfiguration {
        let copy = MockConfiguration(name: name, devices: config.devices.map { $0.withFreshIdentifiers() })
        configurations.append(copy)
        saveConfigurations()
        return copy
    }

    var allConfigurations: [MockConfiguration] {
        StockConfigurations.all + configurations
    }
}

extension MockDevice {
    /// A deep copy whose device, services, characteristics, and descriptors all
    /// get new ids, so copies never share identifiers with their source.
    func withFreshIdentifiers() -> MockDevice {
        var d = self
        d.id = UUID()
        d.services = d.services.map { svc in
            var s = svc
            s.id = UUID()
            s.characteristics = s.characteristics.map { ch in
                var c = ch
                c.id = UUID()
                c.descriptors = c.descriptors.map { desc in
                    var dd = desc
                    dd.id = UUID()
                    return dd
                }
                return c
            }
            return s
        }
        return d
    }
}
