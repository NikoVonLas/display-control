import Foundation

public final class ConfigurationStore {
    private let defaults: UserDefaults
    private let hubConfigurationKey = "hubCommandConfiguration"
    private let hubConfigurationVersionKey = "hubCommandConfigurationVersion"
    // Version 2 uses the live-tested V11 mapping: EA=0 is USB-B, EA=1 is USB-C.
    private let currentHubConfigurationVersion = 2

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadHubConfiguration() -> HubCommandConfiguration {
        if defaults.integer(forKey: hubConfigurationVersionKey) < currentHubConfigurationVersion {
            let configuration = HubCommandConfiguration.xv282KPatchedFirmware
            saveHubConfiguration(configuration)
            defaults.set(currentHubConfigurationVersion, forKey: hubConfigurationVersionKey)
            return configuration
        }

        guard
            let data = defaults.data(forKey: hubConfigurationKey),
            let configuration = try? JSONDecoder().decode(HubCommandConfiguration.self, from: data)
        else {
            return .xv282KPatchedFirmware
        }
        return configuration
    }

    public func saveHubConfiguration(_ configuration: HubCommandConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }
        defaults.set(data, forKey: hubConfigurationKey)
    }
}
