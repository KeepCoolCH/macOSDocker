import SwiftUI
import AppKit
import Combine

@main
struct macOSDockerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .appSettings) {}
                LanguageCommands(language: delegate.language)
                AppUpdateCommands()
            }
    }
}

struct LanguageCommands: Commands {
    @ObservedObject var language: AppLanguage
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Menu(String(localized: "Sprache")) {
                Picker(String(localized: "Sprache"), selection: Binding(get: { language.selection }, set: { language.select($0) })) {
                    Text(String(localized: "Systemsprache verwenden")).tag("system")
                    Text(verbatim: "Deutsch").tag("de")
                    Text(verbatim: "English").tag("en")
                }.pickerStyle(.inline)
            }
        }
    }
}

private struct DashboardRoot: View {
    let runtime: RuntimeManager
    @ObservedObject var language: AppLanguage
    var body: some View {
        ContentView().environmentObject(runtime)
            .alert(String(localized: "Sprache gespeichert"), isPresented: $language.restartRequired) {
                Button(String(localized: "OK"), role: .cancel) { }
            } message: {
                Text(String(localized: "Die neue Sprache wird beim nächsten App-Start verwendet. Bitte die App beenden und erneut öffnen. Dabei wird auch die VM gestoppt und wieder gestartet."))
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let runtime = RuntimeManager()
    let language = AppLanguage()
    private var statusController: MenuBarController?
    private var dashboard: NSWindow?
    private var errorSubscription: AnyCancellable?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier {
            let current = NSRunningApplication.current
            let oldest = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { !$0.isTerminated }
                .sorted { ($0.launchDate ?? .distantFuture, $0.processIdentifier) < ($1.launchDate ?? .distantFuture, $1.processIdentifier) }
                .first
            if let oldest, oldest.processIdentifier != current.processIdentifier {
                if let url = oldest.bundleURL {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                }
                NSApp.terminate(nil)
                return
            }
        }
        statusController = MenuBarController(runtime: runtime) { [weak self] in self?.showDashboard() }
        errorSubscription = runtime.$error.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.showDashboard()
        }
        AppUpdateController.shared.start()
        runtime.backups.startScheduler()
        showDashboard()
        runtime.perform { try await self.runtime.startOnLaunch() }
    }

    func showDashboard() {
        NSApp.setActivationPolicy(.regular)
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "macOSDocker"
            window.identifier = NSUserInterfaceItemIdentifier("com.macOSDocker.dashboard")
            window.setFrameAutosaveName("macOSDocker.dashboard")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: DashboardRoot(runtime: runtime, language: language))
            window.minSize = NSSize(width: 1050, height: 650)
            if !window.setFrameUsingName("macOSDocker.dashboard") { window.center() }
            dashboard = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.deminiaturize(nil)
        dashboard?.makeKeyAndOrderFront(nil)
        runtime.dashboardVisible = true
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === dashboard else { return }
        runtime.dashboardVisible = false
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        if runtime.commandRunning { runtime.error = String(localized: "Bitte die CLI-Ausführung beenden oder unter Befehle abbrechen, bevor die App geschlossen wird."); showDashboard(); return .terminateCancel }
        if runtime.busy || runtime.engineMaintenance || runtime.backupInProgress { runtime.error = String(localized: "Bitte den laufenden VM-Vorgang abwarten, bevor die App beendet wird."); showDashboard(); return .terminateCancel }
        guard runtime.running else { return .terminateNow }
        terminating = true
        statusController?.setTerminating(true)
        Task {
            do { try await runtime.stop(); sender.reply(toApplicationShouldTerminate: true) }
            catch { terminating = false; statusController?.setTerminating(false); runtime.error = error.localizedDescription; showDashboard(); sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
}
