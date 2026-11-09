import SwiftUI

struct VolumeRenameView: View {
    let volume: DockerVolume
    @EnvironmentObject private var runtime: RuntimeManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Volume umbenennen")).font(.title2.bold())
            Text(volume.Name).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            TextField(String(localized: "Neuer Name"), text: $name)
            Text(String(localized: "Die Daten werden in ein neues Volume kopiert und geprüft. Erst danach wird das alte Volume gelöscht. Dafür wird bei Bedarf debian:bookworm-slim heruntergeladen und zusätzlicher Speicherplatz benötigt."))
            Text(String(localized: "Nur für lokale Volumes ohne Container-Verknüpfungen. Auch gestoppte Container müssen vorher entfernt werden; Stoppen allein genügt nicht. Compose-Dateien anschließend auf den neuen Namen anpassen. Während der Migration das Volume nicht über Terminal oder andere Apps verändern."))
                .font(.callout).foregroundStyle(.secondary)
            if working { ProgressView(String(localized: "Volume wird migriert …")) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(String(localized: "Abbrechen")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(String(localized: "Migrieren und umbenennen")) {
                    working = true
                    error = nil
                    Task {
                        do {
                            try await runtime.renameVolume(volume.Name, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        working = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == volume.Name)
            }
        }.padding(24).frame(width: 540).interactiveDismissDisabled(working)
            .onAppear { name = volume.Name }
    }
}
