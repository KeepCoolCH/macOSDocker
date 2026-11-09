import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

enum LaunchKind: String, CaseIterable, Identifiable {
    case run = "Docker run"
    case yaml = "Compose-YAML"
    case compose = "Compose-Befehl"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .run: String(localized: "Docker run")
        case .yaml: String(localized: "Compose-YAML")
        case .compose: String(localized: "Compose-Befehl")
        }
    }
}

@MainActor
final class LaunchController: ObservableObject {
    @Published var kind: LaunchKind = .run
    @Published var runText = "docker run -d --name web -p 8080:80 nginx:alpine"
    @Published var composeText = "docker compose up -d"
    @Published var yamlText = "services:\n  web:\n    image: nginx:alpine\n    ports:\n      - \"8080:80\"\n"
    @Published var project = "mein-projekt"
    @Published var directory = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var automaticallyShare = true
    @Published var working = false
    @Published var output = String(localized: "Befehl oder Compose-Inhalt eingeben und starten. Die Ausgabe erscheint hier.")
    @Published var status = String(localized: "Bereit")
    private var task: Task<Void, Never>?
    private var job: CLIProcess?
    private var outputData = Data()
    private var token = UUID()
    private let outputLimit = 1024 * 1024

    var text: String {
        get { switch kind { case .run: runText; case .yaml: yamlText; case .compose: composeText } }
        set { switch kind { case .run: runText = newValue; case .yaml: yamlText = newValue; case .compose: composeText = newValue } }
    }
    private func append(_ data: Data) {
        outputData.append(data)
        if outputData.count > outputLimit { outputData = Data(outputData.suffix(outputLimit)) }
        output = String(decoding: outputData, as: UTF8.self)
    }
    func cancel() { job?.cancel(); task?.cancel() }

    func execute(runtime: RuntimeManager, inTerminal: Bool = false) {
        guard !working, runtime.running, !runtime.commandRunning else { return }
        working = true; runtime.commandRunning = true
        outputData = Data(); output = ""; status = String(localized: "Prüfe Eingabe …")
        let operation = UUID(); token = operation
        let process = CLIProcess(); job = process
        let mode = kind, input = text, projectName = project, automatic = automaticallyShare
        let folder = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        task = Task {
            defer { token = UUID(); working = false; runtime.commandRunning = false; job = nil; task = nil }
            do {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AppFailure(message: String(localized: "Bitte einen vorhandenen Arbeitsordner wählen.")) }
                let arguments: [String], binds: [BindRequirement], workingDirectory: URL
                if mode == .run {
                    let help = try await process.run(arguments: ["run", "--help"]).checked()
                    let prepared = try DockerRunParser.prepare(input, directory: folder, help: String(decoding: help.stdout, as: UTF8.self))
                    guard !prepared.interactive || inTerminal else { throw AppFailure(message: String(localized: "Dieser Befehl benötigt interaktive Eingabe (-i/-t). Bitte „Im Terminal starten“ verwenden.")) }
                    arguments = prepared.arguments; binds = prepared.binds; workingDirectory = folder
                } else {
                    let prepared = try await ComposeLauncher.prepare(yaml: mode == .yaml ? input : nil, command: mode == .compose ? input : nil,
                                                                   project: projectName, directory: folder, host: "unix://" + runtime.dockerPath, job: process)
                    arguments = prepared.arguments; binds = prepared.binds; workingDirectory = prepared.directory
                    append(Data(String(localized: "Compose gültig: \(prepared.serviceCount) Service(s).\n").utf8))
                }
                try Task.checkCancellation()
                status = String(localized: "Prüfe Mac-Freigaben …")
                let added = try await runtime.prepareMacBinds(binds, automaticallyShare: automatic)
                if !added.isEmpty { append(Data((String(localized: "Mac-Freigaben eingerichtet:\n") + added.joined(separator: "\n") + "\n\n").utf8)) }
                try Task.checkCancellation()
                if inTerminal {
                    try runtime.openDockerTerminal(arguments: arguments, directory: workingDirectory)
                    status = String(localized: "Im Terminal gestartet")
                    append(Data(String(localized: "Ausgabe und interaktive Eingabe sind im geöffneten Terminal verfügbar.\n").utf8))
                } else {
                    status = String(localized: "Läuft …")
                    let preamble = outputData
                    let receiver = self
                    let result = try await process.run(arguments: arguments, host: "unix://" + runtime.dockerPath, directory: workingDirectory) { data in
                        Task { @MainActor in
                            guard receiver.token == operation else { return }
                            receiver.append(data)
                        }
                    }
                    token = UUID()
                    outputData = preamble
                    append(result.combined)
                    status = result.status == 0 ? String(localized: "Erfolgreich (Exit 0)") : String(localized: "Fehlgeschlagen (Exit \(result.status))")
                    if result.truncated { append(Data(String(localized: "\n[Ausgabe gekürzt]\n").utf8)) }
                    if result.combined.isEmpty { append(Data(String(localized: "Befehl beendet (Exit \(result.status)).\n").utf8)) }
                }
                try await runtime.refresh()
            } catch is CancellationError {
                status = String(localized: "Abgebrochen")
                append(Data(String(localized: "\nCLI-Ausführung abgebrochen. Bereits erstellte Container bleiben in der Containerliste sichtbar.\n").utf8))
                try? await runtime.refresh()
            } catch {
                status = String(localized: "Fehlgeschlagen")
                append(Data(("\n" + error.localizedDescription + "\n").utf8))
                try? await runtime.refresh()
            }
        }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = String(localized: "Basis für relative Bind-Pfade, Compose-Dateien und .env.")
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }
    func loadComposeFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.yaml, .json]; panel.message = String(localized: "Compose-Datei in den Editor laden.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            yamlText = try String(contentsOf: url, encoding: .utf8)
            directory = url.deletingLastPathComponent().path
            let proposed = url.deletingLastPathComponent().lastPathComponent.lowercased().replacingOccurrences(of: "[^a-z0-9_-]", with: "-", options: .regularExpression)
            project = proposed.first?.isLetter == true || proposed.first?.isNumber == true ? proposed : "projekt-" + proposed
            kind = .yaml
        } catch { output = error.localizedDescription }
    }
}

struct CommandEntryView: View {
    @ObservedObject var launcher: LaunchController
    @EnvironmentObject var runtime: RuntimeManager
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(String(localized: "Eingabe"), selection: $launcher.kind) { ForEach(LaunchKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).disabled(launcher.working)
                        HStack {
                            TextField(String(localized: "Arbeitsordner"), text: $launcher.directory)
                            Button(String(localized: "Ordner …")) { launcher.chooseDirectory() }
                        }.disabled(launcher.working)
                        if launcher.kind == .yaml {
                            HStack {
                                TextField(String(localized: "Projektname"), text: $launcher.project)
                                Button(String(localized: "Datei laden …")) { launcher.loadComposeFile() }
                            }.disabled(launcher.working)
                        }
                        PlainCodeEditor(text: Binding(get: { launcher.text }, set: { launcher.text = $0 }))
                            .font(.system(.body, design: .monospaced))
                            .disableAutocorrection(true)
                            .disabled(launcher.working)
                            .frame(height: max(200, geometry.size.height - 400))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(launcher.kind == .yaml
                             ? String(localized: "Compose wird geprüft und mit up -d gestartet. Relative Pfade und .env beziehen sich auf den Arbeitsordner. Der Projektname bestimmt, welcher Stack erstellt oder aktualisiert wird.")
                             : launcher.kind == .run
                             ? String(localized: "Anführungszeichen, mehrzeilige Befehle mit \\ sowie $HOME, $PWD und $(pwd) sind möglich. Für -it bitte im Terminal starten.")
                             : String(localized: "Zum Beispiel: docker compose -f compose.yaml -p mein-projekt up -d. Andere Compose-Aktionen sind im Terminal verfügbar."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                        HStack {
                            Text(String(localized: "Fehlende Mac-Ordner automatisch freigeben"))
                            Spacer()
                            Toggle(String(localized: "Fehlende Mac-Ordner automatisch freigeben"), isOn: $launcher.automaticallyShare)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(launcher.working)
                        }
                        Divider()
                        Text(String(localized: "Bei Datei-Binds wird der übergeordnete Ordner freigegeben. Fehlende Dateien oder Ordner werden nicht automatisch angelegt."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            if launcher.working { ProgressView().controlSize(.small) }
                            Text(launcher.status).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if launcher.working { Button(String(localized: "Abbrechen"), role: .cancel) { launcher.cancel() } }
                            else {
                                Button(String(localized: "Im Terminal starten")) { launcher.execute(runtime: runtime, inTerminal: true) }.disabled(!runtime.running || runtime.commandRunning)
                                Button(String(localized: "Ausführen")) { launcher.execute(runtime: runtime) }.buttonStyle(.borderedProminent).disabled(!runtime.running || runtime.commandRunning)
                            }
                        }
                        if !runtime.running { Text(String(localized: "Zuerst die Runtime starten.")).font(.caption).foregroundStyle(.orange) }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }.padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}
