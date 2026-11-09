import SwiftUI
import AppKit
import Virtualization
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var runtime: RuntimeManager
    @StateObject private var launcher = LaunchController()
    @State private var section = "Container"
    @State private var terminalSelection = ""
    @State private var creation: String?
    @State private var deletion: DeleteRequest?
    @State private var renamingVolume: DockerVolume?
    @State private var renamingNetwork: DockerNetwork?
    private let sections = ["Container", "Images", "Volumes", "Netzwerke", "Builds", "Backups", "Mac-Freigaben", "Befehle", "Runtime"]
    var body: some View {
        NavigationSplitView {
            List(sections, id: \.self, selection: $section) { name in
                Label {
                    Text(AppText.sectionTitle(name))
                } icon: {
                    if name == "Netzwerke" {
                        NetworkSidebarIcon()
                            .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: icon(name))
                    }
                }.tag(name)
            }
            .navigationTitle("macOSDocker")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(runtime.running ? .green : .secondary).frame(width: 7, height: 7)
                        Text(runtime.state).font(.caption)
                        Spacer()
                        if runtime.busy || runtime.engineMaintenance || runtime.backupInProgress { ProgressView().controlSize(.small) }
                    }
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Text(verbatim: "Version " + version)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(Self.developerCredit)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding()
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(AppText.sectionTitle(section)).font(.largeTitle.bold())
                    Spacer()
                    if runtime.running && ["Container", "Images", "Volumes", "Netzwerke"].contains(section) {
                        Button { creation = section } label: { Image(systemName: "plus") }.help(String(localized: "Erstellen / herunterladen"))
                        Button { runtime.perform { try await runtime.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    }
                }.padding()
                if !runtime.stopping && !runtime.forceStopping && !runtime.starting, let problem = runtime.synchronizationError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Aktualisierung verzögert – automatischer Neuversuch läuft.")).font(.caption.bold())
                            Text(problem).font(.caption).textSelection(.enabled)
                        }
                    }.foregroundStyle(.orange).padding(.horizontal).padding(.bottom, 8)
                }
                Divider()
                if section == "Runtime" { runtimeView }
                else if section == "Backups" { BackupView(controller: runtime.backups) }
                else if section == "Mac-Freigaben" { sharesView }
                else if section == "Befehle" { CommandEntryView(launcher: launcher) }
                else if !runtime.running {
                    emptyState(String(localized: "Runtime ist gestoppt"), systemImage: "server.rack", description: String(localized: "VM starten. Das mitgelieferte Linux-Image wird automatisch eingerichtet."))
                } else if section == "Builds" { BuildHistoryView() }
                else { resources }
            }
            .disabled(runtime.engineMaintenance && section != "Backups")
            .safeAreaInset(edge: .top, spacing: 0) { BackupActivityView(controller: runtime.backups) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("macOSDocker")
            .navigationSplitViewColumnWidth(min: 480, ideal: 560, max: 900)
        } detail: {
            VStack(alignment: .leading) {
                HStack {
                    Text(String(localized: "Details / Ausgabe")).font(.headline)
                    Spacer()
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(section == "Befehle" ? launcher.output : runtime.details, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                }
                GeometryReader { geometry in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 12) {
                            if section != "Befehle", let id = runtime.selectedContainerID {
                                if runtime.containerDetailMode == .resources {
                                    ContainerMetricsView(containerID: id).id(id)
                                        .frame(width: geometry.size.width)
                                } else if runtime.containerDetailMode == .summary {
                                    ContainerSummaryView(data: runtime.containerSummary)
                                        .frame(width: geometry.size.width)
                                }
                            }
                            if section != "Befehle", let summary = runtime.inventorySummary {
                                InventorySummaryView(summary: summary).frame(width: geometry.size.width)
                            }
                            if section != "Befehle", let data = runtime.guestSummary {
                                GuestSummaryView(data: data).frame(width: geometry.size.width)
                            }
                            Text(section == "Befehle" ? launcher.output : (runtime.details.isEmpty ? String(localized: "Objekt auswählen, um Details zu sehen.") : runtime.details))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: geometry.size.width, alignment: .leading)
                        }
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
            }.padding().navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 800)
        }
        .frame(minWidth: 1050, minHeight: 650)
        .toolbar {
            Button(runtime.running ? String(localized: "Stoppen") : String(localized: "Starten"), systemImage: runtime.running ? "stop.fill" : "play.fill") {
                runtime.perform { if runtime.running { try await runtime.stop() } else { try await runtime.start() } }
            }.disabled(runtime.busy || runtime.commandRunning || runtime.engineMaintenance)
            Button(String(localized: "VM neu starten"), systemImage: "arrow.clockwise") {
                runtime.perform { try await runtime.restart() }
            }.disabled(!runtime.running || runtime.busy || runtime.commandRunning || runtime.engineMaintenance)
                .help(String(localized: "VM neu starten"))
            Button(String(localized: "Terminal"), systemImage: "terminal") { runtime.perform { try runtime.terminal() } }.disabled(!runtime.running || runtime.engineMaintenance)
        }
        .sheet(isPresented: Binding(get: { creation != nil }, set: { if !$0 { creation = nil } })) {
            CreateResourceView(kind: creation ?? "Container").environmentObject(runtime)
        }
        .sheet(item: $renamingNetwork) { network in
            NetworkRenameView(network: network).environmentObject(runtime)
        }
        .sheet(item: $renamingVolume) { volume in
            VolumeRenameView(volume: volume).environmentObject(runtime)
        }
        .alert(String(localized: "Aktion fehlgeschlagen"), isPresented: Binding(get: { runtime.error != nil }, set: { if !$0 { runtime.error = nil } })) {
            Button(String(localized: "OK")) { runtime.error = nil }
        } message: { Text(runtime.error ?? "") }
        .confirmationDialog(deletion?.title ?? String(localized: "Löschen?"), isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            Button(String(localized: "Löschen"), role: .destructive) {
                guard let request = deletion else { return }
                runtime.perform {
                    if let id = request.containerID { try await runtime.deleteContainer(id) }
                    else { try await runtime.mutate("DELETE", request.endpoint) }
                }
            }
        }
    }
    @ViewBuilder private func portLinks(_ ports: [DockerPort], running: Bool) -> some View {
        ForEach(ports) { port in
            if port.browserCapable {
                Button { runtime.perform { try await runtime.openPort(port) } } label: {
                    Label(port.label, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless).font(.caption).disabled(!running)
                .help(String(localized: "Veröffentlichten Port auf der VM im Browser öffnen. Der Dienst muss HTTP oder HTTPS anbieten."))
                .contextMenu {
                    Button(String(localized: "Mit HTTP öffnen")) { runtime.perform { try await runtime.openPort(port, scheme: "http") } }
                    Button(String(localized: "Mit HTTPS öffnen")) { runtime.perform { try await runtime.openPort(port, scheme: "https") } }
                }
            } else {
                Text(port.label).font(.caption).foregroundStyle(.secondary)
                    .help(String(localized: "Dieser Port ist nur an die Loopback-Adresse der VM gebunden."))
            }
        }
    }

    private func icon(_ name: String) -> String {
        ["Backups": "externaldrive.badge.timemachine", "Builds": "hammer", "Container": "shippingbox", "Images": "square.stack.3d.up", "Volumes": "externaldrive", "Netzwerke": "network", "Mac-Freigaben": "folder", "Runtime": "server.rack", "Befehle": "terminal"][name] ?? "circle"
    }
    @ViewBuilder private var resources: some View {
        List {
            switch section {
            case "Container":
                ForEach(runtime.containers) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle().fill(item.State == "running" ? .green : .gray).frame(width: 8, height: 8)
                            Text(item.name).font(.headline)
                            Spacer()
                            if let activity = runtime.containerActivities[item.id] {
                                ProgressView().controlSize(.small)
                                Text(activity).foregroundStyle(.secondary)
                            } else {
                                Text(AppText.containerState(item.State)).foregroundStyle(.secondary)
                            }
                        }
                        Text(item.Image).font(.caption).foregroundStyle(.secondary)
                        if runtime.containerActivities[item.id] == nil { Text(item.Status).font(.caption) }
                        let ports = DockerPort.publishedTCP(item.Ports ?? [])
                        if !ports.isEmpty {
                            ViewThatFits(in: .horizontal) {
                                HStack { portLinks(ports, running: item.State == "running") }
                                VStack(alignment: .leading, spacing: 4) { portLinks(ports, running: item.State == "running") }
                            }
                        }

                        HStack {
                            Button(item.State == "running" ? String(localized: "Stop") : String(localized: "Start")) { runtime.perform { try await runtime.mutate("POST", "/containers/\(item.id)/\(item.State == "running" ? "stop" : "start")") } }
                            Button(String(localized: "Restart")) { runtime.perform { try await runtime.mutate("POST", "/containers/\(item.id)/restart") } }
                            Button(String(localized: "Logs")) { runtime.perform { try await runtime.logs(item.id) } }
                            Button(String(localized: "Terminal")) { runtime.perform { try runtime.terminal(item) } }.disabled(item.State != "running")
                            Menu {
                                Button(String(localized: "Details, Ports und Mounts")) { runtime.perform { try await runtime.inspect("/containers/\(item.id)/json") } }
                                Button(String(localized: "Ressourcenverbrauch")) { runtime.perform { try await runtime.inspect("/containers/\(item.id)/stats?stream=false&one-shot=true") } }
                                Button(String(localized: "Löschen …"), role: .destructive) { deletion = DeleteRequest(title: String(localized: "Container \(item.name) löschen? Falls er läuft, wird er zuerst gestoppt."), endpoint: "/containers/\(item.id)", containerID: item.id) }.disabled(runtime.busy)
                            } label: { Image(systemName: "ellipsis") }
                        }.controlSize(.small).disabled(runtime.containerActivities[item.id] != nil)
                    }.padding(.vertical, 8).contentShape(Rectangle())
                        .onTapGesture { runtime.perform { try await runtime.inspect("/containers/\(item.id)/json") } }
                }
            case "Images":
                ForEach(runtime.images) { item in
                    HStack {
                        VStack(alignment: .leading) { Text(item.name).font(.headline); Text(ByteCountFormatter.string(fromByteCount: item.Size, countStyle: .file)).foregroundStyle(.secondary) }
                        Spacer()
                        Button(String(localized: "Details")) { runtime.perform { try await runtime.inspect("/images/\(item.id)/json") } }
                        Button(role: .destructive) { deletion = DeleteRequest(title: String(localized: "Image \(item.name) löschen?"), endpoint: "/images/\(item.id)") } label: { Image(systemName: "trash") }
                    }.padding(.vertical, 6).contentShape(Rectangle())
                        .onTapGesture { runtime.perform { try await runtime.inspect("/images/\(item.id)/json") } }
                }
            case "Volumes":
                ForEach(runtime.volumes) { item in
                    HStack {
                        VStack(alignment: .leading) { Text(item.Name).font(.headline); Text(item.Driver).foregroundStyle(.secondary) }
                        Spacer()
                        Button(String(localized: "Im Finder öffnen")) {
                            runtime.perform { try await runtime.openVolumeInFinder(item.Name) }
                        }.disabled(!runtime.running || runtime.volumeMountBusy || item.Driver != "local")
                        Button(String(localized: "Details / Nutzung")) { showVolumeDetails(item.Name) }
                        Button { renamingVolume = item } label: { Image(systemName: "pencil") }
                            .help(String(localized: "Volume umbenennen"))
                            .accessibilityLabel(String(localized: "Volume umbenennen"))
                            .disabled(runtime.busy || runtime.commandRunning || item.Driver != "local")
                        Button { runtime.toggleAutomaticVolume(item.Name) } label: {
                            Image(systemName: runtime.automaticallyMountsVolume(item.Name) ? "externaldrive.badge.checkmark" : "externaldrive.badge.plus")
                                .foregroundStyle(runtime.automaticallyMountsVolume(item.Name) ? Color.accentColor : Color.secondary)
                        }
                        .help(runtime.automaticVolumeErrors[item.Name] ?? String(localized: "Nach dem VM-Start automatisch per SMB einbinden"))
                        .accessibilityLabel(String(localized: "Nach dem VM-Start automatisch per SMB einbinden"))
                        .accessibilityValue(runtime.automaticallyMountsVolume(item.Name) ? String(localized: "Ein") : String(localized: "Aus"))
                        .disabled(runtime.busy || runtime.volumeMountBusy || item.Driver != "local")
                        Button(role: .destructive) { deletion = DeleteRequest(title: String(localized: "Volume \(item.Name) und seine Daten endgültig löschen?"), endpoint: "/volumes/\(item.Name)") } label: { Image(systemName: "trash") }
                    }.padding(.vertical, 6).contentShape(Rectangle())
                        .onTapGesture { showVolumeDetails(item.Name) }
                }
            case "Netzwerke":
                ForEach(runtime.networks) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.Name).font(.headline)
                            Text(item.Driver).foregroundStyle(.secondary)
                            if item.Driver == "macvlan" && !runtime.networkAvailable(item) {
                                Text(runtime.macvlanUnavailableReason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(runtime.networkAvailable(item) ? Color.primary : Color.secondary)
                        Spacer()
                        Button(String(localized: "Subnetze / Container")) { runtime.perform { try await runtime.inspect("/networks/\(item.id)") } }
                        Button { renamingNetwork = item } label: { Image(systemName: "pencil") }
                            .help(String(localized: "Netzwerk umbenennen"))
                            .accessibilityLabel(String(localized: "Netzwerk umbenennen"))
                            .disabled(!runtime.networkAvailable(item) || runtime.busy || runtime.commandRunning || ["bridge", "host", "none"].contains(item.Name) || !["bridge", "macvlan", "ipvlan"].contains(item.Driver))
                        Button(role: .destructive) { deletion = DeleteRequest(title: String(localized: "Netzwerk \(item.Name) löschen?"), endpoint: "/networks/\(item.id)") } label: { Image(systemName: "trash") }
                    }.padding(.vertical, 6).contentShape(Rectangle())
                        .onTapGesture { runtime.perform { try await runtime.inspect("/networks/\(item.id)") } }
                }
            default: EmptyView()
            }
        }.overlay(alignment: .topLeading) {
            if (section == "Container" && runtime.containers.isEmpty) || (section == "Images" && runtime.images.isEmpty) || (section == "Volumes" && runtime.volumes.isEmpty) {
                emptyState(String(localized: "Noch keine Objekte"), systemImage: icon(section), description: String(localized: "Über + erstellen oder Docker CLI / Compose verwenden."))
            }
        }
    }
    private func showVolumeDetails(_ name: String) {
        runtime.perform {
            let volume = try await runtime.api.request("GET", "/volumes/\(name)")
            let filter = try JSONSerialization.data(withJSONObject: ["volume": [name]])
            let encoded = String(decoding: filter, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            let users = try await runtime.api.request("GET", "/containers/json?all=1&filters=\(encoded)")
            runtime.details = prettyJSON(volume) + String(localized: "\n\nVerwendende Container:\n") + prettyJSON(users)
            runtime.inventorySummary = InventorySummary(section: "Volumes", data: volume, users: users)
        }
    }
    private func emptyState(_ title: String, systemImage: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(description).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sharesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Text(String(localized: "Freigegebene Mac-Ordner verwenden freie Pfade im VM-Verzeichnisbaum. Konfliktpfade liegen unter /macos. Der tatsächliche VM-Pfad wird nach dem Start angezeigt. Änderungen an bestehenden Freigaben bitte bei gestoppter VM vornehmen."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        Toggle(String(localized: "/Users automatisch freigeben"), isOn: Binding(get: { runtime.settings.automaticallyShareUsersPaths }, set: { runtime.setAutomaticMacPaths($0, root: "/Users") }))
                        Toggle(String(localized: "/Volumes automatisch freigeben"), isOn: Binding(get: { runtime.settings.automaticallyShareVolumesPaths }, set: { runtime.setAutomaticMacPaths($0, root: "/Volumes") }))
                    }
                    .toggleStyle(.switch)
                    .disabled(runtime.running || runtime.busy || runtime.engineMaintenance)
                    Text(String(localized: "Die Automatik gilt getrennt für /Users und /Volumes. Im jeweils deaktivierten Bereich sind nur manuelle Freigaben erlaubt. Automatisch hinzugefügte Freigaben dieses Bereichs werden beim Deaktivieren entfernt. Zum Umschalten die VM stoppen. Vorhandene Freigaben aus älteren Versionen bleiben als manuelle Freigaben erhalten.") + " " + String(localized: "Freie Pfade werden direkt im VM-Root eingebunden. Bei Konflikten mit Linux-Systemordnern oder vorhandenen VM-Pfaden wird /macos vorangestellt, zum Beispiel /macos/var."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if runtime.running && !runtime.automaticMacBindsAvailable {
                        Text(String(localized: "Für automatische Mac-Bind-Mounts aus allen Docker-Tools bitte unter Runtime das Basisimage aktualisieren."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(String(localized: "Mac-Ordner hinzufügen …"), systemImage: "folder.badge.plus") { runtime.addShare() }
                        .disabled(runtime.busy)
                }
                ForEach($runtime.settings.shares) { $share in
                    Section {
                        VStack(alignment: .leading) {
                            Text(share.path).textSelection(.enabled)
                            if let mount = runtime.shareMounts[share.path] { Text(String(localized: "VM-Pfad: ") + mount).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if share.automatic == true { Text(String(localized: "Automatisch hinzugefügt")).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Toggle(String(localized: "Nur lesen"), isOn: $share.readOnly).disabled(runtime.running || runtime.busy).onChange(of: share.readOnly) { runtime.applyShares() }
                                Spacer()
                                Button(String(localized: "Finder")) { NSWorkspace.shared.open(URL(fileURLWithPath: share.path)) }
                                Button(String(localized: "Entfernen"), role: .destructive) { runtime.settings.shares.removeAll { $0.id == share.id }; runtime.applyShares() }.disabled(runtime.running || runtime.busy)
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
    private func engineConfirmation(_ title: String, _ message: String, action: @escaping @MainActor () async throws -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        alert.addButton(withTitle: String(localized: "Fortfahren"))
        if alert.runModal() == .alertSecondButtonReturn { runtime.perform(action) }
    }

    private static var developerCredit: AttributedString {
        var credit = AttributedString("Developed by Kevin Tobler - ")
        var website = AttributedString("www.kevintobler.ch")
        website.link = URL(string: "https://kevintobler.ch")
        credit.append(website)
        return credit
    }

    private var runtimeView: some View {
        Form {
            Section(String(localized: "App")) {
                LaunchAtLoginSettings()
                AppUpdateSettings()
                Button(String(localized: "App-Datenordner im Finder öffnen")) {
                    do {
                        try FileManager.default.createDirectory(at: RuntimeSettings.directory, withIntermediateDirectories: true)
                        guard NSWorkspace.shared.open(RuntimeSettings.directory) else { throw AppFailure(message: String(localized: "Der App-Datenordner konnte nicht geöffnet werden.")) }
                    } catch { runtime.error = error.localizedDescription }
                }
            }
            Section(String(localized: "Linux-VM")) {
                LabeledContent(String(localized: "Status"), value: runtime.state)
                Stepper(String(localized: "CPU-Kerne: \(runtime.settings.cpus)"), value: $runtime.settings.cpus, in: 1...runtime.maximumCPUCount).disabled(runtime.running || runtime.busy)
                Stepper(String(localized: "Arbeitsspeicher: \(runtime.settings.memoryGiB) GiB"), value: $runtime.settings.memoryGiB, in: 1...runtime.maximumMemoryGiB).disabled(runtime.running || runtime.busy)
                Stepper(String(localized: "Datendisk bei Ersterstellung: \(runtime.settings.dataGiB) GiB"), value: $runtime.settings.dataGiB, in: 8...1024, step: 8).disabled(runtime.running || runtime.busy)
                Button(String(localized: "Basisimage aktualisieren …")) {
                    engineConfirmation(
                        String(localized: "Basisimage aktualisieren?"),
                        String(localized: "Übernimmt das Basisimage aus dieser App. Die VM wird bei Bedarf gestoppt und vorher gesichert. Container, Images, Docker-Volumes und Mac-Freigaben bleiben erhalten. Eigene Änderungen am Linux-System werden ersetzt. Eine zuvor laufende VM wird danach wieder gestartet. Nach einem Docker-Upgrade können ältere Engine-Versionen die Docker-Daten möglicherweise nicht lesen; dafür die vollständige Sicherung vor dem Update verwenden.")) {
                            try await runtime.updateBaseImage()
                        }
                }.disabled(runtime.busy || runtime.commandRunning || runtime.engineMaintenance || runtime.starting || runtime.forceStopping)
                if runtime.baseImageUpdating { ProgressView() }
                if !runtime.baseImageStatus.isEmpty {
                    Text(runtime.baseImageStatus).font(.caption).textSelection(.enabled)
                }
                Text(String(localized: "Das Basisimage wird bei der Ersteinrichtung und bei jeder neuen App-Version vor dem VM-Start übernommen. Vorhandene VM-Daten werden vorher gesichert. Dabei wird auch die enthaltene Docker-Version übernommen. Eigene Änderungen am Linux-System werden ersetzt.")).font(.caption).foregroundStyle(.secondary)
                Button(String(localized: "Hart stoppen …"), role: .destructive) {
                    let alert = NSAlert(); alert.messageText = String(localized: "VM hart stoppen?"); alert.informativeText = String(localized: "Ungespeicherte Daten können verloren gehen."); alert.addButton(withTitle: String(localized: "Abbrechen")); alert.addButton(withTitle: String(localized: "Hart stoppen"))
                    if alert.runModal() == .alertSecondButtonReturn { runtime.perform { try await runtime.forceStop() } }
                }.disabled(!runtime.canForceStop)
            }
            Section(String(localized: "Docker Engine")) {
                LabeledContent(String(localized: "Installierte Version"), value: runtime.engineVersion)
                Button(String(localized: "Nach Docker-Updates suchen")) {
                    runtime.perform { try await runtime.checkEngineUpdate() }
                }.disabled(!runtime.running || runtime.busy || runtime.commandRunning)
                Button(String(localized: "Docker Engine aktualisieren …")) {
                    engineConfirmation(
                        String(localized: "Docker Engine aktualisieren?"),
                        String(localized: "Die VM wird für eine Sicherung beider Datenträger gestoppt. Danach werden Docker-Pakete aus dem Alpine-Repository aktualisiert und zuvor laufende Container gestartet. Die Sicherung benötigt zusätzlichen Speicher, sobald Daten verändert werden.")) {
                            try await runtime.updateEngine()
                        }
                }.disabled(!runtime.running || runtime.busy || runtime.commandRunning || !runtime.engineUpdateAvailable)
                Button(String(localized: "Auf den Stand vor dem Update zurücksetzen …")) {
                    engineConfirmation(
                        String(localized: "System und Docker-Daten zurücksetzen?"),
                        String(localized: "Die VM wird gestoppt. Systemdisk und Docker-Datendisk werden auf den Sicherungsstand zurückgesetzt. Spätere Änderungen an Containern, Images und Volumes sind danach nicht im aktiven Stand enthalten. Mac-Freigaben werden nicht zurückgesetzt.")) {
                            try await runtime.restoreEngineBackup()
                        }
                }.disabled(runtime.busy || runtime.commandRunning || !runtime.engineRecoveryAvailable)
                if runtime.engineMaintenance && !runtime.baseImageUpdating { ProgressView() }
                if !runtime.engineUpdateStatus.isEmpty {
                    Text(runtime.engineUpdateStatus).font(.caption).textSelection(.enabled)
                }
            }
            Section(String(localized: "Netzwerk")) {
                if runtime.nativeBridgeEnabled {
                Picker(String(localized: "Anbindung"), selection: $runtime.settings.bridgeID) {
                    Text(String(localized: "NAT – VM-Netzwerk mit Portweiterleitung")).tag("")
                    ForEach(runtime.interfaces, id: \.identifier) { interface in Text(String(localized: "Bridge: \(interface.localizedDisplayName ?? interface.identifier)")).tag(interface.identifier) }
                }.disabled(runtime.running || runtime.busy)
                Picker(String(localized: "IPv4-Konfiguration"), selection: Binding(
                    get: { runtime.effectiveNetworkConfiguration.ipv4ConfigurationMode },
                    set: { mode in
                        guard !runtime.effectiveBridgeID.isEmpty, !runtime.running, !runtime.busy else { return }
                        runtime.settings.networkConfiguration.ipv4ConfigurationMode = mode
                    }
                )) {
                    ForEach(VMIPv4Mode.allCases) { mode in Text(mode.title).tag(mode) }
                }.disabled(runtime.effectiveBridgeID.isEmpty || runtime.running || runtime.busy)
                .onChange(of: runtime.settings.networkConfiguration.ipv4ConfigurationMode) { _, _ in
                    if !runtime.running && !runtime.busy { runtime.settings.networkConfiguration.suggestIPv4Gateway() }
                }
                if !runtime.effectiveNetworkConfiguration.automatic {
                    TextField(String(localized: "IPv4-Adresse"), text: $runtime.settings.networkConfiguration.address, prompt: Text(String(localized: "z. B. 192.168.1.50")))
                        .disabled(runtime.running || runtime.busy)
                        .onChange(of: runtime.settings.networkConfiguration.address) { _, _ in
                            if !runtime.running && !runtime.busy { runtime.settings.networkConfiguration.suggestIPv4Gateway() }
                        }
                    Stepper(String(localized: "IPv4-Präfix: /\(runtime.settings.networkConfiguration.prefix)"), value: $runtime.settings.networkConfiguration.prefix, in: 1...30).disabled(runtime.running || runtime.busy)
                    TextField(String(localized: "IPv4-Gateway (optional)"), text: $runtime.settings.networkConfiguration.gateway, prompt: Text(String(localized: "z. B. 192.168.1.1"))).disabled(runtime.running || runtime.busy)
                    TextField(String(localized: "IPv4-DNS (optional)"), text: $runtime.settings.networkConfiguration.dns, prompt: Text(String(localized: "IPv4-Adressen, durch Komma getrennt"))).disabled(runtime.running || runtime.busy)
                    Text(String(localized: "Eine freie Adresse im Netz des Adapters wählen. Ein Gateway wird für IPv4-Ziele außerhalb des Subnetzes benötigt. Leeres DNS übernimmt die beim Start erhaltenen DNS-Server.")).font(.caption).foregroundStyle(.secondary)
                }
                } else {
                    LabeledContent(String(localized: "Anbindung")) {
                        Text(String(localized: "NAT – VM-Netzwerk mit Portweiterleitung"))
                    }
                    Text(String(localized: "Bridge ist bis zur Freigabe der Apple-Netzwerkberechtigung deaktiviert. Die VM verwendet NAT und DHCP.")).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(String(localized: "IPv6 für neue Container und Netzwerke"), isOn: Binding(
                    get: { runtime.settings.createsIPv6Containers },
                    set: { enabled in
                        runtime.settings.createsIPv6Containers = enabled
                        if enabled && runtime.settings.networkConfiguration.ipv6Configuration.mode == .disabled {
                            runtime.settings.networkConfiguration.ipv6Configuration.mode = .automatic
                        }
                    }
                )).toggleStyle(.switch).controlSize(.small).disabled(runtime.running || runtime.busy)
                if runtime.settings.createsIPv6Containers {
                    Picker(String(localized: "IPv6-Konfiguration"), selection: Binding(
                        get: { runtime.effectiveNetworkConfiguration.ipv6Configuration.mode },
                        set: { runtime.settings.networkConfiguration.ipv6Configuration.mode = $0 }
                    )) {
                        ForEach([VMIPv6Mode.automatic, .manual]) { mode in Text(mode.title).tag(mode) }
                    }.disabled(runtime.running || runtime.busy || runtime.effectiveBridgeID.isEmpty)
                    if !runtime.effectiveBridgeID.isEmpty && runtime.settings.networkConfiguration.ipv6Configuration.mode == .manual {
                        TextField(String(localized: "IPv6-Adresse"), text: $runtime.settings.networkConfiguration.ipv6Configuration.address).disabled(runtime.running || runtime.busy)
                        Stepper(String(localized: "IPv6-Präfix: /\(runtime.settings.networkConfiguration.ipv6Configuration.prefix)"), value: $runtime.settings.networkConfiguration.ipv6Configuration.prefix, in: 1...128).disabled(runtime.running || runtime.busy)
                        TextField(String(localized: "IPv6-Gateway (optional)"), text: $runtime.settings.networkConfiguration.ipv6Configuration.gateway).disabled(runtime.running || runtime.busy)
                        TextField(String(localized: "IPv6-DNS (optional)"), text: $runtime.settings.networkConfiguration.ipv6Configuration.dns).disabled(runtime.running || runtime.busy)
                    }
                    Text(String(localized: "IPv6 kann bei manchen Containern Verbindungsprobleme verursachen.")).font(.caption).foregroundStyle(.orange)
                }
                Text(String(localized: "Die Auswahl gilt nur für neue Container und Netzwerke. Bestehende werden nicht umgestellt. IPv6 benötigt ein geeignetes Netzwerk; Host-Netzwerke teilen die VM-Anbindung. Beim Deaktivieren bleiben bestehende IPv6-Verbindungen erhalten.")).font(.caption).foregroundStyle(.secondary)
                if runtime.effectiveBridgeID.isEmpty {
                    LabeledContent(String(localized: "Mac-IPv4")) { Text(runtime.macIPAddress ?? String(localized: "Nicht verfügbar")).textSelection(.enabled) }
                    if !runtime.macIPv6Addresses.isEmpty { LabeledContent(String(localized: "Mac-IPv6")) { Text(runtime.macIPv6Addresses.joined(separator: ", ")).textSelection(.enabled) } }
                }
                LabeledContent(String(localized: "Zugewiesene VM-IP")) { Text(runtime.assignedIP).textSelection(.enabled) }
                if runtime.running { Text(String(localized: "VM stoppen, um die Anbindung zu ändern.")).font(.caption).foregroundStyle(.secondary) }
                Text(runtime.effectiveBridgeID.isEmpty
                    ? String(localized: "Privates VM-Netzwerk über Virtualization.framework. Veröffentlichte TCP-Ports sind über die verfügbaren IPv4-Adressen des Macs erreichbar, sofern die Ports dort frei sind. Die VM-IP bleibt direkt erreichbar. Die ursprüngliche Client-IP bleibt bei der TCP-Weiterleitung nicht erhalten.")
                    : String(localized: "Direkte Bridge über Virtualization.framework. Die VM erhält eine eigene LAN-IP. Veröffentlichte Ports sind über die VM-IP erreichbar. Für diese Verbindung ist kein Netzwerkhelfer erforderlich.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(String(localized: "Werkzeuge")) {
                if let last = runtime.lastSynchronization {
                    LabeledContent(String(localized: "Letzte vollständige Aktualisierung")) { Text(last, style: .time) }
                }
                LabeledContent(String(localized: "Docker-Socket")) { Text(runtime.dockerPath).font(.caption).textSelection(.enabled) }
                Button(String(localized: "Gaststatus und IP-Adressen")) { runtime.perform { try await runtime.inspectGuest() } }.disabled(!runtime.running)
                Button(String(localized: "VM-Konsole anzeigen")) { runtime.details = (try? String(contentsOf: RuntimeSettings.directory.appendingPathComponent("console.log"), encoding: .utf8)) ?? String(localized: "Noch keine Konsole vorhanden.") }
                Picker(String(localized: "Terminal-Standard"), selection: $terminalSelection) {
                    Text("—").tag("")
                    ForEach(runtime.terminalContexts, id: \.self) { name in
                        Text(name == "desktop-linux" ? "Docker Desktop" : (name == "orbstack" ? "OrbStack" : (name == "macosdocker" ? "macOSDocker" : name))).tag(name)
                    }
                }
                HStack {
                    Button(String(localized: "Als Terminal-Standard verwenden")) {
                        runtime.perform { try await runtime.selectTerminalContext(terminalSelection) }
                    }.disabled(terminalSelection.isEmpty || runtime.commandRunning || runtime.busy)
                    Button(String(localized: "Aktualisieren")) {
                        runtime.perform { try await runtime.loadTerminalContexts(); terminalSelection = runtime.terminalContext }
                    }
                }
                Text(runtime.terminalStatus).font(.caption).foregroundStyle(.secondary)
                Text(String(localized: "Installierte Docker-Contexts werden angeboten. Die gewählte Runtime muss laufen. Neue Terminals verwenden die Auswahl; DOCKER_HOST, DOCKER_CONTEXT oder DOCKER_CONFIG können sie überschreiben. Die App verwaltet weiterhin ihre eigene VM.")).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .task {
                do { try await runtime.loadTerminalContexts(); terminalSelection = runtime.terminalContext }
                catch { runtime.terminalStatus = error.localizedDescription }
            }
    }
}

private struct DeleteRequest { let title: String; let endpoint: String; var containerID: String? = nil }

struct CreateResourceView: View {
    let kind: String
    @EnvironmentObject var runtime: RuntimeManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var image = "nginx:alpine"
    @State private var hostPort = "8080"
    @State private var containerPort = "80"
    @State private var network = "bridge"
    @State private var shareID = ""
    @State private var volumeName = ""
    @State private var networkCreation = NetworkCreation()
    @State private var target = "/usr/share/nginx/html"
    @State private var readOnly = true
    @State private var working = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppText.creationTitle(kind)).font(.title2.bold())
            Form {
                if kind != "Images" { TextField(String(localized: "Name"), text: $name) }
                if kind == "Images" || kind == "Container" { TextField(String(localized: "Image"), text: $image) }
                if kind == "Container" {
                    TextField(String(localized: "VM-Port (leer = keiner)"), text: $hostPort)
                    TextField(String(localized: "Container-Port TCP"), text: $containerPort)
                    Picker(String(localized: "Netzwerk"), selection: $network) { ForEach(runtime.networks) { item in Text(item.Name).tag(item.Name).disabled(!runtime.networkAvailable(item)) } }
                    Picker(String(localized: "Mac-Ordner"), selection: $shareID) { Text(String(localized: "Keiner")).tag(""); ForEach(runtime.settings.shares) { Text($0.path).tag($0.id.uuidString) } }.disabled(!volumeName.isEmpty)
                    Picker(String(localized: "Docker-Volume"), selection: $volumeName) { Text(String(localized: "Keines")).tag(""); ForEach(runtime.volumes) { Text($0.Name).tag($0.Name) } }.disabled(!shareID.isEmpty)
                    if !shareID.isEmpty || !volumeName.isEmpty { TextField(String(localized: "Pfad im Container"), text: $target); Toggle(String(localized: "Nur lesen"), isOn: $readOnly) }
                }
                if kind == "Netzwerke" {
                    Picker(String(localized: "Netzwerktreiber"), selection: $networkCreation.driver) {
                        ForEach(NetworkDriver.allCases) { driver in Text(verbatim: driver.rawValue).tag(driver).disabled(driver == .macvlan && !runtime.macvlanAvailable) }
                    }
                    if !runtime.macvlanAvailable {
                        Text(runtime.macvlanUnavailableReason)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(String(localized: "IPv6 aktivieren"), isOn: $networkCreation.ipv6Enabled).toggleStyle(.switch).controlSize(.small).disabled(!runtime.settings.createsIPv6Containers)
                    if networkCreation.ipv6Enabled && runtime.settings.createsIPv6Containers {
                        TextField(String(localized: "IPv6-Subnetz (CIDR, optional bei Bridge)"), text: $networkCreation.ipv6Subnet)
                        TextField(String(localized: "IPv6-Gateway (optional)"), text: $networkCreation.ipv6Gateway)
                        TextField(String(localized: "IPv6-IP-Bereich (optional)"), text: $networkCreation.ipv6Range)
                    }
                    TextField(String(localized: "IPv4-Subnetz (CIDR)"), text: $networkCreation.subnet, prompt: Text(verbatim: "192.168.111.0/24"))
                    TextField(String(localized: "Gateway (optional)"), text: $networkCreation.gateway)
                        .disabled(networkCreation.driver == .ipvlan && networkCreation.ipvlanMode != "l2")
                    TextField(String(localized: "IP-Bereich (CIDR, optional)"), text: $networkCreation.ipRange)
                    if networkCreation.driver == .bridge {
                        Text(String(localized: "Ohne Subnetz wählt Docker automatisch einen freien Bereich.")).font(.caption).foregroundStyle(.secondary)
                        Toggle(String(localized: "Internes Netzwerk ohne externen Zugriff"), isOn: $networkCreation.internalOnly)
                    } else {
                        TextField(String(localized: "Linux-Schnittstelle (Parent)"), text: $networkCreation.parent)
                        if networkCreation.driver == .ipvlan {
                            Picker(String(localized: "IPvlan-Modus"), selection: $networkCreation.ipvlanMode) {
                                Text(verbatim: "L2").tag("l2")
                                Text(verbatim: "L3").tag("l3")
                                Text(verbatim: "L3S").tag("l3s")
                            }
                        }
                        Text(String(localized: "eth0 ist der VM-Adapter. Für LAN-Adressen Ethernet-Bridge verwenden und einen reservierten IP-Bereich außerhalb des DHCP-Pools wählen.")).font(.caption).foregroundStyle(.secondary)
                        if networkCreation.driver == .ipvlan && networkCreation.ipvlanMode != "l2" {
                            Text(String(localized: "L3/L3S benötigt passende Routen im übergeordneten Netzwerk.")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(String(localized: "Abbrechen")) { dismiss() }.disabled(working)
                Button(working ? String(localized: "Bitte warten …") : String(localized: "Erstellen")) {
                    working = true
                    Task {
                        do { try await create(); dismiss() }
                        catch { self.error = error.localizedDescription }
                        working = false
                    }
                }.buttonStyle(.borderedProminent).disabled(working || (kind == "Netzwerke" && networkCreation.driver == .macvlan && !runtime.macvlanAvailable))
            }
        }.padding(24).frame(width: 560).onAppear { networkCreation.ipv6Enabled = runtime.settings.createsIPv6Containers }
    }
    private func create() async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind != "Images" {
            guard trimmed.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil else { throw AppFailure(message: String(localized: "Name: Buchstaben, Ziffern, Punkt, Unterstrich und Bindestrich verwenden.")) }
        }
        switch kind {
        case "Images": try await runtime.pull(image)
        case "Volumes": try await runtime.mutate("POST", "/volumes/create", object: ["Name": trimmed])
        case "Netzwerke":
            guard networkCreation.driver != .macvlan || runtime.macvlanAvailable else { throw AppFailure(message: String(localized: "Macvlan ist nur mit Bridge-Anbindung verfügbar.")) }
            try await runtime.mutate("POST", "/networks/create", object: try networkCreation.payload(name: trimmed))
        default:
            guard !runtime.networks.contains(where: { $0.Name == network && !runtime.networkAvailable($0) }) else { throw AppFailure(message: runtime.macvlanUnavailableReason) }
            var host: [String: Any] = ["NetworkMode": network]
            var exposed: [String: Any] = [:]
            if !hostPort.isEmpty {
                guard let external = Int(hostPort), let internalPort = Int(containerPort), (1...65535).contains(external), (1...65535).contains(internalPort) else { throw AppFailure(message: String(localized: "Ports müssen zwischen 1 und 65535 liegen.")) }
                host["PortBindings"] = ["\(internalPort)/tcp": [["HostPort": String(external), "HostIp": runtime.settings.createsIPv6Containers ? "" : "0.0.0.0"]]]
                exposed["\(internalPort)/tcp"] = [:] as [String: String]
            }
            if !shareID.isEmpty || !volumeName.isEmpty {
                guard target.hasPrefix("/"), target != "/" else { throw AppFailure(message: String(localized: "Container-Mount benötigt einen absoluten Pfad unterhalb von /.")) }
                if let share = runtime.settings.shares.first(where: { $0.id.uuidString == shareID }) {
                    try await runtime.synchronizeShares()
                    host["Mounts"] = [["Type": "bind", "Source": runtime.shareMounts[share.path] ?? share.path, "Target": target, "ReadOnly": readOnly || share.readOnly]]
                } else if !volumeName.isEmpty { host["Mounts"] = [["Type": "volume", "Source": volumeName, "Target": target, "ReadOnly": readOnly]] }
            }
            let body = try JSONSerialization.data(withJSONObject: ["Image": image, "HostConfig": host, "ExposedPorts": exposed])
            let response = try await runtime.api.request("POST", "/containers/create?name=\(trimmed)", body: body)
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any], let id = object["Id"] as? String else { throw AppFailure(message: String(localized: "Container-ID fehlt.")) }
            try await runtime.mutate("POST", "/containers/\(id)/start")
        }
    }
}
