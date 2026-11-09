import SwiftUI

struct AppUpdateSettings: View {
    @ObservedObject private var updates = AppUpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(String(localized: "Automatisch nach App-Updates suchen"), isOn: $updates.automaticChecks)
                .toggleStyle(.switch).controlSize(.small)
            Text(String(localized: "Prüft einmal täglich, solange die App geöffnet ist. Downloads werden im Browser geöffnet und manuell installiert.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Nach App-Updates suchen …")) { updates.check() }.disabled(updates.checking)
                if updates.checking { ProgressView().controlSize(.small) }
                if updates.available != nil { Button(String(localized: "Download öffnen")) { updates.openAvailableDownload() } }
            }
            if !updates.message.isEmpty { Text(updates.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let last = updates.lastChecked {
                LabeledContent(String(localized: "Letzte App-Updateprüfung")) { Text(last, format: .dateTime.day().month().year().hour().minute()) }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AppUpdateCommands: Commands {
    @ObservedObject private var updates = AppUpdateController.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(String(localized: "Nach App-Updates suchen …")) { updates.check() }.disabled(updates.checking)
        }
    }
}
