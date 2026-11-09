import AppKit
import Combine

@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()
    static let feedURL = URL(string: "https://kevintobler.ch/files/updates/macosdocker.json")!
    @Published private(set) var checking = false
    @Published private(set) var available: AppUpdate?
    @Published private(set) var message = ""
    @Published private(set) var lastChecked: Date?
    @Published var automaticChecks: Bool {
        didSet {
            defaults.set(automaticChecks, forKey: "AppUpdateAutomaticChecks")
            if automaticChecks { checkIfDue() }
        }
    }
    private let defaults: UserDefaults
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var notifyWhenFinished = false
    private var installedBuild: Int? { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticChecks = defaults.bool(forKey: "AppUpdateAutomaticChecks")
        lastChecked = defaults.object(forKey: "AppUpdateLastChecked") as? Date
    }

    func start() {
        guard timer == nil else { return }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard automaticChecks else { return }
        let last = defaults.object(forKey: "AppUpdateLastAttempt") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 86400 else { return }
        check(manual: false)
    }

    func check(manual: Bool = true) {
        if checking {
            notifyWhenFinished = notifyWhenFinished || manual
            return
        }
        checking = true
        notifyWhenFinished = manual
        message = String(localized: "App-Updates werden gesucht …")
        defaults.set(Date(), forKey: "AppUpdateLastAttempt")
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.checking = false; self.task = nil }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 25
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                guard let installedBuild, installedBuild > 0 else { throw AppFailure(message: String(localized: "Die installierte Buildnummer ist ungültig.")) }
                let update = try await AppUpdate.fetch(from: Self.feedURL, session: session)
                let checked = Date()
                lastChecked = checked
                defaults.set(checked, forKey: "AppUpdateLastChecked")
                if update.build > installedBuild {
                    available = update
                    message = String(localized: "Version \(update.version) (Build \(update.build)) ist verfügbar.")
                    if notifyWhenFinished || defaults.integer(forKey: "AppUpdateLastNotifiedBuild") < update.build {
                        defaults.set(update.build, forKey: "AppUpdateLastNotifiedBuild")
                        presentAvailable(update)
                    }
                } else {
                    available = nil
                    message = String(localized: "macOSDocker ist aktuell.")
                    if notifyWhenFinished { presentMessage(title: String(localized: "Keine neue App-Version"), text: message) }
                }
            } catch {
                message = String(localized: "App-Updateprüfung fehlgeschlagen: ") + error.localizedDescription
                if notifyWhenFinished { presentMessage(title: String(localized: "Updateprüfung fehlgeschlagen"), text: message) }
            }
        }
    }

    func openAvailableDownload() {
        guard let available else { return }
        NSWorkspace.shared.open(available.downloadURL)
    }

    private func presentAvailable(_ update: AppUpdate) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Neue App-Version verfügbar")
        alert.informativeText = String(localized: "Version \(update.version) (Build \(update.build)) kann heruntergeladen werden. Der Download wird im Browser geöffnet. Die Installation erfolgt manuell; die laufende VM wird nicht unterbrochen.")
        alert.addButton(withTitle: String(localized: "Download öffnen"))
        alert.addButton(withTitle: String(localized: "Später"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(update.downloadURL) }
    }

    private func presentMessage(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
