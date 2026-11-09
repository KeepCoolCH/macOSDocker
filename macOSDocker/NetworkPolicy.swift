import Foundation

enum NetworkPolicy {
    static var nativeBridgeEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MacOSDockerNativeBridgeEnabled") as? Bool ?? false
    }

    static func bridgeID(saved: String, enabled: Bool = nativeBridgeEnabled) -> String {
        enabled ? saved : ""
    }

    static func configuration(saved: VMNetworkSettings, enabled: Bool = nativeBridgeEnabled) -> VMNetworkSettings {
        enabled ? saved : VMNetworkSettings()
    }
}
