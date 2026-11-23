import Combine
import Foundation

/// Persists `AppSettings` as JSON inside `UserDefaults` (injectable for unit tests).
@MainActor
public final class SettingsStore: ObservableObject {
    public nonisolated static let defaultsKey = "com.piszeprogramy.openbetterdisplay.settings.v1"

    @Published public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?(settings)
        }
    }

    /// Invoked after every effective change (after persistence).
    public var onChange: ((AppSettings) -> Void)?

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = SettingsStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
        self.settings = SettingsStore.load(defaults: defaults, key: key)
    }

    public nonisolated static func load(defaults: UserDefaults, key: String = SettingsStore.defaultsKey) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings.default
        }
        return decoded
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    public func reload() {
        settings = SettingsStore.load(defaults: defaults, key: key)
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }

    public func resetToDefaults() {
        settings = AppSettings.default
    }
}
