import SwiftUI

struct NetworkRenameView: View {
    let network: DockerNetwork
    @EnvironmentObject private var runtime: RuntimeManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Netzwerk umbenennen")).font(.title2.bold())
            Text(network.Name).font(.system(.body, design: .monospaced))
            TextField(String(localized: "Neuer Name"), text: $name)
            Text(String(localized: "Docker erstellt das Netzwerk mit gleichem Treiber, Subnetz und denselben Optionen neu. Die Netzwerk-ID ändert sich. Nur unbenutzte Netzwerke können umbenannt werden, auch gestoppte Container dürfen nicht verbunden sein."))
            Text(String(localized: "Compose-Dateien und externe Verweise anschließend anpassen. Währenddessen das Netzwerk nicht über andere Apps oder das Terminal verändern."))
                .font(.callout).foregroundStyle(.secondary)
            if working { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(String(localized: "Abbrechen")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(String(localized: "Umbenennen")) {
                    working = true; error = nil
                    Task {
                        do {
                            try await runtime.renameNetwork(network.id, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        working = false
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == network.Name)
            }
        }.padding(24).frame(width: 540).interactiveDismissDisabled(working)
            .onAppear { name = network.Name }
    }
}
