import AppKit
import Combine
import QuartzCore

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let identity = "com.macOSDocker.status-item"
    private let runtime: RuntimeManager
    private let openDashboard: () -> Void
    private let statusItem: NSStatusItem
    let menu = NSMenu(title: "macOSDocker")
    private var tracking = false
    private var liveTimer: Timer?
    private var vmStatusItem: NSMenuItem?
    private var actionInFlight = false { didSet { updateBlinking() } }
    private var runtimeWorking = false
    private var terminating = false
    private var activitySubscription: AnyCancellable?
    private(set) var isBlinking = false

    init(runtime: RuntimeManager, openDashboard: @escaping () -> Void) {
        self.runtime = runtime
        self.openDashboard = openDashboard
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.autosaveName = Self.identity
        statusItem.behavior = []
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "macOSDocker")
            button.image?.isTemplate = true
            button.toolTip = "macOSDocker"
            button.setAccessibilityIdentifier(Self.identity)
            button.setAccessibilityLabel("macOSDocker")
            button.setAccessibilityTitle("macOSDocker")
        }
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        activitySubscription = Publishers.CombineLatest3(runtime.$busy, runtime.$commandRunning, runtime.$engineMaintenance)
            .map { busy, command, maintenance in busy || command || maintenance }
            .combineLatest(runtime.$activeOperations)
            .map { flags, operations in flags || operations > 0 }
            .combineLatest(runtime.$backupInProgress)
            .map { activity, backup in activity || backup }
            .removeDuplicates()
            .sink { [weak self] working in
                self?.runtimeWorking = working
                self?.updateBlinking()
            }
    }

    func setTerminating(_ value: Bool) {
        terminating = value
        updateBlinking()
    }
    private func updateBlinking() {
        let working = runtimeWorking || actionInFlight || terminating
        guard working != isBlinking else { return }
        isBlinking = working
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        layer.removeAnimation(forKey: "macOSDocker.activityPulse")
        button.alphaValue = 1
        guard working else { return }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [1, 0.3, 1]
        opacity.keyTimes = [0, 0.5, 1]
        opacity.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut),
                                   CAMediaTimingFunction(name: .easeInEaseOut)]
        opacity.duration = 1.1
        opacity.repeatCount = .infinity
        layer.add(opacity, forKey: "macOSDocker.activityPulse")
    }

    private var canOperate: Bool {
        !actionInFlight && !runtime.busy && !runtime.commandRunning && !runtime.engineMaintenance
    }
    private func item(_ title: String, action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }
    func menuWillOpen(_ menu: NSMenu) {
        tracking = true
        liveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, target: self, selector: #selector(updateOpenMenu), userInfo: nil, repeats: true)
        liveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        updateOpenMenu()
    }
    func menuDidClose(_ menu: NSMenu) {
        tracking = false
        liveTimer?.invalidate()
        liveTimer = nil
    }
    @objc private func updateOpenMenu() {
        guard tracking else { return }
        if vmStatusItem?.title != runtime.state { vmStatusItem?.title = runtime.state }
        for entry in menu.items {
            switch entry.action {
            case #selector(startVM): entry.isEnabled = canOperate && !runtime.running
            case #selector(stopVM), #selector(restartVM): entry.isEnabled = canOperate && runtime.running
            case #selector(checkAppUpdates): entry.isEnabled = !AppUpdateController.shared.checking
            case #selector(quitApp): entry.isEnabled = canOperate && !runtime.backupInProgress
            default: break
            }
            guard let id = entry.representedObject as? String, let submenu = entry.submenu else { continue }
            guard let container = runtime.containers.first(where: { $0.id == id }) else {
                entry.isEnabled = false
                for child in submenu.items { child.isEnabled = false }
                continue
            }
            let status = runtime.containerActivities[id] ?? AppText.containerState(container.State)
            let title = container.name + " — " + status
            if entry.title != title { entry.title = title }
            entry.toolTip = container.Status
            let fresh = containerMenu(container)
            for child in submenu.items where !child.isSeparatorItem {
                let candidate = fresh.items.first { other in
                    guard child.action == other.action else { return false }
                    if child.action == #selector(copyValue(_:)) || child.action == #selector(openContainerPort(_:)) {
                        return child.title == other.title
                    }
                    return true
                }
                child.isEnabled = candidate?.isEnabled ?? false
                if let candidate { child.representedObject = candidate.representedObject }
            }
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !tracking else { return }
        menu.removeAllItems()
        _ = item("macOSDocker", action: nil, enabled: false)
        _ = item(String(localized: "Dashboard öffnen"), action: #selector(showDashboard))
        menu.addItem(.separator())
        vmStatusItem = item(runtime.state, action: nil, enabled: false)
        _ = item(String(localized: "VM starten"), action: #selector(startVM), enabled: canOperate && !runtime.running)
        _ = item(String(localized: "VM stoppen"), action: #selector(stopVM), enabled: canOperate && runtime.running)
        _ = item(String(localized: "VM neu starten"), action: #selector(restartVM), enabled: canOperate && runtime.running)
        menu.addItem(.separator())
        _ = item(String(localized: "Laufende Container"), action: nil, enabled: false)
        let containers = runtime.containers.filter { $0.State == "running" }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        if containers.isEmpty {
            _ = item(String(localized: "Keine laufenden Container"), action: nil, enabled: false)
        } else {
            for container in containers {
                let row = item(container.name + " — " + AppText.containerState(container.State), action: nil)
                row.representedObject = container.id
                row.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
                row.submenu = containerMenu(container)
            }
        }
        menu.addItem(.separator())
        _ = item(String(localized: "Gestoppte Container"), action: nil, enabled: false)
        let inactive = runtime.containers.filter { $0.State != "running" }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        if inactive.isEmpty {
            _ = item(String(localized: "Keine gestoppten Container"), action: nil, enabled: false)
        }
        for container in inactive {
            let row = item(container.name + " — " + AppText.containerState(container.State), action: nil)
                row.representedObject = container.id
            row.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
            row.toolTip = AppText.containerState(container.State)
            row.submenu = containerMenu(container)
        }
        menu.addItem(.separator())
        _ = item(String(localized: "Nach App-Updates suchen …"), action: #selector(checkAppUpdates), enabled: !AppUpdateController.shared.checking)
        _ = item(String(localized: "macOSDocker beenden"), action: #selector(quitApp), enabled: canOperate && !runtime.backupInProgress)
    }
    private func containerMenu(_ container: DockerContainer) -> NSMenu {
        let submenu = NSMenu(title: container.name)
        submenu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, _ action: Selector?, enabled: Bool = true, value: Any? = nil) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            entry.isEnabled = enabled
            entry.representedObject = value ?? container.id
            submenu.addItem(entry)
        }
        let active = container.State == "running"
        let allowed = canOperate && runtime.running && runtime.containerActivities[container.id] == nil
        add(String(localized: "Start"), "play.fill", #selector(startContainer(_:)),
            enabled: allowed && ["created", "exited"].contains(container.State))
        add(String(localized: "Stop"), "stop.fill", #selector(stopContainer(_:)), enabled: allowed && active)
        add(String(localized: "Restart"), "arrow.clockwise", #selector(restartContainer(_:)), enabled: allowed && active)
        add(String(localized: "Löschen …"), "trash", #selector(deleteContainer(_:)), enabled: allowed)
        submenu.addItem(.separator())
        add(String(localized: "Logs"), "doc.text", #selector(containerLogs(_:)), enabled: allowed)
        add(String(localized: "Terminal"), "terminal", #selector(containerTerminal(_:)), enabled: allowed && active)
        add(String(localized: "Details, Ports und Mounts"), "info.circle", #selector(showContainer(_:)))
        add(String(localized: "Ressourcenverbrauch"), "gauge.with.dots.needle.50percent", #selector(containerStats(_:)), enabled: allowed && active)
        submenu.addItem(.separator())
        add("ID: " + String(container.id.prefix(12)), "document.on.document", #selector(copyValue(_:)), value: container.id)
        add("Image: " + container.Image, "document.on.document", #selector(copyValue(_:)), value: container.Image)
        let ports = DockerPort.publishedTCP(container.Ports ?? [])
        if !ports.isEmpty {
            submenu.addItem(.separator())
            for port in ports {
                add(port.label, "arrow.up.right.square", #selector(openContainerPort(_:)),
                    enabled: allowed && active && port.browserCapable,
                    value: PortSelection(containerID: container.id, port: port))
            }
        }
        let mounts = (container.Mounts ?? []).sorted { $0.Destination < $1.Destination }
        if !mounts.isEmpty {
            submenu.addItem(.separator())
            for mount in mounts {
                add(mount.Destination, "folder", #selector(copyValue(_:)), value: mount.Destination)
                submenu.items.last?.toolTip = mount.Source
            }
        }
        return submenu
    }
    private func selectedContainer(_ sender: NSMenuItem) -> DockerContainer? {
        guard canOperate, runtime.running, let id = sender.representedObject as? String else { return nil }
        guard runtime.containerActivities[id] == nil else { return nil }
        return runtime.containers.first { $0.id == id }
    }
    @objc private func startContainer(_ sender: NSMenuItem) {
        guard let container = selectedContainer(sender), ["created", "exited"].contains(container.State) else { return }
        operate { try await self.runtime.mutate("POST", "/containers/" + container.id + "/start") }
    }
    @objc private func stopContainer(_ sender: NSMenuItem) {
        guard let container = selectedContainer(sender) else { return }
        operate { try await self.runtime.mutate("POST", "/containers/" + container.id + "/stop") }
    }
    @objc private func restartContainer(_ sender: NSMenuItem) {
        guard let container = selectedContainer(sender) else { return }
        operate { try await self.runtime.mutate("POST", "/containers/" + container.id + "/restart") }
    }
    @objc private func deleteContainer(_ sender: NSMenuItem) {
        guard let container = selectedContainer(sender) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Container \(container.name) löschen? Falls er läuft, wird er zuerst gestoppt.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Löschen"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        operate { try await self.runtime.deleteContainer(container.id) }
    }
    @objc private func containerLogs(_ sender: NSMenuItem) {
        guard let container = selectedContainer(sender) else { return }
        openDashboard()
        operate { try await self.runtime.logs(container.id) }
    }
    @objc private func containerStats(_ sender: NSMenuItem) {
        guard let container = selectedContainer(sender) else { return }
        openDashboard()
        operate { try await self.runtime.inspect("/containers/" + container.id + "/stats?stream=false&one-shot=true") }
    }
    @objc private func containerTerminal(_ sender: NSMenuItem) {
        guard let container = selectedContainer(sender), container.State == "running" else { return }
        operate { try self.runtime.terminal(container) }
    }
    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    private struct PortSelection {
        let containerID: String
        let port: DockerPort
    }
    @objc private func openContainerPort(_ sender: NSMenuItem) {
        guard runtime.running, !runtime.busy, !runtime.engineMaintenance,
              let selection = sender.representedObject as? PortSelection,
              let container = runtime.containers.first(where: { $0.id == selection.containerID && $0.State == "running" }),
              (container.Ports ?? []).contains(selection.port) else { NSSound.beep(); return }
        runtime.perform { try await self.runtime.openPort(selection.port) }
    }
    @objc private func showDashboard() { openDashboard() }
    @objc private func showContainer(_ sender: NSMenuItem) {
        openDashboard()
        guard runtime.running, let id = sender.representedObject as? String else { return }
        runtime.perform { try await self.runtime.inspect("/containers/" + id + "/json") }
    }
    private func operate(_ action: @escaping @MainActor () async throws -> Void) {
        guard canOperate else { NSSound.beep(); return }
        actionInFlight = true
        Task {
            defer { actionInFlight = false }
            do { try await action() }
            catch { runtime.presentOperationError(error); if runtime.error != nil { openDashboard() } }
        }
    }
    @objc private func startVM() { guard !runtime.running else { return }; operate { try await self.runtime.start() } }
    @objc private func stopVM() { guard runtime.running else { return }; operate { try await self.runtime.stop() } }
    @objc private func restartVM() { guard runtime.running else { return }; operate { try await self.runtime.restart() } }
    @objc private func checkAppUpdates() { AppUpdateController.shared.check() }
    @objc private func quitApp() { guard canOperate && !runtime.backupInProgress else { return }; NSApp.terminate(nil) }
}
