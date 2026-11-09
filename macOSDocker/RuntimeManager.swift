import AppKit
import Combine
import Virtualization
import Darwin

@MainActor
final class RuntimeManager: NSObject, ObservableObject, VZVirtualMachineDelegate {
    lazy var backups = BackupController(runtime: self)
    @Published var settings = RuntimeSettings.load()
    @Published var state = String(localized: "Gestoppt")
    @Published var running = false
    @Published private(set) var automaticMacBindsAvailable = false
    @Published private(set) var macvlanPolicyAvailable = false
    var macvlanAvailable: Bool { !effectiveBridgeID.isEmpty && macvlanPolicyAvailable }
    func networkAvailable(_ network: DockerNetwork) -> Bool { network.Driver != "macvlan" || macvlanAvailable }
    var macvlanUnavailableReason: String {
        effectiveBridgeID.isEmpty ? String(localized: "Macvlan ist nur mit Bridge-Anbindung verfügbar.") : String(localized: "Für Macvlan bitte unter Runtime das Basisimage aktualisieren.")
    }
    @Published private(set) var stopping = false
    var canQueryDocker: Bool { running && !starting && !stopping && !forceStopping && !engineMaintenance }
    @Published private(set) var starting = false
    @Published private(set) var forceStopping = false
    private var startStopRequested = false
    private var bridgePromptTask: Task<Void, Never>?
    private var lastBridgePrompt = Date.distantPast
    var canForceStop: Bool { (running || starting || vm != nil) && !forceStopping }
    @Published private(set) var activeOperations = 0
    @Published var busy = false
    @Published var backupInProgress = false
    @Published var engineMaintenance = false
    @Published var engineVersion = "—"
    @Published var engineUpdateStatus = ""
    @Published var baseImageStatus = ""
    @Published var baseImageUpdating = false
    @Published var engineUpdateAvailable = false
    @Published var engineRecoveryAvailable = EngineRecovery.latest != nil
    @Published var error: String?
    @Published private(set) var shareMounts: [String: String] = [:]
    @Published var guestInfo = ""
    @Published private(set) var vmIPAddresses: [String] = []
    @Published private(set) var macIPAddress = HostNetwork.ipv4Address()
    @Published private(set) var forwardedTCPPorts = Set<UInt16>()
    @Published private(set) var forwardedIPv6TCPPorts = Set<UInt16>()
    @Published private(set) var macIPv6Addresses = HostNetwork.ipv6Addresses()
    @Published var assignedIP = String(localized: "VM ist gestoppt")
    @Published private(set) var containerActivities: [String: String] = [:]
    @Published var containers: [DockerContainer] = []
    @Published var images: [DockerImage] = []
    @Published var volumes: [DockerVolume] = []
    @Published var networks: [DockerNetwork] = []
    @Published var synchronizationError: String?
    private var consecutiveSynchronizationFailures = 0
    @Published var lastSynchronization: Date?
    @Published var dashboardVisible = false
    enum ContainerDetailMode { case output, summary, resources }
    @Published var containerDetailMode: ContainerDetailMode = .output
    @Published var containerSummary: Data?
    @Published var selectedContainerID: String?
    @Published private(set) var guestSummary: Data?
    @Published var inventorySummary: InventorySummary?
    @Published var details = "" {
        didSet {
            guestSummary = nil
            inventorySummary = nil
            containerSummary = nil
            containerDetailMode = .output
        }
    }
    @Published var terminalContexts: [String] = []
    @Published var terminalContext = ""
    @Published var terminalStatus = String(localized: "Context noch nicht eingerichtet.")
    @Published var commandRunning = false
    private var vm: VZVirtualMachine?
    private var relays: [SocketRelay] = []
    private let tcpForwarder = TCPPortForwarder()
    private let ipv6TCPForwarder = TCPPortForwarder()
    private var smbRelay: SocketRelay?
    private var volumeFinder = VolumeFinder()
    private let vmHostname = VMHostname()
    @Published private(set) var volumeMountBusy = false
    @Published private(set) var automaticVolumeErrors: [String: String] = [:]
    private var attemptedAutomaticVolumes = Set<String>()
    private var poll: Task<Void, Never>?
    private var terminalSetupTask: Task<Void, Never>?
    private var terminalMountServer: TerminalMountServer?
    private var guestMountServer: GuestMountServer?
    let macBindQueue = MacBindQueue()
    private var shutdownWaiter: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
    private var shutdownTimeout: Task<Void, Never>?
    private var logHandle: FileHandle?
    private var inputPipe: Pipe?
    private var generation = UUID()
    private var lockDescriptor: Int32 = -1
    private var exportedShares: [HostShare] = []
    private var multipleDirectorySharing = false
    private var sharedDirectories: [String: VZSharedDirectory] = [:]
    static var socketDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MACOSDOCKER_SOCKET_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".macosdocker")
    }
    var dockerPath: String { Self.socketDirectory.appendingPathComponent("docker.sock").path }
    var terminalMountPath: String { Self.socketDirectory.appendingPathComponent("terminal-mounts.sock").path }
    var controlPath: String { Self.socketDirectory.appendingPathComponent("control.sock").path }
    var api: SocketHTTP { SocketHTTP(path: dockerPath) }
    var control: SocketHTTP { SocketHTTP(path: controlPath) }
    func openVolumeInFinder(_ name: String) async throws {
        NSWorkspace.shared.open(try await mountVolume(name))
    }

    func mountVolume(_ name: String) async throws -> URL {
        guard running, !busy, !volumeMountBusy, let smbRelay else { throw CancellationError() }
        if !effectiveBridgeID.isEmpty && !vmIPAddresses.contains(where: { !$0.contains(":") }) {
            throw AppFailure(message: String(localized: "Noch keine Adresse zugewiesen"))
        }
        volumeMountBusy = true
        defer { volumeMountBusy = false }
        if !effectiveBridgeID.isEmpty {
            for _ in 0..<20 {
                if vmHostname.serviceHost != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        return try await volumeFinder.mount(name: name, control: control, port: smbRelay.port, bridgeAddress: effectiveBridgeID.isEmpty ? nil : vmIPAddresses.first(where: { !$0.contains(":") }), serviceHost: vmHostname.serviceHost)
    }

    func automaticallyMountsVolume(_ name: String) -> Bool {
        settings.automaticSMBVolumes?.contains(name) == true
    }

    func toggleAutomaticVolume(_ name: String) {
        var updated = settings
        var names = Set(updated.automaticSMBVolumes ?? [])
        if !names.insert(name).inserted { names.remove(name) }
        updated.automaticSMBVolumes = names.sorted()
        do {
            try updated.save()
            settings = updated
            attemptedAutomaticVolumes.remove(name)
            automaticVolumeErrors.removeValue(forKey: name)
            Task { await mountAutomaticVolumes() }
        } catch { self.error = error.localizedDescription }
    }

    private func mountAutomaticVolumes() async {
        guard running, !busy, !volumeMountBusy, !engineMaintenance else { return }
        let token = generation
        for name in (settings.automaticSMBVolumes ?? []).sorted() {
            guard token == generation, running, !busy, !volumeMountBusy else { return }
            guard automaticallyMountsVolume(name), !attemptedAutomaticVolumes.contains(name),
                  volumes.contains(where: { $0.Name == name && $0.Driver == "local" }) else { continue }
            attemptedAutomaticVolumes.insert(name)
            do { _ = try await mountVolume(name) }
            catch {
                guard token == generation else { return }
                automaticVolumeErrors[name] = error.localizedDescription
            }
        }
    }

    func renameVolume(_ source: String, to destination: String) async throws {
        try VolumeMigration.validate(source: source, destination: destination)
        guard running, !busy, !commandRunning else {
            throw AppFailure(message: String(localized: "Runtime ist beschäftigt oder gestoppt."))
        }
        busy = true
        defer { busy = false }
        let host = "unix://" + dockerPath
        func cli(_ arguments: [String]) async throws -> CLIResult {
            try await CLIProcess().run(arguments: arguments, host: host).checked()
        }
        func requireUnused() async throws {
            let result = try await cli(["ps", "--all", "--filter", "volume=" + source, "--format", "{{.Names}}"])
            let names = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard names.isEmpty else {
                throw AppFailure(message: String(localized: "Das Volume wird noch von folgenden Containern verwendet (auch gestoppte zählen):\n") + names)
            }
        }
        try await requireUnused()
        let inspection = try await cli(["volume", "inspect", source])
        guard let objects = try JSONSerialization.jsonObject(with: inspection.stdout) as? [[String: Any]],
              let volume = objects.first, volume["Driver"] as? String == "local",
              (volume["Options"] as? [String: String] ?? [:]).isEmpty,
              volume["Scope"] as? String == "local" else {
            throw AppFailure(message: String(localized: "Nur lokale Docker-Volumes ohne Treiberoptionen können migriert werden."))
        }
        func requireAvailableName() async throws {
            let result = try await cli(["volume", "ls", "--format", "{{.Name}}"])
            guard !String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").contains(Substring(destination)) else {
                throw AppFailure(message: String(localized: "Der neue Volume-Name existiert bereits."))
            }
        }
        try await requireAvailableName()
        if try await CLIProcess().run(arguments: ["image", "inspect", VolumeMigration.image], host: host).status != 0 {
            _ = try await cli(["image", "pull", VolumeMigration.image])
        }
        try await volumeFinder.disconnect(only: source)
        try await requireUnused()
        try await requireAvailableName()
        var create = ["volume", "create", "--driver", "local"]
        for (key, value) in (volume["Labels"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) {
            create += ["--label", key + "=" + value]
        }
        create.append(destination)
        _ = try await cli(create)
        let helper = "macosdocker-volume-migration-" + UUID().uuidString.lowercased()
        do {
            _ = try await cli(VolumeMigration.copyArguments(source: source, destination: destination, helper: helper))
            _ = try await cli(["container", "rm", helper])
            try await requireUnused()
            _ = try await cli(["volume", "rm", source])
        } catch {
            _ = try? await cli(["container", "rm", helper])
            try? await refresh()
            throw AppFailure(message: String(localized: "Migration nicht abgeschlossen. Das neue Volume bleibt zur Prüfung erhalten: ") + destination + "\n" + error.localizedDescription)
        }
        if automaticallyMountsVolume(source) {
            settings.automaticSMBVolumes = Array(Set((settings.automaticSMBVolumes ?? []).filter { $0 != source } + [destination])).sorted()
            try settings.save()
        }
        details = String(localized: "Volume erfolgreich migriert: ") + source + " → " + destination
        try? await refresh()
    }

    var maximumCPUCount: Int { min(RuntimeDefaults.maximumCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount) }
    var maximumMemoryGiB: Int { min(RuntimeDefaults.maximumMemoryGiB, max(1, Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize / (1024 * 1024 * 1024)))) }
    var nativeBridgeEnabled: Bool { NetworkPolicy.nativeBridgeEnabled }
    var effectiveBridgeID: String { NetworkPolicy.bridgeID(saved: settings.bridgeID) }
    var effectiveNetworkConfiguration: VMNetworkSettings {
        var network = effectiveBridgeID.isEmpty ? VMNetworkSettings() : NetworkPolicy.configuration(saved: settings.networkConfiguration)
        var ipv6 = settings.networkConfiguration.ipv6Configuration
        if !settings.createsIPv6Containers { ipv6.mode = .disabled }
        else if effectiveBridgeID.isEmpty || ipv6.mode == .disabled { ipv6.mode = .automatic }
        network.ipv6 = ipv6
        return network
    }
    var interfaces: [VZBridgedNetworkInterface] { nativeBridgeEnabled ? VZBridgedNetworkInterface.networkInterfaces : [] }
    var imageDirectory: URL { RuntimeSettings.directory.appendingPathComponent("image") }
    var readyToStart: Bool { true }

    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            activeOperations += 1
            defer { activeOperations -= 1 }
            do { try await action() } catch { self.presentOperationError(error) }
        }
    }

    func presentOperationError(_ failure: Error) {
        if failure.localizedDescription.contains("Macvlan requires Bridge mode") {
            requestBridgeActivation()
        } else {
            error = failure.localizedDescription
        }
    }

    func requestBridgeActivation() {
        guard effectiveBridgeID.isEmpty, running, bridgePromptTask == nil,
              Date().timeIntervalSince(lastBridgePrompt) > 5 else { return }
        bridgePromptTask = Task { [weak self] in
            guard let self else { return }
            defer { self.bridgePromptTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(500))
                while self.busy || self.commandRunning || self.activeOperations > 0 || self.engineMaintenance || self.backupInProgress || self.volumeMountBusy {
                    guard self.running, !Task.isCancelled else { return }
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard self.running, self.effectiveBridgeID.isEmpty else { return }
                let adapters = self.interfaces
                let alert = NSAlert()
                alert.messageText = String(localized: "Bridge für Macvlan verwenden?")
                if adapters.isEmpty {
                    alert.informativeText = String(localized: "Macvlan benötigt eine Bridge-Anbindung. Aktuell ist kein Bridge-Adapter verfügbar.")
                    alert.addButton(withTitle: String(localized: "OK"))
                    NSApp.activate(ignoringOtherApps: true)
                    self.lastBridgePrompt = Date()
                    alert.runModal()
                    self.lastBridgePrompt = Date()
                    return
                }
                alert.informativeText = String(localized: "Macvlan benötigt eine Bridge-Anbindung. Wähle einen Netzwerkadapter. Beim Wechsel wird die VM mit allen Containern gestoppt und neu gestartet. Danach den Container oder Befehl erneut starten.")
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
                for adapter in adapters { picker.addItem(withTitle: adapter.localizedDisplayName ?? adapter.identifier) }
                picker.selectItem(at: adapters.firstIndex(where: { $0.identifier == self.settings.bridgeID }) ?? adapters.firstIndex(where: { $0.localizedDisplayName?.localizedCaseInsensitiveContains("ethernet") == true }) ?? 0)
                picker.setAccessibilityLabel(String(localized: "Netzwerkadapter"))
                alert.accessoryView = picker
                alert.addButton(withTitle: String(localized: "Auf Bridge wechseln"))
                alert.addButton(withTitle: String(localized: "Abbrechen"))
                self.lastBridgePrompt = Date()
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                self.lastBridgePrompt = Date()
                guard response == .alertFirstButtonReturn else { return }
                let adapter = adapters[picker.indexOfSelectedItem].identifier
                guard self.running, !self.busy, !self.commandRunning, !self.engineMaintenance, !self.backupInProgress else {
                    throw AppFailure(message: String(localized: "Runtime ist beschäftigt oder gestoppt."))
                }
                self.activeOperations += 1
                defer { self.activeOperations -= 1 }
                try await self.stop()
                self.settings.bridgeID = adapter
                try self.settings.save()
                try await self.start()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func startOnLaunch() async throws {
        let initialSetup = !FileManager.default.fileExists(atPath: RuntimeSettings.directory.appendingPathComponent("data.raw").path)
        do { try await start() }
        catch {
            guard initialSetup, effectiveBridgeID.isEmpty, error.localizedDescription.contains("Guest networking did not become ready") else { throw error }
            state = String(localized: "NAT-Netzwerk noch nicht bereit. Einmaliger neuer Startversuch …")
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
            try await start()
        }
    }

    func start() async throws {
        guard vm == nil, !busy else { return }
        busy = true
        starting = true
        startStopRequested = false
        state = String(localized: "VM wird gestartet …")
        let token = UUID()
        generation = token
        var automaticImageBackup = false
        defer { busy = false; starting = false; forceStopping = false }
        do {
            try FileManager.default.createDirectory(at: RuntimeSettings.directory, withIntermediateDirectories: true)
            let descriptor = Darwin.open(RuntimeSettings.directory.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw AppFailure(message: String(localized: "Runtime-Sperre konnte nicht erstellt werden.")) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(descriptor)
                throw AppFailure(message: String(localized: "Diese Runtime wird bereits von einem anderen App-Prozess verwendet."))
            }
            lockDescriptor = descriptor
            await Task.detached(priority: .utility) { EngineRecovery.pruneWhileRuntimeLocked() }.value
            guard !startStopRequested, token == generation else { throw CancellationError() }
            settings.limitResources(maximumCPUs: maximumCPUCount, maximumMemoryGiB: maximumMemoryGiB)
            _ = try effectiveNetworkConfiguration.payload()
            try settings.save()
            try FileManager.default.createDirectory(at: Self.socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            automaticImageBackup = try await prepareBundledImageForStartup()
            guard !startStopRequested, token == generation else { throw CancellationError() }
            let configuration = VZVirtualMachineConfiguration()
            configuration.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(settings.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
            configuration.memorySize = UInt64(settings.memoryGiB) * 1024 * 1024 * 1024
            let loader = VZLinuxBootLoader(kernelURL: imageDirectory.appendingPathComponent("vmlinuz"))
            loader.initialRamdiskURL = imageDirectory.appendingPathComponent("initramfs")
            loader.commandLine = "console=hvc0 root=/dev/vda rw rootfstype=ext4 modules=virtio_pci,virtio_blk,ext4 ipv6.disable_ipv6=1 quiet"
            configuration.bootLoader = loader
            configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
            let system = try VZDiskImageStorageDeviceAttachment(url: imageDirectory.appendingPathComponent("system.raw"), readOnly: false)
            let dataURL = RuntimeSettings.directory.appendingPathComponent("data.raw")
            if !FileManager.default.fileExists(atPath: dataURL.path) {
                guard FileManager.default.createFile(atPath: dataURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AppFailure(message: String(localized: "Datendisk konnte nicht erstellt werden.")) }
                let handle = try FileHandle(forWritingTo: dataURL)
                try handle.truncate(atOffset: UInt64(settings.dataGiB) * 1024 * 1024 * 1024)
                try handle.close()
            }
            configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: system), VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: dataURL, readOnly: false))]
            let network = VZVirtioNetworkDeviceConfiguration()
            let macURL = RuntimeSettings.directory.appendingPathComponent("mac-address")
            if let saved = try? String(contentsOf: macURL, encoding: .utf8), let mac = VZMACAddress(string: saved) { network.macAddress = mac }
            else { network.macAddress = .randomLocallyAdministered(); try network.macAddress.string.write(to: macURL, atomically: true, encoding: .utf8) }
            if effectiveBridgeID.isEmpty { network.attachment = VZNATNetworkDeviceAttachment() }
            else {
                guard let interface = interfaces.first(where: { $0.identifier == effectiveBridgeID }) else {
                    throw AppFailure(message: String(localized: "Netzwerkschnittstelle nicht verfügbar."))
                }
                network.attachment = VZBridgedNetworkDeviceAttachment(interface: interface)
            }
            configuration.networkDevices = [network]
            configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
            multipleDirectorySharing = FileManager.default.fileExists(atPath: imageDirectory.appendingPathComponent("multiple-directory-sharing").path)
            if multipleDirectorySharing {
                let device = VZVirtioFileSystemDeviceConfiguration(tag: "macos")
                device.share = try multipleShare(settings.shares)
                configuration.directorySharingDevices = [device]
            } else {
                guard settings.shares.count <= 16 else { throw AppFailure(message: String(localized: "Für weitere Freigaben zuerst das Basisimage aktualisieren.")) }
                configuration.directorySharingDevices = try (0..<16).map { index in
                    let device = VZVirtioFileSystemDeviceConfiguration(tag: "macos\(index)")
                    if index < settings.shares.count { device.share = try singleShare(settings.shares[index]) }
                    return device
                }
            }
            exportedShares = settings.shares
            let logURL = RuntimeSettings.directory.appendingPathComponent("console.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            logHandle = try FileHandle(forWritingTo: logURL)
            inputPipe = Pipe()
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: inputPipe!.fileHandleForReading, fileHandleForWriting: logHandle!)
            configuration.serialPorts = [serial]
            try configuration.validate()
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = self
            vm = machine
            try await machine.start()
            guard !startStopRequested, token == generation else { throw CancellationError() }
            guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else { throw AppFailure(message: String(localized: "VirtioSocket fehlt.")) }
            let mountServer = GuestMountServer { [weak self] request in
                guard let self, self.generation == token, self.running, !self.startStopRequested else {
                    throw AppFailure(message: String(localized: "Runtime ist beschäftigt oder gestoppt."))
                }
                if request.requireBridge == true {
                    self.requestBridgeActivation()
                    return
                }
                _ = try await self.prepareMacBinds(request.binds, automaticallyShare: !self.engineMaintenance, generation: token)
            }
            device.setSocketListener(mountServer.listener, forPort: 2378)
            guestMountServer = mountServer
            for (path, port) in [(dockerPath, UInt32(2375)), (controlPath, UInt32(2376))] {
                let relay = SocketRelay(path: path)
                try relay.start { completion in
                    DispatchQueue.main.async {
                        device.connect(toPort: port) { result in
                            switch result { case .success(let connection): completion(connection); case .failure: completion(nil) }
                        }
                    }
                }
                relays.append(relay)
            }
            let smb = SocketRelay(loopback: true)
            try smb.start { completion in
                DispatchQueue.main.async {
                    device.connect(toPort: 2377) { result in
                        switch result { case .success(let connection): completion(connection); case .failure: completion(nil) }
                    }
                }
            }
            smbRelay = smb
            volumeFinder = VolumeFinder()
            state = String(localized: "Linux/Docker starten ...")
            var healthObject: [String: Any]?
            let guestDeadline = ProcessInfo.processInfo.systemUptime + 90
            while ProcessInfo.processInfo.systemUptime < guestDeadline {
                try Task.checkCancellation()
                guard !startStopRequested, token == generation else { throw CancellationError() }
                if let data = try? await control.request("GET", "/health", timeout: 2),
                   let health = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    guestInfo = prettyJSON(data)
                    healthObject = health
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            macvlanPolicyAvailable = healthObject?["macvlanPolicyVersion"] as? Int == 1
            automaticMacBindsAvailable = healthObject?["automaticMacBindsVersion"] as? Int == 1
            guard let healthObject else { throw AppFailure(message: String(localized: "Gastdienst nicht bereit. Bitte VM-Konsole prüfen.")) }
            guard healthObject["ipv6PolicyVersion"] as? Int == 1 else {
                throw AppFailure(message: String(localized: "Für diese App-Version bitte unter Runtime das Basisimage aktualisieren."))
            }
            guard !startStopRequested, token == generation else { throw CancellationError() }
            if healthObject["parallelStartupVersion"] as? Int == 1 {
                let network = try JSONSerialization.jsonObject(with: effectiveNetworkConfiguration.payload())
                let body = try JSONSerialization.data(withJSONObject: ["network": network, "shares": shareDefinitions, "bridge": !effectiveBridgeID.isEmpty])
                let mounted = try await control.request("POST", "/startup", body: body, timeout: 120)
                recordShareMounts(mounted)
            } else {
                if healthObject["networkConfigurationVersion"] as? Int == 1 {
                    _ = try await control.request("POST", "/network", body: effectiveNetworkConfiguration.payload(), timeout: 90)
                } else if !effectiveNetworkConfiguration.automatic {
                    throw AppFailure(message: String(localized: "Das installierte Linux-Image unterstützt feste IP-Adressen noch nicht. VM stoppen und unter Runtime das enthaltene Basisimage aktualisieren. Containerdaten bleiben erhalten."))
                }
                try await synchronizeShares()
            }
            guard !startStopRequested, token == generation else { throw CancellationError() }
            var dockerReady = false
            let dockerDeadline = ProcessInfo.processInfo.systemUptime + 30
            while ProcessInfo.processInfo.systemUptime < dockerDeadline {
                try Task.checkCancellation()
                guard !startStopRequested, token == generation else { throw CancellationError() }
                if (try? await api.request("GET", "/_ping", timeout: 2)) != nil { dockerReady = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard dockerReady else { throw AppFailure(message: String(localized: "Docker wurde nicht rechtzeitig bereit.")) }
            guard !startStopRequested, token == generation else { throw CancellationError() }
            let terminalServer = TerminalMountServer(path: terminalMountPath)
            try terminalServer.start { [weak self] request in
                guard let self, self.generation == token, self.running, !self.busy, !self.engineMaintenance, !self.commandRunning else {
                    throw AppFailure(message: String(localized: "Runtime ist beschäftigt oder gestoppt."))
                }
                self.commandRunning = true
                defer { self.commandRunning = false }
                _ = try await self.prepareMacBinds(request.binds, automaticallyShare: true)
            }
            terminalMountServer = terminalServer
            running = true
            state = String(localized: "Läuft")
            terminalSetupTask = Task { [weak self] in
                guard let self, self.generation == token else { return }
                do { try await self.installTerminalContext(makeDefault: false) }
                catch is CancellationError { return }
                catch {
                    guard self.generation == token else { return }
                    self.terminalStatus = error.localizedDescription
                }
            }
            guard !startStopRequested, token == generation else { throw CancellationError() }
            poll = Task { [weak self] in
                await InventoryPoller.run {
                    guard let self, self.generation == token, self.running else { throw CancellationError() }
                    if !self.engineMaintenance { try await self.refresh() }
                } onFailure: { _ in
                }
            }
        } catch {
            guard token == generation else { return }
            if forceStopping, vm?.state == .stopping { return }
            if let machine = vm, machine.canStop { try? await machine.stop() }
            cleanup()
            if startStopRequested {
                state = String(localized: "Gestoppt")
                return
            }
            state = String(localized: "Start fehlgeschlagen")
            if automaticImageBackup {
                let startupError = error
                do {
                    _ = try await Task.detached(priority: .utility) { try EngineRecovery.restore(kind: .baseImage) }.value
                } catch {
                    throw AppFailure(message: startupError.localizedDescription + "\n" + String(localized: "Die automatische Wiederherstellung ist fehlgeschlagen. Die Rückfallsicherung bleibt im App-Datenordner erhalten.") + "\n" + error.localizedDescription)
                }
                engineRecoveryAvailable = EngineRecovery.latest != nil
                throw AppFailure(message: startupError.localizedDescription + "\n" + String(localized: "Der Stand vor der automatischen Basisimage-Aktualisierung wurde wiederhergestellt."))
            }
            throw error
        }
    }

    func restart() async throws {
        guard running, !busy, !commandRunning else { return }
        try await stop()
        try Task.checkCancellation()
        try await start()
    }

    func stop() async throws {
        guard let machine = vm, !busy else { return }
        busy = true
        stopping = true
        synchronizationError = nil
        defer { busy = false }
        do { try await volumeFinder.disconnect() }
        catch { stopping = false; throw error }
        poll?.cancel()
        state = String(localized: "Wird heruntergefahren …")
        _ = try? await control.request("POST", "/shutdown", body: Data("{}".utf8), timeout: 5)
        let stopped = await waitForShutdown(machine)
        try Task.checkCancellation()
        if stopped {
            if vm === machine { cleanup() }
            state = String(localized: "Gestoppt")
            return
        }
        state = String(localized: "Herunterfahren dauert länger")
        throw AppFailure(message: String(localized: "Linux fährt noch herunter. Konsole prüfen oder ausdrücklich hart stoppen."))
    }

    private func waitForShutdown(_ machine: VZVirtualMachine) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if vm !== machine || machine.state == .stopped {
                    continuation.resume(returning: true)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    shutdownWaiter = (id, continuation)
                    shutdownTimeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(40)) }
                        catch { return }
                        self?.finishShutdownWait(stopped: false, id: id)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishShutdownWait(stopped: false, id: id) }
        }
    }

    private func finishShutdownWait(stopped: Bool, id: UUID? = nil) {
        guard let waiter = shutdownWaiter, id == nil || id == waiter.id else { return }
        shutdownWaiter = nil
        shutdownTimeout?.cancel()
        shutdownTimeout = nil
        waiter.continuation.resume(returning: stopped)
    }

    func forceStop() async throws {
        guard canForceStop else { return }
        if starting { startStopRequested = true }
        forceStopping = true
        defer { if !starting { forceStopping = false } }
        guard let machine = vm, machine.canStop else { return }
        do {
            try await machine.stop()
        } catch {
            forceStopping = false
            throw error
        }
        cleanup()
        state = String(localized: "Gestoppt")
    }
    private func cleanup() {
        finishShutdownWait(stopped: true)
        tcpForwarder.stop()
        ipv6TCPForwarder.stop()
        forwardedTCPPorts = []
        forwardedIPv6TCPPorts = []
        macvlanPolicyAvailable = false
        vmHostname.stop()
        volumeFinder.stop()
        smbRelay?.stop(); smbRelay = nil
        generation = UUID()
        poll?.cancel(); poll = nil
        terminalSetupTask?.cancel(); terminalSetupTask = nil
        terminalMountServer?.stop(); terminalMountServer = nil
        guestMountServer?.stop(); guestMountServer = nil
        automaticMacBindsAvailable = false
        relays.forEach { $0.stop() }; relays.removeAll()
        vm = nil; running = false; stopping = false
        vmIPAddresses = []
        assignedIP = String(localized: "VM ist gestoppt")
        exportedShares.removeAll()
        sharedDirectories.removeAll()
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); Darwin.close(lockDescriptor); lockDescriptor = -1 }
        try? logHandle?.close(); logHandle = nil; inputPipe = nil
        containers = []; images = []; volumes = []; networks = []
        attemptedAutomaticVolumes.removeAll(); automaticVolumeErrors.removeAll()
        consecutiveSynchronizationFailures = 0
        synchronizationError = nil; lastSynchronization = nil
    }
    func guestDidStop(_ virtualMachine: VZVirtualMachine) { guard vm === virtualMachine else { return }; cleanup(); state = String(localized: "Gestoppt") }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { guard vm === virtualMachine else { return }; cleanup(); state = String(localized: "VM-Fehler"); self.error = error.localizedDescription }

    func validateMountGeneration(_ token: UUID) throws {
        guard generation == token, running, !startStopRequested, vm?.state == .running else {
            throw AppFailure(message: String(localized: "Runtime ist beschäftigt oder gestoppt."))
        }
    }

    private func singleShare(_ share: HostShare) throws -> VZSingleDirectoryShare {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: share.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AppFailure(message: String(localized: "Freigabe fehlt: \(share.path)")) }
        return VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: share.path), readOnly: share.readOnly))
    }
    private func multipleShare(_ shares: [HostShare]) throws -> VZMultipleDirectoryShare {
        var directories: [String: VZSharedDirectory] = [:]
        for share in shares {
            if let directory = sharedDirectories[share.key] { directories[share.key] = directory }
            else { directories[share.key] = try singleShare(share).directory }
        }
        sharedDirectories = directories
        return VZMultipleDirectoryShare(directories: directories)
    }
    private var shareDefinitions: [[String: Any]] {
        settings.shares.enumerated().map {
            var definition: [String: Any] = ["key": $0.element.key, "tag": multipleDirectorySharing ? "macos" : "macos\($0.offset)", "path": $0.element.path, "readonly": $0.element.readOnly]
            if multipleDirectorySharing { definition["directory"] = $0.element.key }
            return definition
        }
    }

    private func recordShareMounts(_ data: Data) {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entries = body["mounted"] as? [[String: Any]] else { return }
        shareMounts = Dictionary(entries.compactMap { item in
            guard let path = item["path"] as? String, let mount = item["mount"] as? String else { return nil }
            return (path, mount)
        }, uniquingKeysWith: { _, latest in latest })
    }

    func synchronizeShares() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["shares": shareDefinitions])
        let mounted = try await control.request("POST", "/shares", body: body)
        recordShareMounts(mounted)
    }
    func addShare() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), path != "/" else { error = String(localized: "Bitte einen Mac-Ordner unterhalb des Root-Verzeichnisses auswählen."); return }
        guard !settings.shares.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") || $0.path.hasPrefix(path + "/") }) else { error = String(localized: "Dieser Ordner überschneidet sich mit einer bestehenden Freigabe."); return }
        settings.shares.append(HostShare(path: path))
        applyShares()
    }
    func setAutomaticMacPaths(_ enabled: Bool, root: String) {
        guard !running, !busy, !engineMaintenance, ["/Users", "/Volumes"].contains(root) else { return }
        settings.setAutomaticSharing(enabled, root: root)
        applyShares()
    }
    func applyShares() { perform { try await self.updateShares() } }
    func updateShares() async throws {
        if let machine = vm {
            guard settings.shares.starts(with: exportedShares) else { throw AppFailure(message: String(localized: "Bestehende Freigaben erst bei gestoppter VM verändern.")) }
            if multipleDirectorySharing {
                guard let device = machine.directorySharingDevices.first as? VZVirtioFileSystemDevice else { throw AppFailure(message: String(localized: "VirtioFS-Gerät fehlt.")) }
                device.share = try multipleShare(settings.shares)
            } else {
                guard settings.shares.count <= machine.directorySharingDevices.count else { throw AppFailure(message: String(localized: "Für weitere Freigaben zuerst das Basisimage aktualisieren.")) }
                for index in exportedShares.count..<settings.shares.count {
                    guard let device = machine.directorySharingDevices[index] as? VZVirtioFileSystemDevice else { throw AppFailure(message: String(localized: "VirtioFS-Gerät fehlt.")) }
                    device.share = try singleShare(settings.shares[index])
                }
            }
            exportedShares = settings.shares
            try await synchronizeShares()
        } else {
            for share in settings.shares { _ = try singleShare(share) }
        }
        try settings.save()
    }
    private func inventoryResponse(_ endpoint: String) async -> Result<Data, Error> {
        do { return .success(try await api.request("GET", endpoint, timeout: 8)) }
        catch { return .failure(error) }
    }
    func refresh() async throws {
        let ipv6Addresses = HostNetwork.ipv6Addresses()
        if macIPv6Addresses != ipv6Addresses { macIPv6Addresses = ipv6Addresses }
        let address = HostNetwork.ipv4Address()
        if macIPAddress != address { macIPAddress = address }
        let token = generation
        async let c = inventoryResponse("/containers/json?all=1")
        async let i = inventoryResponse("/images/json")
        async let v = inventoryResponse("/volumes")
        async let n = inventoryResponse("/networks")
        async let h = control.request("GET", "/health", timeout: 5)
        let health = try? await h
        let values = await (c, i, v, n)
        try Task.checkCancellation()
        guard generation == token, !stopping, !forceStopping else { throw CancellationError() }
        if let health, let object = try? JSONSerialization.jsonObject(with: health) as? [String: Any], let addresses = object["addresses"] as? [[String: Any]] {
            let ips = addresses.filter { $0["ifname"] as? String == "eth0" }.flatMap { $0["addr_info"] as? [[String: Any]] ?? [] }.filter { $0["scope"] as? String == "global" && ["inet", "inet6"].contains($0["family"] as? String ?? "") }.compactMap { $0["local"] as? String }
            vmIPAddresses = ips
            assignedIP = ips.isEmpty ? String(localized: "Noch keine Adresse zugewiesen") : ips.joined(separator: ", ")
        } else { vmIPAddresses = []; assignedIP = String(localized: "Adresse derzeit nicht abrufbar") }
        vmHostname.update(address: effectiveBridgeID.isEmpty ? nil : vmIPAddresses.first(where: { !$0.contains(":") }), interface: effectiveBridgeID)
        let decoder = JSONDecoder()
        var failures: [String] = []
        do { containers = StableInventory.merge(previous: containers, incoming: try decoder.decode([DockerContainer].self, from: values.0.get()), name: { $0.name }) }
        catch { failures.append(String(localized: "Container: ") + error.localizedDescription) }
        do { images = StableInventory.merge(previous: images, incoming: try decoder.decode([DockerImage].self, from: values.1.get()), name: { $0.name }) }
        catch { failures.append(String(localized: "Images: ") + error.localizedDescription) }
        do { volumes = StableInventory.merge(previous: volumes, incoming: try decoder.decode(VolumeList.self, from: values.2.get()).Volumes ?? [], name: { $0.Name }) }
        catch { failures.append(String(localized: "Volumes: ") + error.localizedDescription) }
        do { networks = StableInventory.merge(previous: networks, incoming: try decoder.decode([DockerNetwork].self, from: values.3.get()), name: { $0.Name }) }
        catch { failures.append(String(localized: "Netzwerke: ") + error.localizedDescription) }
        if effectiveBridgeID.isEmpty, let host = vmIPAddresses.first(where: { !$0.contains(":") }) {
            var ports = Set<UInt16>()
            var ipv6Ports = Set<UInt16>()
            for container in containers where container.State == "running" {
                for binding in container.Ports ?? [] {
                    let ip = binding.IP ?? ""
                    guard binding.Type == "tcp", ip.isEmpty || ip == "0.0.0.0" || ip == host,
                          let published = binding.PublicPort, let port = UInt16(exactly: published), port > 0 else { continue }
                    ports.insert(port)
                    if container.Labels?["com.macosdocker.ipv6"] == "enabled" { ipv6Ports.insert(port) }
                }
            }
            tcpForwarder.update(host: host, ports: ports) { [weak self] available in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.effectiveBridgeID.isEmpty else { return }
                    if self.forwardedTCPPorts != available { self.forwardedTCPPorts = available }
                }
            }
            ipv6TCPForwarder.update(host: host, ports: ipv6Ports, bindAddress: "::") { [weak self] available in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.effectiveBridgeID.isEmpty else { return }
                    if self.forwardedIPv6TCPPorts != available { self.forwardedIPv6TCPPorts = available }
                }
            }
        } else if !effectiveBridgeID.isEmpty {
            tcpForwarder.stop()
            ipv6TCPForwarder.stop()
            forwardedTCPPorts = []
            forwardedIPv6TCPPorts = []
        }
        if failures.isEmpty {
            consecutiveSynchronizationFailures = 0
            synchronizationError = nil
            lastSynchronization = Date()
        } else {
            let message = failures.joined(separator: "\n")
            consecutiveSynchronizationFailures = min(consecutiveSynchronizationFailures + 1, 2)
            if consecutiveSynchronizationFailures >= 2 { synchronizationError = message }
            throw AppFailure(message: message)
        }
        await mountAutomaticVolumes()
    }
    private func refreshAfterMutation() async {
        do { try await refresh() }
        catch is CancellationError { return }
        catch { /* refresh() retains the affected lists and sets synchronizationError. */ }
    }

    func deleteContainer(_ id: String) async throws {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let endpoint = "/containers/" + id
        let data = try await api.request("GET", endpoint + "/json")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let state = object?["State"] as? [String: Any]
        if state?["Paused"] as? Bool == true {
            _ = try await api.request("POST", endpoint + "/unpause")
        }
        _ = try await api.request("POST", endpoint + "/stop", timeout: 45, acceptedStatuses: [304])
        _ = try await api.request("DELETE", endpoint)
        await refreshAfterMutation()
    }

    func mutate(_ method: String, _ endpoint: String, object: [String: Any]? = nil) async throws {
        let parts = endpoint.split(separator: "/")
        var activityID: String?
        if method == "POST", parts.count == 3, parts[0] == "containers" {
            let id = String(parts[1])
            let action = parts[2].split(separator: "?").first.map(String.init)
            let title: String?
            switch action {
            case "restart": title = String(localized: "Wird neu gestartet …")
            case "start": title = String(localized: "Wird gestartet …")
            case "stop": title = String(localized: "Wird gestoppt …")
            default: title = nil
            }
            if let title {
                guard containerActivities[id] == nil else { return }
                containerActivities[id] = title
                activityID = id
            }
        }
        defer { if let activityID { containerActivities.removeValue(forKey: activityID) } }
        if method == "DELETE", endpoint.hasPrefix("/volumes/") {
            let name = String(endpoint.dropFirst("/volumes/".count).split(separator: "?").first ?? "")
            try await volumeFinder.disconnect(only: name.removingPercentEncoding ?? name)
        }
        let body = try object.map { try JSONSerialization.data(withJSONObject: $0) }
        _ = try await api.request(method, endpoint, body: body, timeout: 45)
        if let completedID = activityID {
            let token = generation
            do {
                let data = try await api.request("GET", "/containers/json?all=1", timeout: 5)
                let incoming = try JSONDecoder().decode([DockerContainer].self, from: data)
                if generation == token {
                    containers = StableInventory.merge(previous: containers, incoming: incoming, name: { $0.name })
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch { }
            containerActivities.removeValue(forKey: completedID)
            activityID = nil
        }
        if method == "DELETE", endpoint.hasPrefix("/volumes/") {
            let name = String(endpoint.dropFirst("/volumes/".count).split(separator: "?").first ?? "")
            let decoded = name.removingPercentEncoding ?? name
            if automaticallyMountsVolume(decoded) {
                settings.automaticSMBVolumes?.removeAll { $0 == decoded }
                try settings.save()
            }
        }
        await refreshAfterMutation()
    }
    func inspectGuest() async throws {
        let data = try await control.request("GET", "/health", timeout: 5)
        details = prettyJSON(data)
        guestSummary = data
    }
    func inspect(_ endpoint: String) async throws {
        let parts = endpoint.split(separator: "/")
        let id = parts.first == "containers" && parts.count > 1 ? String(parts[1]) : nil
        selectedContainerID = id
        containerSummary = nil
        containerDetailMode = id == nil ? .output : (endpoint.contains("/stats?") ? .resources : .summary)
        let mode = containerDetailMode
        let data = try await api.request("GET", endpoint)
        guard selectedContainerID == id, containerDetailMode == mode else { return }
        details = prettyJSON(data)
        containerDetailMode = mode
        if mode == .summary { containerSummary = data }
        if parts.first == "images" { inventorySummary = InventorySummary(section: "Images", data: data) }
        if parts.first == "networks" { inventorySummary = InventorySummary(section: "Netzwerke", data: data) }
    }
    func logs(_ id: String) async throws {
        selectedContainerID = id
        containerDetailMode = .output
        containerSummary = nil
        let data = try await api.request("GET", "/containers/\(id)/logs?stdout=1&stderr=1&tail=500&timestamps=1")
        var output = Data(); var offset = 0
        while offset + 8 <= data.count && data[offset] <= 2 && data[offset+1] == 0 && data[offset+2] == 0 && data[offset+3] == 0 {
            let length = (4..<8).reduce(0) { ($0 << 8) | Int(data[offset+$1]) }
            guard offset + 8 + length <= data.count else { break }
            output.append(data[(offset+8)..<(offset+8+length)]); offset += 8+length
        }
        details = String(decoding: offset == data.count ? output : data, as: UTF8.self)
    }
    func pull(_ image: String) async throws {
        let encoded = image.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let data = try await api.request("POST", "/images/create?fromImage=\(encoded)", timeout: 600)
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let message = object["error"] as? String { throw AppFailure(message: message) }
        }
        details = String(decoding: data, as: UTF8.self)
        try await refresh()
    }
    func terminal(_ container: DockerContainer? = nil) throws {
        try openDockerTerminal(arguments: container.map { ["exec", "-it", $0.id, "/bin/sh"] })
    }
}
