import SwiftUI
import AppKit

struct BackupView: View {
    @EnvironmentObject var runtime: RuntimeManager
    @ObservedObject var controller: BackupController
    @State private var pendingDeletion: BackupEntry?
    @State private var restoreURL: URL?
    @State private var confirmBackup = false
    @State private var volume = ""
    @State private var exportURL: URL?
    @State private var importURL: URL?
    @State private var importName = ""
    var body: some View {
        Form {
            Section(String(localized: "Vollsicherung")) {
                Text(String(localized: "Sichert Linux-System, Images, Container, Netzwerke und Docker-Volumes. Auf APFS wird die VM nach einer kurzen Klonphase wieder gestartet. Ohne Klonunterstützung bleibt sie während der Kopie gestoppt. Mac-Ordner und externe Volume-Treiber sind nicht enthalten."))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent(String(localized: "Zielordner")) { Text(controller.preferences.folder.isEmpty ? "—" : controller.preferences.folder).textSelection(.enabled) }
                HStack {
                    Button(String(localized: "Backup-Ordner wählen …")) { controller.chooseFolder() }
                    Button(String(localized: "Pfad löschen"), systemImage: "xmark.circle") { controller.clearFolder() }
                        .disabled(controller.preferences.folder.isEmpty)
                        .help(String(localized: "Entfernt nur den Zielpfad und deaktiviert den Zeitplan. Vorhandene Backups bleiben erhalten."))
                }
                HStack {
                    Button(String(localized: "Jetzt sichern …")) { confirmBackup = true }.disabled(controller.preferences.folder.isEmpty)
                    Button(String(localized: "Backup öffnen …")) {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK { restoreURL = panel.url }
                    }
                }
            }
            Section(String(localized: "Automatische Backups")) {
                Toggle(String(localized: "Zeitplan aktivieren"), isOn: $controller.preferences.enabled)
                    .disabled(controller.preferences.folder.isEmpty)
                    .onChange(of: controller.preferences.enabled) { _, enabled in
                        if enabled { controller.preferences.enabledAt = Date(); controller.preferences.lastAutomatic = nil }
                    }
                Stepper(value: $controller.preferences.hours, in: 1...720) {
                    HStack { Text(String(localized: "Intervall")); Spacer(); Text(verbatim: String(controller.preferences.hours)) }
                }
                Picker(String(localized: "Einheit"), selection: Binding(get: { controller.preferences.intervalUnit ?? "hours" }, set: { controller.preferences.intervalUnit = $0 })) {
                    Text(String(localized: "Stunden")).tag("hours")
                    Text(String(localized: "Tage")).tag("days")
                    Text(String(localized: "Wochen")).tag("weeks")
                    Text(String(localized: "Monate")).tag("months")
                }
                Toggle(String(localized: "Nur alle Volumes sichern"), isOn: Binding(get: { controller.preferences.volumesOnly ?? false }, set: { controller.preferences.volumesOnly = $0 }))
                    .toggleStyle(.switch)
                Text(controller.preferences.volumesOnly == true
                     ? String(localized: "Alle lokalen Volumes als TAR-Archive. Container werden währenddessen gestoppt. Archive können einzeln importiert werden; Container und Netzwerke sind nicht enthalten.")
                     : String(localized: "Vollständige Sicherung der VM inklusive Container, Images, Netzwerke und Volumes."))
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $controller.preferences.keep, in: 1...100) {
                    HStack { Text(String(localized: "Automatische Versionen aufbewahren")); Spacer(); Text(verbatim: String(controller.preferences.keep)) }
                }
                Text(String(localized: "Aufbewahrung getrennt pro Sicherungsart.")).font(.caption).foregroundStyle(.secondary)
                if controller.preferences.enabled {
                    LabeledContent(String(localized: "Nächstes Backup")) { Text(controller.next, format: .dateTime.day().month().year().hour().minute()) }
                }
                Text(String(localized: "Läuft solange die Menüleisten-App geöffnet ist. Verpasste Termine werden nachgeholt, sobald die Runtime frei ist. Alte automatische Versionen werden erst nach einer erfolgreichen Sicherung entfernt. Manuelle Backups bleiben erhalten."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(String(localized: "Gespeicherte Backups")) {
                Button(String(localized: "Aktualisieren")) { controller.reload() }
                if controller.entries.isEmpty { Text(String(localized: "Keine Backups im Zielordner.")) }
                ForEach(controller.entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.manifest.created, format: .dateTime.day().month().year().hour().minute())
                            Text(entry.manifest.automatic ? String(localized: "Automatisch") : String(localized: "Manuell")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Image(systemName: "folder") }
                        Button(role: .destructive) { pendingDeletion = entry } label: { Image(systemName: "xmark.circle") }
                            .help(String(localized: "Backup löschen"))
                            .accessibilityLabel(String(localized: "Backup löschen"))
                        if entry.manifest.kind == "volumes" {
                            Button(String(localized: "Volume-Archive öffnen")) { NSWorkspace.shared.open(entry.url) }
                        } else {
                            Button(String(localized: "Wiederherstellen …")) { restoreURL = entry.url }
                        }
                    }
                }
            }
            Section(String(localized: "Volume-Archive")) {
                Text(String(localized: "Export als TAR mit Dateirechten. Verwendende Container werden gestoppt und danach wieder gestartet. Für das Archiv wird zusätzlicher Platz in der VM benötigt. Importiert wird immer in ein neues Volume."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(String(localized: "Volume"), selection: $volume) {
                    Text(verbatim: "—").tag("")
                    ForEach(runtime.volumes.sorted { $0.Name < $1.Name }) { Text(verbatim: $0.Name).tag($0.Name) }
                }
                Button(String(localized: "Volume exportieren …")) {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = volume + ".tar"
                    if panel.runModal() == .OK { exportURL = panel.url }
                }.disabled(!runtime.running || volume.isEmpty)
                Button(String(localized: "Volume importieren …")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK { importURL = panel.url; importName = "" }
                }.disabled(!runtime.running)
            }
            if !controller.status.isEmpty { Text(controller.status).font(.caption).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .disabled(!controller.available)
        .onAppear { controller.reload() }
        .confirmationDialog(String(localized: "Backup wirklich löschen?"), isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            Button(String(localized: "Löschen"), role: .destructive) {
                if let entry = pendingDeletion { controller.delete(entry) }
                pendingDeletion = nil
            }
        } message: {
            Text(String(localized: "Die ausgewählte Sicherung wird dauerhaft aus dem Backup-Ordner entfernt."))
        }
        .confirmationDialog(String(localized: "VM für Vollsicherung stoppen?"), isPresented: $confirmBackup, titleVisibility: .visible) {
            Button(String(localized: "Jetzt sichern")) { controller.backup() }
        }
        .confirmationDialog(String(localized: "Gesamten Docker-Zustand ersetzen? Vorher wird eine Sicherheitssicherung erstellt. Externe Mac-Ordner werden nicht wiederhergestellt."), isPresented: Binding(get: { restoreURL != nil }, set: { if !$0 { restoreURL = nil } }), titleVisibility: .visible) {
            Button(String(localized: "Wiederherstellen"), role: .destructive) { if let url = restoreURL { controller.restore(url) }; restoreURL = nil }
        }
        .confirmationDialog(String(localized: "Verwendende Container für den Export stoppen?"), isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } }), titleVisibility: .visible) {
            Button(String(localized: "Exportieren")) { if let url = exportURL { controller.exportVolume(volume, to: url) }; exportURL = nil }
        }
        .sheet(isPresented: Binding(get: { importURL != nil }, set: { if !$0 { importURL = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "Volume importieren")).font(.headline)
                TextField(String(localized: "Neuer Volume-Name"), text: $importName)
                Text(String(localized: "Bestehende Volumes werden nicht überschrieben. Nur vertrauenswürdige TAR-Archive importieren."))
                    .font(.caption)
                HStack {
                    Button(String(localized: "Abbrechen")) { importURL = nil }
                    Spacer()
                    Button(String(localized: "Importieren")) {
                        if let url = importURL { controller.importVolume(from: url, name: importName) }
                        importURL = nil
                    }.disabled(importName.isEmpty)
                }
            }.padding().frame(width: 440)
        }
    }
}

struct BackupActivityView: View {
    @ObservedObject var controller: BackupController
    var body: some View {
        if controller.working {
            HStack(alignment: .top, spacing: 12) {
                ProgressView().controlSize(.small).frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.background ? String(localized: "Backup im Hintergrund") : String(localized: "Backup läuft"))
                        .font(.callout.weight(.semibold))
                    Text(controller.status).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
}
