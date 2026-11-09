import SwiftUI
import AppKit
import ServiceManagement

struct LaunchAtLoginSettings: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(String(localized: "Beim Anmelden starten"), isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: setEnabled
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            Text(String(localized: "Startet macOSDocker automatisch bei der Anmeldung am Mac.")).font(.caption).foregroundStyle(.secondary)
            if status == .requiresApproval {
                Text(String(localized: "macOS benötigt noch deine Freigabe unter Anmeldeobjekte.")).font(.caption).foregroundStyle(.secondary)
                Button(String(localized: "Anmeldeobjekte öffnen …")) { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        status = SMAppService.mainApp.status
    }

    private func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            self.error = String(localized: "Autostart konnte nicht geändert werden: ") + error.localizedDescription
        }
        refresh()
    }
}
