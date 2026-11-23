import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+).
public final class LaunchAtLoginManager: @unchecked Sendable {
    public init() {}

    public var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// True when the app is registered to launch at login (enabled, or awaiting user approval).
    public var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled:
            return true
        default:
            return false
        }
    }

    public var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        }
    }

    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
